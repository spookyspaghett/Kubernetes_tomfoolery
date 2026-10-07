#!/bin/bash
# Demo 4: horizontal pod autoscaling under load.
# Run: ./showcase/04_autoscale.sh   (cleanup: --cleanup)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NS=showcase-autoscale
WATCH_SECONDS="${WATCH_SECONDS:-240}"

cleanup() { kubectl delete ns "$NS" --ignore-not-found --wait=false; }
parse_cleanup_flag "${1:-}"

require_cluster
require_workers

title "Demo 4: autoscaling under load"
ensure_metrics_server

step "Deploy a CPU-hungry web app with an autoscaler (1-10 pods, target 50% CPU)"
kubectl create ns "$NS" >/dev/null 2>&1
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: php-apache}
spec:
  replicas: 1
  selector: {matchLabels: {app: php-apache}}
  template:
    metadata: {labels: {app: php-apache}}
    spec:
      containers:
        - name: php-apache
          image: registry.k8s.io/hpa-example
          ports: [{containerPort: 80}]
          resources:
            requests: {cpu: 200m}
            limits: {cpu: 500m}
---
apiVersion: v1
kind: Service
metadata: {name: php-apache}
spec:
  selector: {app: php-apache}
  ports: [{port: 80}]
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: php-apache}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: php-apache}
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: {type: Utilization, averageUtilization: 50}
YAML
run "kubectl -n $NS rollout status deploy/php-apache"
run "kubectl -n $NS get hpa"
pause

step "Start 4 load generators hammering the service"
for i in 1 2 3 4; do
    kubectl -n "$NS" run "load-$i" --image=busybox:1.36 --restart=Never --labels=role=load -- \
        /bin/sh -c "while true; do wget -q -O- http://php-apache >/dev/null; done" >/dev/null
done
echo "📈 Watching for up to ${WATCH_SECONDS}s (Ctrl+C to stop early; the autoscaler reacts every ~15s)..."
deadline=$((SECONDS + WATCH_SECONDS))
while ((SECONDS < deadline)); do
    echo
    echo "--- $(date +%T) ---"
    kubectl -n "$NS" get hpa php-apache --no-headers
    kubectl -n "$NS" get pods -l app=php-apache --no-headers -o wide | awk '{print "   " $1, $3, $7}'
    sleep 15
done
pause

step "Stop the load"
run "kubectl -n $NS delete pod -l role=load --wait=false"
echo "ℹ️  Kubernetes waits ~5 minutes before scaling down, to avoid flapping."
echo "   Watch it with: kubectl -n $NS get hpa -w"

echo
echo "✅ Done. Remove the demo with: ./showcase/04_autoscale.sh --cleanup"
