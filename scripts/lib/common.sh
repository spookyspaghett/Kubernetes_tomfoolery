#!/bin/bash
# Shared setup steps for master_startup.sh and worker_startup.sh.
# Source this file; do not execute it directly.

# ---- Configuration (override any of these via environment variables) ----
CRI_SOCKET="${CRI_SOCKET:-unix:///run/containerd/containerd.sock}"
K8S_VERSION="${K8S_VERSION:-v1.29}"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.9}"
CLUSTER_SUBNET="${CLUSTER_SUBNET:-10.0.0.}"
IFACE="${IFACE:-enp0s8}"
GATEWAY="${GATEWAY:-${CLUSTER_SUBNET}1}"
PREFIX_LEN="${PREFIX_LEN:-24}"
# Nodes claim their address from this range (last octet), outside normal DHCP use.
STATIC_FIRST="${STATIC_FIRST:-3}"
STATIC_LAST="${STATIC_LAST:-19}"

NETPLAN_FILE="/etc/netplan/60-k8s-static.yaml"

LEGACY_CRI_SOCKET="unix:///var/run/cri-dockerd.sock"

export DEBIAN_FRONTEND=noninteractive

die() {
    echo "❌ $*" >&2
    exit 1
}

banner() {
    echo "========================================"
    echo " $*"
    echo "========================================"
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Run this script as root (sudo $0)"
}

# wait_for <timeout-seconds> <description> <command...>
wait_for() {
    local timeout="$1" desc="$2"
    shift 2
    local deadline=$((SECONDS + timeout))
    until "$@" >/dev/null 2>&1; do
        ((SECONDS < deadline)) || die "Timed out after ${timeout}s waiting for ${desc}"
        sleep 3
    done
}

# ---- Static IP claiming ----
# The VLAN's DHCP pool can't give stable addresses, so each node claims a free
# address in ${CLUSTER_SUBNET}${STATIC_FIRST}-${STATIC_LAST} and pins it with netplan.

ensure_network_tools() {
    command -v arping >/dev/null && command -v nc >/dev/null && command -v curl >/dev/null && return 0
    echo "📦 Installing network tools..."
    apt-get update
    apt-get install -y iputils-arping netcat-openbsd curl
}

# ARP duplicate-address probe: succeeds if some host answers for the IP.
# Unlike ping, hosts can't ignore ARP, so firewalled machines are still seen.
ip_in_use() {
    ! arping -D -q -c 2 -w 3 -I "$IFACE" "$1" >/dev/null 2>&1
}

# Prints the address this script pinned on a previous run, if still active.
configured_static_ip() {
    [[ -f "$NETPLAN_FILE" ]] || return 1
    local ip
    ip="$(grep -oE "${CLUSTER_SUBNET//./\\.}[0-9]+/" "$NETPLAN_FILE" | head -n1 | tr -d /)"
    [[ -n "$ip" ]] && ip -4 -o addr show "$IFACE" | grep -q " ${ip}/" || return 1
    echo "$ip"
}

# find_free_ip [ip-to-skip...]
find_free_ip() {
    local octet ip skip
    for ((octet = STATIC_FIRST; octet <= STATIC_LAST; octet++)); do
        ip="${CLUSTER_SUBNET}${octet}"
        for skip in "$@"; do
            [[ "$ip" == "$skip" ]] && continue 2
        done
        if ! ip_in_use "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

apply_static_ip() {
    local ip="$1" ssh_ip dns route_line="" dns_line=""

    # Switching address cuts off an SSH session that uses the old one, which
    # would kill this script halfway. tmux/screen sessions survive that.
    if [[ -n "${SSH_CONNECTION:-}" && -z "${TMUX:-}${STY:-}" ]]; then
        ssh_ip="$(awk '{print $3}' <<<"$SSH_CONNECTION")"
        if ip -4 -o addr show "$IFACE" | grep -q " ${ssh_ip}/"; then
            die "Changing $IFACE to $ip would drop this SSH session. Run from the VM console or inside tmux."
        fi
    fi

    # Keep the default route and DNS on this NIC if DHCP had put them here.
    if [[ -n "$(ip -4 route show default dev "$IFACE" 2>/dev/null)" ]]; then
        route_line="      routes: [{to: default, via: ${GATEWAY}}]"
        dns="$(resolvectl dns "$IFACE" 2>/dev/null | cut -d: -f2- | xargs | tr ' ' ',')"
        dns_line="      nameservers: {addresses: [${dns:-$GATEWAY}]}"
    fi

    echo "🔧 Pinning $IFACE to ${ip}/${PREFIX_LEN}..."
    cat >"$NETPLAN_FILE" <<EOF
# Written by Kubernetes setup scripts: static cluster address.
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses: [${ip}/${PREFIX_LEN}]
${route_line}
${dns_line}
EOF
    chmod 600 "$NETPLAN_FILE"
    netplan apply

    wait_for 30 "$ip on $IFACE" bash -c "ip -4 -o addr show '$IFACE' | grep -q ' ${ip}/'"

    # Drop any leftover DHCP lease so Flannel/kubelet only see the static IP.
    local old
    for old in $(ip -4 -o addr show "$IFACE" | awk '{print $4}'); do
        [[ "$old" == "${ip}/"* ]] || ip addr del "$old" dev "$IFACE" || true
    done

    # Catch a race with another node that probed at the same moment.
    if ip_in_use "$ip"; then
        die "Another host also answers for $ip. Remove $NETPLAN_FILE and re-run."
    fi
}

# ensure_static_ip [ip-to-skip...]: sets NODE_IP to this node's pinned address,
# claiming the first free one in the static range if it has none yet.
ensure_static_ip() {
    ensure_network_tools
    if NODE_IP="$(configured_static_ip)"; then
        echo "✅ Keeping static IP $NODE_IP"
        return 0
    fi
    echo "🔍 Probing ${CLUSTER_SUBNET}${STATIC_FIRST}-${STATIC_LAST} for a free address..."
    NODE_IP="$(find_free_ip "$@")" ||
        die "No free address in ${CLUSTER_SUBNET}${STATIC_FIRST}-${STATIC_LAST}"
    apply_static_ip "$NODE_IP"
    echo "✅ Claimed $NODE_IP"
}

# Prints the first address in the static range that serves the Kubernetes API.
find_master() {
    local octet ip
    for ((octet = STATIC_FIRST; octet <= STATIC_LAST; octet++)); do
        ip="${CLUSTER_SUBNET}${octet}"
        nc -z -w 1 "$ip" 6443 >/dev/null 2>&1 || continue
        if curl -sk --max-time 3 "https://${ip}:6443/version" | grep -q '"gitVersion"'; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

set_hostname() {
    local name="$1" ip="$2"
    hostnamectl set-hostname "$name"
    # Keep the new hostname resolvable so sudo/kubelet don't complain.
    sed -i "/[[:space:]]${name}\$/d" /etc/hosts
    echo "${ip} ${name}" >>/etc/hosts
}

# Nodes built by older versions of these scripts ran Kubernetes on
# Docker + cri-dockerd. Tear that down so its containers don't keep holding
# ports (6443, 2379, 10250...) and kubeadm only sees the containerd socket.
remove_legacy_docker_runtime() {
    [[ -e /etc/systemd/system/cri-docker.service || -x /usr/local/bin/cri-dockerd ]] || return 0

    echo "🧹 Removing legacy Docker + cri-dockerd runtime..."
    if command -v kubeadm >/dev/null 2>&1; then
        kubeadm reset -f --cri-socket "$LEGACY_CRI_SOCKET" || true
    fi
    systemctl disable --now cri-docker.service cri-docker.socket 2>/dev/null || true
    rm -f /etc/systemd/system/cri-docker.service /etc/systemd/system/cri-docker.socket \
        /usr/local/bin/cri-dockerd
    # Stopping Docker also stops any leftover Kubernetes containers it ran.
    systemctl disable --now docker.service docker.socket 2>/dev/null || true
    systemctl daemon-reload
}

reset_k8s_state() {
    remove_legacy_docker_runtime

    echo "🧹 Resetting previous Kubernetes state..."
    if command -v kubeadm >/dev/null 2>&1; then
        kubeadm reset -f --cri-socket "$CRI_SOCKET" || true
    fi
    systemctl stop kubelet 2>/dev/null || true

    rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet/* /etc/cni/net.d /var/lib/cni

    ip link delete cni0 2>/dev/null || true
    ip link delete flannel.1 2>/dev/null || true
}

disable_swap() {
    echo "🔧 Disabling swap..."
    swapoff -a
    sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab
}

configure_kernel() {
    echo "🔧 Configuring kernel networking..."
    cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
    modprobe overlay
    modprobe br_netfilter

    cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
    sysctl --system >/dev/null
}

install_dependencies() {
    echo "📦 Installing dependencies..."
    apt-get update
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        conntrack \
        iptables \
        netcat-openbsd \
        containerd
}

configure_containerd() {
    echo "📦 Configuring containerd..."
    mkdir -p /etc/containerd
    # Start from the defaults, then switch to the systemd cgroup driver (which
    # kubelet uses) and pin the pause image to the one kubeadm expects.
    # The sandbox_image/sandbox patterns cover containerd 1.x and 2.x configs.
    containerd config default |
        sed -E \
            -e 's/SystemdCgroup = false/SystemdCgroup = true/' \
            -e "s|^([[:space:]]*sandbox(_image)? = ).*|\1\"${PAUSE_IMAGE}\"|" \
            >/etc/containerd/config.toml

    grep -q 'SystemdCgroup = true' /etc/containerd/config.toml ||
        die "Could not enable SystemdCgroup in /etc/containerd/config.toml"

    systemctl enable containerd
    systemctl restart containerd
}

install_kube_packages() {
    echo "🔑 Installing Kubernetes ${K8S_VERSION} packages..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL --retry 5 --retry-delay 3 \
        "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" |
        gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /
EOF

    # kubeadm pulls in cri-tools (crictl) and kubernetes-cni (/opt/cni/bin).
    apt-get update
    apt-get install -y --allow-change-held-packages kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
}

wait_for_cri() {
    # Default endpoint so plain `crictl ps` works without flags.
    cat >/etc/crictl.yaml <<EOF
runtime-endpoint: ${CRI_SOCKET}
image-endpoint: ${CRI_SOCKET}
EOF

    echo "⏳ Waiting for containerd CRI..."
    wait_for 60 "containerd" crictl info
    echo "✅ containerd ready"
}

configure_kubelet() {
    local node_ip="$1"
    echo "⚙️ Configuring kubelet (node-ip ${node_ip})..."
    echo "KUBELET_EXTRA_ARGS=--node-ip=${node_ip}" >/etc/default/kubelet
    systemctl daemon-reload
    systemctl enable kubelet
}

# Everything both node types need before kubeadm init/join.
prepare_node() {
    local node_ip="$1"
    reset_k8s_state
    disable_swap
    configure_kernel
    install_dependencies
    configure_containerd
    install_kube_packages
    wait_for_cri
    configure_kubelet "$node_ip"
}
