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

MASTER_USER="${MASTER_USER:-kubernetes_master}"

require_root
banner "Kubernetes Worker Setup"

ensure_static_ip "$MASTER_IP"

# .4 -> worker1, .5 -> worker2, ... (relative to the start of the static range)
HOSTNAME_VALUE="${WORKER_NAME:-worker$((${NODE_IP##*.} - STATIC_FIRST))}"

echo "✅ Worker IP: $NODE_IP"
echo "✅ Hostname: $HOSTNAME_VALUE"

echo "🔧 Setting hostname..."
set_hostname "$HOSTNAME_VALUE" "$NODE_IP"

prepare_node "$NODE_IP"

# Run ssh as the user who invoked sudo so their SSH keys are used.
SSH_USER="${SUDO_USER:-root}"
SSH_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"
SSH_KEY="${SSH_KEY:-$SSH_HOME/.ssh/kubernetes_worker}"

as_ssh_user() {
    if [[ "$SSH_USER" != "root" ]]; then
        sudo -u "$SSH_USER" -- "$@"
    else
        "$@"
    fi
}

master_ssh() {
    as_ssh_user ssh -i "$SSH_KEY" -o IdentitiesOnly=yes "${MASTER_USER}@${MASTER_IP}" "$@"
}

echo "⏳ Waiting for master API at ${MASTER_IP}:6443..."
wait_for 600 "the master API server" nc -z "$MASTER_IP" 6443

echo "🔐 Setting up SSH access to master..."
if [[ ! -f "$SSH_KEY" ]]; then
    echo "🔑 Generating SSH key $SSH_KEY"
    as_ssh_user mkdir -p -m 700 "$(dirname "$SSH_KEY")"
    as_ssh_user ssh-keygen -q -t ed25519 -N "" -f "$SSH_KEY"
fi
if ! master_ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new true 2>/dev/null; then
    echo "📤 Installing key on master (enter ${MASTER_USER}'s password once)..."
    as_ssh_user ssh-copy-id -i "${SSH_KEY}.pub" -o StrictHostKeyChecking=accept-new \
        "${MASTER_USER}@${MASTER_IP}" ||
        die "Could not copy SSH key to ${MASTER_USER}@${MASTER_IP}"
fi
if ! master_ssh -o BatchMode=yes "sudo -n kubeadm version" >/dev/null 2>&1; then
    echo "🛡️  Allowing ${MASTER_USER} to run kubeadm without a sudo password (enter it once)..."
    SUDOERS_FILE="/etc/sudoers.d/kubeadm-join"
    SUDOERS_LINE="${MASTER_USER} ALL=(root) NOPASSWD: /usr/bin/kubeadm"
    # -t gives sudo a terminal so it can prompt; the tmp file is validated before install.
    master_ssh -t "sudo sh -c 'echo \"${SUDOERS_LINE}\" > ${SUDOERS_FILE}.tmp && visudo -cf ${SUDOERS_FILE}.tmp && chmod 440 ${SUDOERS_FILE}.tmp && mv ${SUDOERS_FILE}.tmp ${SUDOERS_FILE}'" ||
        die "Could not configure sudo on ${MASTER_IP}"
fi

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
