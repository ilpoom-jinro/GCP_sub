#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: fence-gke-writes.sh <status|fence|unfence>

Blocks every egress connection from stock-demo/stock-api. The normal DR deploy
uses this policy while Cloud SQL is a DMS standby replica, and a controlled
failback uses it before reverse replication. It is removed only after Cloud SQL
has been promoted during an approved failover.
EOF
}

action="${1:-}"
namespace="${DR_NAMESPACE:-stock-demo}"
policy_name="${DR_WRITE_FENCE_POLICY_NAME:-dr-fence-stock-api-egress}"

case "${action}" in
  status)
    kubectl -n "${namespace}" get networkpolicy "${policy_name}" -o yaml || true
    ;;
  fence)
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${policy_name}
  namespace: ${namespace}
  annotations:
    ilpoomjinro.store/dr-purpose: "Fence stock-api while Cloud SQL is standby or AWS is being restored"
spec:
  podSelector:
    matchLabels:
      app: stock-api
  policyTypes:
    - Egress
  egress: []
EOF
    kubectl -n "${namespace}" get networkpolicy "${policy_name}" -o yaml
    ;;
  unfence)
    kubectl -n "${namespace}" delete networkpolicy "${policy_name}" --ignore-not-found
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
