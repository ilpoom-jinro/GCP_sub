#!/usr/bin/env bash

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-ilpoomjinro}"
REGION="${REGION:-asia-northeast3}"
MIGRATION_JOB="${MIGRATION_JOB:-aws-rds-to-cloudsql-dr}"
CLOUDSQL_INSTANCE="${CLOUDSQL_INSTANCE:-dr-standby-postgres}"
EXECUTE=false
AWS_WRITES_FENCED=false

usage() {
  cat <<'EOF'
Usage: scripts/dr/failover-to-gcp.sh [options]

Runs preflight checks for an AWS RDS to Cloud SQL failover. By default, no change
is made. Promotion requires both --execute and --aws-writes-fenced.

Options:
  --project PROJECT_ID
  --region REGION
  --job JOB_ID
  --instance INSTANCE_ID
  --aws-writes-fenced  Confirm AWS application and database writes are blocked.
  --execute             Promote the DMS job after all checks pass.
  -h, --help            Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --job) MIGRATION_JOB="$2"; shift 2 ;;
    --instance) CLOUDSQL_INSTANCE="$2"; shift 2 ;;
    --aws-writes-fenced) AWS_WRITES_FENCED=true; shift ;;
    --execute) EXECUTE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v gcloud >/dev/null || { echo "gcloud is required." >&2; exit 1; }

JOB_STATE="$(gcloud database-migration migration-jobs describe "$MIGRATION_JOB" \
  --project="$PROJECT_ID" --region="$REGION" --format='value(state)')"
JOB_PHASE="$(gcloud database-migration migration-jobs describe "$MIGRATION_JOB" \
  --project="$PROJECT_ID" --region="$REGION" --format='value(phase)')"
CLOUDSQL_STATE="$(gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" --format='value(state)')"

echo "DMS job: $MIGRATION_JOB"
echo "  state: $JOB_STATE"
echo "  phase: ${JOB_PHASE:-not-reported}"
echo "Cloud SQL: $CLOUDSQL_INSTANCE"
echo "  state: $CLOUDSQL_STATE"

[[ "$JOB_STATE" == "RUNNING" ]] || {
  echo "Failover blocked: DMS job must be RUNNING." >&2
  exit 1
}
[[ "$JOB_PHASE" == "CDC" ]] || {
  echo "Failover blocked: DMS job must be in CDC before promotion." >&2
  exit 1
}
[[ "$CLOUDSQL_STATE" == "RUNNABLE" ]] || {
  echo "Failover blocked: Cloud SQL must be RUNNABLE." >&2
  exit 1
}

if [[ "$EXECUTE" != true || "$AWS_WRITES_FENCED" != true ]]; then
  cat <<'EOF'

Preflight passed. No promotion was executed.
Before promoting, stop or fence all AWS application and RDS writes. Then run:

  scripts/dr/failover-to-gcp.sh --execute --aws-writes-fenced
EOF
  exit 0
fi

echo "Promoting DMS job. This permanently ends the current AWS-to-GCP DMS stream."
OPERATION="$(gcloud database-migration migration-jobs promote "$MIGRATION_JOB" \
  --project="$PROJECT_ID" --region="$REGION" --format='value(name)')"

[[ -n "$OPERATION" ]] || {
  echo "Promotion command did not return an operation name. Inspect gcloud output." >&2
  exit 1
}

echo "Promotion operation: $OPERATION"
while true; do
  DONE="$(gcloud database-migration operations describe "$OPERATION" \
    --project="$PROJECT_ID" --region="$REGION" --format='value(done)')"
  [[ "$DONE" == "True" || "$DONE" == "true" ]] && break
  sleep 10
done

ERROR="$(gcloud database-migration operations describe "$OPERATION" \
  --project="$PROJECT_ID" --region="$REGION" --format='value(error.message)')"
if [[ -n "$ERROR" ]]; then
  echo "Promotion failed: $ERROR" >&2
  exit 1
fi

echo "Promotion completed. Confirm Cloud SQL is standalone before switching the application."
gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" \
  --format='yaml(name,state,masterInstanceName)'
echo "Application DB endpoint switching is intentionally not automated by this script."
