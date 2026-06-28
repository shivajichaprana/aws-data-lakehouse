"""AWS Glue PySpark job: PyDeequ data-quality verification of curated events.

The job reads one ingest-date partition of the curated events Parquet directly
from S3, runs a PyDeequ ``VerificationSuite`` of completeness, uniqueness, and
range constraints, and turns the outcome into operational signal:

  * the full constraint-level result set is written to S3 (one partition per
    run) for audit and trend analysis; and
  * compact custom metrics (ConstraintsFailed / ConstraintsTotal / CheckSuccess
    / RowsVerified) are published to CloudWatch so alarms can page on quality
    regressions.

When ``--fail_on_error true`` and any *error*-level constraint fails, the job
raises after metrics are emitted, so both the Glue run state and the CloudWatch
alarm reflect the failure.

Job arguments
-------------
--curated_path             S3 URI prefix of the curated events Parquet.
--results_path             S3 URI prefix for persisted verification results.
--database / --table       Curated database/table (labelling only).
--metric_namespace         CloudWatch namespace for custom metrics.
--metric_job_name          Value of the JobName metric dimension.
--region                   AWS region for the CloudWatch client.
--process_date             Ingest date YYYY-MM-DD. Empty => prior UTC date.
--fail_on_error            "true"/"false": fail the run on error-level failures.
--required_completeness    Min completeness (0-1) for mandatory columns.
--min_user_id_completeness Min completeness (0-1) for user_id (warning level).
--allowed_event_types      Comma-separated closed set for event_type (optional).
--max_quantity             Inclusive upper bound for quantity (optional/empty).
"""

from __future__ import annotations

# PyDeequ resolves the Deequ Maven coordinate from SPARK_VERSION at import time,
# so it must be set before pydeequ is imported. Glue 4.0 bundles Spark 3.3.
import os

os.environ.setdefault("SPARK_VERSION", "3.3")

import sys
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional, Tuple

import boto3
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import DataFrame
from pyspark.sql import functions as F
from pyspark.sql.utils import AnalysisException
from pydeequ.checks import Check, CheckLevel
from pydeequ.verification import VerificationResult, VerificationSuite

# Mandatory columns that must never be null in the curated layer.
REQUIRED_COLUMNS: List[str] = ["event_id", "event_ts", "event_type"]

REQUIRED_ARGS: List[str] = [
    "JOB_NAME",
    "curated_path",
    "results_path",
    "database",
    "table",
    "metric_namespace",
    "metric_job_name",
    "region",
    "process_date",
    "fail_on_error",
    "required_completeness",
    "min_user_id_completeness",
    "allowed_event_types",
    "max_quantity",
]


def resolve_process_date(raw_value: str) -> Tuple[str, str, str]:
    """Return ``(year, month, day)`` zero-padded strings for the target date.

    An empty value defaults to the prior UTC date - the partition a quality job
    scheduled in the early hours should verify once the day has fully landed.
    """
    if raw_value and raw_value.strip():
        target = datetime.strptime(raw_value.strip(), "%Y-%m-%d").replace(tzinfo=timezone.utc)
    else:
        target = datetime.now(timezone.utc) - timedelta(days=1)
    return f"{target.year:04d}", f"{target.month:02d}", f"{target.day:02d}"


def parse_bool(value: str) -> bool:
    """Parse a Glue string argument into a bool."""
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def read_partition(spark, curated_path: str, year: str, month: str, day: str) -> Optional[DataFrame]:
    """Read a single ingest-date partition of curated Parquet.

    Returns ``None`` when the curated location does not yet exist (e.g. before
    the first ETL run) so the caller can treat "no data" distinctly from a
    constraint failure.
    """
    try:
        df = spark.read.parquet(curated_path)
    except AnalysisException:
        return None

    return df.where(
        (F.col("year") == year) & (F.col("month") == month) & (F.col("day") == day)
    )


def build_checks(
    spark,
    required_completeness: float,
    min_user_id_completeness: float,
    allowed_event_types: List[str],
    max_quantity: Optional[float],
) -> List[Check]:
    """Construct the error- and warning-level Deequ checks for curated events."""
    error_check = Check(spark, CheckLevel.Error, "curated-events-quality").hasSize(lambda s: s > 0)

    # Mandatory completeness: exact (==1.0) by default, relaxed if configured.
    for column in REQUIRED_COLUMNS:
        if required_completeness >= 1.0:
            error_check = error_check.isComplete(column)
        else:
            error_check = error_check.hasCompleteness(
                column, lambda c, t=required_completeness: c >= t
            )

    # Primary-key uniqueness and numeric range constraints.
    error_check = (
        error_check.isUnique("event_id")
        .isNonNegative("value")
        .isNonNegative("quantity")
    )

    if max_quantity is not None:
        error_check = error_check.hasMax("quantity", lambda m, t=max_quantity: m <= t)

    if allowed_event_types:
        error_check = error_check.isContainedIn("event_type", allowed_event_types)

    warning_check = Check(spark, CheckLevel.Warning, "curated-events-warnings").hasCompleteness(
        "user_id", lambda c: c >= min_user_id_completeness
    )

    return [error_check, warning_check]


def summarize(result_rows: List) -> Tuple[int, int, int]:
    """Reduce constraint rows to ``(error_failures, total, success_flag)``."""
    total = len(result_rows)
    error_failures = sum(
        1
        for r in result_rows
        if r["check_level"] == "Error" and r["constraint_status"] != "Success"
    )
    success_flag = 0 if error_failures > 0 else 1
    return error_failures, total, success_flag


def emit_metrics(
    region: str,
    namespace: str,
    job_name: str,
    failures: int,
    total: int,
    rows: int,
    success: int,
) -> None:
    """Publish compact data-quality metrics to CloudWatch."""
    client = boto3.client("cloudwatch", region_name=region)
    dimensions = [{"Name": "JobName", "Value": job_name}]
    metrics: Dict[str, float] = {
        "ConstraintsFailed": failures,
        "ConstraintsTotal": total,
        "RowsVerified": rows,
        "CheckSuccess": success,
    }
    client.put_metric_data(
        Namespace=namespace,
        MetricData=[
            {"MetricName": name, "Dimensions": dimensions, "Value": float(value), "Unit": "Count"}
            for name, value in metrics.items()
        ],
    )


def main() -> None:
    args = getResolvedOptions(sys.argv, REQUIRED_ARGS)

    sc = SparkContext.getOrCreate()
    glue_context = GlueContext(sc)
    spark = glue_context.spark_session
    logger = glue_context.get_logger()

    job = Job(glue_context)
    job.init(args["JOB_NAME"], args)

    namespace = args["metric_namespace"]
    job_name = args["metric_job_name"]
    region = args["region"]
    fail_on_error = parse_bool(args["fail_on_error"])
    required_completeness = float(args["required_completeness"])
    min_user_id_completeness = float(args["min_user_id_completeness"])
    allowed_event_types = [v for v in args["allowed_event_types"].split(",") if v.strip()]
    max_quantity = float(args["max_quantity"]) if args["max_quantity"].strip() else None

    year, month, day = resolve_process_date(args["process_date"])
    logger.info(f"quality_checks: verifying partition {year}-{month}-{day}")

    partition = read_partition(spark, args["curated_path"], year, month, day)

    # No curated location or no rows for the date: emit a clean, zero-row result
    # rather than failing. The staleness alarm covers a job that stops running.
    if partition is None or partition.rdd.isEmpty():
        logger.warn("quality_checks: no curated rows for target partition; emitting zero-row result")
        emit_metrics(region, namespace, job_name, failures=0, total=0, rows=0, success=1)
        job.commit()
        return

    row_count = partition.count()

    checks = build_checks(
        spark,
        required_completeness,
        min_user_id_completeness,
        allowed_event_types,
        max_quantity,
    )

    suite = VerificationSuite(spark).onData(partition)
    for check in checks:
        suite = suite.addCheck(check)
    result = suite.run()

    result_df = VerificationResult.checkResultsAsDataFrame(spark, result)
    result_rows = result_df.collect()
    failures, total, success = summarize(result_rows)

    logger.info(
        f"quality_checks: {row_count} rows, {total} constraints, "
        f"{failures} error-level failures, success={success}"
    )

    # Persist the full constraint-level results for audit/trend (one run/date).
    results_uri = f"{args['results_path'].rstrip('/')}/year={year}/month={month}/day={day}/"
    (
        result_df.withColumn("rows_verified", F.lit(row_count))
        .withColumn("verified_at", F.current_timestamp())
        .coalesce(1)
        .write.mode("overwrite")
        .json(results_uri)
    )

    emit_metrics(region, namespace, job_name, failures, total, row_count, success)

    job.commit()

    if failures > 0:
        for r in result_rows:
            if r["check_level"] == "Error" and r["constraint_status"] != "Success":
                logger.error(
                    f"quality_checks: FAILED {r['constraint']} :: {r['constraint_message']}"
                )
        if fail_on_error:
            raise RuntimeError(
                f"Data-quality verification failed: {failures} error-level constraint(s) failed"
            )


if __name__ == "__main__":
    main()
