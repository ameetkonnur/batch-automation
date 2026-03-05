#!/usr/bin/env bash
set -euo pipefail

: "${SUBSCRIPTION_ID:?}"
: "${RESOURCE_GROUP:?}"
: "${BATCH_ACCOUNT:?}"
: "${PRIMARY_POOL:?}"
: "${FALLBACK_POOL:?}"

JOB_PREFIX=${JOB_PREFIX:-"org-x-run"}
TASKS_JSON=${TASKS_JSON:-"tasks.json"}

STATE_DIR=${STATE_DIR:-"/tmp/org-x-batch-failover"}
STATE_FILE="$STATE_DIR/state.env"

az account set --subscription "$SUBSCRIPTION_ID" >/dev/null

# Determine active pool (fallback if failover already happened; else primary)
ACTIVE_POOL="$PRIMARY_POOL"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE" || true
  if [[ -n "${ACTIVE_POOL:-}" ]]; then
    ACTIVE_POOL="$ACTIVE_POOL"
  fi
fi

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
JOB_ID="${JOB_PREFIX}-${RUN_ID}"

# Metadata keys are searchable and survive reruns
az batch job create \
  --account-name "$BATCH_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --id "$JOB_ID" \
  --pool-id "$ACTIVE_POOL" \
  --metadata \
    runId="$RUN_ID" \
    requestedPool="$PRIMARY_POOL" \
    activePool="$ACTIVE_POOL" \
    trace="failover-controller" \
    jobPrefix="$JOB_PREFIX"

# Pass run ID to tasks for easy correlation in stdout/logs
az batch task create \
  --account-name "$BATCH_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --job-id "$JOB_ID" \
  --json-file "$TASKS_JSON" \
  --environment-settings RUN_ID="$RUN_ID" ACTIVE_POOL="$ACTIVE_POOL"

echo "Submitted job: $JOB_ID (pool=$ACTIVE_POOL, runId=$RUN_ID)"
