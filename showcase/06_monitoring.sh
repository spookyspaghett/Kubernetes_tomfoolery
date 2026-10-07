#!/bin/bash
# Demo 6: Prometheus + Grafana monitoring stack (heavy: ~2 GB RAM per node recommended).
# Run: ./showcase/06_monitoring.sh   (cleanup: --cleanup)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NS=monitoring
PORT=30300
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"

cleanup() {
    helm uninstall kps -n "$NS" 2>/dev/null
    kubectl delete ns "$NS" --ignore-not-found --wait=false
}
parse_cleanup_flag "${1:-}"

require_cluster
require_workers
IP="$(node_ip)"

title "Demo 6: Prometheus + Grafana"
echo "⚠️  This stack is large. Expect the install to take several minutes on small VMs."

ensure_helm

step "Install kube-prometheus-stack"
run "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update"
run "helm repo update"
# etcd/scheduler/controller-manager/kube-proxy metrics listen on localhost in a
# default kubeadm cluster, so their scrape targets would show as down. Disable them.
run "helm upgrade --install kps prometheus-community/kube-prometheus-stack -n $NS --create-namespace \
    --set grafana.service.type=NodePort \
    --set grafana.service.nodePort=$PORT \
    --set grafana.adminPassword=$GRAFANA_PASSWORD \
    --set kubeEtcd.enabled=false \
    --set kubeScheduler.enabled=false \
    --set kubeControllerManager.enabled=false \
    --set kubeProxy.enabled=false \
    --set prometheus.prometheusSpec.resources.requests.memory=400Mi \
    --wait --timeout 15m"
run "kubectl -n $NS get pods -o wide"

echo
echo "✅ Monitoring ready"
echo "   Grafana: http://$IP:$PORT   (user: admin, password: $GRAFANA_PASSWORD)"
echo "   Open the dashboards 'Kubernetes / Compute Resources / Node (Pods)' and 'Node Exporter / Nodes'."
echo "💡 Run demo 04 (autoscale) now and watch CPU climb across the cluster."
echo "   Remove with: ./showcase/06_monitoring.sh --cleanup"
