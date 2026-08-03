"""Melbourne foot traffic dashboard.

Reads the Gold fact and dimension tables from Athena and renders foot-traffic
patterns: busiest sensors, hourly rhythm, weekday versus weekend, and a per-sensor
day profile.

Data access is isolated in queries.py so the presentation logic here has no AWS
dependency and the transformation helpers can be unit tested without a warehouse.
"""

from __future__ import annotations

import pandas as pd
import streamlit as st

from dashboard import queries, transforms

st.set_page_config(
    page_title="Melbourne Foot Traffic",
    page_icon="•",
    layout="wide",
)

st.title("Melbourne CBD Foot Traffic")
st.caption(
    "Live pedestrian sensor data through a Bronze/Silver/Gold pipeline on AWS. "
    "Figures below are read from the Gold star schema via Athena."
)


@st.cache_data(ttl=600)
def load_facts() -> pd.DataFrame:
    """Cached load of the hourly fact table. TTL keeps it fresh without hitting
    Athena on every interaction."""
    return queries.read_hourly_facts()


try:
    facts = load_facts()
except Exception as exc:  # noqa: BLE001 - surface any AWS/Athena issue to the user
    st.error(
        "Could not load data from Athena. Check AWS credentials and that the "
        f"Gold tables exist. Details: {exc}"
    )
    st.stop()

if facts.empty:
    st.warning("No data returned. The pipeline may not have populated Gold yet.")
    st.stop()

# ---- Headline metrics -------------------------------------------------------

totals = transforms.headline_metrics(facts)
c1, c2, c3, c4 = st.columns(4)
c1.metric("Total readings", f"{totals['total_readings']:,}")
c2.metric("Sensors", totals["distinct_sensors"])
c3.metric("Hours covered", totals["distinct_hours"])
c4.metric("Peak hourly count", f"{totals['peak_count']:,}")

st.divider()

# ---- Busiest sensors --------------------------------------------------------

left, right = st.columns(2)

with left:
    st.subheader("Busiest sensors")
    busiest = transforms.busiest_sensors(facts, top_n=10)
    st.bar_chart(busiest.set_index("sensor_key")["total_pedestrians"], horizontal=True)

with right:
    st.subheader("Weekday vs weekend, by hour")
    profile = transforms.hourly_profile_by_daytype(facts)
    st.line_chart(profile, x="event_hour", y="avg_count", color="day_type")

st.divider()

# ---- Hourly rhythm ----------------------------------------------------------

st.subheader("Average foot traffic by hour of day")
hourly = transforms.average_by_hour(facts)
st.area_chart(hourly.set_index("event_hour")["avg_count"])

st.caption(
    "Built with Streamlit. Data pipeline: City of Melbourne API to Kinesis to "
    "Firehose to S3, transformed through Glue (Silver) and dbt (Gold), queried "
    "with Athena."
)
