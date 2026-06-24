"""AWS Glue PySpark job: raw clickstream events -> curated Parquet.

The job reads one ingest-date partition of the raw-events Glue table, enforces
the curated schema, flattens the nested ``payload`` struct, de-duplicates by
``event_id`` (keeping the latest record per id), and writes Snappy Parquet to
the curated bucket partitioned by ``event_type/year/month/day``. New partitions
are registered in the Glue Data Catalog via ``enableUpdateCatalog``.

Records that fail validation (missing ``event_id`` or an unparseable ``ts``)
are diverted to a quarantine prefix instead of silently dropped, so data-quality
issues are observable rather than lost.

Job arguments
-------------
--raw_database      Glue database holding the raw-events table.
--raw_table         Raw-events table name.
--curated_db        Glue database for the curated output table.
--curated_table     Curated table name (must already exist).
--curated_path      S3 URI prefix for curated Parquet output.
--quarantine_path   S3 URI prefix for quarantined raw records (JSON).
--process_date      Ingest date to process as YYYY-MM-DD. Empty => yesterday (UTC).
"""

from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from typing import List, Tuple

from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import DataFrame, Window
from pyspark.sql import functions as F

# Partition columns, in physical write order, shared by raw and curated tables.
PARTITION_KEYS: List[str] = ["event_type", "year", "month", "day"]

# Curated column order must match the explicit Glue table definition.
CURATED_COLUMNS: List[str] = [
    "event_id",
    "event_ts",
    "user_id",
    "country",
    "session_id",
    "value",
    "query",
    "sku",
    "quantity",
    "processed_at",
]

# Required job arguments (all are supplied by the Terraform-defined job).
REQUIRED_ARGS: List[str] = [
    "JOB_NAME",
    "raw_database",
    "raw_table",
    "curated_db",
    "curated_table",
    "curated_path",
    "quarantine_path",
    "process_date",
]


def resolve_process_date(raw_value: str) -> Tuple[str, str, str]:
    """Return ``(year, month, day)`` zero-padded strings for the target date.

    An empty ``raw_value`` defaults to yesterday (UTC), which is the natural
    target for a job scheduled in the early hours after a day has fully landed.
    """
    if raw_value and raw_value.strip():
        target = datetime.strptime(raw_value.strip(), "%Y-%m-%d").replace(tzinfo=timezone.utc)
    else:
        target = datetime.now(timezone.utc) - timedelta(days=1)
    return f"{target.year:04d}", f"{target.month:02d}", f"{target.day:02d}"


def enforce_and_flatten(raw_df: DataFrame) -> Tuple[DataFrame, DataFrame]:
    """Split raw rows into (valid_curated, quarantine) frames.

    Validation rules:
      * ``event_id`` must be present and non-empty.
      * ``ts`` must parse to a timestamp.

    The valid frame is flattened to the curated schema; the quarantine frame
    keeps the original raw columns plus a human-readable rejection reason.
    """
    parsed = raw_df.withColumn("_event_ts", F.to_timestamp(F.col("ts")))

    reason = (
        F.when(F.col("event_id").isNull() | (F.trim(F.col("event_id")) == ""), F.lit("missing_event_id"))
        .when(F.col("_event_ts").isNull(), F.lit("unparseable_ts"))
        .otherwise(F.lit(None))
    )
    flagged = parsed.withColumn("_reject_reason", reason)

    quarantine_df = flagged.filter(F.col("_reject_reason").isNotNull()).drop("_event_ts")

    valid = flagged.filter(F.col("_reject_reason").isNull())

    curated_df = (
        valid.select(
            F.col("event_id").cast("string").alias("event_id"),
            F.col("_event_ts").alias("event_ts"),
            F.col("user_id").cast("string").alias("user_id"),
            F.col("payload.country").cast("string").alias("country"),
            F.col("payload.session_id").cast("string").alias("session_id"),
            F.col("payload.value").cast("double").alias("value"),
            F.col("payload.query").cast("string").alias("query"),
            F.col("payload.sku").cast("string").alias("sku"),
            F.col("payload.quantity").cast("int").alias("quantity"),
            F.current_timestamp().alias("processed_at"),
            # Carry partition columns through unchanged.
            F.col("event_type"),
            F.col("year"),
            F.col("month"),
            F.col("day"),
        )
    )
    return curated_df, quarantine_df


def deduplicate(df: DataFrame) -> DataFrame:
    """Keep a single row per ``event_id`` - the most recent by ``event_ts``."""
    window = Window.partitionBy("event_id").orderBy(F.col("event_ts").desc_nulls_last())
    return (
        df.withColumn("_rn", F.row_number().over(window))
        .filter(F.col("_rn") == 1)
        .drop("_rn")
    )


def main() -> None:
    args = getResolvedOptions(sys.argv, REQUIRED_ARGS)

    sc = SparkContext.getOrCreate()
    glue_context = GlueContext(sc)
    logger = glue_context.get_logger()

    job = Job(glue_context)
    job.init(args["JOB_NAME"], args)

    year, month, day = resolve_process_date(args["process_date"])
    predicate = f"year = '{year}' and month = '{month}' and day = '{day}'"
    logger.info(f"raw_to_curated: processing partition {predicate}")

    # Partition pruning via push-down predicate keeps the scan to one day.
    raw_dyf = glue_context.create_dynamic_frame.from_catalog(
        database=args["raw_database"],
        table_name=args["raw_table"],
        push_down_predicate=predicate,
        transformation_ctx="raw_source",
    )

    raw_df = raw_dyf.toDF()
    if raw_df.rdd.isEmpty():
        logger.info("raw_to_curated: no records for target partition; nothing to do")
        job.commit()
        return

    curated_df, quarantine_df = enforce_and_flatten(raw_df)
    curated_df = deduplicate(curated_df).select(*CURATED_COLUMNS, *PARTITION_KEYS)

    curated_count = curated_df.count()
    quarantine_count = quarantine_df.count()
    logger.info(f"raw_to_curated: {curated_count} valid, {quarantine_count} quarantined")

    # Divert rejected records for inspection rather than dropping them.
    if quarantine_count > 0:
        (
            quarantine_df.write.mode("append")
            .partitionBy("event_type", "year", "month", "day")
            .json(f"{args['quarantine_path'].rstrip('/')}/")
        )

    if curated_count == 0:
        logger.info("raw_to_curated: no valid records after enforcement; committing")
        job.commit()
        return

    # Write curated Parquet and register new partitions in the catalog.
    curated_dyf = DynamicFrame.fromDF(curated_df, glue_context, "curated")
    sink = glue_context.getSink(
        path=args["curated_path"],
        connection_type="s3",
        updateBehavior="UPDATE_IN_DATABASE",
        partitionKeys=PARTITION_KEYS,
        enableUpdateCatalog=True,
        transformation_ctx="curated_sink",
    )
    sink.setCatalogInfo(
        catalogDatabase=args["curated_db"],
        catalogTableName=args["curated_table"],
    )
    sink.setFormat("glueparquet", compression="snappy")
    sink.writeFrame(curated_dyf)

    job.commit()
    logger.info("raw_to_curated: job committed successfully")


if __name__ == "__main__":
    main()
