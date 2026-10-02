#!/bin/bash
# Sets up the Kubernetes control-plane node. Run with: sudo ./master_startup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MASTER_HOSTNAME="${MASTER_HOSTNAME:-master}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
FLANNEL_MANIFEST="${FLANNEL_MANIFEST:-https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml}"

require_root
banner "Kubernetes Master Setup"

claim_ip "$MASTER_IP"
echo "✅ Master IP: $MASTER_IP"

echo "🔧 Setting hostname to $MASTER_HOSTNAME..."
set_hostname "$MASTER_HOSTNAME" "$MASTER_IP"

prepare_node "$MASTER_IP"

echo "🚀 Initializing Kubernetes..."
kubeadm init \
    --apiserver-advertise-address="$MASTER_IP" \
    --pod-network-cidr="$POD_CIDR" \
    --cri-socket="$CRI_SOCKET"

export KUBECONFIG=/etc/kubernetes/admin.conf

echo "⚙️ Configuring kubectl..."
install_kubeconfig() {
    local user="$1" home
    home="$(getent passwd "$user" | cut -d: -f6)"
    rm -rf "$home/.kube"
    mkdir -p "$home/.kube"
    cp /etc/kubernetes/admin.conf "$home/.kube/config"
    chown -R "$(id -u "$user"):$(id -g "$user")" "$home/.kube"
}
install_kubeconfig root
# Also give the user who invoked sudo a working kubectl.
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    install_kubeconfig "$SUDO_USER"
fi

echo "⏳ Waiting for API server..."
wait_for 180 "the API server" kubectl get nodes

echo "🌐 Installing Flannel..."
kubectl apply -f "$FLANNEL_MANIFEST"

# Flannel reads its flags from FLANNELD_* env vars. Without this it picks the
# interface with the default route (the VirtualBox NAT adapter), which breaks
# cross-node pod networking.
echo "🔧 Pinning Flannel to interface $IFACE..."
kubectl -n kube-flannel set env daemonset/kube-flannel-ds FLANNELD_IFACE="$IFACE"

echo "⏳ Waiting for Flannel..."
kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=180s

echo "⏳ Waiting for node to become Ready..."
kubectl wait --for=condition=Ready "node/$MASTER_HOSTNAME" --timeout=180s

echo
banner "Master setup complete"
kubectl get nodes -o wide
kubectl get pods -A

echo
echo "Workers can now run: sudo ./worker_startup.sh"
