#!/bin/bash
# Shared helpers for the showcase demos. Source this file; do not execute it.
#
# Environment:
#   DEMO_AUTO=1   don't wait for Enter between steps (just pause briefly)

if [[ -z "${KUBECONFIG:-}" && ! -r "$HOME/.kube/config" && -r /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
fi

BOLD=$'\e[1m'
CYAN=$'\e[36m'
YELLOW=$'\e[33m'
RESET=$'\e[0m'

die() {
    echo "❌ $*" >&2
    exit 1
}

# title <text>: big banner at the start of a demo.
title() {
    echo
    echo "${BOLD}========================================${RESET}"
    echo "${BOLD} $*${RESET}"
    echo "${BOLD}========================================${RESET}"
}

# step <text>: announces what the next command is about to show.
step() {
    echo
    echo "${CYAN}▶ $*${RESET}"
}

# run <command string>: prints the command, then runs it.
run() {
    echo "${YELLOW}\$ $*${RESET}"
    eval "$*"
}

# pause: wait for Enter so the presenter can talk (skipped with DEMO_AUTO=1 or no TTY).
pause() {
    if [[ -n "${DEMO_AUTO:-}" || ! -t 0 ]]; then
        sleep 2
    else
        read -rp "${BOLD}   ⏎  press Enter to continue...${RESET}" _
    fi
}

require_cluster() {
    command -v kubectl >/dev/null || die "kubectl not found (run this on the master)"
    kubectl cluster-info >/dev/null 2>&1 || die "Cannot reach the API server (KUBECONFIG=${KUBECONFIG:-default})"
}

# require_workers: demos that move pods around need at least one worker.
require_workers() {
    local n
    n="$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' | wc -l)"
    [[ "$n" -ge 1 ]] || die "No worker nodes found. Join a worker first (scripts/worker_startup.sh)"
}

first_worker() {
    kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o custom-columns=NAME:.metadata.name | head -n1
}

# node_ip: address of the first node, used for NodePort URLs.
node_ip() {
    kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}

# ensure_metrics_server: installs metrics-server (patched for kubeadm's self-signed kubelet certs).
ensure_metrics_server() {
    if ! kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
        step "Installing metrics-server"
        run "kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
        run "kubectl -n kube-system patch deploy metrics-server --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--kubelet-insecure-tls\"}]'"
    fi
    kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s || die "metrics-server did not become ready"
    echo "⏳ Waiting for the first metrics..."
    local deadline=$((SECONDS + 120))
    until kubectl top nodes >/dev/null 2>&1; do
        ((SECONDS < deadline)) || die "metrics-server has no data after 120s"
        sleep 5
    done
}

# ensure_helm: installs helm using the official installer if missing.
ensure_helm() {
    command -v helm >/dev/null && return 0
    step "Installing helm"
    run "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    command -v helm >/dev/null || die "helm installation failed"
}

# parse_cleanup_flag "$@": if --cleanup was passed, calls cleanup() and exits.
parse_cleanup_flag() {
    if [[ "${1:-}" == "--cleanup" ]]; then
        cleanup
        exit 0
    fi
}
