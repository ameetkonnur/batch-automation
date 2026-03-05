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
