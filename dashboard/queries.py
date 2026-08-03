"""Athena data access for the dashboard.

Isolated here so app.py and transforms.py carry no AWS dependency. This is the
only module that touches the warehouse, which keeps the rest unit testable.
"""

from __future__ import annotations

import os

import pandas as pd

DATABASE = os.environ.get("GLUE_DATABASE", "melbourne_footfall_dev")
WORKGROUP = os.environ.get("ATHENA_WORKGROUP", "melbourne-footfall-dev")


def read_hourly_facts() -> pd.DataFrame:
    """Read the Gold fact table joined to the sensor dimension.

    Returns one row per sensor per hour with the sensor's location id, so the
    dashboard can label sensors rather than show opaque surrogate keys.
    """
    import awswrangler as wr

    sql = """
        SELECT
            f.sensor_key,
            s.location_id,
            f.date_key,
            f.event_hour,
            f.is_weekend,
            f.day_of_week,
            f.pedestrian_count
        FROM fact_footfall_hourly f
        LEFT JOIN dim_sensor s
            ON f.sensor_key = s.sensor_key
        WHERE s.is_current = true
    """
    return wr.athena.read_sql_query(sql, database=DATABASE, workgroup=WORKGROUP)
