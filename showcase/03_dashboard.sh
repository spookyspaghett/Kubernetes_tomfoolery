#!/bin/bash
# Demo 3: live dashboard (Headlamp) plus metrics-server so `kubectl top` works.
# Run: ./showcase/03_dashboard.sh   (cleanup: --cleanup)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PORT=30090
HEADLAMP_MANIFEST="${HEADLAMP_MANIFEST:-https://raw.githubusercontent.com/kubernetes-sigs/headlamp/main/kubernetes-headlamp.yaml}"

cleanup() {
    kubectl delete -f "$HEADLAMP_MANIFEST" --ignore-not-found
    kubectl -n kube-system delete serviceaccount headlamp-admin --ignore-not-found
    kubectl delete clusterrolebinding headlamp-admin --ignore-not-found
    kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml --ignore-not-found
}
parse_cleanup_flag "${1:-}"

require_cluster
IP="$(node_ip)"

title "Demo 3: live cluster dashboard"

ensure_metrics_server
step "Resource usage per node and pod, straight from the terminal"
run "kubectl top nodes"
run "kubectl top pods -A --sort-by=memory | head -n 8"
pause

step "Install Headlamp (web dashboard)"
run "kubectl apply -f $HEADLAMP_MANIFEST"
run "kubectl -n kube-system patch svc headlamp --type=merge -p '{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":80,\"targetPort\":4466,\"nodePort\":$PORT}]}}'"
kubectl -n kube-system create serviceaccount headlamp-admin >/dev/null 2>&1
kubectl create clusterrolebinding headlamp-admin --clusterrole=cluster-admin \
    --serviceaccount=kube-system:headlamp-admin >/dev/null 2>&1
run "kubectl -n kube-system rollout status deploy/headlamp --timeout=180s"

TOKEN="$(kubectl -n kube-system create token headlamp-admin --duration=24h)"
echo
echo "✅ Dashboard ready"
echo "   URL:   http://$IP:$PORT"
echo "   Token (valid 24h, paste it on the login page):"
echo
echo "$TOKEN"
echo
echo "💡 Tip: run demos 01, 02 or 04 with the dashboard open to watch pods move live."
echo "   Remove with: ./showcase/03_dashboard.sh --cleanup"
