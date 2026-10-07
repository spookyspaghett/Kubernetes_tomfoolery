#!/bin/bash
# Demo 2: zero-downtime rolling update and rollback while traffic is flowing.
# Run: ./showcase/02_rolling_update.sh   (cleanup: --cleanup)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NS=showcase-rollout
PORT=30082

cleanup() { kubectl delete ns "$NS" --ignore-not-found --wait=false; }
parse_cleanup_flag "${1:-}"

require_cluster
require_workers
IP="$(node_ip)"

# traffic_during <command string>: runs the command in the background while
# printing live responses from the service, then reports failed requests.
traffic_during() {
    local ok=0 bad=0 out pid
    eval "$1" >/dev/null 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if out="$(curl -s --max-time 2 "http://$IP:$PORT")" && [[ -n "$out" ]]; then
            ok=$((ok + 1))
            echo "   $(date +%T)  $out"
        else
            bad=$((bad + 1))
            echo "   $(date +%T)  ${BOLD}FAILED request${RESET}"
        fi
        sleep 0.3
    done
    wait "$pid"
    echo "📊 $ok requests succeeded, $bad failed"
}

title "Demo 2: zero-downtime rolling update"

step "Deploy version 1 (4 replicas)"
kubectl create ns "$NS" >/dev/null 2>&1
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: web}
spec:
  replicas: 4
  minReadySeconds: 3
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxUnavailable: 0, maxSurge: 1}
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      containers:
        - name: web
          image: hashicorp/http-echo:1.0
          args: ["-text=Hello from version 1"]
          ports: [{containerPort: 5678}]
          readinessProbe: {httpGet: {path: /, port: 5678}}
---
apiVersion: v1
kind: Service
metadata: {name: web}
spec:
  type: NodePort
  selector: {app: web}
  ports: [{port: 80, targetPort: 5678, nodePort: $PORT}]
YAML
run "kubectl -n $NS rollout status deploy/web"
run "curl -s http://$IP:$PORT"
pause

step "Roll out version 2 while requests keep flowing"
traffic_during "kubectl -n $NS patch deploy/web --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/0\",\"value\":\"-text=Hello from version 2\"}]' && kubectl -n $NS rollout status deploy/web"
run "kubectl -n $NS rollout history deploy/web"
pause

step "Oops, version 2 is bad: roll back"
traffic_during "kubectl -n $NS rollout undo deploy/web && kubectl -n $NS rollout status deploy/web"
run "curl -s http://$IP:$PORT"

echo
echo "✅ Done. Remove the demo with: ./showcase/02_rolling_update.sh --cleanup"
