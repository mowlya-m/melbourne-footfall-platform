"""Poll-to-stream adapter.

The City of Melbourne API publishes on a roughly fifteen minute cadence; it is
not an event stream. This Lambda polls it on a schedule, discards anything
already seen, and emits each new sensor reading as an individual record onto
Kinesis. Everything downstream of Kinesis is genuinely stream processed.

This is a normal pattern for integrating batch-published sources into
event-driven platforms, and is documented as such rather than presented as a
native real-time feed.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import UTC, datetime

import boto3
from botocore.exceptions import ClientError

from producer import api_client
from producer.watermark import WatermarkStore, filter_new

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format='{"level":"%(levelname)s","logger":"%(name)s","message":"%(message)s"}',
)
logger = logging.getLogger(__name__)

STREAM_NAME = os.environ.get("KINESIS_STREAM_NAME", "")
WATERMARK_TABLE = os.environ.get("WATERMARK_TABLE_NAME", "")
MAX_RECORDS = int(os.environ.get("MAX_RECORDS_PER_RUN", "500"))

# Kinesis caps a PutRecords call at 500 records or 5 MB.
KINESIS_BATCH_SIZE = 500

_kinesis = boto3.client("kinesis")


def _emit_batch(records: list[dict]) -> tuple[int, int]:
    """Publish one batch, returning (succeeded, failed).

    Kinesis PutRecords can partially succeed: the call returns HTTP 200 while
    individual records fail. Treating a 200 as total success is the classic way
    to silently lose data here, so the per-record result is inspected.
    """
    if not records:
        return 0, 0

    entries = [
        {
            # Firehose concatenates record bodies verbatim. Without a trailing
            # newline the delivered object is one unparseable blob rather than
            # newline-delimited JSON, which Athena and Spark both require.
            "Data": (json.dumps(record) + "\n").encode("utf-8"),
            # Partitioning by sensor keeps one sensor's readings ordered within
            # a shard, which the hot-path consumer relies on for aggregation.
            "PartitionKey": str(record["location_id"]),
        }
        for record in records
    ]

    try:
        response = _kinesis.put_records(StreamName=STREAM_NAME, Records=entries)
    except ClientError:
        logger.exception("put_records call failed entirely")
        return 0, len(entries)

    failed = response.get("FailedRecordCount", 0)

    if failed:
        reasons = {r.get("ErrorCode") for r in response.get("Records", []) if r.get("ErrorCode")}
        logger.error(
            "records rejected by kinesis",
            extra={"failed": failed, "error_codes": sorted(reasons)},
        )

    return len(entries) - failed, failed


def handler(event, context):  # noqa: ARG001 - Lambda signature
    """Entry point.

    Returns a summary that CloudWatch can be queried against, and that makes the
    run visible in the Lambda console without digging through logs.
    """
    started = datetime.now(UTC)

    if not STREAM_NAME or not WATERMARK_TABLE:
        raise RuntimeError("KINESIS_STREAM_NAME and WATERMARK_TABLE_NAME must be set")

    store = WatermarkStore(WATERMARK_TABLE)
    watermark = store.read()
    logger.info("starting run", extra={"watermark": watermark.isoformat()})

    readings = api_client.fetch_recent(max_records=MAX_RECORDS)
    fetched = len(readings)

    new_readings = filter_new(readings, watermark)
    logger.info(
        "deduplicated against watermark",
        extra={"fetched": fetched, "new": len(new_readings)},
    )

    if not new_readings:
        return {
            "status": "no_new_data",
            "fetched": fetched,
            "emitted": 0,
            "duration_seconds": (datetime.now(UTC) - started).total_seconds(),
        }

    records = [r.to_record(ingested_at=started) for r in new_readings]

    emitted = 0
    failed = 0
    for i in range(0, len(records), KINESIS_BATCH_SIZE):
        ok, bad = _emit_batch(records[i : i + KINESIS_BATCH_SIZE])
        emitted += ok
        failed += bad

    # The watermark advances only to the newest record that actually made it to
    # the stream. Advancing past a failed record would create a permanent gap,
    # since the upstream window will have rolled by the next invocation.
    if emitted and not failed:
        newest = max(r.event_timestamp for r in new_readings)
        store.write(newest, record_count=emitted)
    elif failed:
        logger.error(
            "watermark not advanced due to partial failure",
            extra={"emitted": emitted, "failed": failed},
        )

    summary = {
        "status": "partial_failure" if failed else "ok",
        "fetched": fetched,
        "new": len(new_readings),
        "emitted": emitted,
        "failed": failed,
        "duration_seconds": (datetime.now(UTC) - started).total_seconds(),
    }
    logger.info("run complete", extra=summary)

    # A non-zero failure count raises so the Lambda is marked failed and the
    # CloudWatch alarm from PR #9 fires. Returning success on partial data loss
    # is how silent gaps happen.
    if failed:
        raise RuntimeError(f"{failed} records failed to publish")

    return summary
