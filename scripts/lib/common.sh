#!/bin/bash
# Shared setup steps for master_startup.sh and worker_startup.sh.
# Source this file; do not execute it directly.

# ---- Configuration (override any of these via environment variables) ----
CRI_SOCKET="${CRI_SOCKET:-unix:///var/run/cri-dockerd.sock}"
K8S_VERSION="${K8S_VERSION:-v1.29}"
CRICTL_VERSION="${CRICTL_VERSION:-v1.29.0}"
CRIDOCKERD_VERSION="${CRIDOCKERD_VERSION:-0.3.15}"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.9}"
CLUSTER_SUBNET="${CLUSTER_SUBNET:-192.168.10.}"
IFACE="${IFACE:-enp0s8}"

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

reset_k8s_state() {
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
        jq \
        netcat-openbsd \
        docker.io \
        containernetworking-plugins
}

configure_docker() {
    echo "🐳 Configuring Docker..."
    mkdir -p /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
    systemctl enable docker
    systemctl restart docker
}

install_cri_dockerd() {
    echo "🔌 Installing cri-dockerd ${CRIDOCKERD_VERSION}..."
    local tmp tarball="cri-dockerd-${CRIDOCKERD_VERSION}.amd64.tgz"
    tmp="$(mktemp -d)"
    curl -fsSL --retry 5 --retry-delay 3 -o "$tmp/$tarball" \
        "https://github.com/Mirantis/cri-dockerd/releases/download/v${CRIDOCKERD_VERSION}/${tarball}"
    tar -xzf "$tmp/$tarball" -C "$tmp"
    install -m 0755 "$tmp/cri-dockerd/cri-dockerd" /usr/local/bin/cri-dockerd
    rm -rf "$tmp"

    echo "🧩 Creating cri-dockerd systemd units..."
    cat >/etc/systemd/system/cri-docker.service <<EOF
[Unit]
Description=CRI Interface for Docker
After=network-online.target firewalld.service docker.service
Wants=network-online.target
Requires=docker.service cri-docker.socket

[Service]
Type=notify
ExecStart=/usr/local/bin/cri-dockerd --container-runtime-endpoint fd:// --network-plugin=cni --pod-infra-container-image=${PAUSE_IMAGE}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat >/etc/systemd/system/cri-docker.socket <<'EOF'
[Unit]
Description=CRI Docker Socket
PartOf=cri-docker.service

[Socket]
ListenStream=/var/run/cri-dockerd.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF

    systemctl daemon-reload
    systemctl enable --now cri-docker.socket
    systemctl enable cri-docker.service
    systemctl restart cri-docker.service
}

install_crictl() {
    echo "📦 Installing crictl ${CRICTL_VERSION}..."
    local tmp tarball="crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
    tmp="$(mktemp -d)"
    curl -fsSL --retry 5 --retry-delay 3 -o "$tmp/$tarball" \
        "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${tarball}"
    tar -C /usr/local/bin -xzf "$tmp/$tarball"
    rm -rf "$tmp"

    # Default endpoint so plain `crictl ps` works without flags.
    cat >/etc/crictl.yaml <<EOF
runtime-endpoint: ${CRI_SOCKET}
image-endpoint: ${CRI_SOCKET}
EOF

    echo "⏳ Waiting for CRI..."
    wait_for 60 "cri-dockerd" crictl --runtime-endpoint="$CRI_SOCKET" info
    echo "✅ cri-dockerd ready"
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

    apt-get update
    apt-get install -y --allow-change-held-packages kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
}

install_cni_binaries() {
    echo "🔧 Installing CNI binaries..."
    mkdir -p /opt/cni/bin
    cp -f /usr/lib/cni/* /opt/cni/bin/
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
    configure_docker
    install_cri_dockerd
    install_crictl
    install_kube_packages
    install_cni_binaries
    configure_kubelet "$node_ip"
}
