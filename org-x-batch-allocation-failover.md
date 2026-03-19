# Azure Batch Allocation Failover Automation

> **DISCLAIMER:** This code is provided on a best-effort basis for reference and educational purposes only. It is **not** validated, endorsed, or supported by Microsoft. This is **not** production-ready code. Organizations using this code should review, test, and adapt it to their own organizational coding standards, including security, compliance, and operational requirements. Microsoft provides no warranties, guarantees, or support for this code and cannot be held responsible for any issues, damages, or losses arising from its use. Use at your own risk.

## Problem

Azure Batch pool allocations can fail even when quota exists — capacity may not be available at allocation time. When autoscale triggers or a manual resize requests nodes, the pool can end up with `resizeErrors` (e.g. `AccountVMSeriesCoreQuotaReached`) and zero running nodes. Jobs submitted to that pool are stuck and require manual intervention.

## Solution

An automated failover system that:
1. Detects pool allocation failures via Azure Monitor (log-based and metric-based alerts)
2. Evaluates whether failover is needed (configurable gates)
3. Moves active jobs from the failing primary pool to a healthy backup pool

```
Pool resize fails (autoscale or manual)
  → Batch writes PoolResizeCompleteEvent(Failure) to ServiceLog
  → ServiceLog ingested into Log Analytics (~2-5 min)
  → Scheduled Query Rule alert evaluates every 5 min (10 min window)
  → Alert fires → Action Group → Webhook
  → .NET API (Container App) receives alert
  → API checks POOL_MAP: only primary pools are evaluated
  → API evaluates gates:
      Gate 1: Node availability < threshold % of autoscale max?
      Gate 2: Job completion < threshold %?
  → If both gates pass: disable job → update pool → re-enable
  → Jobs run on backup pool (autoscales up, then back to 0 when idle)
```

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────────┐
│  Batch Account  │────→│  Log Analytics    │────→│  Scheduled Query    │
│  (ServiceLog)   │     │  (AzureDiag)      │     │  Rule Alert         │
└─────────────────┘     └──────────────────┘     └────────┬────────────┘
                                                          │ fires
                                                          ▼
                                                 ┌─────────────────────┐
                                                 │  Action Group       │
                                                 │  (Webhook)          │
                                                 └────────┬────────────┘
                                                          │ calls
                                                          ▼
                                                 ┌─────────────────────┐
                                                 │  Container App      │
                                                 │  (.NET Failover API)│
                                                 └────────┬────────────┘
                                                          │ moves jobs
                                                          ▼
                                                 ┌─────────────────────┐
                                                 │  Batch Account      │
                                                 │  (job → backup pool)│
                                                 └─────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `api/Program.cs` | Webhook endpoint. Handles both metric-based and log-based alerts. Routes to failover logic. |
| `api/Services/BatchService.cs` | Core failover logic. Pool mapping, gate checks, job move operations. |
| `api/Models/AlertPayload.cs` | Azure Monitor Common Alert Schema deserialization model. |
| `api/Dockerfile` | Container image build. |
| `api/BatchFailoverApi.csproj` | .NET 8 project file with dependencies. |
| `setup-log-based-alert.sh` | Creates diagnostic settings, Log Analytics config, and Scheduled Query Rule alert. |
| `submit-job.sh` | Job submission script. Submits to primary pool and optionally waits for failover. |

---

## Configuration

### POOL_MAP

Maps primary pools to their backup pools. Set as an environment variable on the Container App.

```
POOL_MAP="primary1:backup1:maxNodes,primary2:backup2:maxNodes,..."
```

Example:
```
POOL_MAP="pool-hbv4:pool-ev3:2"
```

- **Primary pools** (keys) — monitored for failures, jobs are moved FROM these
- **Backup pools** (values) — jobs are moved TO these, never failed over themselves
- **maxNodes** — autoscale max for the primary pool (used in node availability gate)

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BATCH_ACCOUNT_URL` | required | Batch account endpoint (e.g. `https://myaccount.eastus.batch.azure.com`) |
| `POOL_MAP` | required | Primary-to-backup pool mapping (see above) |
| `FAILOVER_THRESHOLD_PERCENT` | `80` | Utilization threshold. Set to `0` to skip utilization check. |
| `JOB_COMPLETION_THRESHOLD_PERCENT` | `90` | Jobs above this completion % are left on the current pool to finish. |
| `NODE_AVAILABILITY_THRESHOLD_PERCENT` | `20` | If current nodes are above this % of autoscale max, skip failover (pool has enough nodes). |

### Autoscale

Both pools should have autoscale enabled:

**Primary pool** — scales to 1+ when jobs have pending tasks, generates `PoolResizeCompleteEvent(Failure)` when allocation fails:
```
$samples = $PendingTasks.GetSamplePercent(TimeInterval_Minute * 5);
$tasks = ($samples < 70) ? 0 : max($PendingTasks.GetSample(1));
$TargetDedicatedNodes = ($tasks > 0) ? 1 : 0;
```

**Backup pool** — scales up for tasks, back to 0 when idle (saves cost):
```
$samples = $PendingTasks.GetSamplePercent(TimeInterval_Minute * 5);
$tasks = ($samples < 70) ? max(0, $TargetDedicatedNodes) : max($PendingTasks.GetSample(1));
$TargetDedicatedNodes = ($tasks > 0) ? max(1, $tasks) : 0;
```

> **Important:** Use `$TargetDedicatedNodes` (uppercase T). The Batch autoscale engine ignores `$targetDedicatedNodes` (lowercase) — the formula will evaluate but the pool won't actually resize.

---

## Failover Logic

### Step-by-step flow in BatchService.cs

1. **Pool classification guard** — reject if pool is a backup pool (never fail those over)
2. **Query pool status** — get `currentNodes`, `targetNodes`, `resizeErrors` from Batch API
3. **Failover trigger decision** — if `resizeErrors` exist and `currentNodes < targetNodes` → trigger
4. **Find active jobs** — list all Batch jobs in `active` state on the failing pool
5. **Node availability gate** — if `currentNodes / maxNodes >= NODE_AVAILABILITY_THRESHOLD_PERCENT`, skip (pool has enough capacity)
6. **Per-job evaluation**:
   - **Job completion gate** — if `completedTasks / totalTasks >= JOB_COMPLETION_THRESHOLD_PERCENT`, skip (let it finish)
   - **Move job** — disable (requeue tasks) → wait for disabled state → update pool to backup → re-enable

> **Note:** After disabling a job, the API waits up to 10 seconds for the job to fully transition to `disabled` state before updating the pool. This prevents a race condition where the pool update fails with "job is not in disabled state".

### Two alert types handled

#### Metric-based alert (poolId in dimensions)
The API extracts `poolId` from `alertContext.condition.allOf[].dimensions`, verifies it's a primary pool, and evaluates just that pool.

#### Log-based alert (no poolId)
The API scans ALL primary pools in `POOL_MAP` and evaluates each one. Backup pools are always skipped.

---

## Alert Payloads

### Metric-based alert payload (Common Alert Schema)

Sent by Azure Monitor metric alerts (e.g. `CreatingNodeCount > 0`). Contains `poolId` in dimensions.

```json
{
  "schemaId": "azureMonitorCommonAlertSchema",
  "data": {
    "essentials": {
      "alertId": "/subscriptions/.../alerts/abc123",
      "alertRule": "batch-alloc-failure-stuck-creating",
      "severity": "Sev1",
      "signalType": "Metric",
      "monitorCondition": "Fired",
      "monitoringService": "Platform",
      "alertTargetIDs": [
        "/subscriptions/.../providers/Microsoft.Batch/batchAccounts/myaccount"
      ],
      "firedDateTime": "2026-03-18T13:37:00.000Z",
      "description": "Nodes stuck in Creating state"
    },
    "alertContext": {
      "conditionType": "SingleResourceMultipleMetricCriteria",
      "condition": {
        "windowSize": "PT5M",
        "allOf": [
          {
            "metricName": "CreatingNodeCount",
            "metricNamespace": "Microsoft.Batch/batchAccounts",
            "operator": "GreaterThan",
            "threshold": "0",
            "timeAggregation": "Average",
            "metricValue": 9999.0,
            "dimensions": [
              {
                "name": "poolId",
                "value": "<primary-pool-id>"
              }
            ]
          }
        ]
      }
    }
  }
}
```

**API behavior:** Extracts `poolId` from `dimensions` → evaluates that specific pool → skips if it's a backup pool.

### Log-based alert payload (Common Alert Schema)

Sent by Scheduled Query Rule alerts. Does **not** contain `poolId` in dimensions — the query results are in a different structure.

```json
{
  "schemaId": "azureMonitorCommonAlertSchema",
  "data": {
    "essentials": {
      "alertId": "/subscriptions/.../alerts/def456",
      "alertRule": "batch-resize-error-log-alert",
      "severity": "Sev1",
      "signalType": "Log",
      "monitorCondition": "Fired",
      "monitoringService": "Log Alerts V2",
      "alertTargetIDs": [
        "/subscriptions/.../providers/Microsoft.OperationalInsights/workspaces/myworkspace"
      ],
      "firedDateTime": "2026-03-18T13:37:32.916Z",
      "description": "Batch pool resize failed"
    },
    "alertContext": {
      "conditionType": "LogQueryCriteria",
      "condition": {
        "windowSize": "PT10M",
        "allOf": [
          {
            "searchQuery": "AzureDiagnostics | where OperationName == 'PoolResizeCompleteEvent' ...",
            "metricValue": 1,
            "operator": "GreaterThan",
            "threshold": "0",
            "timeAggregation": "Count",
            "linkToSearchResultsUI": "https://portal.azure.com#...",
            "linkToFilteredSearchResultsUI": "https://portal.azure.com#..."
          }
        ]
      }
    }
  }
}
```

**API behavior:** No `poolId` in dimensions → scans **all primary pools** in `POOL_MAP` → evaluates each for resize errors → moves jobs from any that are failing.

---

## Alert Configuration

### KQL Query (Scheduled Query Rule)

Pool-agnostic — fires for any pool with resize failures. The API determines primary vs backup.

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.BATCH"
| where Category == "ServiceLog"
| where OperationName == "PoolResizeCompleteEvent"
| where resultCode_s == "Failure"
| project TimeGenerated, poolId=id_s, resultCode_s, targetDedicatedNodes_d, currentDedicatedNodes_d
| summarize ErrorCount=count(), arg_max(TimeGenerated, *) by poolId
```

### Alert Settings

| Setting | Value | Why |
|---------|-------|-----|
| Evaluation frequency | 5 min | Balance between responsiveness and cost |
| Window size | 10 min | Accounts for log ingestion delay (~2-5 min) |
| Auto-mitigate | false | Fires every cycle while failures exist (enables repeated failover for new jobs) |
| Severity | Sev1 | High priority |

### Diagnostic Settings

Enabled via `setup-log-based-alert.sh`:

| Category | Purpose |
|----------|---------|
| ServiceLog | Pool resize events (`PoolResizeCompleteEvent`, `PoolResizeStartEvent`) |
| AuditLog | Data-plane API operations (`GetJob`, `ResizePool`) |
| AllMetrics | Node counts, core counts |

---

## Setup

```bash
# 1. Deploy the API to Container App
cd api
az containerapp up --name batch-failover-api --resource-group <rg> --source .

# 2. Assign managed identity permissions
az containerapp identity assign --name batch-failover-api --resource-group <rg> --system-assigned
PRINCIPAL_ID=$(az containerapp show --name batch-failover-api --resource-group <rg> --query identity.principalId -o tsv)
BATCH_ID="/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Batch/batchAccounts/<account>"
az role assignment create --assignee $PRINCIPAL_ID --role Contributor --scope $BATCH_ID

# 3. Set environment variables
az containerapp update --name batch-failover-api --resource-group <rg> \
  --set-env-vars \
    "BATCH_ACCOUNT_URL=https://<account>.eastus.batch.azure.com" \
    "POOL_MAP=<primary>:<backup>:<maxNodes>" \
    "FAILOVER_THRESHOLD_PERCENT=0" \
    "JOB_COMPLETION_THRESHOLD_PERCENT=90" \
    "NODE_AVAILABILITY_THRESHOLD_PERCENT=20"

# 4. Set up diagnostic logs + alert
export SUBSCRIPTION_ID="..." RESOURCE_GROUP="..." BATCH_ACCOUNT="..."
./setup-log-based-alert.sh

# 5. Enable autoscale on pools
az batch pool autoscale enable --pool-id <primary-pool> \
  --auto-scale-formula '<formula>' --auto-scale-evaluation-interval PT5M
az batch pool autoscale enable --pool-id <backup-pool> \
  --auto-scale-formula '<formula>' --auto-scale-evaluation-interval PT5M
```

## Testing

```bash
# Submit a job and wait for the real Azure Monitor alert to fire and move it
./submit-job.sh --wait

# Submit a job only (check status manually later)
./submit-job.sh

# Custom task command
COMMAND="/bin/bash -c 'my-script.sh'" ./submit-job.sh --wait

# Check job status
az batch job show --job-id <job-id> --query '{pool:poolInfo.poolId,state:state}' -o json
```

`submit-job.sh` configuration (override via env vars):

| Variable | Default | Description |
|----------|---------|-------------|
| `BATCH_ACCOUNT_NAME` | required | Batch account name |
| `RESOURCE_GROUP` | `batch` | Resource group |
| `PRIMARY_POOL` | (configured) | Primary pool ID |
| `FALLBACK_POOL` | (configured) | Backup pool ID |
| `JOB_PREFIX` | `batch-run` | Job name prefix |
| `COMMAND` | `echo hello` | Task command to run |
| `MAX_WAIT_MINUTES` | `15` | Max wait time in `--wait` mode |

### What happens
1. Job is submitted to the primary pool
2. Autoscale attempts to allocate nodes → fails (quota/capacity)
3. `PoolResizeCompleteEvent(Failure)` is written to ServiceLog
4. Log Analytics ingests the event (~2-5 min)
5. Scheduled Query Rule alert evaluates and fires
6. Webhook calls the API
7. API scans primary pools, finds the failure
8. API checks gates (node availability, job completion)
9. API moves the job to the backup pool
10. Backup pool autoscales up, task runs, pool scales back to 0

## Timing

| Step | Latency |
|------|---------|
| Pool resize failure | Instant (quota rejection) or seconds (capacity) |
| Autoscale evaluation | Every 5 min (generates fresh resize events) |
| ServiceLog ingestion to Log Analytics | ~2-5 min |
| Scheduled query evaluation | Every 5 min |
| Webhook call + API failover | ~1-3 sec |
| **Total end-to-end** | **~5-15 min** |

## Limitations

- Does **not** guarantee capacity on the backup pool
- Does **not** support checkpointing — interrupted tasks are requeued from scratch
- Log-based alerts depend on ServiceLog ingestion latency (~2-5 min)
- The `PoolResizeCompleteEvent` is only emitted on resize operations — with autoscale enabled, this happens every evaluation interval (5 min)
- Azure Monitor webhook calls have aggressive timeouts; the API may return HTTP 499 on long operations (the failover still completes on the second retry)
- Jobs near completion (above `JOB_COMPLETION_THRESHOLD_PERCENT`) are intentionally left on the failing pool
- Autoscale formula variables are **case-sensitive** — must use `$TargetDedicatedNodes` (uppercase T)

## Known Issues and Fixes

| Issue | Cause | Fix |
|-------|-------|-----|
| Autoscale evaluates but pool doesn't resize | Formula uses `$targetDedicatedNodes` (lowercase) | Use `$TargetDedicatedNodes` (uppercase T) |
| Job left in `disabled` state after failover | Race condition — pool update attempted before job fully transitions to disabled | API now waits up to 10s for disabled state before updating pool |
| Alert fires but returns HTTP 499 | Azure Monitor webhook timeout (<5s) | Failover still completes; Azure Monitor retries the call |
| No `PoolResizeCompleteEvent` after job submit | Fixed-size pool with existing errors doesn't generate new events | Enable autoscale — it re-evaluates every 5 min, generating fresh events |
