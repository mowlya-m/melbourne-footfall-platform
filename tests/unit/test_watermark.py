"""Tests for watermark tracking and deduplication."""

from __future__ import annotations

from datetime import UTC, datetime

import pytest
from botocore.exceptions import ClientError

from producer.api_client import SensorReading
from producer.watermark import EPOCH, WatermarkStore, filter_new


class FakeDynamo:
    """Minimal stand-in. moto would work but is slower and heavier than needed."""

    def __init__(self, item=None, raise_on_get=False, raise_on_put=None):
        self.item = item
        self.raise_on_get = raise_on_get
        self.raise_on_put = raise_on_put
        self.put_calls = []

    def get_item(self, **kwargs):
        if self.raise_on_get:
            raise ClientError(
                {"Error": {"Code": "ProvisionedThroughputExceededException"}}, "GetItem"
            )
        return {"Item": self.item} if self.item else {}

    def put_item(self, **kwargs):
        self.put_calls.append(kwargs)
        if self.raise_on_put:
            raise ClientError({"Error": {"Code": self.raise_on_put}}, "PutItem")
        return {}


def reading(ts: str, location_id: int = 3) -> SensorReading:
    return SensorReading(
        location_id=location_id,
        sensing_datetime=ts,
        sensing_date="2026-07-23",
        sensing_time="23:56",
        direction_1=1,
        direction_2=1,
        total_of_directions=2,
    )


class TestRead:
    def test_returns_epoch_when_no_watermark_exists(self):
        store = WatermarkStore("t", client=FakeDynamo())
        assert store.read() == EPOCH

    def test_returns_stored_timestamp(self):
        client = FakeDynamo(item={"last_event_ts": {"S": "2026-07-23T13:56:00+00:00"}})
        store = WatermarkStore("t", client=client)
        assert store.read() == datetime(2026, 7, 23, 13, 56, tzinfo=UTC)

    def test_read_failure_falls_back_to_epoch_rather_than_halting(self):
        """Reprocessing is harmless; halting ingestion is not."""
        store = WatermarkStore("t", client=FakeDynamo(raise_on_get=True))
        assert store.read() == EPOCH

    def test_unparseable_watermark_falls_back_to_epoch(self):
        client = FakeDynamo(item={"last_event_ts": {"S": "not-a-timestamp"}})
        store = WatermarkStore("t", client=client)
        assert store.read() == EPOCH


class TestWrite:
    def test_writes_the_timestamp_and_record_count(self):
        client = FakeDynamo()
        store = WatermarkStore("t", client=client)
        store.write(datetime(2026, 7, 23, 14, 0, tzinfo=UTC), record_count=42)

        item = client.put_calls[0]["Item"]
        assert item["last_event_ts"]["S"].startswith("2026-07-23T14:00:00")
        assert item["last_record_count"]["N"] == "42"

    def test_uses_a_conditional_write_to_prevent_going_backwards(self):
        client = FakeDynamo()
        WatermarkStore("t", client=client).write(
            datetime(2026, 7, 23, 14, 0, tzinfo=UTC), record_count=1
        )
        assert "ConditionExpression" in client.put_calls[0]

    def test_conditional_failure_is_tolerated(self):
        """A slower overlapping run losing the race is expected, not an error."""
        client = FakeDynamo(raise_on_put="ConditionalCheckFailedException")
        store = WatermarkStore("t", client=client)
        store.write(datetime(2026, 7, 23, 14, 0, tzinfo=UTC), record_count=1)

    def test_other_errors_propagate(self):
        client = FakeDynamo(raise_on_put="InternalServerError")
        store = WatermarkStore("t", client=client)
        with pytest.raises(ClientError):
            store.write(datetime(2026, 7, 23, 14, 0, tzinfo=UTC), record_count=1)


class TestFilterNew:
    def test_keeps_only_readings_after_the_watermark(self):
        readings = [
            reading("2026-07-23T13:00:00+00:00"),
            reading("2026-07-23T14:00:00+00:00"),
            reading("2026-07-23T15:00:00+00:00"),
        ]
        watermark = datetime(2026, 7, 23, 14, 0, tzinfo=UTC)
        kept = filter_new(readings, watermark)

        assert len(kept) == 1
        assert kept[0].sensing_datetime == "2026-07-23T15:00:00+00:00"

    def test_reading_exactly_at_the_watermark_is_treated_as_seen(self):
        readings = [reading("2026-07-23T14:00:00+00:00")]
        watermark = datetime(2026, 7, 23, 14, 0, tzinfo=UTC)
        assert filter_new(readings, watermark) == []

    def test_epoch_watermark_keeps_everything(self):
        readings = [reading("2026-07-23T13:00:00+00:00"), reading("2026-07-23T14:00:00+00:00")]
        assert len(filter_new(readings, EPOCH)) == 2

    def test_empty_input_returns_empty(self):
        assert filter_new([], EPOCH) == []
