#!/usr/bin/env bash

set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
HEALTH_CHECK_FQDN="${HEALTH_CHECK_FQDN:-health.ilpumjinro.store}"
ACTION="${1:-status}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-300}"

usage() {
  cat <<'EOF'
Usage: scripts/dr/route53-primary-health.sh [status|failover|failback]

status    Show the AWS PRIMARY health-check configuration and current status.
failover  Invert the health check so Route 53 treats the AWS PRIMARY as failed.
failback  Remove inversion so Route 53 follows the real AWS health status.
EOF
}

case "$ACTION" in
  status|failover|failback) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown action: $ACTION" >&2; usage >&2; exit 2 ;;
esac

command -v aws >/dev/null || { echo "aws CLI is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }

mapfile -t HEALTH_CHECK_IDS < <(
  aws route53 list-health-checks --region "$AWS_REGION" --output json |
    jq -r --arg fqdn "$HEALTH_CHECK_FQDN" \
      '.HealthChecks[] | select(.HealthCheckConfig.FullyQualifiedDomainName == $fqdn) | .Id'
)

if (( ${#HEALTH_CHECK_IDS[@]} != 1 )); then
  echo "Expected exactly one Route 53 health check for ${HEALTH_CHECK_FQDN}; found ${#HEALTH_CHECK_IDS[@]}." >&2
  exit 1
fi

HEALTH_CHECK_ID="${HEALTH_CHECK_IDS[0]}"

CURRENT_INVERTED="$(aws route53 get-health-check --health-check-id "$HEALTH_CHECK_ID" \
  --region "$AWS_REGION" --query 'HealthCheck.HealthCheckConfig.Inverted' --output text)"
CURRENT_STATUS="$(aws route53 get-health-check-status --health-check-id "$HEALTH_CHECK_ID" \
  --region "$AWS_REGION" --query 'HealthCheckObservations[0].StatusReport.Status' --output text)"

show_status() {
  local inverted status
  inverted="$(aws route53 get-health-check --health-check-id "$HEALTH_CHECK_ID" \
    --region "$AWS_REGION" --query 'HealthCheck.HealthCheckConfig.Inverted' --output text)"
  status="$(aws route53 get-health-check-status --health-check-id "$HEALTH_CHECK_ID" \
    --region "$AWS_REGION" --query 'HealthCheckObservations[0].StatusReport.Status' --output text)"
  echo "Route 53 AWS PRIMARY health check"
  echo "  id: $HEALTH_CHECK_ID"
  echo "  fqdn: $HEALTH_CHECK_FQDN"
  echo "  inverted: $inverted"
  echo "  observed status: $status"
}

if [[ "$ACTION" == "status" ]]; then
  show_status
  exit 0
fi

if [[ "$ACTION" == "failover" ]]; then
  if [[ "$CURRENT_INVERTED" == "False" && "$CURRENT_STATUS" == "Failure"* ]]; then
    echo "AWS PRIMARY is already unhealthy without inversion; Route 53 is failing over naturally."
    show_status
    exit 0
  fi
  aws route53 update-health-check --health-check-id "$HEALTH_CHECK_ID" \
    --region "$AWS_REGION" --inverted >/dev/null
  EXPECTED_INVERTED="True"
  EXPECTED_STATUS="Failure"
else
  aws route53 update-health-check --health-check-id "$HEALTH_CHECK_ID" \
    --region "$AWS_REGION" --no-inverted >/dev/null
  EXPECTED_INVERTED="False"
  EXPECTED_STATUS="Success"
fi

WAITED_SECONDS=0
while (( WAITED_SECONDS < MAX_WAIT_SECONDS )); do
  INVERTED="$(aws route53 get-health-check --health-check-id "$HEALTH_CHECK_ID" \
    --region "$AWS_REGION" --query 'HealthCheck.HealthCheckConfig.Inverted' --output text)"
  STATUS="$(aws route53 get-health-check-status --health-check-id "$HEALTH_CHECK_ID" \
    --region "$AWS_REGION" --query 'HealthCheckObservations[0].StatusReport.Status' --output text)"

  if [[ "$INVERTED" == "$EXPECTED_INVERTED" && "$STATUS" == "$EXPECTED_STATUS"* ]]; then
    show_status
    exit 0
  fi

  sleep 10
  WAITED_SECONDS=$((WAITED_SECONDS + 10))
done

show_status
echo "Route 53 did not reach expected status ${EXPECTED_STATUS} within ${MAX_WAIT_SECONDS}s." >&2
exit 1
