#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: fence-gke-writes.sh <status|fence|unfence>

Temporarily blocks every egress connection from stock-demo/stock-api. This
prevents Cloud SQL writes during a controlled failback. The policy is removed
before a later failover so the promoted GCP service can use Cloud SQL again.
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
    ilpoomjinro.store/dr-purpose: "Temporarily fence stock-api database writes before AWS failback"
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
