"""Tests for the Bronze to Silver transformation.

Runs against a local SparkSession, no Glue or AWS. The transformation logic is
pure DataFrame-in, DataFrame-out, which is what makes this possible. Spark is
slow to start, so a single session is shared across the module.
"""

from __future__ import annotations

import pytest
from pyspark.sql import SparkSession
from pyspark.sql import types as T

from glue_jobs.bronze_to_silver import (
    clean_counts,
    deduplicate,
    parse_and_type,
    split_valid_and_quarantine,
    transform,
)

BRONZE_SCHEMA = T.StructType(
    [
        T.StructField("location_id", T.IntegerType(), True),
        T.StructField("sensing_datetime", T.StringType(), True),
        T.StructField("sensing_date", T.StringType(), True),
        T.StructField("sensing_time", T.StringType(), True),
        T.StructField("direction_1", T.IntegerType(), True),
        T.StructField("direction_2", T.IntegerType(), True),
        T.StructField("total_of_directions", T.IntegerType(), True),
        T.StructField("dedupe_key", T.StringType(), True),
        T.StructField("ingested_at", T.StringType(), True),
    ]
)


@pytest.fixture(scope="module")
def spark():
    session = (
        SparkSession.builder.master("local[1]")
        .appName("test")
        .config("spark.sql.shuffle.partitions", "1")
        .config("spark.ui.enabled", "false")
        .config("spark.sql.session.timeZone", "UTC")
        .getOrCreate()
    )
    yield session
    session.stop()


def _row(
    location_id=3,
    ts="2026-07-23T13:56:00+00:00",
    d1=4,
    d2=6,
    total=10,
    dedupe_key=None,
    ingested="2026-07-24T06:00:00+00:00",
):
    return (
        location_id,
        ts,
        "2026-07-23",
        "23:56",
        d1,
        d2,
        total,
        dedupe_key or f"{location_id}#{ts}",
        ingested,
    )


def _df(spark, rows):
    return spark.createDataFrame(rows, schema=BRONZE_SCHEMA)


class TestParseAndType:
    def test_derives_local_date_and_hour(self, spark):
        df = parse_and_type(_df(spark, [_row()]))
        row = df.collect()[0]
        # 13:56 UTC is 23:56 Melbourne (AEST, UTC+10)
        assert row["event_hour"] == 23
        assert str(row["event_date"]) == "2026-07-23"

    def test_flags_weekend(self, spark):
        # 2026-07-25 is a Saturday
        df = parse_and_type(_df(spark, [_row(ts="2026-07-25T02:00:00+00:00")]))
        assert df.collect()[0]["is_weekend"] is True

    def test_flags_weekday(self, spark):
        # 2026-07-23 is a Thursday
        df = parse_and_type(_df(spark, [_row(ts="2026-07-23T02:00:00+00:00")]))
        assert df.collect()[0]["is_weekend"] is False


class TestQuarantine:
    def test_valid_row_passes(self, spark):
        typed = parse_and_type(_df(spark, [_row()]))
        valid, quarantined = split_valid_and_quarantine(typed)
        assert valid.count() == 1
        assert quarantined.count() == 0

    def test_null_location_is_quarantined(self, spark):
        typed = parse_and_type(_df(spark, [_row(location_id=None)]))
        valid, quarantined = split_valid_and_quarantine(typed)
        assert valid.count() == 0
        assert quarantined.count() == 1

    def test_unparseable_timestamp_is_quarantined(self, spark):
        typed = parse_and_type(_df(spark, [_row(ts="not-a-timestamp")]))
        valid, quarantined = split_valid_and_quarantine(typed)
        assert valid.count() == 0
        assert quarantined.count() == 1

    def test_good_and_bad_rows_split_correctly(self, spark):
        rows = [_row(location_id=3), _row(location_id=None), _row(location_id=5)]
        typed = parse_and_type(_df(spark, rows))
        valid, quarantined = split_valid_and_quarantine(typed)
        assert valid.count() == 2
        assert quarantined.count() == 1


class TestCleanCounts:
    def test_null_counts_become_zero(self, spark):
        df = clean_counts(_df(spark, [_row(d1=None, d2=None, total=None)]))
        row = df.collect()[0]
        assert row["direction_1"] == 0
        assert row["direction_2"] == 0
        assert row["total_of_directions"] == 0

    def test_total_is_recomputed_not_trusted(self, spark):
        # Upstream total is wrong (99); we recompute 4 + 6 = 10
        df = clean_counts(_df(spark, [_row(d1=4, d2=6, total=99)]))
        assert df.collect()[0]["total_of_directions"] == 10


class TestDeduplicate:
    def test_keeps_most_recently_ingested(self, spark):
        key = "3#2026-07-23T13:56:00+00:00"
        rows = [
            _row(dedupe_key=key, ingested="2026-07-24T06:00:00+00:00", d1=1),
            _row(dedupe_key=key, ingested="2026-07-24T07:00:00+00:00", d1=9),
        ]
        typed = parse_and_type(_df(spark, rows))
        result = deduplicate(typed).collect()
        assert len(result) == 1
        assert result[0]["direction_1"] == 9  # the later ingestion won

    def test_distinct_keys_all_kept(self, spark):
        rows = [_row(location_id=3), _row(location_id=5), _row(location_id=7)]
        typed = parse_and_type(_df(spark, rows))
        assert deduplicate(typed).count() == 3


class TestTransformEndToEnd:
    def test_full_pipeline_produces_clean_silver(self, spark):
        rows = [
            _row(location_id=3),
            _row(location_id=None),  # quarantined
            _row(location_id=3),  # duplicate of the first
        ]
        bronze = _df(spark, rows)
        silver, quarantined = transform(bronze)

        assert silver.count() == 1  # one valid, deduplicated
        assert quarantined.count() == 1  # the null-location row
        # Silver schema does not leak Bronze-only columns
        assert "sensing_date" not in silver.columns
        assert "event_ts_utc" in silver.columns
