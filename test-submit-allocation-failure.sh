#!/usr/bin/env bash
# test-submit-allocation-failure.sh
# Creates a pool + job that will hit an allocation error for testing.
# Uses an absurdly high node count on a constrained VM size to force the failure.
#
# Prerequisites: az cli logged in, env vars set (see below).
set -euo pipefail

: "${BATCH_ACCOUNT_NAME:?Set BATCH_ACCOUNT_NAME}"
: "${RESOURCE_GROUP:?Set RESOURCE_GROUP}"

POOL_ID="pool-hbv4"
JOB_ID="test-alloc-fail-$(date -u +%Y%m%dT%H%M%SZ)"
VM_SIZE="Standard_HB120rs_v4"
TARGET_NODES=9999  # way beyond quota → allocation failure

echo "=== Test: force allocation failure ==="
echo "Pool:   $POOL_ID"
echo "Job:    $JOB_ID"
echo "VM:     $VM_SIZE"
echo "Nodes:  $TARGET_NODES (intentionally over quota)"
echo ""

# ── 1. Create pool (ignore error if it already exists) ──
echo "[1/3] Creating pool $POOL_ID ..."
az batch pool create \
  --account-name "$BATCH_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --id "$POOL_ID" \
  --vm-size "$VM_SIZE" \
  --target-dedicated-nodes "$TARGET_NODES" \
  --image "canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest" \
  --node-agent-sku-id "batch.node.ubuntu 22.04" \
  2>&1 || echo "(pool may already exist — continuing)"

# ── 2. Submit a job targeting that pool ──
echo ""
echo "[2/3] Creating job $JOB_ID on pool $POOL_ID ..."
az batch job create \
  --account-name "$BATCH_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --id "$JOB_ID" \
  --pool-id "$POOL_ID"

# ── 3. Add a simple task ──
echo ""
echo "[3/3] Adding task to job $JOB_ID ..."
az batch task create \
  --account-name "$BATCH_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --job-id "$JOB_ID" \
  --task-id "task-1" \
  --command-line "/bin/bash -c 'echo hello from test task; sleep 10'"

echo ""
echo "=== Done ==="
echo "Pool $POOL_ID will be stuck resizing (allocation failure)."
echo "Job $JOB_ID is queued but tasks can't run."
echo ""
echo "Check pool status:"
echo "  az batch pool show --account-name $BATCH_ACCOUNT_NAME --resource-group $RESOURCE_GROUP --pool-id $POOL_ID --query '[allocationState,currentDedicatedNodes,targetDedicatedNodes,resizeErrors]'"
echo ""
echo "To test the webhook API, run:"
echo "  ./test-send-webhook.sh"
