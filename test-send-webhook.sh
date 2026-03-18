#!/usr/bin/env bash
# test-send-webhook.sh
# Sends a mock Azure Monitor Common Alert Schema payload to the local Function API.
# Use this after running test-submit-allocation-failure.sh to test the failover logic.
set -euo pipefail

API_URL="${API_URL:-http://localhost:7071/api/batch/allocation-alert}"
POOL_ID="${POOL_ID:-pool-hbv4}"

echo "Sending mock alert webhook to: $API_URL"
echo "Pool ID in payload: $POOL_ID"
echo ""

curl -s -w "\nHTTP %{http_code}\n" \
  -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d @- <<EOF | jq . 2>/dev/null || cat
{
  "schemaId": "azureMonitorCommonAlertSchema",
  "data": {
    "essentials": {
      "alertId": "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.AlertsManagement/alerts/test-$(date +%s)",
      "alertRule": "Batch Pool Allocation Failure - ${POOL_ID}",
      "severity": "Sev1",
      "signalType": "Metric",
      "monitorCondition": "Fired",
      "monitoringService": "Platform",
      "alertTargetIDs": [
        "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.Batch/batchAccounts/myaccount"
      ],
      "configurationItems": [
        "myaccount"
      ],
      "firedDateTime": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
      "description": "Test allocation failure alert for pool ${POOL_ID}"
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
            "metricValue": 0.0,
            "dimensions": [
              {
                "name": "poolId",
                "value": "${POOL_ID}"
              }
            ]
          }
        ]
      }
    }
  }
}
EOF
