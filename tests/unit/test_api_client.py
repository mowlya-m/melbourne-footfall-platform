"""Tests for the pedestrian API client.

Uses a recorded response fixture rather than hitting the live API, so the suite
runs offline and deterministically. The fixture doubles as a contract test: if
the upstream schema changes, these fail loudly instead of the pipeline failing
silently at three in the morning.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from producer.api_client import (
    SensorReading,
    parse_response,
)

FIXTURE = Path(__file__).resolve().parents[1] / "fixtures" / "pedestrian_past_hour.json"


@pytest.fixture
def payload() -> dict:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


class TestParseResponse:
    def test_parses_every_record_in_the_fixture(self, payload):
        readings = parse_response(payload)
        assert len(readings) == len(payload["results"])
        assert all(isinstance(r, SensorReading) for r in readings)

    def test_preserves_upstream_field_values(self, payload):
        first = parse_response(payload)[0]
        raw = payload["results"][0]

        assert first.location_id == raw["location_id"]
        assert first.sensing_datetime == raw["sensing_datetime"]
        assert first.direction_1 == raw["direction_1"]
        assert first.direction_2 == raw["direction_2"]

    def test_coerces_null_counts_to_zero(self):
        """A null count means the sensor reported nothing, which is zero."""
        payload = {
            "results": [
                {
                    "location_id": 3,
                    "sensing_datetime": "2026-07-23T13:56:00+00:00",
                    "sensing_date": "2026-07-23",
                    "sensing_time": "23:56",
                    "direction_1": None,
                    "direction_2": None,
                    "total_of_directions": None,
                }
            ]
        }
        reading = parse_response(payload)[0]
        assert reading.direction_1 == 0
        assert reading.direction_2 == 0

    def test_skips_malformed_records_without_losing_the_batch(self):
        """One bad record must not cost us the good ones."""
        payload = {
            "results": [
                {"location_id": 3, "sensing_datetime": "bad"},  # missing fields
                {
                    "location_id": 5,
                    "sensing_datetime": "2026-07-23T13:56:00+00:00",
                    "sensing_date": "2026-07-23",
                    "sensing_time": "23:56",
                    "direction_1": 1,
                    "direction_2": 2,
                    "total_of_directions": 3,
                },
            ]
        }
        readings = parse_response(payload)
        assert len(readings) == 1
        assert readings[0].location_id == 5

    def test_empty_results_returns_empty_list(self):
        assert parse_response({"results": []}) == []

    def test_missing_results_key_returns_empty_list(self):
        assert parse_response({}) == []


class TestSensorReading:
    def _reading(self, location_id=3, ts="2026-07-23T13:56:00+00:00") -> SensorReading:
        return SensorReading(
            location_id=location_id,
            sensing_datetime=ts,
            sensing_date="2026-07-23",
            sensing_time="23:56",
            direction_1=4,
            direction_2=6,
            total_of_directions=10,
        )

    def test_dedupe_key_combines_sensor_and_timestamp(self):
        assert self._reading().dedupe_key == "3#2026-07-23T13:56:00+00:00"

    def test_dedupe_key_differs_across_sensors_at_the_same_instant(self):
        a = self._reading(location_id=3)
        b = self._reading(location_id=5)
        assert a.dedupe_key != b.dedupe_key

    def test_event_timestamp_is_utc_aware(self):
        ts = self._reading().event_timestamp
        assert ts.tzinfo is not None
        assert ts == datetime(2026, 7, 23, 13, 56, tzinfo=UTC)

    def test_to_record_carries_ingestion_time_alongside_event_time(self):
        """Silver needs both to tell late data from delayed processing."""
        ingested = datetime(2026, 7, 24, 1, 0, tzinfo=UTC)
        record = self._reading().to_record(ingested_at=ingested)

        assert record["sensing_datetime"] == "2026-07-23T13:56:00+00:00"
        assert record["ingested_at"] == ingested.isoformat()
        assert record["dedupe_key"] == "3#2026-07-23T13:56:00+00:00"
