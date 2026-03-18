#!/usr/bin/env bash
# setup-allocation-alert.sh
# Creates an Azure Monitor metric alert on a Batch account that fires on
# pool allocation failures and calls a custom webhook endpoint.
#
# Usage:
#   export SUBSCRIPTION_ID="..."
#   export RESOURCE_GROUP="..."
#   export BATCH_ACCOUNT="..."
#   export WEBHOOK_URL="https://my-api.example.com/api/batch/allocation-alert"
#   export POOL_ID="pool-hbv4-err-..."   # optional, defaults to all pools
#   ./setup-allocation-alert.sh
set -euo pipefail

: "${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID}"
: "${RESOURCE_GROUP:?Set RESOURCE_GROUP}"
: "${BATCH_ACCOUNT:?Set BATCH_ACCOUNT}"
: "${WEBHOOK_URL:?Set WEBHOOK_URL — your .NET API endpoint}"

ALERT_NAME="${ALERT_NAME:-batch-alloc-failure}"
ACTION_GROUP_NAME="${ACTION_GROUP_NAME:-ag-batch-alloc-webhook}"
POOL_ID="${POOL_ID:-}"

BATCH_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Batch/batchAccounts/${BATCH_ACCOUNT}"

echo "=== Azure Monitor allocation-failure alert setup ==="
echo "Subscription:   $SUBSCRIPTION_ID"
echo "Resource Group: $RESOURCE_GROUP"
echo "Batch Account:  $BATCH_ACCOUNT"
echo "Webhook URL:    $WEBHOOK_URL"
echo "Pool filter:    ${POOL_ID:-<all pools>}"
echo ""

az account set --subscription "$SUBSCRIPTION_ID"

# ── 1. Create / update action group with webhook ──
echo "[1/2] Creating action group: $ACTION_GROUP_NAME ..."

az monitor action-group create \
  --name "$ACTION_GROUP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --short-name "BatchWH" \
  --action webhook "callBatchApi" "$WEBHOOK_URL" \
  -o none

ACTION_GROUP_ID=$(az monitor action-group show \
  --name "$ACTION_GROUP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "id" -o tsv)

echo "  Action group: $ACTION_GROUP_ID"

# ── 2. Build pool-scoped condition or account-wide ──
# When POOL_ID is set, alerts are scoped to that pool via dimension filter.
# Otherwise they fire for any pool on the account.

build_condition() {
  local metric="$1"
  if [[ -n "$POOL_ID" ]]; then
    echo "avg ${metric} > 0 where poolId includes ${POOL_ID}"
  else
    echo "avg ${metric} > 0"
  fi
}

echo "[2/2] Creating metric alerts ..."

# A) Start-task failures — nodes allocated but start tasks fail
ALERT_A="${ALERT_NAME}-start-task-failure"
echo "  Creating: $ALERT_A"
az monitor metrics alert create \
  --name "$ALERT_A" \
  --resource-group "$RESOURCE_GROUP" \
  --scopes "$BATCH_RESOURCE_ID" \
  --description "Batch pool${POOL_ID:+ '${POOL_ID}'}: start tasks failing on allocated nodes." \
  --severity 1 \
  --evaluation-frequency "PT1M" \
  --window-size "PT5M" \
  --condition "$(build_condition StartTaskFailedNodeCount)" \
  --action "$ACTION_GROUP_ID" \
  --auto-mitigate true \
  --tags "purpose=batch-failover" "scenario=start-task-failure" \
  -o none

# B) Unusable nodes — allocation succeeded but VM is broken
ALERT_B="${ALERT_NAME}-unusable-nodes"
echo "  Creating: $ALERT_B"
az monitor metrics alert create \
  --name "$ALERT_B" \
  --resource-group "$RESOURCE_GROUP" \
  --scopes "$BATCH_RESOURCE_ID" \
  --description "Batch pool${POOL_ID:+ '${POOL_ID}'}: nodes in Unusable state." \
  --severity 1 \
  --evaluation-frequency "PT1M" \
  --window-size "PT5M" \
  --condition "$(build_condition UnusableNodeCount)" \
  --action "$ACTION_GROUP_ID" \
  --auto-mitigate true \
  --tags "purpose=batch-failover" "scenario=unusable-nodes" \
  -o none

# C) Stuck creating — primary signal for quota / capacity failures.
#    When the pool requests nodes but can't allocate (e.g.
#    AccountVMSeriesCoreQuotaReached), nodes sit in "Creating" then
#    the pool goes steady with resizeErrors.  A sustained
#    CreatingNodeCount > 0 over 5 min signals a stalled allocation.
ALERT_C="${ALERT_NAME}-stuck-creating"
echo "  Creating: $ALERT_C"
az monitor metrics alert create \
  --name "$ALERT_C" \
  --resource-group "$RESOURCE_GROUP" \
  --scopes "$BATCH_RESOURCE_ID" \
  --description "Batch pool${POOL_ID:+ '${POOL_ID}'}: nodes stuck in Creating state (quota/capacity issue)." \
  --severity 1 \
  --evaluation-frequency "PT1M" \
  --window-size "PT5M" \
  --condition "$(build_condition CreatingNodeCount)" \
  --action "$ACTION_GROUP_ID" \
  --auto-mitigate true \
  --tags "purpose=batch-failover" "scenario=stuck-creating" \
  -o none

echo ""
echo "=== Done ==="
echo "Alerts created:"
echo "  $ALERT_A  — start task failures"
echo "  $ALERT_B  — unusable nodes"
echo "  $ALERT_C  — stuck creating (quota/capacity)"
echo "Action group: $ACTION_GROUP_NAME → $WEBHOOK_URL"
echo ""
echo "Verify:"
echo "  az monitor metrics alert list --resource-group $RESOURCE_GROUP -o table"
