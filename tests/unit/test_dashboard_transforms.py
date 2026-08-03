"""Tests for the dashboard's pure transforms. No AWS, no Streamlit."""

from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd
import pytest

# dashboard package lives at repo root; make it importable
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from dashboard import transforms


@pytest.fixture
def facts():
    rows = []
    for sensor in ["s1", "s2"]:
        for hour in range(24):
            for weekend in [False, True]:
                rows.append(
                    {
                        "sensor_key": sensor,
                        "location_id": 1 if sensor == "s1" else 2,
                        "date_key": "2026-07-23" if not weekend else "2026-07-25",
                        "event_hour": hour,
                        "is_weekend": weekend,
                        "day_of_week": 4 if not weekend else 6,
                        "pedestrian_count": (hour + 1) * (1 if sensor == "s1" else 5),
                    }
                )
    return pd.DataFrame(rows)


class TestHeadlineMetrics:
    def test_counts_are_correct(self, facts):
        m = transforms.headline_metrics(facts)
        assert m["distinct_sensors"] == 2
        assert m["total_readings"] == len(facts)
        assert m["peak_count"] == 24 * 5  # s2, hour 23


class TestBusiestSensors:
    def test_returns_sensors_sorted_descending(self, facts):
        b = transforms.busiest_sensors(facts)
        assert list(b["sensor_key"]) == ["s2", "s1"]  # s2 has 5x the counts

    def test_respects_top_n(self, facts):
        assert len(transforms.busiest_sensors(facts, top_n=1)) == 1


class TestAverageByHour:
    def test_one_row_per_hour(self, facts):
        h = transforms.average_by_hour(facts)
        assert len(h) == 24
        assert set(h["event_hour"]) == set(range(24))

    def test_hours_are_ordered(self, facts):
        h = transforms.average_by_hour(facts)
        assert list(h["event_hour"]) == sorted(h["event_hour"])


class TestHourlyProfileByDaytype:
    def test_splits_into_weekday_and_weekend(self, facts):
        p = transforms.hourly_profile_by_daytype(facts)
        assert set(p["day_type"]) == {"weekday", "weekend"}

    def test_two_rows_per_hour(self, facts):
        p = transforms.hourly_profile_by_daytype(facts)
        # 24 hours x 2 day types
        assert len(p) == 48
