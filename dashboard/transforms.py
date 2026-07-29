"""Pure DataFrame transforms for the dashboard.

No AWS, no Streamlit. Each function takes the fact DataFrame and returns exactly
what a chart or metric needs, which makes the presentation layer thin and these
functions unit testable.
"""

from __future__ import annotations

import pandas as pd


def headline_metrics(facts: pd.DataFrame) -> dict:
    """Top-line numbers for the metric cards."""
    return {
        "total_readings": int(facts["pedestrian_count"].count()),
        "distinct_sensors": int(facts["sensor_key"].nunique()),
        "distinct_hours": int(facts[["date_key", "event_hour"]].drop_duplicates().shape[0]),
        "peak_count": int(facts["pedestrian_count"].max()),
    }


def busiest_sensors(facts: pd.DataFrame, top_n: int = 10) -> pd.DataFrame:
    """Total pedestrians per sensor, top N, labelled by location where available."""
    grouped = (
        facts.groupby("sensor_key", as_index=False)["pedestrian_count"]
        .sum()
        .rename(columns={"pedestrian_count": "total_pedestrians"})
        .sort_values("total_pedestrians", ascending=False)
        .head(top_n)
    )
    return grouped


def average_by_hour(facts: pd.DataFrame) -> pd.DataFrame:
    """Mean pedestrian count for each hour of the day, across all sensors."""
    return (
        facts.groupby("event_hour", as_index=False)["pedestrian_count"]
        .mean()
        .rename(columns={"pedestrian_count": "avg_count"})
        .sort_values("event_hour")
    )


def hourly_profile_by_daytype(facts: pd.DataFrame) -> pd.DataFrame:
    """Mean count per hour, split into weekday and weekend series.

    Long format (one row per hour per day-type) so a charting library can colour
    by day_type directly.
    """
    labelled = facts.copy()
    labelled["day_type"] = labelled["is_weekend"].map({True: "weekend", False: "weekday"})

    return (
        labelled.groupby(["event_hour", "day_type"], as_index=False)["pedestrian_count"]
        .mean()
        .rename(columns={"pedestrian_count": "avg_count"})
        .sort_values("event_hour")
    )
