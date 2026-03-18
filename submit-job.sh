#!/usr/bin/env bash
# submit-job.sh
# Submits a Batch job on the primary pool with metadata for traceability.
# Optionally waits for failover if the pool has allocation errors.
#
# Modes:
#   submit          Submit a job and exit (default)
#   submit --wait   Submit and wait for alert-triggered failover (up to MAX_WAIT_MINUTES)
#   submit --manual Submit and call webhook directly to trigger failover
#
# Usage:
#   ./submit-job.sh                           # submit only
#   ./submit-job.sh --wait                    # submit + wait for real alert
#   ./submit-job.sh --manual                  # submit + call webhook directly
#   COMMAND="python train.py" ./submit-job.sh # custom task command
#
# Config (override via env vars):
#   BATCH_ACCOUNT_NAME  — default: batchaccountameetk
#   RESOURCE_GROUP      — default: batch
#   PRIMARY_POOL        — the primary pool to submit to
#   FALLBACK_POOL       — the backup pool (for verification only)
#   WEBHOOK_URL         — the Container App webhook endpoint
#   JOB_PREFIX          — job name prefix (default: batch-run)
#   COMMAND             — task command (default: echo hello)
#   MAX_WAIT_MINUTES    — how long to wait for failover (default: 15)
set -euo pipefail

MODE="${1:-submit}"
BATCH_ACCOUNT_NAME="${BATCH_ACCOUNT_NAME:-batchaccountameetk}"
RESOURCE_GROUP="${RESOURCE_GROUP:-batch}"
PRIMARY_POOL="${PRIMARY_POOL:-pool-hbv4-err-20260317T091514Z}"
FALLBACK_POOL="${FALLBACK_POOL:-pool-ev3-swedencentral-20260317T091042Z}"
WEBHOOK_URL="${WEBHOOK_URL:-https://batch-failover-api.jollyocean-1d29d8d9.eastus.azurecontainerapps.io/api/batch/allocation-alert}"
JOB_PREFIX="${JOB_PREFIX:-batch-run}"
COMMAND="${COMMAND:-/bin/bash -c 'echo hello from batch job'}"
MAX_WAIT_MINUTES="${MAX_WAIT_MINUTES:-15}"

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
JOB_ID="${JOB_PREFIX}-${RUN_ID}"

echo "============================================"
echo "  Batch Job Submission"
echo "============================================"
echo "Batch Account:  $BATCH_ACCOUNT_NAME"
echo "Primary Pool:   $PRIMARY_POOL"
echo "Fallback Pool:  $FALLBACK_POOL"
echo "Job ID:         $JOB_ID"
echo "Command:        $COMMAND"
echo "Mode:           $MODE"
echo ""

# ── 1. Login ──
echo "[1/4] Logging into batch account..."
az batch account login \
  --name "$BATCH_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" 2>/dev/null

# ── 2. Check primary pool health ──
echo "[2/4] Checking primary pool status..."
POOL_JSON=$(az batch pool show --pool-id "$PRIMARY_POOL" -o json 2>&1)
ALLOC_STATE=$(echo "$POOL_JSON" | jq -r '.allocationState // "unknown"')
CURRENT=$(echo "$POOL_JSON" | jq -r '.currentDedicatedComputeNodes // 0')
AUTOSCALE=$(echo "$POOL_JSON" | jq -r '.enableAutoScale // false')
RESIZE_ERR=$(echo "$POOL_JSON" | jq -r '.resizeErrors[0].code // "none"')

echo "  Allocation: $ALLOC_STATE | Nodes: $CURRENT | AutoScale: $AUTOSCALE | ResizeError: $RESIZE_ERR"
if [[ "$RESIZE_ERR" != "none" ]]; then
  echo "  WARNING: Pool has resize errors — job will be stuck until failover moves it"
fi

# ── 3. Submit job ──
echo ""
echo "[3/4] Submitting job '$JOB_ID' on $PRIMARY_POOL..."
az batch job create \
  --id "$JOB_ID" \
  --pool-id "$PRIMARY_POOL" \
  --on-all-tasks-complete "terminateJob" \
  --metadata \
    runId="$RUN_ID" \
    primaryPool="$PRIMARY_POOL" \
    fallbackPool="$FALLBACK_POOL" \
    submittedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

az batch task create \
  --job-id "$JOB_ID" \
  --task-id "task-1" \
  --command-line "$COMMAND" \
  --environment-settings RUN_ID="$RUN_ID" PRIMARY_POOL="$PRIMARY_POOL"

CURRENT_POOL=$(az batch job show --job-id "$JOB_ID" --query "poolInfo.poolId" -o tsv)
echo "  Job submitted: $JOB_ID"
echo "  Pool: $CURRENT_POOL"
echo "  State: $(az batch job show --job-id "$JOB_ID" --query "state" -o tsv)"

# ── 4. Post-submit action based on mode ──
echo ""
if [[ "$MODE" == "submit" ]]; then
  echo "[4/4] Done. Job submitted."
  echo ""
  echo "Monitor:"
  echo "  az batch job show --job-id $JOB_ID --query '{pool:poolInfo.poolId,state:state}' -o json"
  exit 0
fi

if [[ "$MODE" == "--manual" ]]; then
  echo "[4/4] Calling webhook to trigger failover..."
  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d '{
    "schemaId": "azureMonitorCommonAlertSchema",
    "data": {
      "essentials": {
        "alertRule": "manual-test",
        "severity": "Sev1",
        "monitorCondition": "Fired",
        "firedDateTime": "'"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"'"
      },
      "alertContext": {
        "conditionType": "SingleResourceMultipleMetricCriteria",
        "condition": {
          "allOf": [{
            "metricName": "CreatingNodeCount",
            "dimensions": [{"name": "poolId", "value": "'"$PRIMARY_POOL"'"}]
          }]
        }
      }
    }
  }')

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | head -n -1)
  echo "  HTTP: $HTTP_CODE"
  echo "$BODY" | jq . 2>/dev/null || echo "$BODY"

elif [[ "$MODE" == "--wait" ]]; then
  echo "[4/4] Waiting for Azure Monitor alert to fire (max ${MAX_WAIT_MINUTES} min)..."
  echo "  Autoscale will attempt allocation → fail → ServiceLog → alert → webhook → failover"
  echo ""

  POLL_INTERVAL=30
  MAX_POLLS=$(( MAX_WAIT_MINUTES * 60 / POLL_INTERVAL ))

  for (( POLL=1; POLL<=MAX_POLLS; POLL++ )); do
    ELAPSED=$(( POLL * POLL_INTERVAL ))
    CURRENT_POOL=$(az batch job show --job-id "$JOB_ID" --query "poolInfo.poolId" -o tsv 2>/dev/null || echo "unknown")
    if [[ "$CURRENT_POOL" == "$FALLBACK_POOL" ]]; then
      echo "  [$(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s] Job moved to fallback pool!"
      break
    fi
    printf "  [%dm %ds] Waiting... pool=%s\r" "$(( ELAPSED / 60 ))" "$(( ELAPSED % 60 ))" "$CURRENT_POOL"
    sleep "$POLL_INTERVAL"
  done
  echo ""
fi

# ── Result ──
echo ""
NEW_POOL=$(az batch job show --job-id "$JOB_ID" --query "poolInfo.poolId" -o tsv 2>/dev/null)
JOB_STATE=$(az batch job show --job-id "$JOB_ID" --query "state" -o tsv 2>/dev/null)

echo "============================================"
echo "  Result"
echo "============================================"
echo "  Job:   $JOB_ID"
echo "  Pool:  $NEW_POOL"
echo "  State: $JOB_STATE"
if [[ "$NEW_POOL" == "$FALLBACK_POOL" ]]; then
  echo "  ✅ Job running on fallback pool"
elif [[ "$NEW_POOL" == "$PRIMARY_POOL" ]]; then
  echo "  ⏳ Job still on primary pool (alert may not have fired yet)"
fi
echo "============================================"
