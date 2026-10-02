#!/bin/bash
# Shared setup steps for master_startup.sh and worker_startup.sh.
# Source this file; do not execute it directly.

# ---- Configuration (override any of these via environment variables) ----
CRI_SOCKET="${CRI_SOCKET:-unix:///run/containerd/containerd.sock}"
K8S_VERSION="${K8S_VERSION:-v1.29}"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.9}"
CLUSTER_SUBNET="${CLUSTER_SUBNET:-192.168.10.}"
IFACE="${IFACE:-enp0s8}"

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

# Prints the IPv4 address of $IFACE and checks it is on the cluster subnet.
detect_node_ip() {
    local ip
    ip="$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    [[ -n "$ip" ]] || die "Could not find IPv4 address on $IFACE"
    [[ "$ip" == "${CLUSTER_SUBNET}"* ]] || die "Wrong network detected on $IFACE: $ip (expected ${CLUSTER_SUBNET}x)"
    echo "$ip"
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
