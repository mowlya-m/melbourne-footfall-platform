"""High-water mark tracking, so repeated polls do not re-emit the same readings.

The upstream API returns a rolling window rather than only what is new. Without
a watermark, a five-minute schedule against a one-hour window would emit every
reading roughly twelve times.

The watermark stores the newest event timestamp successfully published. On the
next invocation, anything at or before that timestamp is discarded.
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

WATERMARK_PARTITION_KEY = "producer#pedestrian"

# Before the first successful run there is no watermark. Returning epoch rather
# than None means the caller has one code path instead of two.
EPOCH = datetime(1970, 1, 1, tzinfo=UTC)


class WatermarkStore:
    """Reads and writes the producer's high-water mark."""

    def __init__(self, table_name: str, client=None) -> None:
        self._table_name = table_name
        self._client = client or boto3.client("dynamodb")

    def read(self) -> datetime:
        """Return the last published event timestamp, or epoch if unset.

        A read failure returns epoch rather than raising. Reprocessing a window
        is harmless because downstream writes are idempotent; halting ingestion
        on a transient DynamoDB error is not.
        """
        try:
            response = self._client.get_item(
                TableName=self._table_name,
                Key={"pk": {"S": WATERMARK_PARTITION_KEY}},
                ConsistentRead=True,
            )
        except ClientError:
            logger.exception("watermark read failed, treating as unset")
            return EPOCH

        item = response.get("Item")
        if not item or "last_event_ts" not in item:
            logger.info("no watermark found, starting from epoch")
            return EPOCH

        raw = item["last_event_ts"]["S"]
        try:
            return datetime.fromisoformat(raw).astimezone(UTC)
        except ValueError:
            logger.warning("unparseable watermark, treating as unset", extra={"raw": raw})
            return EPOCH

    def write(self, event_ts: datetime, record_count: int) -> None:
        """Advance the watermark.

        The conditional write guards against a late-finishing invocation moving
        the watermark backwards and causing a gap. Two overlapping runs are
        possible if one is slow; the newer timestamp always wins.
        """
        iso = event_ts.astimezone(UTC).isoformat()

        try:
            self._client.put_item(
                TableName=self._table_name,
                Item={
                    "pk": {"S": WATERMARK_PARTITION_KEY},
                    "last_event_ts": {"S": iso},
                    "updated_at": {"S": datetime.now(UTC).isoformat()},
                    "last_record_count": {"N": str(record_count)},
                },
                ConditionExpression="attribute_not_exists(pk) OR last_event_ts < :ts",
                ExpressionAttributeValues={":ts": {"S": iso}},
            )
            logger.info("watermark advanced", extra={"last_event_ts": iso})

        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                logger.info(
                    "watermark not advanced, a newer value already exists",
                    extra={"attempted": iso},
                )
                return
            raise


def filter_new(readings, watermark: datetime):
    """Drop readings at or before the watermark.

    Uses a strict comparison so a reading exactly at the watermark is treated as
    already published. Duplicate suppression matters more here than the risk of
    losing a reading that shares a timestamp, because the composite dedupe key
    is emitted with every record for downstream reconciliation.
    """
    return [r for r in readings if r.event_timestamp > watermark]
