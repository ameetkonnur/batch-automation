using System.Text.Json.Serialization;

namespace BatchFailoverApi.Models;

public record AlertPayload(
    [property: JsonPropertyName("data")] AlertData? Data);

public record AlertData(
    [property: JsonPropertyName("essentials")] AlertEssentials? Essentials,
    [property: JsonPropertyName("alertContext")] AlertContext? AlertContext);

public record AlertEssentials(
    [property: JsonPropertyName("alertId")] string? AlertId,
    [property: JsonPropertyName("alertRule")] string? AlertRule,
    [property: JsonPropertyName("severity")] string? Severity,
    [property: JsonPropertyName("monitorCondition")] string? MonitorCondition,
    [property: JsonPropertyName("firedDateTime")] string? FiredDateTime);

public record AlertContext(
    [property: JsonPropertyName("condition")] AlertCondition? Condition);

public record AlertCondition(
    [property: JsonPropertyName("allOf")] List<MetricCondition>? AllOf);

public record MetricCondition(
    [property: JsonPropertyName("metricName")] string? MetricName,
    [property: JsonPropertyName("dimensions")] List<MetricDimension>? Dimensions);

public record MetricDimension(
    [property: JsonPropertyName("name")] string? Name,
    [property: JsonPropertyName("value")] string? Value);
