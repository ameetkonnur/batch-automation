using System.Text.Json;
using BatchFailoverApi.Models;
using BatchFailoverApi.Services;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<BatchService>();

var app = builder.Build();

// ────────────────────────────────────────────────────────────────────────
// WEBHOOK ENDPOINT: Receives Azure Monitor alerts (Common Alert Schema)
// Handles both metric-based alerts (poolId in dimensions) and
// log-based alerts (no poolId — scans all primary pools).
// ────────────────────────────────────────────────────────────────────────
app.MapPost("/api/batch/allocation-alert", async (HttpContext ctx, BatchService batchService, ILogger<Program> logger) =>
{
    var thresholdPercent = int.TryParse(Environment.GetEnvironmentVariable("FAILOVER_THRESHOLD_PERCENT"), out var v) ? v : 80;

    logger.LogInformation("[WEBHOOK] Incoming alert received. Threshold configured: {Threshold}%", thresholdPercent);

    var alert = await JsonSerializer.DeserializeAsync<AlertPayload>(ctx.Request.Body);
    if (alert?.Data?.Essentials is null)
    {
        logger.LogWarning("[WEBHOOK] Rejected: missing data.essentials in payload");
        return Results.BadRequest(new { error = "Missing data.essentials in alert payload" });
    }

    var essentials = alert.Data.Essentials;
    logger.LogInformation("[WEBHOOK] Alert received — rule={Rule}, severity={Severity}, monitorCondition={Condition}, firedAt={FiredAt}",
        essentials.AlertRule, essentials.Severity, essentials.MonitorCondition, essentials.FiredDateTime);

    if (!string.Equals(essentials.MonitorCondition, "Fired", StringComparison.OrdinalIgnoreCase))
    {
        logger.LogInformation("[WEBHOOK] Ignoring alert: monitorCondition is '{Condition}' (not Fired)", essentials.MonitorCondition);
        return Results.Ok(new { action = "ignored", reason = $"MonitorCondition is '{essentials.MonitorCondition}'" });
    }

    var poolId = alert.Data.AlertContext?.Condition?.AllOf?
        .SelectMany(c => c.Dimensions ?? [])
        .FirstOrDefault(d => string.Equals(d.Name, "poolId", StringComparison.OrdinalIgnoreCase))
        ?.Value;

    if (string.IsNullOrEmpty(poolId))
    {
        // Log-based alerts (Scheduled Query Rules) don't include poolId in dimensions.
        // Evaluate all primary pools (never fallback pools) and failover any that have errors.
        logger.LogInformation("[WEBHOOK] No poolId in dimensions — scanning all primary pools for failures (fallback pools are excluded)...");

        var allResults = await batchService.EvaluateAllPoolsAsync(thresholdPercent);
        var executed = allResults.Where(r => r.Action == "failover_executed").ToList();

        if (executed.Count > 0)
            logger.LogWarning("[WEBHOOK] FAILOVER COMPLETED for {Count} pool(s)", executed.Count);
        else
            logger.LogInformation("[WEBHOOK] No pools needed failover");

        return Results.Ok(new { action = executed.Count > 0 ? "failover_executed" : "no_action", poolResults = allResults });
    }

    // Metric-based alert with specific poolId — verify it's a primary pool
    if (batchService.IsFallbackPool(poolId) && !batchService.IsPrimaryPool(poolId))
    {
        logger.LogInformation("[WEBHOOK] Pool '{PoolId}' is a FALLBACK pool — ignoring alert (only primary pools trigger failover)", poolId);
        return Results.Ok(new { action = "skipped", reason = $"Pool '{poolId}' is a fallback pool — not eligible for failover" });
    }

    logger.LogInformation("[WEBHOOK] Pool identified from alert: {PoolId} (primary pool). Evaluating failover with threshold={Threshold}%...", poolId, thresholdPercent);

    var result = await batchService.EvaluateAndFailoverAsync(poolId, thresholdPercent);

    if (result.Action == "failover_executed")
        logger.LogWarning("[WEBHOOK] FAILOVER COMPLETED — {Reason}", result.Reason);
    else
        logger.LogInformation("[WEBHOOK] Failover decision: action={Action}, reason={Reason}", result.Action, result.Reason);

    return Results.Ok(result);
});

app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));

app.Run();
