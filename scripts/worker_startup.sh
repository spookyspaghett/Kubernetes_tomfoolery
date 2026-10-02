#!/bin/bash
# Sets up a Kubernetes worker node and joins it to the cluster.
# Run with: sudo ./worker_startup.sh
#
# The join command is fetched from the master over SSH, so the invoking user
# (SUDO_USER, or root) needs key-based SSH access to MASTER_USER@MASTER_IP,
# and MASTER_USER needs passwordless sudo on the master.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MASTER_IP="${MASTER_IP:-192.168.10.3}"
MASTER_USER="${MASTER_USER:-osboxes}"

require_root
banner "Kubernetes Worker Setup"

echo "🔍 Detecting node IP..."
NODE_IP="$(detect_node_ip)"

case "$NODE_IP" in
    192.168.10.4) HOSTNAME_VALUE="worker1" ;;
    192.168.10.5) HOSTNAME_VALUE="worker2" ;;
    192.168.10.6) HOSTNAME_VALUE="worker3" ;;
    *) die "Unknown worker IP: $NODE_IP" ;;
esac

echo "✅ Worker IP: $NODE_IP"
echo "✅ Hostname: $HOSTNAME_VALUE"

echo "🔧 Setting hostname..."
set_hostname "$HOSTNAME_VALUE" "$NODE_IP"

prepare_node "$NODE_IP"

# Run ssh as the user who invoked sudo so their SSH keys are used.
master_ssh() {
    local -a cmd=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
        "${MASTER_USER}@${MASTER_IP}" "$@")
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        sudo -u "$SUDO_USER" -- "${cmd[@]}"
    else
        "${cmd[@]}"
    fi
}

echo "⏳ Waiting for master API at ${MASTER_IP}:6443..."
wait_for 600 "the master API server" nc -z "$MASTER_IP" 6443

echo "🔐 Testing SSH access to master..."
master_ssh "sudo -n true" ||
    die "Cannot SSH to ${MASTER_USER}@${MASTER_IP} with passwordless sudo (set up keys with ssh-copy-id)"

echo "🔑 Getting fresh join command from master..."
JOIN_COMMAND="$(master_ssh "sudo -n kubeadm token create --print-join-command")"

[[ "$JOIN_COMMAND" == "kubeadm join "* ]] || die "Unexpected join command from master: '$JOIN_COMMAND'"

echo "🚀 Joining cluster..."
read -ra JOIN_ARGS <<<"$JOIN_COMMAND"
"${JOIN_ARGS[@]}" --cri-socket "$CRI_SOCKET"

echo
banner "Worker setup complete"
echo "Hostname: $HOSTNAME_VALUE"
echo "Node IP:  $NODE_IP"
echo
echo "Check from the master:"
echo "kubectl get nodes -o wide"
