#!/bin/bash
# Demo 5: persistent storage. Data survives pod deletion.
# Run: ./showcase/05_stateful.sh   (cleanup: --cleanup)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NS=showcase-stateful
LPP_MANIFEST="${LPP_MANIFEST:-https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml}"

cleanup() {
    kubectl delete ns "$NS" --ignore-not-found --wait=false
    kubectl delete -f "$LPP_MANIFEST" --ignore-not-found
}
parse_cleanup_flag "${1:-}"

require_cluster
require_workers

title "Demo 5: stateful app with persistent storage"

step "Install a storage provisioner (local-path) and make it the default"
run "kubectl apply -f $LPP_MANIFEST"
run "kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s"
run "kubectl patch storageclass local-path -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'"
pause

step "Deploy Redis with a persistent volume"
kubectl create ns "$NS" >/dev/null 2>&1
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: redis-data}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: redis}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: redis}}
  template:
    metadata: {labels: {app: redis}}
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          args: ["--appendonly", "yes"]
          volumeMounts: [{name: data, mountPath: /data}]
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: redis-data}
YAML
run "kubectl -n $NS rollout status deploy/redis --timeout=180s"
run "kubectl -n $NS get pvc,pods -o wide"
pause

step "Write some data"
run "kubectl -n $NS exec deploy/redis -- redis-cli set demo 'I survived a pod restart'"
run "kubectl -n $NS exec deploy/redis -- redis-cli get demo"
pause

step "Kill the Redis pod"
run "kubectl -n $NS delete pod -l app=redis"
run "kubectl -n $NS rollout status deploy/redis --timeout=180s"
run "kubectl -n $NS get pods -o wide"
pause

step "Is the data still there?"
run "kubectl -n $NS exec deploy/redis -- redis-cli get demo"
echo
echo "ℹ️  local-path volumes live on one node's disk, so the pod is always scheduled back there."
echo "   For storage that follows pods between nodes you'd use NFS/Longhorn/Ceph instead."

echo
echo "✅ Done. Remove the demo with: ./showcase/05_stateful.sh --cleanup"
