# ---------------------------------------------------------------------------
# Glue Data Catalog module.
#
# Composes the metadata and ETL layer that sits between raw ingest and the
# query/BI layers:
#
#   * three databases  - raw / staging / curated (one per lake layer)
#   * catalog tables    - a canonical raw-events schema (consumed by Firehose
#                         Parquet conversion and the ETL job) and the curated
#                         output table
#   * crawlers          - keep partitions discovered on the raw and curated
#                         tables, on a schedule
#   * ETL job           - a PySpark raw -> curated transform with schema
#                         enforcement, de-duplication, and catalog updates
#
# All Glue resources share a security configuration that encrypts S3 output,
# job bookmarks, and CloudWatch logs with the lake CMK supplied by the storage
# module.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Glue/Athena strongly prefer underscores in database identifiers.
  db_prefix = replace("${var.project}_${var.environment}", "-", "_")

  database_names = {
    raw     = "${local.db_prefix}_raw"
    staging = "${local.db_prefix}_staging"
    curated = "${local.db_prefix}_curated"
  }

  # Canonical table names. event_type/year/month/day are Hive partition keys
  # materialised by Firehose, so they are NOT repeated as data columns.
  raw_table     = "events"
  curated_table = "events"

  # Data lands under this prefix in every layer (see ingest/firehose.tf).
  events_prefix = "events"

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name
}

# Encrypt Glue output, bookmarks, and logs with the lake CMK. Mirrors the
# at-rest posture the storage and ingest modules already enforce.
resource "aws_glue_security_configuration" "this" {
  name = "${local.name_prefix}-catalog"

  encryption_configuration {
    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn                = var.kms_key_arn
    }

    job_bookmarks_encryption {
      job_bookmarks_encryption_mode = "CSE-KMS"
      kms_key_arn                   = var.kms_key_arn
    }

    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = var.kms_key_arn
    }
  }
}
