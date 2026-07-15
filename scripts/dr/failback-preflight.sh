#!/usr/bin/env bash

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-ilpoomjinro}"
REGION="${REGION:-asia-northeast3}"
MIGRATION_JOB="${MIGRATION_JOB:-aws-rds-to-cloudsql-dr}"
CLOUDSQL_INSTANCE="${CLOUDSQL_INSTANCE:-dr-standby-postgres}"

usage() {
  cat <<'EOF'
Usage: scripts/dr/failback-preflight.sh [--project PROJECT_ID] [--region REGION] [--job JOB_ID] [--instance INSTANCE_ID]

Checks whether the promoted Cloud SQL instance is ready for reverse-replication planning.
It does not create a reverse replication subscription or switch application traffic.
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
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }

JOB_STATE="$(gcloud database-migration migration-jobs describe "$MIGRATION_JOB" \
  --project="$PROJECT_ID" --region="$REGION" --format='value(state)')"
CLOUDSQL_STATE="$(gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" --format='value(state)')"
MASTER_INSTANCE="$(gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" --format='value(masterInstanceName)')"
LOGICAL_DECODING="$(gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" --format=json | \
  jq -r '.settings.databaseFlags[]? | select(.name == "cloudsql.logical_decoding") | .value' | \
  head -n 1)"

echo "DMS state: $JOB_STATE"
echo "Cloud SQL state: $CLOUDSQL_STATE"
echo "Cloud SQL master instance: ${MASTER_INSTANCE:-none}"
echo "cloudsql.logical_decoding: ${LOGICAL_DECODING:-not-set}"

[[ "$CLOUDSQL_STATE" == "RUNNABLE" ]] || { echo "Failback blocked: Cloud SQL is not RUNNABLE." >&2; exit 1; }
[[ -z "$MASTER_INSTANCE" ]] || { echo "Failback blocked: Cloud SQL is still a replica." >&2; exit 1; }
[[ "$LOGICAL_DECODING" == "on" ]] || { echo "Failback blocked: cloudsql.logical_decoding must be on." >&2; exit 1; }

cat <<'EOF'

Preflight passed. Before reverse replication, fence all writes to AWS RDS, apply
the failback network changes, and verify the AWS Router Cloud SQL proxy.

The AWS Router command `cloudsql-reverse-replication` performs the protected
baseline export/restore and native logical-replication setup. It must be run
only after GCP is the sole writer and the AWS RDS target may be replaced.

Do not enable writes on AWS until the subscription catches up and the GCP writer is fenced.
EOF
