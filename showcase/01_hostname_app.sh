#!/bin/bash
# Demo 1: load balancing, scaling, self-healing and draining a node.
# Run: ./showcase/01_hostname_app.sh   (cleanup: --cleanup)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NS=showcase-hostname
PORT=30081

cleanup() {
    kubectl uncordon "$(first_worker)" >/dev/null 2>&1
    kubectl delete ns "$NS" --ignore-not-found --wait=false
}
parse_cleanup_flag "${1:-}"

require_cluster
require_workers
IP="$(node_ip)"

# hits <n>: curl the service n times and count how many requests each pod answered.
hits() {
    for _ in $(seq 1 "${1:-20}"); do
        curl -s --max-time 5 "http://$IP:$PORT" | awk '/^Hostname/ {print $2}'
    done | sort | uniq -c
}

title "Demo 1: a web app that tells you which pod answered"

step "Deploy 3 replicas of a tiny app that prints its own pod name"
kubectl create ns "$NS" >/dev/null 2>&1
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: whoami}
spec:
  replicas: 3
  selector: {matchLabels: {app: whoami}}
  template:
    metadata: {labels: {app: whoami}}
    spec:
      containers:
        - name: whoami
          image: traefik/whoami
          ports: [{containerPort: 80}]
          readinessProbe: {httpGet: {path: /, port: 80}}
---
apiVersion: v1
kind: Service
metadata: {name: whoami}
spec:
  type: NodePort
  selector: {app: whoami}
  ports: [{port: 80, nodePort: $PORT}]
YAML
run "kubectl -n $NS rollout status deploy/whoami"
run "kubectl -n $NS get pods -o wide"
echo "🌐 App URL: http://$IP:$PORT (open it in a browser and refresh)"
pause

step "Send 20 requests: traffic is spread over the pods"
run "hits 20"
pause

step "Scale up to 10 replicas"
run "kubectl -n $NS scale deploy/whoami --replicas=10"
run "kubectl -n $NS rollout status deploy/whoami"
run "kubectl -n $NS get pods -o wide"
run "hits 30"
pause

step "Self-healing: delete a pod, Kubernetes replaces it immediately"
VICTIM="$(kubectl -n "$NS" get pods -o name | head -n1)"
run "kubectl -n $NS delete $VICTIM --wait=false"
sleep 2
run "kubectl -n $NS get pods"
run "kubectl -n $NS rollout status deploy/whoami"
pause

WORKER="$(first_worker)"
step "Node failure drill: drain $WORKER, its pods move to the other nodes"
echo "Pods currently on $WORKER:"
kubectl -n "$NS" get pods -o wide --field-selector "spec.nodeName=$WORKER"
run "kubectl drain $WORKER --ignore-daemonsets --delete-emptydir-data --force --timeout=120s >/dev/null"
run "kubectl -n $NS rollout status deploy/whoami"
run "kubectl -n $NS get pods -o wide"
run "hits 20"
pause

step "Bring the node back"
run "kubectl uncordon $WORKER"

echo
echo "✅ Done. Remove the demo with: ./showcase/01_hostname_app.sh --cleanup"
