# Azure Batch Allocation Failover Automation

## Problem

Azure Batch pool allocations can fail even when quota exists — capacity may not be available at allocation time. When autoscale triggers or a manual resize requests nodes, the pool can end up with `resizeErrors` (e.g. `AccountVMSeriesCoreQuotaReached`) and zero running nodes. Jobs submitted to that pool are stuck and require manual intervention.

## Solution

An automated failover system that detects pool allocation failures via Azure Monitor and moves active jobs from the failing primary pool to a healthy backup pool.

```
Pool resize fails
  → Batch writes PoolResizeCompleteEvent (Failure) to ServiceLog
  → ServiceLog ingested into Log Analytics (~2-5 min)
  → Scheduled Query Rule alert evaluates every 5 min (10 min window)
  → Alert fires → Action Group → Webhook
  → .NET API (Container App) receives alert
  → API checks POOL_MAP: only primary pools are evaluated (backup pools are never failed over)
  → API detects resize errors on primary pool
  → Active jobs are moved: disable → update pool → re-enable
  → Jobs run on backup pool
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
| `api/` | .NET 8 ASP.NET Core API deployed as a Container App. Receives alert webhooks and performs job failover. |
| `api/Program.cs` | Webhook endpoint. Handles both metric-based alerts (poolId in dimensions) and log-based alerts (scans all primary pools). |
| `api/Services/BatchService.cs` | Core failover logic. Parses `POOL_MAP`, detects resize errors, moves jobs between pools. |
| `api/Models/AlertPayload.cs` | Azure Monitor Common Alert Schema model. |
| `api/Dockerfile` | Container image build for the API. |
| `setup-log-based-alert.sh` | Creates diagnostic settings, Log Analytics workspace config, and Scheduled Query Rule alert. |
| `test-failover-e2e.sh` | End-to-end test script. `--wait` mode waits for real alert; `--manual` mode calls webhook directly. |
| `submit-job-with-metadata.sh` | Job submission utility with metadata for traceability. |

## Configuration

### POOL_MAP (Environment Variable on Container App)

Maps primary pools to their backup pools. Format:

```
POOL_MAP="primary1:backup1:maxNodes,primary2:backup2:maxNodes,..."
```

Example:
```
POOL_MAP="pool-hbv4:pool-ev3:2,pool-nc:pool-nv:10"
```

- **Primary pools** (keys) — monitored for failures, jobs are moved FROM these
- **Backup pools** (values) — jobs are moved TO these, never failed over themselves
- **maxNodes** — maximum dedicated nodes for utilization-based failover (optional, default 100)

### Other Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BATCH_ACCOUNT_URL` | required | Batch account endpoint (e.g. `https://myaccount.eastus.batch.azure.com`) |
| `POOL_MAP` | required | Primary-to-backup pool mapping (see above) |
| `FAILOVER_THRESHOLD_PERCENT` | `80` | Utilization threshold for capacity-based failover. Set to `0` to skip utilization check and failover on any resize error. |

### Alert Configuration

Set via `setup-log-based-alert.sh`:

| Setting | Value | Description |
|---------|-------|-------------|
| Evaluation frequency | 5 min | How often the KQL query runs |
| Window size | 10 min | How far back the query looks for failure events |
| Auto-mitigate | false | Alert fires every cycle while failures exist |
| Severity | Sev1 | High severity |

### KQL Alert Query

Pool-agnostic — fires for any pool with resize failures. The API determines which pools are primary vs backup.

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.BATCH"
| where Category == "ServiceLog"
| where OperationName == "PoolResizeCompleteEvent"
| where resultCode_s == "Failure"
| project TimeGenerated, poolId=id_s, resultCode_s, targetDedicatedNodes_d, currentDedicatedNodes_d
| summarize ErrorCount=count(), arg_max(TimeGenerated, *) by poolId
```

## Failover Logic

The API handles two alert types:

### Metric-based alerts (poolId in dimensions)
1. Extract `poolId` from `alertContext.condition.allOf[].dimensions`
2. Check if poolId is a primary pool (in `POOL_MAP` keys) — skip if it's a backup
3. Query pool status via Batch API
4. If resize errors detected: find active jobs on that pool and move them

### Log-based alerts (no poolId in dimensions)
1. Scan ALL primary pools in `POOL_MAP`
2. For each primary pool: query status, check for resize errors
3. Move active jobs from any failing primary pool to its configured backup

### Job Move Process
For each active job on a failing pool:
1. **Disable** the job (requeue running tasks)
2. **Update** the job's pool to the backup pool
3. **Re-enable** the job (tasks run on backup pool)

### Guards
- Backup pools are **never** failed over (protected in code)
- Unknown pools (not in `POOL_MAP`) are skipped
- Jobs with `onAllTasksComplete: terminateJob` auto-terminate after tasks complete on the backup pool

## Prerequisites

### Azure Resources
- Batch account with primary and backup pools
- Log Analytics workspace
- Container App (or any hosting for the .NET API)
- Managed identity on the Container App with **Contributor** role on the Batch account

### Diagnostic Settings
Enabled via `setup-log-based-alert.sh`:
- **ServiceLog** → Log Analytics (captures `PoolResizeCompleteEvent`)
- **AuditLog** → Log Analytics (captures API operations)
- **AllMetrics** → Log Analytics (node counts, core counts)

## Setup

```bash
# 1. Deploy the API to Container App
cd api
az containerapp up --name batch-failover-api --resource-group <rg> --source .

# 2. Assign managed identity permissions
az containerapp identity assign --name batch-failover-api --resource-group <rg> --system-assigned
PRINCIPAL_ID=$(az containerapp show --name batch-failover-api --resource-group <rg> --query identity.principalId -o tsv)
az role assignment create --assignee $PRINCIPAL_ID --role Contributor --scope <batch-account-resource-id>

# 3. Set environment variables
az containerapp update --name batch-failover-api --resource-group <rg> \
  --set-env-vars \
    "BATCH_ACCOUNT_URL=https://<account>.eastus.batch.azure.com" \
    "POOL_MAP=<primary>:<backup>:<maxNodes>" \
    "FAILOVER_THRESHOLD_PERCENT=0"

# 4. Set up diagnostic logs + alert
export SUBSCRIPTION_ID="..."
export RESOURCE_GROUP="..."
export BATCH_ACCOUNT="..."
./setup-log-based-alert.sh
```

## Testing

### Manual mode (instant, calls webhook directly)
```bash
./test-failover-e2e.sh --manual
```

### Wait mode (waits for real Azure Monitor alert)
```bash
./test-failover-e2e.sh
```

### What the test does
1. Verifies the HB pool has a resize error
2. Submits a job with a simple task on the failing pool
3. Fires the webhook (manual) or waits for the alert (wait mode)
4. Verifies the job moved to the backup pool

## Timing

| Step | Latency |
|------|---------|
| Pool resize failure | Instant (quota rejection) |
| ServiceLog ingestion to Log Analytics | ~2-5 min |
| Scheduled query evaluation | Every 5 min |
| Webhook call + API failover | ~1-3 sec |
| **Total end-to-end** | **~5-10 min** |

## Limitations

- Does **not** guarantee capacity on the backup pool
- Does **not** support checkpointing — interrupted tasks are requeued from scratch
- Log-based alerts depend on ServiceLog ingestion latency (~2-5 min)
- The `PoolResizeCompleteEvent` is only emitted on resize operations — a pool that's already failed won't generate new events without a new resize (e.g. from autoscale)
- Azure Monitor webhook calls have aggressive timeouts; the API may return 499 on long failover operations (the failover still completes)
