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
$cmd = "/bin/bash /opt/org-x/failover-controller.sh --once"
Write-Output "Executing: $cmd"

bash -c $cmd

Write-Output "Runbook completed"
