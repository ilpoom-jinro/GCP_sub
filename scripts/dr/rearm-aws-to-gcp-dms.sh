#!/usr/bin/env bash

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-ilpoomjinro}"
REGION="${REGION:-asia-northeast3}"
NETWORK="${NETWORK:-projects/${PROJECT_ID}/global/networks/vpc-gcp-prd}"
MIGRATION_JOB="${MIGRATION_JOB:-aws-rds-to-cloudsql-dr}"
SOURCE_PROFILE="${SOURCE_PROFILE:-aws-postgres-source}"
DESTINATION_PROFILE="${DESTINATION_PROFILE:-cloudsql-dr-destination}"
CLOUDSQL_INSTANCE="${CLOUDSQL_INSTANCE:-dr-standby-postgres}"
DATABASE_NAME="${DATABASE_NAME:-financial_service}"

EXECUTE=false
GCP_WRITES_FENCED=false
CONFIRMATION=""

usage() {
  cat <<'EOF'
Usage:
  scripts/dr/rearm-aws-to-gcp-dms.sh [--execute] [--gcp-writes-fenced]
      [--confirm REARM_AWS_TO_GCP_DMS]
      [--project PROJECT_ID] [--region REGION] [--network NETWORK]

Preflight verifies that the prior Cloud SQL destination was promoted and is now
standalone. Execute mode deletes only the previous DMS migration job and its
destination connection profile, then creates and starts a new AWS RDS -> Cloud
SQL continuous migration job using the existing Cloud SQL instance.

The new job performs an initial load from AWS. Run it only after AWS is the
authoritative writer, public traffic has returned to AWS, and GCP application
writes are fenced. Do not use --force: it would delete the Cloud SQL instance.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    --gcp-writes-fenced) GCP_WRITES_FENCED=true; shift ;;
    --confirm) CONFIRMATION="${2:-}"; shift 2 ;;
    --project) PROJECT_ID="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --network) NETWORK="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command in gcloud curl jq; do
  command -v "$command" >/dev/null || {
    echo "${command} is required." >&2
    exit 1
  }
done

job_exists() {
  gcloud database-migration migration-jobs describe "$MIGRATION_JOB" \
    --project="$PROJECT_ID" --region="$REGION" --format='value(name)' >/dev/null 2>&1
}

profile_exists() {
  gcloud database-migration connection-profiles describe "$1" \
    --project="$PROJECT_ID" --region="$REGION" --format='value(name)' >/dev/null 2>&1
}

wait_for_operation() {
  local operation="$1"
  operation="${operation##*/}"

  for _ in $(seq 1 180); do
    local operation_json done error
    operation_json="$(gcloud database-migration operations describe "$operation" \
      --project="$PROJECT_ID" --region="$REGION" --format=json)"
    done="$(jq -r '.done // false' <<<"$operation_json")"
    error="$(jq -c '.error // empty' <<<"$operation_json")"
    if [[ "$done" == "true" ]]; then
      [[ -z "$error" ]] || {
        echo "DMS operation ${operation} failed: ${error}" >&2
        exit 1
      }
      return 0
    fi
    sleep 10
  done

  echo "Timed out waiting for DMS operation ${operation}." >&2
  exit 1
}

run_async_dms_command() {
  local operation
  operation="$("$@" --format='value(name)')"
  [[ -n "$operation" ]] || {
    echo "DMS command did not return an operation name: $*" >&2
    exit 1
  }
  wait_for_operation "$operation"
}

cloudsql_state="$(gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" --format='value(state)')"
master_instance="$(gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" --format='value(masterInstanceName)')"
job_state="missing"
if job_exists; then
  job_state="$(gcloud database-migration migration-jobs describe "$MIGRATION_JOB" \
    --project="$PROJECT_ID" --region="$REGION" --format='value(state)')"
fi

echo "Cloud SQL state: ${cloudsql_state}"
echo "Cloud SQL master instance: ${master_instance:-none}"
echo "Previous DMS job state: ${job_state}"

[[ "$cloudsql_state" == "RUNNABLE" ]] || {
  echo "DMS rearm blocked: Cloud SQL is not RUNNABLE." >&2
  exit 1
}
[[ -z "$master_instance" ]] || {
  echo "DMS rearm blocked: Cloud SQL is still a replica." >&2
  exit 1
}
[[ "$job_state" != "RUNNING" ]] || {
  echo "DMS rearm blocked: the existing AWS -> GCP job is still RUNNING." >&2
  exit 1
}

cat <<EOF

Preflight passed. No DMS resource was changed.

Execute mode will:
  1. Delete the previous DMS job and its destination profile without --force.
  2. Keep the Cloud SQL instance, private IP, and Terraform state intact.
  3. Recreate the destination profile and a continuous ${DATABASE_NAME} migration.
  4. Demote Cloud SQL into the new DMS standby role, verify, and start CDC.

The new initial load makes AWS RDS authoritative for ${DATABASE_NAME}. Keep
GCP writes fenced until the next planned failover.
EOF

if [[ "$EXECUTE" != true ]]; then
  exit 0
fi

[[ "$GCP_WRITES_FENCED" == true ]] || {
  echo "GCP application writes must be fenced before DMS rearm." >&2
  exit 1
}
[[ "$CONFIRMATION" == "REARM_AWS_TO_GCP_DMS" ]] || {
  echo "Confirmation must equal REARM_AWS_TO_GCP_DMS." >&2
  exit 1
}

# The source profile is provisioned with REQUIRED TLS before the first DMS
# cycle. Re-patching it here makes DMS revalidate an obsolete Cloud SQL master
# after a promotion, even though this rearm does not change the source profile.
echo "Keeping the existing REQUIRED TLS configuration on DMS source profile ${SOURCE_PROFILE}."

if job_exists; then
  echo "Deleting previous DMS job ${MIGRATION_JOB} without --force..."
  gcloud database-migration migration-jobs delete "$MIGRATION_JOB" \
    --project="$PROJECT_ID" --region="$REGION" --quiet
fi

# A normal job deletion removes its destination profile. Remove a leftover
# profile only when a previous interrupted run left one behind; never use force.
if profile_exists "$DESTINATION_PROFILE"; then
  echo "Deleting leftover destination profile ${DESTINATION_PROFILE} without --force..."
  gcloud database-migration connection-profiles delete "$DESTINATION_PROFILE" \
    --project="$PROJECT_ID" --region="$REGION" --quiet
fi

echo "Creating Cloud SQL destination profile..."
gcloud database-migration connection-profiles create postgresql "$DESTINATION_PROFILE" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --role=DESTINATION \
  --cloudsql-instance="$CLOUDSQL_INSTANCE" \
  --display-name="Cloud SQL DR destination" \
  --no-async

echo "Creating the new AWS RDS to Cloud SQL continuous migration job..."
gcloud database-migration migration-jobs create "$MIGRATION_JOB" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --display-name="AWS RDS to Cloud SQL DR" \
  --source="$SOURCE_PROFILE" \
  --destination="$DESTINATION_PROFILE" \
  --type=CONTINUOUS \
  --peer-vpc="$NETWORK" \
  --databases-filter="$DATABASE_NAME" \
  --no-async

echo "Demoting Cloud SQL to the new DMS destination role..."
run_async_dms_command gcloud database-migration migration-jobs demote-destination "$MIGRATION_JOB" \
  --project="$PROJECT_ID" --region="$REGION"

echo "Verifying the new migration job..."
run_async_dms_command gcloud database-migration migration-jobs verify "$MIGRATION_JOB" \
  --project="$PROJECT_ID" --region="$REGION"

echo "Fetching source objects for audit..."
gcloud database-migration migration-jobs fetch-source-objects "$MIGRATION_JOB" \
  --project="$PROJECT_ID" --region="$REGION" >/dev/null

echo "Starting the new migration job..."
run_async_dms_command gcloud database-migration migration-jobs start "$MIGRATION_JOB" \
  --project="$PROJECT_ID" --region="$REGION"

echo "Waiting for the migration job to reach CDC..."
for _ in $(seq 1 360); do
  state="$(gcloud database-migration migration-jobs describe "$MIGRATION_JOB" \
    --project="$PROJECT_ID" --region="$REGION" --format='value(state)')"
  phase="$(gcloud database-migration migration-jobs describe "$MIGRATION_JOB" \
    --project="$PROJECT_ID" --region="$REGION" --format='value(phase)')"
  echo "DMS state=${state}, phase=${phase}"
  [[ "$state" == "RUNNING" && "$phase" == "CDC" ]] && break
  sleep 10
done

[[ "$state" == "RUNNING" && "$phase" == "CDC" ]] || {
  echo "The new DMS job did not reach RUNNING/CDC within one hour." >&2
  exit 1
}

echo "DMS rearm completed. AWS is the sole writer and AWS -> GCP CDC is active."
