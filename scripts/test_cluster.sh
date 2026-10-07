#!/bin/bash
# Smoke-tests the cluster from the master and deploys a sample nginx app.
# Run with: ./scripts/test_cluster.sh [--keep]
#
# Checks: nodes Ready, system pods healthy, then deploys nginx (one replica per
# node), and verifies the NodePort on every node and in-cluster DNS.
# The test namespace is deleted afterwards unless --keep is given.
set -uo pipefail

NS="${TEST_NS:-k8s-smoke-test}"
NODE_PORT="${NODE_PORT:-30080}"
TIMEOUT="${TIMEOUT:-180}"
KEEP=false
[[ "${1:-}" == "--keep" ]] && KEEP=true

if [[ -z "${KUBECONFIG:-}" && ! -r "$HOME/.kube/config" && -r /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
fi

PASS=0
FAIL=0
check() { # check <description> <command...>
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "✅ $desc"
        PASS=$((PASS + 1))
    else
        echo "❌ $desc"
        FAIL=$((FAIL + 1))
    fi
}

command -v kubectl >/dev/null || { echo "❌ kubectl not found" >&2; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "❌ Cannot reach the API server (KUBECONFIG=${KUBECONFIG:-default})" >&2; exit 1; }

cleanup() {
    if $KEEP; then
        echo "ℹ️  Keeping namespace $NS (delete with: kubectl delete ns $NS)"
    else
        echo "🧹 Cleaning up namespace $NS..."
        kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
    fi
}
trap cleanup EXIT

echo "== Cluster health =="
kubectl get nodes -o wide
echo
NODES="$(kubectl get nodes --no-headers | wc -l)"
NOT_READY="$(kubectl get nodes --no-headers | awk '$2 != "Ready"' | wc -l)"
check "$NODES node(s) registered, all Ready" test "$NODES" -ge 1 -a "$NOT_READY" -eq 0
check "At least one worker joined" test "$NODES" -ge 2
BAD_PODS="$(kubectl get pods -A --no-headers | awk '$4 != "Running" && $4 != "Completed"' | wc -l)"
check "All kube-system/flannel pods Running" test "$BAD_PODS" -eq 0
check "CoreDNS available" kubectl -n kube-system wait --for=condition=Available deploy/coredns --timeout=60s

echo
echo "== Deploying sample app (nginx x$NODES) =="
kubectl delete ns "$NS" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl create ns "$NS" >/dev/null || { echo "❌ Could not create namespace $NS" >&2; exit 1; }

kubectl -n "$NS" apply -f - <<EOF >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: $NODES
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      # Spread across nodes so cross-node networking is exercised.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: {app: web}
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      containers:
        - name: nginx
          image: nginx:stable
          ports: [{containerPort: 80}]
          readinessProbe:
            httpGet: {path: /, port: 80}
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: NodePort
  selector: {app: web}
  ports: [{port: 80, targetPort: 80, nodePort: $NODE_PORT}]
EOF

check "Deployment rolled out within ${TIMEOUT}s" kubectl -n "$NS" rollout status deploy/web --timeout="${TIMEOUT}s"
kubectl -n "$NS" get pods -o wide
echo

echo "== Connectivity =="
for ip in $(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'); do
    check "NodePort $ip:$NODE_PORT serves nginx" curl -fsS --max-time 10 "http://$ip:$NODE_PORT"
done
check "In-cluster DNS + service reachable from a pod" \
    kubectl -n "$NS" run dns-test --rm -i --restart=Never --image=busybox:1.36 --timeout=120s -- \
    wget -qO- -T 10 http://web.$NS.svc.cluster.local

echo
echo "Passed: $PASS, Failed: $FAIL"
$KEEP && echo "App reachable at http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}'):$NODE_PORT"
[[ $FAIL -eq 0 ]]
