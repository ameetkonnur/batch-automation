#!/usr/bin/env bash
# test-failover-e2e.sh
# End-to-end test: submits a job on the HBv4 pool (which has an allocation
# failure), then waits for Azure Monitor to detect the resize error in
# diagnostic logs, fire the alert, and call the webhook which moves the job
# to the E2s_v3 pool.
#
# Mode:
#   --wait    (default) Wait for real Azure Monitor alert to fire
#   --manual  Directly call the webhook (faster, for quick validation)
#
# Usage:
#   ./test-failover-e2e.sh          # wait for real alert
#   ./test-failover-e2e.sh --manual # call webhook directly
#
# Config (override via env vars):
#   BATCH_ACCOUNT_NAME  — default: batchaccountameetk
#   RESOURCE_GROUP      — default: batch
#   HB_POOL_ID          — the failing HBv4 pool
#   EV3_POOL_ID         — the healthy E2s_v3 fallback pool
#   WEBHOOK_URL         — the Container App webhook endpoint
#   MAX_WAIT_MINUTES    — how long to wait for alert (default: 15)
set -euo pipefail

MODE="${1:---wait}"
BATCH_ACCOUNT_NAME="${BATCH_ACCOUNT_NAME:-batchaccountameetk}"
RESOURCE_GROUP="${RESOURCE_GROUP:-batch}"
HB_POOL_ID="${HB_POOL_ID:-pool-hbv4-err-20260317T091514Z}"
EV3_POOL_ID="${EV3_POOL_ID:-pool-ev3-swedencentral-20260317T091042Z}"
WEBHOOK_URL="${WEBHOOK_URL:-https://batch-failover-api.jollyocean-1d29d8d9.eastus.azurecontainerapps.io/api/batch/allocation-alert}"
MAX_WAIT_MINUTES="${MAX_WAIT_MINUTES:-15}"

JOB_ID="test-failover-$(date -u +%Y%m%dT%H%M%SZ)"

echo "============================================"
echo "  Batch Failover End-to-End Test"
echo "============================================"
echo "Mode:           $MODE"
echo "Batch Account:  $BATCH_ACCOUNT_NAME"
echo "HB Pool (src):  $HB_POOL_ID"
echo "E Pool (dest):  $EV3_POOL_ID"
echo "Job ID:         $JOB_ID"
if [[ "$MODE" == "--manual" ]]; then
  echo "Webhook:        $WEBHOOK_URL"
else
  echo "Max wait:       ${MAX_WAIT_MINUTES} minutes (for Azure Monitor alert)"
fi
echo ""

# ── 0. Login to batch account ──
echo "[0/5] Logging into batch account..."
az batch account login \
  --name "$BATCH_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" 2>/dev/null

# ── 1. Verify HB pool has allocation failure ──
echo "[1/5] Checking HB pool allocation status..."
RESIZE_ERRORS=$(az batch pool show --pool-id "$HB_POOL_ID" \
  --query "resizeErrors[0].code" -o tsv 2>/dev/null || echo "")

if [[ -z "$RESIZE_ERRORS" ]]; then
  echo "  WARNING: HB pool has no resize errors. Forcing resize to trigger failure..."
  az batch pool resize --pool-id "$HB_POOL_ID" --target-dedicated-nodes 9999 2>/dev/null || true
  echo "  Waiting 30s for allocation failure..."
  sleep 30
  RESIZE_ERRORS=$(az batch pool show --pool-id "$HB_POOL_ID" \
    --query "resizeErrors[0].code" -o tsv 2>/dev/null || echo "")
fi
echo "  HB pool resize error: ${RESIZE_ERRORS:-none}"

# ── 2. Submit a job targeting the HB pool ──
echo ""
echo "[2/5] Submitting job '$JOB_ID' on HB pool..."
az batch job create \
  --id "$JOB_ID" \
  --pool-id "$HB_POOL_ID"

az batch task create \
  --job-id "$JOB_ID" \
  --task-id "task-1" \
  --command-line "/bin/bash -c 'echo hello from failover test; sleep 30'"

echo "  Job created and task added."

# Verify job is on HB pool
CURRENT_POOL=$(az batch job show --job-id "$JOB_ID" \
  --query "poolInfo.poolId" -o tsv)
echo "  Job pool (before failover): $CURRENT_POOL"

# ── 3. Trigger failover ──
echo ""
if [[ "$MODE" == "--manual" ]]; then
  # ── 3a. Manual mode: call webhook directly ──
  echo "[3/5] Firing webhook directly to trigger failover..."
  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d '{
    "schemaId": "azureMonitorCommonAlertSchema",
    "data": {
      "essentials": {
        "alertId": "/subscriptions/112c43af-e391-41b6-813d-ffffedeeb871/providers/Microsoft.AlertsManagement/alerts/test-e2e-'"$JOB_ID"'",
        "alertRule": "batch-alloc-failure-stuck-creating",
        "severity": "Sev1",
        "signalType": "Metric",
        "monitorCondition": "Fired",
        "monitoringService": "Platform",
        "alertTargetIDs": ["/subscriptions/112c43af-e391-41b6-813d-ffffedeeb871/resourceGroups/batch/providers/Microsoft.Batch/batchAccounts/'"$BATCH_ACCOUNT_NAME"'"],
        "configurationItems": ["'"$BATCH_ACCOUNT_NAME"'"],
        "firedDateTime": "'"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"'",
        "description": "E2E test: allocation failure on '"$HB_POOL_ID"'"
      },
      "alertContext": {
        "conditionType": "SingleResourceMultipleMetricCriteria",
        "condition": {
          "windowSize": "PT5M",
          "allOf": [{
            "metricName": "CreatingNodeCount",
            "metricNamespace": "Microsoft.Batch/batchAccounts",
            "operator": "GreaterThan",
            "threshold": "0",
            "timeAggregation": "Average",
            "metricValue": 9999.0,
            "dimensions": [{"name": "poolId", "value": "'"$HB_POOL_ID"'"}]
          }]
        }
      }
    }
  }')

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | head -n -1)

  echo "  HTTP status: $HTTP_CODE"
  echo "  Response:"
  echo "$BODY" | jq . 2>/dev/null || echo "$BODY"

  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "  ERROR: Webhook returned non-200 status"
    exit 1
  fi

  ACTION=$(echo "$BODY" | jq -r '.action // "unknown"' 2>/dev/null || echo "unknown")
  echo "  Failover action: $ACTION"

else
  # ── 3b. Wait mode: re-trigger resize error and wait for Azure Monitor ──
  echo "[3/5] Re-triggering allocation failure and waiting for Azure Monitor..."

  # Force a fresh resize to generate new diagnostic log entries
  echo "  Resizing pool to 0..."
  az batch pool resize --pool-id "$HB_POOL_ID" --target-dedicated-nodes 0 2>/dev/null || true
  sleep 5
  echo "  Resizing pool to 9999 (will fail on quota)..."
  az batch pool resize --pool-id "$HB_POOL_ID" --target-dedicated-nodes 9999 2>/dev/null || true

  echo ""
  echo "  Now waiting for Azure Monitor to detect the resize error in diagnostic logs."
  echo "  The scheduled query alert runs every 5 min. With log ingestion delay,"
  echo "  expect ~5-15 min before the webhook is called automatically."
  echo ""

  POLL_INTERVAL=30
  MAX_POLLS=$(( MAX_WAIT_MINUTES * 60 / POLL_INTERVAL ))
  POLL=0

  while [[ $POLL -lt $MAX_POLLS ]]; do
    POLL=$((POLL + 1))
    ELAPSED=$(( POLL * POLL_INTERVAL ))
    ELAPSED_MIN=$(( ELAPSED / 60 ))

    # Check if the job has moved to the fallback pool
    CURRENT_POOL=$(az batch job show --job-id "$JOB_ID" \
      --query "poolInfo.poolId" -o tsv 2>/dev/null || echo "unknown")

    if [[ "$CURRENT_POOL" == "$EV3_POOL_ID" ]]; then
      echo "  [${ELAPSED_MIN}m] Job moved to E pool! Alert fired and failover completed."
      break
    fi

    printf "  [%dm %ds] Waiting... job still on: %s\r" "$ELAPSED_MIN" "$((ELAPSED % 60))" "$CURRENT_POOL"
    sleep "$POLL_INTERVAL"
  done
  echo ""
fi

# ── 4. Verify job moved to E pool ──
echo ""
echo "[4/5] Verifying job pool assignment..."
sleep 3
NEW_POOL=$(az batch job show --job-id "$JOB_ID" \
  --query "poolInfo.poolId" -o tsv)
JOB_STATE=$(az batch job show --job-id "$JOB_ID" \
  --query "state" -o tsv)

echo "  Job pool (after failover):  $NEW_POOL"
echo "  Job state:                  $JOB_STATE"

# ── 5. Result ──
echo ""
echo "============================================"
if [[ "$NEW_POOL" == "$EV3_POOL_ID" ]]; then
  echo "  ✅ SUCCESS: Job moved from HB → E pool"
  echo "     $HB_POOL_ID → $EV3_POOL_ID"
  if [[ "$MODE" != "--manual" ]]; then
    echo "     (triggered by real Azure Monitor alert)"
  fi
  RESULT=0
else
  if [[ "$MODE" != "--manual" ]]; then
    echo "  ⏰ TIMEOUT: Job was not moved within ${MAX_WAIT_MINUTES} minutes"
    echo "     Job is still on: $NEW_POOL"
    echo "     This can happen if:"
    echo "       - Diagnostic logs haven't appeared in Log Analytics yet (first-time delay ~10 min)"
    echo "       - The KQL query columns don't match the actual log schema"
    echo "       - The scheduled query alert hasn't evaluated yet"
    echo ""
    echo "     Debug:"
    echo "       az monitor scheduled-query show --name batch-resize-error-log-alert --resource-group $RESOURCE_GROUP"
    echo "       # Check Log Analytics for Batch diagnostic data:"
    echo "       az monitor log-analytics query --workspace-name workspace-batchP9ma -g $RESOURCE_GROUP \\"
    echo "         --analytics-query \"AzureDiagnostics | where ResourceProvider == 'MICROSOFT.BATCH' | take 5\""
  else
    echo "  ❌ FAIL: Job is still on $NEW_POOL"
    echo "     Expected: $EV3_POOL_ID"
  fi
  RESULT=1
fi
echo "============================================"
echo ""

# Cleanup hint
echo "Cleanup (optional):"
echo "  az batch job delete --job-id $JOB_ID --yes"

exit $RESULT
