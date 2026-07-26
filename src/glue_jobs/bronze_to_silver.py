"""Bronze to Silver transformation.

Reads raw NDJSON from the Bronze layer, cleans and deduplicates it, and writes
typed Parquet to Silver. Runs as an AWS Glue PySpark job.

Design choices worth noting:
- The transformation logic lives in pure functions that take and return
  DataFrames, so they can be unit tested against a local SparkSession without
  Glue, AWS, or network access.
- Silver is idempotent: it overwrites the target partition rather than appending,
  so re-running any date produces identical output.
- Deduplication keeps the most recently ingested copy of each reading, which
  matters because the producer can re-emit a record after a watermark reset.
"""

from __future__ import annotations

import sys

from pyspark.sql import DataFrame, SparkSession
from pyspark.sql import functions as F
from pyspark.sql import types as T
from pyspark.sql.window import Window

# Explicit schema. Inferring from JSON is slower and, worse, lets an upstream
# change silently alter column types rather than failing loudly.
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

MELBOURNE_TZ = "Australia/Melbourne"


def parse_and_type(df: DataFrame) -> DataFrame:
    """Cast strings to their proper types and derive time columns.

    The event timestamp arrives as an ISO 8601 string in UTC. It is converted to
    a genuine timestamp and to Melbourne local time, from which the local date
    and hour are derived. Deriving them here rather than trusting the upstream
    `sensing_date`/`sensing_time` means one source of truth and correct DST
    handling.
    """
    # try_to_timestamp returns null on a malformed value rather than throwing.
    # Spark runs in ANSI mode by default, where a plain cast would abort the
    # entire job on one bad record. A null here routes the row to quarantine.
    return (
        df.withColumn("event_ts_utc", F.expr("try_to_timestamp(sensing_datetime)"))
        .withColumn("ingested_ts_utc", F.expr("try_to_timestamp(ingested_at)"))
        .withColumn("event_ts_local", F.from_utc_timestamp("event_ts_utc", MELBOURNE_TZ))
        .withColumn("event_date", F.to_date("event_ts_local"))
        .withColumn("event_hour", F.hour("event_ts_local"))
        .withColumn("day_of_week", F.dayofweek("event_ts_local"))
        .withColumn("is_weekend", F.dayofweek("event_ts_local").isin([1, 7]))
    )


def quarantine_predicate() -> F.Column:
    """Rows that fail this are structurally unusable and must not reach Silver.

    A null location or unparseable timestamp is a genuine defect, not a zero.
    Count fields are handled separately: a null count is a real zero and is
    coerced, not quarantined.
    """
    return (
        F.col("location_id").isNotNull()
        & F.col("event_ts_utc").isNotNull()
        & (F.col("location_id") > 0)
    )


def split_valid_and_quarantine(df: DataFrame) -> tuple[DataFrame, DataFrame]:
    """Partition the input into clean rows and quarantined rows.

    Returning both rather than silently dropping bad rows means the quarantine
    can be written out and monitored: a sudden spike in quarantined rows is a
    signal that something upstream changed.
    """
    predicate = quarantine_predicate()
    valid = df.filter(predicate)
    quarantined = df.filter(~predicate | predicate.isNull())
    return valid, quarantined


def clean_counts(df: DataFrame) -> DataFrame:
    """Coerce null counts to zero and recompute the total.

    A null count means the sensor reported nothing that minute, which is zero.
    The total is recomputed from the two directions rather than trusting the
    upstream `total_of_directions`, so the invariant total = d1 + d2 always holds
    even if the source is inconsistent.
    """
    d1 = F.coalesce(F.col("direction_1"), F.lit(0))
    d2 = F.coalesce(F.col("direction_2"), F.lit(0))
    return (
        df.withColumn("direction_1", d1)
        .withColumn("direction_2", d2)
        .withColumn("total_of_directions", d1 + d2)
    )


def deduplicate(df: DataFrame) -> DataFrame:
    """Keep one row per dedupe_key, preferring the most recently ingested.

    The producer can re-emit a reading after a watermark reset, so Bronze may
    hold the same event twice with different ingested_at values. Row-number over
    a window ordered by ingestion time descending keeps the freshest copy.
    """
    window = Window.partitionBy("dedupe_key").orderBy(F.col("ingested_ts_utc").desc())
    return df.withColumn("_rn", F.row_number().over(window)).filter(F.col("_rn") == 1).drop("_rn")


def select_silver_columns(df: DataFrame) -> DataFrame:
    """Project the final Silver schema.

    Silver keeps both event and ingestion timestamps so downstream can still
    distinguish late-arriving data from delayed processing, and keeps the
    dedupe_key for lineage back to Bronze.
    """
    return df.select(
        "location_id",
        "event_ts_utc",
        "event_ts_local",
        "event_date",
        "event_hour",
        "day_of_week",
        "is_weekend",
        "direction_1",
        "direction_2",
        "total_of_directions",
        "dedupe_key",
        "ingested_ts_utc",
    )


def transform(bronze: DataFrame) -> tuple[DataFrame, DataFrame]:
    """Full Bronze to Silver pipeline, composed of the pure steps above.

    Returns the clean Silver DataFrame and the quarantined rows.
    """
    typed = parse_and_type(bronze)
    valid, quarantined = split_valid_and_quarantine(typed)
    silver = select_silver_columns(deduplicate(clean_counts(valid)))
    return silver, quarantined


def _run(spark: SparkSession, bronze_path: str, silver_path: str, quarantine_path: str) -> None:
    """Read, transform, write. Kept thin so the logic stays in `transform`."""
    bronze = spark.read.schema(BRONZE_SCHEMA).json(bronze_path)
    silver, quarantined = transform(bronze)

    # Overwrite the partition rather than appending, so a re-run is idempotent.
    (silver.write.mode("overwrite").partitionBy("event_date").parquet(silver_path))

    if quarantined.take(1):
        (quarantined.write.mode("append").partitionBy("sensing_date").parquet(quarantine_path))


def main() -> None:
    """Glue entry point. Reads job arguments and wires paths together."""
    from awsglue.utils import getResolvedOptions  # noqa: PLC0415 - only present in Glue

    args = getResolvedOptions(
        sys.argv, ["JOB_NAME", "bronze_path", "silver_path", "quarantine_path"]
    )

    # Pin the session timezone to UTC so timestamp parsing is deterministic
    # regardless of the host's local zone. Without this, try_to_timestamp
    # interprets naive timestamps in the machine's zone and downstream
    # conversions shift by the host offset.
    spark = (
        SparkSession.builder.appName(args["JOB_NAME"])
        .config("spark.sql.session.timeZone", "UTC")
        .getOrCreate()
    )
    _run(spark, args["bronze_path"], args["silver_path"], args["quarantine_path"])
    spark.stop()


if __name__ == "__main__":
    main()
