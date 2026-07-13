#!/usr/bin/env bash

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-ilpoomjinro}"
REGION="${REGION:-asia-northeast3}"
MIGRATION_JOB="${MIGRATION_JOB:-aws-rds-to-cloudsql-dr}"
CLOUDSQL_INSTANCE="${CLOUDSQL_INSTANCE:-dr-standby-postgres}"

usage() {
  cat <<'EOF'
Usage: scripts/dr/status.sh [--project PROJECT_ID] [--region REGION] [--job JOB_ID] [--instance INSTANCE_ID]

Displays the DMS migration state and the Cloud SQL replication role.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --job) MIGRATION_JOB="$2"; shift 2 ;;
    --instance) CLOUDSQL_INSTANCE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v gcloud >/dev/null || { echo "gcloud is required." >&2; exit 1; }

echo "DMS migration job"
gcloud database-migration migration-jobs describe "$MIGRATION_JOB" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --format='yaml(state,phase,type,source,destination,updateTime)'

echo
echo "Cloud SQL instance"
gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" \
  --format='yaml(name,state,backendType,masterInstanceName,replicaConfiguration,settings.databaseFlags)'
