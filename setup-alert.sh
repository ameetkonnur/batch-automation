#!/usr/bin/env bash
# setup-alert.sh
# Configures an Azure Monitor metric alert on a Batch account that fires
# when pool allocation looks stuck, then calls the .NET webhook via an
# action group.
#
# Prerequisites:
#   - az cli logged in with Contributor on the target resource group
#   - The Function App already deployed (need its name + resource group)
#
# Usage:
#   export SUBSCRIPTION_ID="..."
#   export RESOURCE_GROUP="..."
#   export BATCH_ACCOUNT="..."
#   export FUNCTION_APP_NAME="..."
#   export FUNCTION_APP_RG="..."          # defaults to RESOURCE_GROUP
#   ./setup-alert.sh
set -euo pipefail

: "${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID}"
: "${RESOURCE_GROUP:?Set RESOURCE_GROUP}"
: "${BATCH_ACCOUNT:?Set BATCH_ACCOUNT}"
: "${FUNCTION_APP_NAME:?Set FUNCTION_APP_NAME}"
FUNCTION_APP_RG="${FUNCTION_APP_RG:-$RESOURCE_GROUP}"

ALERT_NAME="${ALERT_NAME:-batch-pool-allocation-failure}"
ACTION_GROUP_NAME="${ACTION_GROUP_NAME:-ag-batch-failover}"
POOL_ID="${POOL_ID:-pool-hbv4}"
LOCATION="${LOCATION:-eastus}"

BATCH_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Batch/batchAccounts/${BATCH_ACCOUNT}"

echo "=== Azure Monitor alert setup ==="
echo "Subscription:   $SUBSCRIPTION_ID"
echo "Resource Group: $RESOURCE_GROUP"
echo "Batch Account:  $BATCH_ACCOUNT"
echo "Pool ID:        $POOL_ID"
echo "Function App:   $FUNCTION_APP_NAME"
echo ""

az account set --subscription "$SUBSCRIPTION_ID"

# ── 1. Get the Function App webhook URI (function key included) ──
echo "[1/3] Retrieving Function App webhook URI ..."

FUNCTION_ID=$(az functionapp function show \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$FUNCTION_APP_RG" \
  --function-name "BatchAllocationWebhook" \
  --query "id" -o tsv)

FUNCTION_KEY=$(az functionapp function keys list \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$FUNCTION_APP_RG" \
  --function-name "BatchAllocationWebhook" \
  --query "default" -o tsv)

WEBHOOK_URI="https://${FUNCTION_APP_NAME}.azurewebsites.net/api/batch/allocation-alert?code=${FUNCTION_KEY}"
echo "  Webhook URI resolved (key redacted)"

# ── 2. Create action group targeting the webhook ──
echo "[2/3] Creating action group: $ACTION_GROUP_NAME ..."

az monitor action-group create \
  --name "$ACTION_GROUP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --short-name "BatchFO" \
  --action azurefunction \
      "callFailoverWebhook" \
      "$FUNCTION_ID" \
      "BatchAllocationWebhook" \
      "$FUNCTION_KEY"

ACTION_GROUP_ID=$(az monitor action-group show \
  --name "$ACTION_GROUP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "id" -o tsv)

echo "  Action group ID: $ACTION_GROUP_ID"

# ── 3. Create metric alerts ──
# Each failure scenario gets its own alert rule so they fire independently
# (multiple --condition flags in a single rule are AND'd, not OR'd).
#
# Alert A: Start-task failures — nodes allocated but start tasks fail
# Alert B: Unusable nodes      — nodes allocated but marked unusable (bad VM, disk, etc.)
# Alert C: Stuck creating      — nodes stuck in "Creating" (no capacity available);
#                                 catches both manual-scale and autoscale failures

echo "[3/3] Creating metric alerts ..."

# A) Start task failures
echo "  Creating alert: ${ALERT_NAME}-start-task-failure"
az monitor metrics alert create \
  --name "${ALERT_NAME}-start-task-failure" \
  --resource-group "$RESOURCE_GROUP" \
  --scopes "$BATCH_RESOURCE_ID" \
  --description "Pool '${POOL_ID}': nodes are being allocated but start tasks are failing." \
  --severity 1 \
  --evaluation-frequency "PT1M" \
  --window-size "PT5M" \
  --condition "avg StartTaskFailedNodeCount > 0 where poolId includes ${POOL_ID}" \
  --action "$ACTION_GROUP_ID" \
  --auto-mitigate true \
  --tags "purpose=batch-failover" "pool=${POOL_ID}" "scenario=start-task-failure"

# B) Unusable nodes (covers both manual and autoscale pools)
echo "  Creating alert: ${ALERT_NAME}-unusable-nodes"
az monitor metrics alert create \
  --name "${ALERT_NAME}-unusable-nodes" \
  --resource-group "$RESOURCE_GROUP" \
  --scopes "$BATCH_RESOURCE_ID" \
  --description "Pool '${POOL_ID}': nodes transitioned to Unusable state (allocation succeeded but VM is broken)." \
  --severity 1 \
  --evaluation-frequency "PT1M" \
  --window-size "PT5M" \
  --condition "avg UnusableNodeCount > 0 where poolId includes ${POOL_ID}" \
  --action "$ACTION_GROUP_ID" \
  --auto-mitigate true \
  --tags "purpose=batch-failover" "pool=${POOL_ID}" "scenario=unusable-nodes"

# C) Nodes stuck creating — the primary signal for "no capacity" on both
#    fixed-size and autoscale pools.  When autoscale evaluates its formula
#    and sets a target, Azure tries to provision VMs.  If capacity isn't
#    available, nodes stay in "Creating" state indefinitely.  A sustained
#    CreatingNodeCount > 0 over 5 minutes means the allocation is stalled.
echo "  Creating alert: ${ALERT_NAME}-stuck-creating"
az monitor metrics alert create \
  --name "${ALERT_NAME}-stuck-creating" \
  --resource-group "$RESOURCE_GROUP" \
  --scopes "$BATCH_RESOURCE_ID" \
  --description "Pool '${POOL_ID}': nodes stuck in Creating state for 5+ min (no VM capacity — affects both fixed-size and autoscale pools)." \
  --severity 1 \
  --evaluation-frequency "PT1M" \
  --window-size "PT5M" \
  --condition "avg CreatingNodeCount > 0 where poolId includes ${POOL_ID}" \
  --action "$ACTION_GROUP_ID" \
  --auto-mitigate true \
  --tags "purpose=batch-failover" "pool=${POOL_ID}" "scenario=stuck-creating"

echo ""
echo "=== Done ==="
echo "Alerts created:"
echo "  ${ALERT_NAME}-start-task-failure  — nodes allocated, start task fails"
echo "  ${ALERT_NAME}-unusable-nodes      — nodes became unusable (bad VM)"
echo "  ${ALERT_NAME}-stuck-creating      — no capacity (autoscale or fixed)"
echo "Action group: $ACTION_GROUP_NAME"
echo "Webhook:      ${FUNCTION_APP_NAME} → BatchAllocationWebhook"
echo ""
echo "To verify:"
echo "  az monitor metrics alert list --resource-group $RESOURCE_GROUP -o table"
echo "  az monitor action-group show  --name $ACTION_GROUP_NAME --resource-group $RESOURCE_GROUP"
