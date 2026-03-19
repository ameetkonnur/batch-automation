using Azure.Identity;
using Microsoft.Azure.Batch;
using Microsoft.Azure.Batch.Auth;
using Microsoft.Azure.Batch.Common;
using Microsoft.Extensions.Logging;

namespace BatchFailoverApi.Services;

/// <summary>
/// Core failover service for Azure Batch pool allocation failures.
///
/// Monitors primary pools for resize errors and moves active jobs to backup pools.
/// Pool mappings are configured via POOL_MAP env var. Backup pools are protected
/// and never failed over themselves.
///
/// Failover decision flow:
///   1. Check if pool is a primary (not a backup) pool
///   2. Query pool status from Batch API for resize errors
///   3. If resize errors exist and current nodes < target → trigger failover
///   4. Gate: skip if node availability is above threshold (pool has enough nodes)
///   5. For each active job on the pool:
///      a. Gate: skip if job completion % is above threshold (nearly done)
///      b. Disable job (requeue tasks) → update pool to backup → re-enable job
/// </summary>
public class BatchService
{
    // ────────────────────────────────────────────────────────────────────────
    // CONFIGURATION: Pool mappings and failover thresholds
    // ────────────────────────────────────────────────────────────────────────

    private readonly ILogger<BatchService> _logger;

    // Configured via POOL_MAP env var: "primary1:backup1:maxNodes,primary2:backup2:maxNodes,..."
    // Each entry maps a primary pool to its backup pool for failover.
    // Only primary pools are monitored for failures. Backup pools are never failed over.
    private static readonly Dictionary<string, PoolConfig> PoolMap = ParsePoolMap();

    private static Dictionary<string, PoolConfig> ParsePoolMap()
    {
        var map = new Dictionary<string, PoolConfig>(StringComparer.OrdinalIgnoreCase);
        var raw = Environment.GetEnvironmentVariable("POOL_MAP") ?? "";
        foreach (var entry in raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = entry.Split(':');
            if (parts.Length >= 2)
            {
                var maxNodes = parts.Length >= 3 && int.TryParse(parts[2], out var n) ? n : 100;
                map[parts[0]] = new(parts[1], maxNodes);
            }
        }
        return map;
    }

    // Failover gate thresholds (configurable via env vars)
    // Jobs are only moved if BOTH conditions are met:
    //   1. Job completion % is BELOW this threshold (e.g. 50 = move if less than 50% done)
    //   2. Current nodes are BELOW this % of autoscale max (e.g. 20 = move if pool has < 20% of max nodes)
    private static readonly int JobCompletionThreshold =
        int.TryParse(Environment.GetEnvironmentVariable("JOB_COMPLETION_THRESHOLD_PERCENT"), out var jc) ? jc : 90;
    private static readonly int NodeAvailabilityThreshold =
        int.TryParse(Environment.GetEnvironmentVariable("NODE_AVAILABILITY_THRESHOLD_PERCENT"), out var na) ? na : 20;

    public BatchService(ILogger<BatchService> logger)
    {
        _logger = logger;
        _logger.LogInformation("[CONFIG] Pool failover mappings ({Count} configured):", PoolMap.Count);
        foreach (var (primary, config) in PoolMap)
            _logger.LogInformation("[CONFIG]   {Primary} → {Backup} (maxNodes={Max})", primary, config.FallbackPoolId, config.MaxDedicatedNodes);
        if (FallbackPoolIds.Count > 0)
            _logger.LogInformation("[CONFIG] Protected backup pools (never failed over): [{Backups}]", string.Join(", ", FallbackPoolIds));
        _logger.LogInformation("[CONFIG] Job completion threshold: {Threshold}% (move only if below this)", JobCompletionThreshold);
        _logger.LogInformation("[CONFIG] Node availability threshold: {Threshold}% of autoscale max (move only if below this)", NodeAvailabilityThreshold);
    }

    // ────────────────────────────────────────────────────────────────────────
    // POOL CLASSIFICATION: Primary vs backup pool lookups
    // ────────────────────────────────────────────────────────────────────────

    // Set of all fallback pool IDs — these must never be failed over
    private static readonly HashSet<string> FallbackPoolIds = new(
        PoolMap.Values.Select(c => c.FallbackPoolId), StringComparer.OrdinalIgnoreCase);

    public PoolConfig? GetPoolConfig(string poolId) =>
        PoolMap.GetValueOrDefault(poolId);

    /// <summary>Returns true if poolId is a primary (source) pool in the POOL_MAP.</summary>
    public bool IsPrimaryPool(string poolId) =>
        PoolMap.ContainsKey(poolId);

    /// <summary>Returns true if poolId is a fallback (backup) pool — must never be failed over.</summary>
    public bool IsFallbackPool(string poolId) =>
        FallbackPoolIds.Contains(poolId);

    // ────────────────────────────────────────────────────────────────────────
    // EVALUATE ALL POOLS: Scans every primary pool (used by log-based alerts)
    // ────────────────────────────────────────────────────────────────────────

    public async Task<List<FailoverResult>> EvaluateAllPoolsAsync(int thresholdPercent)
    {
        _logger.LogInformation("[FAILOVER] Scanning {PrimaryCount} primary pool(s), skipping {FallbackCount} fallback pool(s)",
            PoolMap.Count, FallbackPoolIds.Count);
        var results = new List<FailoverResult>();
        foreach (var poolId in PoolMap.Keys)
        {
            var result = await EvaluateAndFailoverAsync(poolId, thresholdPercent);
            results.Add(result);
        }
        return results;
    }

    // ────────────────────────────────────────────────────────────────────────
    // EVALUATE SINGLE POOL: Core failover logic for one primary pool
    // ────────────────────────────────────────────────────────────────────────

    public async Task<FailoverResult> EvaluateAndFailoverAsync(string poolId, int thresholdPercent)
    {
        _logger.LogInformation("[FAILOVER] Evaluating pool '{PoolId}' — threshold={Threshold}%, poolMap entries={MapCount}",
            poolId, thresholdPercent, PoolMap.Count);

        // ── STEP 1: Pool classification guard ──
        // Guard: never failover a backup pool
        if (IsFallbackPool(poolId) && !IsPrimaryPool(poolId))
        {
            _logger.LogInformation("[FAILOVER] Pool '{PoolId}' is a FALLBACK pool — skipping (only primary pools are failed over)", poolId);
            return new(poolId, "skipped", $"Pool '{poolId}' is a fallback pool — not eligible for failover");
        }

        if (!PoolMap.TryGetValue(poolId, out var poolConfig))
        {
            _logger.LogWarning("[FAILOVER] No fallback mapping found for pool '{PoolId}'. Known primary pools: [{Primaries}], fallback pools: [{Fallbacks}]",
                poolId, string.Join(", ", PoolMap.Keys), string.Join(", ", FallbackPoolIds));
            return new(poolId, "skipped", $"No fallback mapping configured for pool '{poolId}'");
        }

        _logger.LogInformation("[FAILOVER] Pool '{PoolId}' maps to fallback '{FallbackPool}' (maxNodes={MaxNodes})",
            poolId, poolConfig.FallbackPoolId, poolConfig.MaxDedicatedNodes);

        // ── STEP 2: Query pool status from Batch API ──
        using var client = CreateBatchClient();

        var pool = await client.PoolOperations.GetPoolAsync(poolId);
        var currentNodes = pool.CurrentDedicatedComputeNodes ?? 0;
        var targetNodes = pool.TargetDedicatedComputeNodes ?? 0;
        var hasResizeErrors = pool.ResizeErrors?.Any() == true;

        _logger.LogInformation("[FAILOVER] Pool '{PoolId}' status — vmSize={VmSize}, allocationState={AllocState}, currentNodes={Current}, targetNodes={Target}, resizeErrors={HasErrors}",
            poolId, pool.VirtualMachineSize, pool.AllocationState, currentNodes, targetNodes, hasResizeErrors);

        if (hasResizeErrors)
        {
            foreach (var err in pool.ResizeErrors!)
                _logger.LogWarning("[FAILOVER] Pool '{PoolId}' resize error: code={Code}, message={Message}",
                    poolId, err.Code, err.Message);
        }

        // ── STEP 3: Failover trigger decision ──
        // Allocation failure: pool requested nodes but couldn't allocate (quota, capacity, etc.)
        bool shouldFailover;
        string triggerReason;

        if (hasResizeErrors && currentNodes < targetNodes)
        {
            var errorCodes = string.Join(", ", pool.ResizeErrors!.Select(e => e.Code));
            triggerReason = $"Allocation failure detected: {errorCodes} (current={currentNodes}, target={targetNodes})";
            shouldFailover = true;
            _logger.LogWarning("[FAILOVER] DECISION: Failover TRIGGERED for pool '{PoolId}' — {Reason}", poolId, triggerReason);
        }
        else
        {
            var utilization = poolConfig.MaxDedicatedNodes > 0
                ? (double)currentNodes / poolConfig.MaxDedicatedNodes * 100 : 0;
            shouldFailover = utilization >= thresholdPercent;
            triggerReason = shouldFailover
                ? $"Pool utilization ({utilization:F1}%) >= threshold ({thresholdPercent}%)"
                : $"Pool utilization ({utilization:F1}%) below threshold ({thresholdPercent}%)";
            _logger.LogInformation("[FAILOVER] DECISION: Utilization check for pool '{PoolId}' — utilization={Util:F1}%, threshold={Threshold}%, failover={ShouldFailover}",
                poolId, utilization, thresholdPercent, shouldFailover);
        }

        if (!shouldFailover)
        {
            _logger.LogInformation("[FAILOVER] No failover needed for pool '{PoolId}': {Reason}", poolId, triggerReason);
            return new(poolId, "skipped", triggerReason, poolConfig.FallbackPoolId);
        }

        // ── STEP 4: Find active jobs on the failing pool ──
        var filter = new ODATADetailLevel(filterClause: "state eq 'active'");
        var jobIds = new List<string>();
        var enumerator = client.JobOperations.ListJobs(filter).GetPagedEnumerator();
        while (await enumerator.MoveNextAsync())
        {
            if (string.Equals(enumerator.Current.PoolInformation?.PoolId, poolId, StringComparison.OrdinalIgnoreCase))
                jobIds.Add(enumerator.Current.Id);
        }

        if (jobIds.Count == 0)
        {
            _logger.LogInformation("[FAILOVER] No active jobs found on pool '{PoolId}' — nothing to move", poolId);
            return new(poolId, "no_jobs", "Threshold met but no active jobs to move", poolConfig.FallbackPoolId);
        }

        _logger.LogInformation("[FAILOVER] Found {Count} active job(s) on pool '{PoolId}' to evaluate: [{JobIds}]",
            jobIds.Count, poolId, string.Join(", ", jobIds));

        // ── STEP 5: Node availability gate ──
        // Gate check: node availability — skip failover if pool has enough nodes
        var nodeAvailPct = poolConfig.MaxDedicatedNodes > 0
            ? (double)currentNodes / poolConfig.MaxDedicatedNodes * 100 : 0;
        _logger.LogInformation("[FAILOVER] Node availability: {Current}/{Max} = {Pct:F1}% (threshold: below {Threshold}%)",
            currentNodes, poolConfig.MaxDedicatedNodes, nodeAvailPct, NodeAvailabilityThreshold);

        if (nodeAvailPct >= NodeAvailabilityThreshold)
        {
            var skipReason = $"Node availability ({nodeAvailPct:F1}%) >= threshold ({NodeAvailabilityThreshold}%) — pool has enough nodes, skipping failover";
            _logger.LogInformation("[FAILOVER] GATE: {Reason}", skipReason);
            return new(poolId, "skipped", skipReason, poolConfig.FallbackPoolId);
        }

        // ── STEP 6: Per-job evaluation and move ──
        // Move each job: check completion % gate, then disable → update pool → re-enable
        var results = new List<MoveJobResult>();
        foreach (var jobId in jobIds)
        {
            try
            {
                // ── STEP 6a: Job completion gate ──
                // Gate check: job completion % — skip if job is nearly done
                var taskCounts = await client.JobOperations.GetJobTaskCountsAsync(jobId);
                var totalTasks = taskCounts.TaskCounts.Active + taskCounts.TaskCounts.Running + taskCounts.TaskCounts.Completed;
                var completionPct = totalTasks > 0 ? (double)taskCounts.TaskCounts.Completed / totalTasks * 100 : 0;

                _logger.LogInformation("[FAILOVER] Job '{JobId}' task progress: completed={Completed}, active={Active}, running={Running}, total={Total}, completion={Pct:F1}% (threshold: below {Threshold}%)",
                    jobId, taskCounts.TaskCounts.Completed, taskCounts.TaskCounts.Active, taskCounts.TaskCounts.Running, totalTasks, completionPct, JobCompletionThreshold);

                if (completionPct >= JobCompletionThreshold)
                {
                    _logger.LogInformation("[FAILOVER] GATE: Job '{JobId}' is {Pct:F1}% complete (>= {Threshold}%) — letting it finish on current pool",
                        jobId, completionPct, JobCompletionThreshold);
                    results.Add(new(jobId, poolConfig.FallbackPoolId, false, $"Skipped: {completionPct:F1}% complete (>= {JobCompletionThreshold}% threshold)"));
                    continue;
                }

                _logger.LogInformation("[FAILOVER] GATE PASSED: Job '{JobId}' completion={Pct:F1}% < {Threshold}%, nodes={NodePct:F1}% < {NodeThreshold}% — proceeding with move",
                    jobId, completionPct, JobCompletionThreshold, nodeAvailPct, NodeAvailabilityThreshold);

                _logger.LogInformation("[FAILOVER] Moving job '{JobId}': {SourcePool} → {TargetPool} (disable → update pool → re-enable)",
                    jobId, poolId, poolConfig.FallbackPoolId);

                await client.JobOperations.DisableJobAsync(jobId, DisableJobOption.Requeue);
                _logger.LogInformation("[FAILOVER] Job '{JobId}': disabled (tasks requeued)", jobId);

                // Wait for job to fully transition to 'disabled' state before updating pool.
                // Without this, the pool update can fail with "job is not in disabled state".
                for (var wait = 0; wait < 10; wait++)
                {
                    var jobState = (await client.JobOperations.GetJobAsync(jobId)).State;
                    if (jobState == Microsoft.Azure.Batch.Common.JobState.Disabled) break;
                    _logger.LogInformation("[FAILOVER] Job '{JobId}': waiting for disabled state (current: {State})...", jobId, jobState);
                    await Task.Delay(1000);
                }

                var job = await client.JobOperations.GetJobAsync(jobId);
                job.PoolInformation = new PoolInformation { PoolId = poolConfig.FallbackPoolId };
                await job.CommitAsync();
                _logger.LogInformation("[FAILOVER] Job '{JobId}': pool updated to '{TargetPool}'", jobId, poolConfig.FallbackPoolId);

                await client.JobOperations.EnableJobAsync(jobId);
                _logger.LogInformation("[FAILOVER] Job '{JobId}': re-enabled on '{TargetPool}' — MOVE COMPLETE", jobId, poolConfig.FallbackPoolId);

                results.Add(new(jobId, poolConfig.FallbackPoolId, true));
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "[FAILOVER] FAILED to move job '{JobId}' from '{SourcePool}' to '{TargetPool}'",
                    jobId, poolId, poolConfig.FallbackPoolId);
                results.Add(new(jobId, poolConfig.FallbackPoolId, false, ex.Message));
            }
        }

        var moved = results.Count(r => r.Success);
        var failed = results.Count(r => !r.Success);
        _logger.LogWarning("[FAILOVER] SUMMARY — pool='{PoolId}', trigger='{Trigger}', jobsMoved={Moved}, jobsFailed={Failed}, targetPool='{TargetPool}'",
            poolId, triggerReason, moved, failed, poolConfig.FallbackPoolId);

        return new(poolId, "failover_executed",
            $"Moved {moved} job(s) to fallback pool. Trigger: {triggerReason}",
            poolConfig.FallbackPoolId, results);
    }

    // ────────────────────────────────────────────────────────────────────────
    // BATCH CLIENT: Authenticates via managed identity (DefaultAzureCredential)
    // ────────────────────────────────────────────────────────────────────────

    private BatchClient CreateBatchClient()
    {
        var accountUrl = Environment.GetEnvironmentVariable("BATCH_ACCOUNT_URL")
            ?? throw new InvalidOperationException("BATCH_ACCOUNT_URL is not configured");

        var credential = new DefaultAzureCredential();
        return BatchClient.Open(new BatchTokenCredentials(accountUrl, async () =>
        {
            var token = await credential.GetTokenAsync(
                new Azure.Core.TokenRequestContext(["https://batch.core.windows.net/.default"]));
            return token.Token;
        }));
    }
}

public record PoolConfig(string FallbackPoolId, int MaxDedicatedNodes);
public record MoveJobResult(string JobId, string TargetPoolId, bool Success, string? Error = null);
public record FailoverResult(string SourcePoolId, string Action, string Reason,
    string? TargetPoolId = null, List<MoveJobResult>? JobResults = null);
