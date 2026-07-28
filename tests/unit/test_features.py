"""Tests for forecasting feature engineering.

Pure pandas, no AWS. Verifies the two things most likely to be silently wrong in
a forecasting pipeline: that lags never leak across sensors, and that no feature
leaks the target.

The fixture respects the Gold fact grain: one row per sensor per hour, hours
0-23 once per date. The feature code relies on that grain to order rows
chronologically, which mirrors the guarantee fact_footfall_hourly provides.
"""

from __future__ import annotations

import pandas as pd
import pytest

from forecasting.features import (
    add_lag_features,
    add_target,
    add_time_features,
    build_features,
    feature_columns,
)


@pytest.fixture
def sample():
    """Two sensors, two full days each, at the Gold grain: one row per hour."""
    rows = []
    for sensor, scale in [("a", 1), ("b", 10)]:
        counter = 0
        for day in ["2026-07-20", "2026-07-21"]:
            for hour in range(24):
                rows.append(
                    {
                        "sensor_key": sensor,
                        "date_key": day,
                        "event_hour": hour,
                        "day_of_week": 5,
                        "is_weekend": False,
                        "pedestrian_count": counter * scale,
                    }
                )
                counter += 1
    return pd.DataFrame(rows)


class TestTimeFeatures:
    def test_hour_is_cyclically_encoded(self, sample):
        out = add_time_features(sample)
        h0 = out[out["event_hour"] == 0].iloc[0]
        assert abs(h0["hour_sin"]) < 1e-9
        assert abs(h0["hour_cos"] - 1.0) < 1e-9

    def test_weekend_becomes_integer(self, sample):
        out = add_time_features(sample)
        assert set(out["is_weekend"].unique()) <= {0, 1}


class TestLagFeatures:
    def test_lag_does_not_leak_across_sensors(self, sample):
        out = add_lag_features(sample)
        b = out[out["sensor_key"] == "b"].sort_values(["date_key", "event_hour"])
        assert pd.isna(b.iloc[0]["lag_1h"])

    def test_lag_1h_is_previous_hour_same_sensor(self, sample):
        out = add_lag_features(sample)
        a = (
            out[out["sensor_key"] == "a"]
            .sort_values(["date_key", "event_hour"])
            .reset_index(drop=True)
        )
        assert a.loc[5, "lag_1h"] == a.loc[4, "pedestrian_count"]

    def test_rolling_mean_uses_only_past_hours(self, sample):
        out = add_lag_features(sample)
        a = (
            out[out["sensor_key"] == "a"]
            .sort_values(["date_key", "event_hour"])
            .reset_index(drop=True)
        )
        # shift(1) then window 3: row 10 averages rows 7, 8, 9.
        expected = a.loc[[7, 8, 9], "pedestrian_count"].mean()
        assert abs(a.loc[10, "roll_mean_3h"] - expected) < 1e-9


class TestTarget:
    def test_target_is_next_hour(self, sample):
        out = add_target(sample)
        a = (
            out[out["sensor_key"] == "a"]
            .sort_values(["date_key", "event_hour"])
            .reset_index(drop=True)
        )
        assert a.loc[5, "target_next_hour"] == a.loc[6, "pedestrian_count"]

    def test_last_row_target_is_nan(self, sample):
        out = add_target(sample)
        a = out[out["sensor_key"] == "a"].sort_values(["date_key", "event_hour"])
        assert pd.isna(a.iloc[-1]["target_next_hour"])


class TestBuildFeatures:
    def test_output_has_all_feature_columns_and_target(self, sample):
        out = build_features(sample)
        for col in feature_columns():
            assert col in out.columns
        assert "target_next_hour" in out.columns

    def test_no_nulls_remain(self, sample):
        out = build_features(sample)
        required = [*feature_columns(), "target_next_hour"]
        assert not out[required].isnull().any().any()

    def test_current_count_is_not_a_feature(self, sample):
        assert "pedestrian_count" not in feature_columns()
