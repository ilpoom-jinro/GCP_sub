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
CLOUDSQL_DB_OWNER_USER="${CLOUDSQL_DB_OWNER_USER:-}"
CLOUDSQL_DB_OWNER_PASSWORD="${CLOUDSQL_DB_OWNER_PASSWORD:-}"
KUBERNETES_NAMESPACE="${KUBERNETES_NAMESPACE:-stock-demo}"
DATABASE_DROP_SECRET="dr-rearm-cloudsql-db-owner"
DATABASE_DROP_POD="dr-rearm-drop-cloudsql-database"

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
standalone. Execute mode deletes the previous DMS migration job, its destination
connection profile, and the existing application database on Cloud SQL. It then
creates and starts a new AWS RDS -> Cloud SQL continuous migration job using
the existing Cloud SQL instance.

When the Cloud SQL application database already exists, execute mode drops it
through a short-lived GKE Pod authenticated as its database owner. Provide the
owner credentials through CLOUDSQL_DB_OWNER_USER and CLOUDSQL_DB_OWNER_PASSWORD.

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

database_exists() {
  gcloud sql databases describe "$DATABASE_NAME" \
    --instance="$CLOUDSQL_INSTANCE" --project="$PROJECT_ID" >/dev/null 2>&1
}

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

cloudsql_master_instance() {
  gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
    --project="$PROJECT_ID" --format='value(masterInstanceName)'
}

wait_for_cloudsql_standalone() {
  for _ in $(seq 1 180); do
    local current_master
    current_master="$(cloudsql_master_instance)"
    [[ -z "$current_master" ]] && return 0
    echo "Waiting for Cloud SQL to detach from DMS master ${current_master}..."
    sleep 10
  done

  echo "Cloud SQL did not return to standalone mode after deleting the DMS job." >&2
  exit 1
}

detach_cloudsql_from_dms_master() {
  local current_master
  current_master="$(cloudsql_master_instance)"
  [[ -z "$current_master" ]] && return 0

  # Deleting a DMS job leaves its Cloud SQL destination as a read replica of
  # the DMS-managed master. Promote it before reusing the same instance.
  echo "Promoting Cloud SQL replica to detach from DMS master ${current_master}..."
  gcloud sql instances promote-replica "$CLOUDSQL_INSTANCE" \
    --project="$PROJECT_ID" \
    --quiet
  wait_for_cloudsql_standalone
}

cloudsql_private_ip() {
  gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
    --project="$PROJECT_ID" --format=json |
    jq -r '.ipAddresses[] | select(.type == "PRIVATE") | .ipAddress' |
    head -n 1
}

cleanup_database_drop_resources() {
  kubectl -n "$KUBERNETES_NAMESPACE" delete pod "$DATABASE_DROP_POD" \
    --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$KUBERNETES_NAMESPACE" delete secret "$DATABASE_DROP_SECRET" \
    --ignore-not-found >/dev/null 2>&1 || true
}

delete_cloudsql_database_as_owner() {
  command -v kubectl >/dev/null || {
    echo "kubectl is required to delete the existing Cloud SQL database." >&2
    exit 1
  }

  local private_ip phase
  private_ip="$(cloudsql_private_ip)"
  [[ -n "$private_ip" ]] || {
    echo "Cloud SQL instance ${CLOUDSQL_INSTANCE} has no private IP." >&2
    exit 1
  }
  [[ -n "$CLOUDSQL_DB_OWNER_USER" && -n "$CLOUDSQL_DB_OWNER_PASSWORD" ]] || {
    echo "CLOUDSQL_DB_OWNER_USER and CLOUDSQL_DB_OWNER_PASSWORD are required to delete existing database ${DATABASE_NAME}." >&2
    exit 1
  }
  [[ "$DATABASE_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    echo "DATABASE_NAME contains unsupported characters: ${DATABASE_NAME}" >&2
    exit 1
  }

  cleanup_database_drop_resources
  kubectl -n "$KUBERNETES_NAMESPACE" create secret generic "$DATABASE_DROP_SECRET" \
    --from-literal=password="$CLOUDSQL_DB_OWNER_PASSWORD" >/dev/null

  cat <<EOF | kubectl -n "$KUBERNETES_NAMESPACE" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${DATABASE_DROP_POD}
spec:
  restartPolicy: Never
  containers:
    - name: drop-database
      image: postgres:16
      command: ["/bin/sh", "-ceu"]
      args:
        - |
          psql -h "\$PGHOST" -p "\$PGPORT" -U "\$PGUSER" -d postgres -v ON_ERROR_STOP=1 \\
            -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DATABASE_NAME}' AND pid <> pg_backend_pid();" \\
            -c 'DROP DATABASE ${DATABASE_NAME};'
      env:
        - name: PGHOST
          value: "${private_ip}"
        - name: PGPORT
          value: "5432"
        - name: PGUSER
          value: "${CLOUDSQL_DB_OWNER_USER}"
        - name: PGSSLMODE
          value: "require"
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: ${DATABASE_DROP_SECRET}
              key: password
EOF

  for _ in $(seq 1 60); do
    phase="$(kubectl -n "$KUBERNETES_NAMESPACE" get pod "$DATABASE_DROP_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded)
        kubectl -n "$KUBERNETES_NAMESPACE" logs "$DATABASE_DROP_POD"
        cleanup_database_drop_resources
        return 0
        ;;
      Failed)
        kubectl -n "$KUBERNETES_NAMESPACE" logs "$DATABASE_DROP_POD" >&2 || true
        cleanup_database_drop_resources
        echo "Database-owner Pod failed while deleting ${DATABASE_NAME}." >&2
        exit 1
        ;;
    esac
    sleep 5
  done

  kubectl -n "$KUBERNETES_NAMESPACE" logs "$DATABASE_DROP_POD" >&2 || true
  cleanup_database_drop_resources
  echo "Timed out waiting for the database-owner Pod to delete ${DATABASE_NAME}." >&2
  exit 1
}

cloudsql_state="$(gcloud sql instances describe "$CLOUDSQL_INSTANCE" \
  --project="$PROJECT_ID" --format='value(state)')"
master_instance="$(cloudsql_master_instance)"
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
[[ "$job_state" != "RUNNING" ]] || {
  echo "DMS rearm blocked: the existing AWS -> GCP job is still RUNNING." >&2
  exit 1
}

cat <<EOF

Preflight passed. No DMS resource was changed.

Execute mode will:
  1. Delete the previous DMS job and its destination profile without --force.
  2. Delete the existing Cloud SQL database ${DATABASE_NAME}.
  3. Keep the Cloud SQL instance, private IP, and Terraform state intact.
  4. Recreate the destination profile and a continuous ${DATABASE_NAME} migration.
  5. Demote Cloud SQL into the new DMS standby role, verify, and start CDC.

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

# Check credentials before removing DMS resources so an omitted Secret leaves
# the currently configured recovery state untouched.
if database_exists; then
  [[ -n "$CLOUDSQL_DB_OWNER_USER" && -n "$CLOUDSQL_DB_OWNER_PASSWORD" ]] || {
    echo "GCP_DMS_REARM_DB_OWNER_USER and GCP_DMS_REARM_DB_OWNER_PASSWORD must be configured before rearming DMS." >&2
    exit 1
  }
fi

# The source profile is provisioned with REQUIRED TLS before the first DMS
# cycle. Re-patching it here makes DMS revalidate an obsolete Cloud SQL master
# after a promotion, even though this rearm does not change the source profile.
echo "Keeping the existing REQUIRED TLS configuration on DMS source profile ${SOURCE_PROFILE}."

if job_exists; then
  echo "Deleting previous DMS job ${MIGRATION_JOB} without --force..."
  gcloud database-migration migration-jobs delete "$MIGRATION_JOB" \
    --project="$PROJECT_ID" --region="$REGION" --quiet
fi

# A prior interrupted rearm can already have deleted the job while leaving the
# Cloud SQL destination attached to its DMS-managed master. Handle both the
# normal and interrupted states before reusing the instance.
detach_cloudsql_from_dms_master

# A normal job deletion removes its destination profile. Remove a leftover
# profile only when a previous interrupted run left one behind; never use force.
if profile_exists "$DESTINATION_PROFILE"; then
  echo "Deleting leftover destination profile ${DESTINATION_PROFILE} without --force..."
  gcloud database-migration connection-profiles delete "$DESTINATION_PROFILE" \
    --project="$PROJECT_ID" --region="$REGION" --quiet
fi

# DMS requires an empty Cloud SQL destination for a new initial load. The
# failback baseline and any prior Cloud SQL writes are authoritative on AWS at
# this point, and GCP writes are fenced before this destructive step.
if database_exists; then
  echo "Deleting existing Cloud SQL database ${DATABASE_NAME} before the AWS initial load..."
  delete_cloudsql_database_as_owner
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
