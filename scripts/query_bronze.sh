#!/usr/bin/env bash
#
# Runs a set of verification queries against the Bronze layer via Athena and
# prints the results. Useful for confirming the pipeline end to end, and for
# demonstrating the platform without opening the console.
#
# Usage: bash scripts/query_bronze.sh
set -euo pipefail

REGION="${AWS_REGION:-ap-southeast-2}"
WORKGROUP="${ATHENA_WORKGROUP:-melbourne-footfall-dev}"
DATABASE="${GLUE_DATABASE:-melbourne_footfall_dev}"

run_query() {
  local label="$1"
  local sql="$2"

  echo ""
  echo "=============================================================="
  echo "$label"
  echo "=============================================================="

  local execution_id
  execution_id=$(aws athena start-query-execution \
    --query-string "$sql" \
    --work-group "$WORKGROUP" \
    --query-execution-context "Database=$DATABASE" \
    --region "$REGION" \
    --query 'QueryExecutionId' --output text)

  local state="RUNNING"
  local waited=0
  while [[ "$state" == "RUNNING" || "$state" == "QUEUED" ]]; do
    sleep 2
    waited=$((waited + 2))
    state=$(aws athena get-query-execution \
      --query-execution-id "$execution_id" \
      --region "$REGION" \
      --query 'QueryExecution.Status.State' --output text)

    if (( waited > 120 )); then
      echo "Timed out after 120 seconds."
      return 1
    fi
  done

  if [[ "$state" != "SUCCEEDED" ]]; then
    echo "Query $state:"
    aws athena get-query-execution --query-execution-id "$execution_id" \
      --region "$REGION" --query 'QueryExecution.Status.StateChangeReason' --output text
    return 1
  fi

  aws athena get-query-results \
    --query-execution-id "$execution_id" \
    --region "$REGION" \
    --query 'ResultSet.Rows[].Data[].VarCharValue' \
    --output text | column -t

  local scanned
  scanned=$(aws athena get-query-execution --query-execution-id "$execution_id" \
    --region "$REGION" --query 'QueryExecution.Statistics.DataScannedInBytes' --output text)
  echo ""
  echo "(scanned ${scanned} bytes)"
}

run_query "Row count and distinct sensors" "
SELECT
  COUNT(*)                         AS total_readings,
  COUNT(DISTINCT location_id)      AS distinct_sensors,
  MIN(sensing_datetime)            AS earliest_event,
  MAX(sensing_datetime)            AS latest_event
FROM bronze_pedestrian
WHERE dt = date_format(current_date, '%Y-%m-%d')
"

run_query "Busiest sensors in the most recent hour" "
SELECT
  location_id,
  SUM(total_of_directions) AS pedestrians,
  COUNT(*)                 AS minutes_reported
FROM bronze_pedestrian
WHERE dt = date_format(current_date, '%Y-%m-%d')
GROUP BY location_id
ORDER BY pedestrians DESC
LIMIT 10
"

run_query "Duplicate check on the natural key" "
SELECT
  COUNT(*)                    AS total_rows,
  COUNT(DISTINCT dedupe_key)  AS distinct_keys,
  COUNT(*) - COUNT(DISTINCT dedupe_key) AS duplicates
FROM bronze_pedestrian
WHERE dt = date_format(current_date, '%Y-%m-%d')
"

run_query "Ingestion lag: event time versus ingestion time" "
SELECT
  location_id,
  sensing_datetime,
  ingested_at,
  date_diff('second',
            from_iso8601_timestamp(sensing_datetime),
            from_iso8601_timestamp(ingested_at)) AS lag_seconds
FROM bronze_pedestrian
WHERE dt = date_format(current_date, '%Y-%m-%d')
ORDER BY sensing_datetime DESC
LIMIT 5
"

echo ""
echo "Done."
