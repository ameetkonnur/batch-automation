# AGEAS Azure Batch Allocation Failover Automation (AZ CLI)

## What problem this solves (and how)
AGEAS/AG Insurance HPC runs can fail **even when quota exists** because **capacity isn’t available at allocation time**. When that happens, Azure Batch pools can get stuck in resize/allocation failures and the run requires manual intervention.

This document implements a **simple, reliable multi-pool failover** pattern:

**Architecture (simple + reliable)**
Two pools in the same Batch account:

- `pool-hbv4` (primary)
- `pool-edsv5` (fallback)

**Automation loop**

- Monitor for allocation failure signals (pool resize failing / nodes unusable / no nodes coming online)
- If failure condition persists for **N minutes**:
  - scale down primary pool
  - scale up fallback pool
  - (optionally) re-queue jobs / ensure job-level pool selection for the rerun
- Send notification to Teams/email.

This matches the “multi-pool + automation” approach mentioned in the AGEAS discussions.

---

## Key constraints (don’t skip)
- This automation **does not guarantee capacity** and **does not reserve HBv4**.
- It **does not enable checkpointing**; interrupted workloads must be restarted.

---

## Components delivered in this package
- `failover-controller.sh` – health check + persistence window + cooldown + failover
- `submit-job-with-metadata.sh` – job submission helper that adds metadata for traceability
- `runbook-HandleBatchAllocationAlert.ps1` – Azure Automation runbook (Common Alert Schema webhook) that can call the controller

---

## Prerequisites

### Tools
- Azure CLI
- Bash (Linux shell) for the controller/submission helper

### RBAC
The identity running this needs rights to:
- read pool state
- resize pools
- create jobs/tasks (if you use the submission helper)

---

## Environment variables

```bash
export SUBSCRIPTION_ID="<subscription-id>"
export RESOURCE_GROUP="<resource-group>"
export BATCH_ACCOUNT="<batch-account-name>"

export PRIMARY_POOL="pool-hbv4"
export FALLBACK_POOL="pool-edsv5"

# operational knobs
export PERSIST_MINUTES=10          # N minutes: failure must persist this long
export COOLDOWN_MINUTES=30         # prevents pool flapping
export CHECK_INTERVAL_SECONDS=60   # how often controller runs when in loop mode

# scale targets
export PRIMARY_TARGET_NODES=0      # typically 0 during failover action
export FALLBACK_TARGET_NODES=50

# notification (optional)
export WEBHOOK_URL=""             # Teams/LogicApp webhook; leave blank to disable
```

---

## 1) Enhanced controller: persistence window + cooldown (avoid flapping)

### `failover-controller.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${SUBSCRIPTION_ID:?}"
: "${RESOURCE_GROUP:?}"
: "${BATCH_ACCOUNT:?}"
: "${PRIMARY_POOL:?}"
: "${FALLBACK_POOL:?}"

PERSIST_MINUTES=${PERSIST_MINUTES:-10}
COOLDOWN_MINUTES=${COOLDOWN_MINUTES:-30}
CHECK_INTERVAL_SECONDS=${CHECK_INTERVAL_SECONDS:-60}

PRIMARY_TARGET_NODES=${PRIMARY_TARGET_NODES:-0}
FALLBACK_TARGET_NODES=${FALLBACK_TARGET_NODES:-50}

STATE_DIR=${STATE_DIR:-"/tmp/ageas-batch-failover"}
STATE_FILE="$STATE_DIR/state.env"
mkdir -p "$STATE_DIR"

now_epoch() { date +%s; }

# state variables (defaults)
FIRST_FAILURE_EPOCH=""
LAST_FAILOVER_EPOCH=""
ACTIVE_POOL=""
FAILOVER_COUNT=0

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
  fi
}

save_state() {
  cat > "$STATE_FILE" <<EOF
FIRST_FAILURE_EPOCH="${FIRST_FAILURE_EPOCH}"
LAST_FAILOVER_EPOCH="${LAST_FAILOVER_EPOCH}"
ACTIVE_POOL="${ACTIVE_POOL}"
FAILOVER_COUNT=${FAILOVER_COUNT}
EOF
}

pool_snapshot_tsv() {
  local pool_id="$1"
  az batch pool show \
    --account-name "$BATCH_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --pool-id "$pool_id" \
    --query "[allocationState,targetDedicatedNodes,currentDedicatedNodes]" \
    -o tsv
}

is_allocation_failure() {
  # Heuristic: target > 0, current == 0, allocationState == resizing
  local alloc="$1"; local target="$2"; local current="$3"
  if [[ "$alloc" == "resizing" && "$target" != "" && "$current" != "" ]]; then
    if [[ "$target" -gt 0 && "$current" -eq 0 ]]; then
      return 0
    fi
  fi
  return 1
}

cooldown_active() {
  if [[ -z "$LAST_FAILOVER_EPOCH" ]]; then
    return 1
  fi
  local now; now=$(now_epoch)
  local cooldown=$(( COOLDOWN_MINUTES * 60 ))
  if (( now - LAST_FAILOVER_EPOCH < cooldown )); then
    return 0
  fi
  return 1
}

notify() {
  local message="$1"
  if [[ -n "${WEBHOOK_URL:-}" ]]; then
    curl -sS -X POST "$WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"AGEAS Batch Failover\",\"message\":\"$message\"}" >/dev/null || true
  fi
}

perform_failover() {
  echo "[ACTION] Scaling down primary pool: $PRIMARY_POOL -> $PRIMARY_TARGET_NODES"
  az batch pool resize \
    --account-name "$BATCH_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --pool-id "$PRIMARY_POOL" \
    --target-dedicated-nodes "$PRIMARY_TARGET_NODES"

  echo "[ACTION] Scaling up fallback pool: $FALLBACK_POOL -> $FALLBACK_TARGET_NODES"
  az batch pool resize \
    --account-name "$BATCH_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --pool-id "$FALLBACK_POOL" \
    --target-dedicated-nodes "$FALLBACK_TARGET_NODES"
}

step_once() {
  az account set --subscription "$SUBSCRIPTION_ID" >/dev/null
  load_state

  # Get primary pool state
  local line alloc target current
  line=$(pool_snapshot_tsv "$PRIMARY_POOL")
  alloc=$(echo "$line" | awk '{print $1}')
  target=$(echo "$line" | awk '{print $2}')
  current=$(echo "$line" | awk '{print $3}')

  echo "[INFO] primary=$PRIMARY_POOL alloc=$alloc target=$target current=$current"

  if is_allocation_failure "$alloc" "$target" "$current"; then
    local now; now=$(now_epoch)

    if [[ -z "$FIRST_FAILURE_EPOCH" ]]; then
      FIRST_FAILURE_EPOCH=$now
      save_state
      echo "[WARN] Allocation failure detected on $PRIMARY_POOL. Starting persistence timer."
      notify "Allocation failure detected on $PRIMARY_POOL. Starting persistence timer."
      return 0
    fi

    if cooldown_active; then
      echo "[INFO] Failure persists but cooldown is active; skipping failover."
      return 0
    fi

    local persist_seconds=$(( PERSIST_MINUTES * 60 ))
    local elapsed=$(( now - FIRST_FAILURE_EPOCH ))

    if (( elapsed >= persist_seconds )); then
      echo "[CRIT] Failure persisted for ${PERSIST_MINUTES}m. Triggering failover."
      perform_failover

      FAILOVER_COUNT=$(( FAILOVER_COUNT + 1 ))
      LAST_FAILOVER_EPOCH=$now
      ACTIVE_POOL="$FALLBACK_POOL"
      FIRST_FAILURE_EPOCH=""
      save_state

      notify "Failover executed. Primary=$PRIMARY_POOL -> Fallback=$FALLBACK_POOL. failover_count=$FAILOVER_COUNT"
    else
      echo "[INFO] Failure ongoing. elapsed=${elapsed}s < persist=${persist_seconds}s."
    fi
  else
    # No failure observed
    if [[ -n "$FIRST_FAILURE_EPOCH" ]]; then
      echo "[INFO] Failure cleared before persistence threshold. Resetting timer."
      FIRST_FAILURE_EPOCH=""
      save_state
      notify "Allocation failure cleared on $PRIMARY_POOL before threshold."
    fi
  fi
}

loop() {
  while true; do
    step_once || true
    sleep "$CHECK_INTERVAL_SECONDS"
  done
}

case "${1:-}" in
  --once) step_once ;;
  --loop|"") loop ;;
  *) echo "Usage: $0 [--once|--loop]"; exit 1 ;;
esac
```

**How it prevents flapping**
- Requires failure to persist **PERSIST_MINUTES** before triggering.
- Enforces **COOLDOWN_MINUTES** after a failover before allowing another.

---

## 2) Job-level tagging for rerun traceability
Azure CLI supports **job metadata** on `az batch job create`.

### `submit-job-with-metadata.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${SUBSCRIPTION_ID:?}"
: "${RESOURCE_GROUP:?}"
: "${BATCH_ACCOUNT:?}"
: "${PRIMARY_POOL:?}"
: "${FALLBACK_POOL:?}"

JOB_PREFIX=${JOB_PREFIX:-"ageas-run"}
TASKS_JSON=${TASKS_JSON:-"tasks.json"}

STATE_DIR=${STATE_DIR:-"/tmp/ageas-batch-failover"}
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
```

**Traceability outcome**
- Each job carries `runId`, `requestedPool`, `activePool`, and a `trace` marker.
- Tasks get `RUN_ID` and `ACTIVE_POOL` injected as environment variables.

---

## 3) Azure Monitor alert → Azure Automation Runbook
You can trigger an Automation runbook from Azure Monitor using an **Action Group**, which calls the runbook via an HTTP POST (webhook). Use the **Common Alert Schema**.

### Runbook: `runbook-HandleBatchAllocationAlert.ps1`

```powershell
param(
  [Parameter(Mandatory=$false)]
  [object] $WebhookData
)

Write-Output "Runbook started"

if ($null -eq $WebhookData -or [string]::IsNullOrEmpty($WebhookData.RequestBody)) {
  Write-Output "No WebhookData.RequestBody found. Exiting."
  return
}

$payload = $WebhookData.RequestBody | ConvertFrom-Json

$alertId = $payload.data.essentials.alertId
$severity = $payload.data.essentials.severity
$rule = $payload.data.essentials.alertRule

Write-Output "AlertId=$alertId Severity=$severity Rule=$rule"

# Hybrid Worker example: call controller once
$cmd = "/bin/bash /opt/ageas/failover-controller.sh --once"
Write-Output "Executing: $cmd"

bash -c $cmd

Write-Output "Runbook completed"
```

### Wiring steps (high level)
1. Enable Batch diagnostics to Log Analytics (ServiceLog/PoolResize events recommended).
2. Create an Alert rule that detects pool resize failures.
3. Attach an Action Group that triggers the Automation runbook (Common Alert Schema enabled).

---

## Recommended hardening checklist
- Add a second failure signal (e.g., PoolResizeCompleteEvent resultCode != Success) in addition to the heuristic.
- Store state in a durable place (Automation Variable, Key Vault, Storage) if not running on a single host.
- Add “cooldown override” for manual operator actions.
- Add ‘dry-run’ mode for testing.

---

## Status
This is a starter operational kit intended to be reviewed and hardened before production.
