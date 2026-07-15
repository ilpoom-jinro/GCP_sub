#!/usr/bin/env bash

set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
HEALTH_CHECK_FQDN="${HEALTH_CHECK_FQDN:-health.ilpumjinro.store}"
FORCE_FAILOVER_ALARM_NAME="${FORCE_FAILOVER_ALARM_NAME:-financial-stock-web-dr-force-failover}"
FORCE_FAILOVER_METRIC_NAMESPACE="${FORCE_FAILOVER_METRIC_NAMESPACE:-Ilpoomjinro/DR}"
FORCE_FAILOVER_METRIC_NAME="${FORCE_FAILOVER_METRIC_NAME:-ForceFailover}"
FORCE_FAILOVER_DIMENSION_NAME="${FORCE_FAILOVER_DIMENSION_NAME:-Service}"
FORCE_FAILOVER_DIMENSION_VALUE="${FORCE_FAILOVER_DIMENSION_VALUE:-stock-web}"
ACTION="${1:-status}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-600}"

usage() {
  cat <<'EOF'
Usage: scripts/dr/route53-primary-health.sh [status|failover|failback]

status    Show endpoint, calculated health-check, and DR test-gate states.
failover  Emit a DR test metric so Route 53 treats AWS PRIMARY as failed.
failback  Clear the DR test metric and follow the real AWS health status.
EOF
}

case "$ACTION" in
  status|failover|failback) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown action: $ACTION" >&2; usage >&2; exit 2 ;;
esac

command -v aws >/dev/null || { echo "aws CLI is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }

mapfile -t ENDPOINT_HEALTH_CHECK_IDS < <(
  aws route53 list-health-checks --region "$AWS_REGION" --output json |
    jq -r --arg fqdn "$HEALTH_CHECK_FQDN" \
      '.HealthChecks[] | select(.HealthCheckConfig.Type == "HTTPS" and .HealthCheckConfig.FullyQualifiedDomainName == $fqdn) | .Id'
)

if (( ${#ENDPOINT_HEALTH_CHECK_IDS[@]} != 1 )); then
  echo "Expected exactly one HTTPS health check for ${HEALTH_CHECK_FQDN}; found ${#ENDPOINT_HEALTH_CHECK_IDS[@]}." >&2
  exit 1
fi

ENDPOINT_HEALTH_CHECK_ID="${ENDPOINT_HEALTH_CHECK_IDS[0]}"

mapfile -t EFFECTIVE_HEALTH_CHECK_IDS < <(
  aws route53 list-health-checks --region "$AWS_REGION" --output json |
    jq -r --arg endpoint_id "$ENDPOINT_HEALTH_CHECK_ID" \
      '.HealthChecks[] | select(.HealthCheckConfig.Type == "CALCULATED" and ((.HealthCheckConfig.ChildHealthChecks // []) | index($endpoint_id))) | .Id'
)

if (( ${#EFFECTIVE_HEALTH_CHECK_IDS[@]} != 1 )); then
  echo "Expected exactly one calculated health check using ${ENDPOINT_HEALTH_CHECK_ID}; found ${#EFFECTIVE_HEALTH_CHECK_IDS[@]}." >&2
  exit 1
fi

EFFECTIVE_HEALTH_CHECK_ID="${EFFECTIVE_HEALTH_CHECK_IDS[0]}"

health_status() {
  local health_check_id="$1"
  aws route53 get-health-check-status --health-check-id "$health_check_id" \
    --region "$AWS_REGION" --query 'HealthCheckObservations[0].StatusReport.Status' --output text
}

alarm_state() {
  aws cloudwatch describe-alarms --region "$AWS_REGION" \
    --alarm-names "$FORCE_FAILOVER_ALARM_NAME" \
    --query 'MetricAlarms[0].StateValue' --output text
}

show_status() {
  echo "Route 53 AWS endpoint health check"
  echo "  id: $ENDPOINT_HEALTH_CHECK_ID"
  echo "  fqdn: $HEALTH_CHECK_FQDN"
  echo "  observed status: $(health_status "$ENDPOINT_HEALTH_CHECK_ID")"
  echo "Route 53 AWS effective calculated health check"
  echo "  id: $EFFECTIVE_HEALTH_CHECK_ID"
  echo "  observed status: $(health_status "$EFFECTIVE_HEALTH_CHECK_ID")"
  echo "DR test-gate CloudWatch alarm"
  echo "  name: $FORCE_FAILOVER_ALARM_NAME"
  echo "  state: $(alarm_state)"
}

if [[ "$ACTION" == "status" ]]; then
  show_status
  exit 0
fi

if [[ "$ACTION" == "failover" ]]; then
  METRIC_VALUE=1
  EXPECTED_ALARM_STATE="ALARM"
  EXPECTED_EFFECTIVE_STATUS="Failure"
else
  METRIC_VALUE=0
  EXPECTED_ALARM_STATE="OK"
  EXPECTED_EFFECTIVE_STATUS="Success"
fi

aws cloudwatch put-metric-data --region "$AWS_REGION" \
  --namespace "$FORCE_FAILOVER_METRIC_NAMESPACE" \
  --metric-data "MetricName=$FORCE_FAILOVER_METRIC_NAME,Dimensions=[{Name=$FORCE_FAILOVER_DIMENSION_NAME,Value=$FORCE_FAILOVER_DIMENSION_VALUE}],Value=$METRIC_VALUE,Unit=Count" \
  >/dev/null

WAITED_SECONDS=0
while (( WAITED_SECONDS < MAX_WAIT_SECONDS )); do
  ALARM_STATE="$(alarm_state)"
  EFFECTIVE_STATUS="$(health_status "$EFFECTIVE_HEALTH_CHECK_ID")"

  if [[ "$ALARM_STATE" == "$EXPECTED_ALARM_STATE" && "$EFFECTIVE_STATUS" == "$EXPECTED_EFFECTIVE_STATUS"* ]]; then
    show_status
    exit 0
  fi

  sleep 10
  WAITED_SECONDS=$((WAITED_SECONDS + 10))
done

show_status
echo "Route 53 did not reach expected status ${EXPECTED_EFFECTIVE_STATUS} within ${MAX_WAIT_SECONDS}s." >&2
exit 1
