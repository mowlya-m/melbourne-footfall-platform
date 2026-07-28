"""Feature engineering for the footfall forecasting model.

Reads the Gold fact table and builds features for a next-hour pedestrian-count
forecast. Written as pure functions on pandas DataFrames so the logic is unit
tested without AWS, exactly as the Silver transform is.

The model target is next hour's `pedestrian_count` for a given sensor. The
features are the ones that actually drive foot traffic: time of day, day of week,
weekend flag, and short-window lags and rolling means that capture recent
momentum.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

# Lags in hours. 1 and 2 capture immediate momentum; 24 captures the same hour
# yesterday, which is the single strongest signal for foot traffic.
LAG_HOURS = [1, 2, 3, 24]

# Column combining date and hour into a single sortable chronological key.
_ORDER = ["sensor_key", "date_key", "event_hour"]

# Rolling windows in hours, for smoothing over recent noise.
ROLLING_WINDOWS = [3, 6]


def add_time_features(df: pd.DataFrame) -> pd.DataFrame:
    """Cyclical encodings of hour and day.

    Hour and day-of-week are cyclical: hour 23 is adjacent to hour 0, not far
    from it. Encoding them as sine/cosine pairs lets the model treat them as the
    circles they are, rather than as a linear 0-23 that wrongly places midnight
    and 1am at opposite ends.
    """
    out = df.copy()
    out["hour_sin"] = np.sin(2 * np.pi * out["event_hour"] / 24)
    out["hour_cos"] = np.cos(2 * np.pi * out["event_hour"] / 24)
    out["dow_sin"] = np.sin(2 * np.pi * out["day_of_week"] / 7)
    out["dow_cos"] = np.cos(2 * np.pi * out["day_of_week"] / 7)
    out["is_weekend"] = out["is_weekend"].astype(int)
    return out


def add_lag_features(df: pd.DataFrame) -> pd.DataFrame:
    """Per-sensor lagged counts.

    Lags are computed within each sensor, ordered by time, so a lag never leaks
    a value from a different sensor. Sorting first is what makes the shift
    correct; an unsorted shift would silently produce garbage.
    """
    out = df.sort_values(["sensor_key", "date_key", "event_hour"]).copy()
    grouped = out.groupby("sensor_key")["pedestrian_count"]

    for lag in LAG_HOURS:
        out[f"lag_{lag}h"] = grouped.shift(lag)

    for window in ROLLING_WINDOWS:
        # shift(1) so the rolling mean uses only past hours, never the current
        # row. Including the current value would leak the target into a feature.
        # transform keeps the result aligned to the original rows; a plain
        # rolling().mean() after groupby returns a re-indexed frame that must be
        # realigned, which is an easy place to silently misplace values.
        out[f"roll_mean_{window}h"] = grouped.transform(
            lambda s, w=window: s.shift(1).rolling(w).mean()
        )

    return out


def add_target(df: pd.DataFrame) -> pd.DataFrame:
    """Next-hour count as the supervised target.

    The target is the same sensor's count one hour ahead. Rows where the next
    hour is missing (end of each sensor's series) get NaN and are dropped before
    training.
    """
    out = df.sort_values(["sensor_key", "date_key", "event_hour"]).copy()
    out["target_next_hour"] = out.groupby("sensor_key")["pedestrian_count"].shift(-1)
    return out


def build_features(df: pd.DataFrame) -> pd.DataFrame:
    """Full feature pipeline, composed of the pure steps above.

    Returns rows ready for training: features plus target, with rows that lack a
    complete lag history or a target dropped.
    """
    featured = add_target(add_lag_features(add_time_features(df)))

    feature_cols = feature_columns()
    required = [*feature_cols, "target_next_hour"]

    # Drop rows with any missing feature or target. Early hours of each sensor's
    # series necessarily lack their 24h lag, so some loss here is expected.
    return featured.dropna(subset=required)


def feature_columns() -> list[str]:
    """The exact columns the model trains on. Single source of truth so training
    and inference cannot drift."""
    cyclical = ["hour_sin", "hour_cos", "dow_sin", "dow_cos", "is_weekend"]
    lags = [f"lag_{lag}h" for lag in LAG_HOURS]
    rolls = [f"roll_mean_{w}h" for w in ROLLING_WINDOWS]
    return [*cyclical, *lags, *rolls]
