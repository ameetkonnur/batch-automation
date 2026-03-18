#!/usr/bin/env bash
# setup-log-based-alert.sh
# Configures Azure Monitor log-based (Scheduled Query Rule) alert on the Batch
# account that fires when a pool resize completes with errors (e.g. quota
# exceeded, capacity unavailable).
#
# This catches instant allocation failures that metric-based alerts miss
# (metrics like CreatingNodeCount never rise when quota is rejected immediately).
#
# What it does:
#   1. Enables Batch diagnostic logs (ServiceLog) → Log Analytics workspace
#   2. Creates a Scheduled Query Rule alert that runs a KQL query every 5 min
#      looking for resize errors in the ServiceLog
#   3. The alert fires the existing action group (webhook → Container App API)
#
# Prerequisites:
#   - az cli logged in with Contributor on the target resource group
#   - Action group 'ag-batch-alloc-webhook' already exists (from setup-allocation-alert.sh)
#   - Log Analytics workspace exists in the resource group
#
# Usage:
#   export SUBSCRIPTION_ID="..."
#   export RESOURCE_GROUP="..."
#   export BATCH_ACCOUNT="..."
#   export WORKSPACE_NAME="..."
#   ./setup-log-based-alert.sh
set -euo pipefail

: "${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID}"
: "${RESOURCE_GROUP:?Set RESOURCE_GROUP}"
: "${BATCH_ACCOUNT:?Set BATCH_ACCOUNT}"
WORKSPACE_NAME="${WORKSPACE_NAME:-workspace-batchP9ma}"
ACTION_GROUP_NAME="${ACTION_GROUP_NAME:-ag-batch-alloc-webhook}"
ALERT_NAME="${ALERT_NAME:-batch-resize-error-log-alert}"
DIAG_SETTING_NAME="${DIAG_SETTING_NAME:-batch-logs-to-laws}"

BATCH_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Batch/batchAccounts/${BATCH_ACCOUNT}"

echo "============================================"
echo "  Log-Based Alert Setup"
echo "============================================"
echo "Subscription:   $SUBSCRIPTION_ID"
echo "Resource Group: $RESOURCE_GROUP"
echo "Batch Account:  $BATCH_ACCOUNT"
echo "Workspace:      $WORKSPACE_NAME"
echo "Action Group:   $ACTION_GROUP_NAME"
echo "Alert Name:     $ALERT_NAME"
echo ""

az account set --subscription "$SUBSCRIPTION_ID"

# ── 1. Get resource IDs ──
echo "[1/3] Resolving resource IDs..."

WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --workspace-name "$WORKSPACE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "id" -o tsv)
echo "  Workspace: $WORKSPACE_ID"

ACTION_GROUP_ID=$(az monitor action-group show \
  --name "$ACTION_GROUP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "id" -o tsv)
echo "  Action Group: $ACTION_GROUP_ID"

# ── 2. Enable diagnostic logs ──
echo ""
echo "[2/3] Enabling Batch diagnostic logs → Log Analytics..."

# Check if our diagnostic setting already exists
EXISTING=$(az monitor diagnostic-settings show \
  --name "$DIAG_SETTING_NAME" \
  --resource "$BATCH_RESOURCE_ID" \
  --query "name" -o tsv 2>/dev/null || echo "")

if [[ -n "$EXISTING" ]]; then
  echo "  Diagnostic setting '$DIAG_SETTING_NAME' already exists — updating..."
fi

az monitor diagnostic-settings create \
  --name "$DIAG_SETTING_NAME" \
  --resource "$BATCH_RESOURCE_ID" \
  --workspace "$WORKSPACE_ID" \
  --logs '[
    {"category": "ServiceLog", "enabled": true, "retentionPolicy": {"enabled": false, "days": 0}},
    {"category": "AuditLog",   "enabled": true, "retentionPolicy": {"enabled": false, "days": 0}}
  ]' \
  --metrics '[
    {"category": "AllMetrics", "enabled": true, "retentionPolicy": {"enabled": false, "days": 0}}
  ]' \
  -o none

echo "  Diagnostic logs enabled: ServiceLog, AuditLog, AllMetrics → $WORKSPACE_NAME"

# ── 3. Create Scheduled Query Rule alert ──
echo ""
echo "[3/3] Creating log-based alert: $ALERT_NAME..."

# KQL query: detects pool resize failures from Batch ServiceLog.
# This is pool-agnostic — fires for ANY pool that fails to resize.
# The API determines which pools are primary vs fallback and only
# acts on primary pools.
KQL_QUERY='AzureDiagnostics
| where ResourceProvider == "MICROSOFT.BATCH"
| where Category == "ServiceLog"
| where OperationName == "PoolResizeCompleteEvent"
| where resultCode_s == "Failure"
| project TimeGenerated, poolId=id_s, resultCode_s, targetDedicatedNodes_d, currentDedicatedNodes_d
| summarize ErrorCount=count(), arg_max(TimeGenerated, *) by poolId'

# Create or update the scheduled query rule
az monitor scheduled-query create \
  --name "$ALERT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --scopes "$WORKSPACE_ID" \
  --condition "count 'q0' > 0" \
  --condition-query q0="$KQL_QUERY" \
  --description "Fires when any Batch pool resize fails. The webhook API determines primary vs fallback pools and only fails over primary pools." \
  --severity 1 \
  --evaluation-frequency "5m" \
  --window-size "10m" \
  --action-groups "$ACTION_GROUP_ID" \
  --auto-mitigate false \
  --skip-query-validation true \
  -o none 2>&1

echo "  Log-based alert created: $ALERT_NAME"

echo ""
echo "============================================"
echo "  Setup Complete"
echo "============================================"
echo ""
echo "Flow:"
echo "  Pool resize fails"
echo "    → Batch writes ServiceLog to Log Analytics"
echo "    → Scheduled query runs every 5 min"
echo "    → Detects resize errors in logs"
echo "    → Fires alert → action group → webhook"
echo "    → Container App API performs failover"
echo ""
echo "Note: It may take 5-10 min for the first diagnostic logs to appear"
echo "in Log Analytics after enabling. Plan for ~10 min total latency"
echo "(log ingestion delay + 5 min query interval)."
echo ""
echo "Verify:"
echo "  az monitor scheduled-query show --name $ALERT_NAME --resource-group $RESOURCE_GROUP"
echo "  az monitor diagnostic-settings show --name $DIAG_SETTING_NAME --resource $BATCH_RESOURCE_ID"
echo ""
echo "Test query in Log Analytics:"
echo "  $KQL_QUERY"
