# ---------------------------------------------------------------------------
# Raw -> curated PySpark ETL job.
#
# The job reads a date partition of the raw-events table, enforces the curated
# schema (typed casts, payload flattening), de-duplicates by event_id, writes
# Snappy Parquet to the curated bucket partitioned by event_type/year/month/day,
# and updates the Glue catalog with any new partitions. An optional scheduled
# trigger runs it daily after the raw crawler.
# ---------------------------------------------------------------------------

# --------------------------- ETL script asset -----------------------------
# Ship the PySpark script to the staging bucket under a non-data prefix.
resource "aws_s3_object" "etl_script" {
  bucket = var.staging_bucket_id
  key    = "assets/glue/raw_to_curated.py"
  source = "${path.module}/../../glue-scripts/raw_to_curated.py"
  source_hash = filemd5("${path.module}/../../glue-scripts/raw_to_curated.py")

  # Bucket default SSE-KMS (lake CMK) applies; tag for housekeeping.
  tags = merge(var.tags, { Asset = "glue-etl-script" })
}

# --------------------------- ETL job IAM role -----------------------------
data "aws_iam_policy_document" "job_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "job" {
  name                 = "${local.name_prefix}-glue-job"
  assume_role_policy   = data.aws_iam_policy_document.job_assume.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "job_service" {
  role       = aws_iam_role.job.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "job_inline" {
  # Read raw input and the job script.
  statement {
    sid    = "ReadRawAndScript"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      var.raw_bucket_arn,
      "${var.raw_bucket_arn}/*",
      var.staging_bucket_arn,
      "${var.staging_bucket_arn}/*",
    ]
  }

  # Write curated output and quarantined records (staging), plus temp/bookmarks.
  statement {
    sid    = "WriteCuratedAndStaging"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      var.curated_bucket_arn,
      "${var.curated_bucket_arn}/*",
      var.staging_bucket_arn,
      "${var.staging_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "UseLakeCmk"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "job_inline" {
  name   = "lake-etl"
  role   = aws_iam_role.job.id
  policy = data.aws_iam_policy_document.job_inline.json
}

# --------------------------- Glue ETL job ---------------------------------
resource "aws_glue_job" "raw_to_curated" {
  name              = "${local.name_prefix}-raw-to-curated"
  description       = "Transforms raw clickstream events into curated Parquet with schema enforcement."
  role_arn          = aws_iam_role.job.arn
  glue_version      = var.glue_version
  worker_type       = var.worker_type
  number_of_workers = var.number_of_workers
  timeout           = var.job_timeout_minutes
  max_retries       = var.job_max_retries

  security_configuration = aws_glue_security_configuration.this.name

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${var.staging_bucket_id}/${aws_s3_object.etl_script.key}"
  }

  execution_property {
    max_concurrent_runs = var.max_concurrent_runs
  }

  # Job arguments. --process_date is overridable per run; empty means "yesterday".
  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-enable"
    "--enable-metrics"                   = "true"
    "--enable-observability-metrics"     = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-spark-ui"                  = "false"
    "--enable-glue-datacatalog"          = "true"

    "--raw_database"   = aws_glue_catalog_database.raw.name
    "--raw_table"      = aws_glue_catalog_table.raw_events.name
    "--curated_db"     = aws_glue_catalog_database.curated.name
    "--curated_table"  = aws_glue_catalog_table.curated_events.name
    "--curated_path"   = "s3://${var.curated_bucket_id}/${local.events_prefix}/"
    "--quarantine_path" = "s3://${var.staging_bucket_id}/quarantine/${local.events_prefix}/"
    "--process_date"   = ""

    "--TempDir" = "s3://${var.staging_bucket_id}/glue-temp/"
  }

  tags = var.tags
}

# --------------------------- Scheduled trigger ----------------------------
resource "aws_glue_trigger" "daily" {
  count = var.enable_job_schedule ? 1 : 0

  name        = "${local.name_prefix}-raw-to-curated-daily"
  description = "Runs the raw->curated job on a daily schedule."
  type        = "SCHEDULED"
  schedule    = var.job_schedule
  enabled     = true

  actions {
    job_name = aws_glue_job.raw_to_curated.name
    timeout  = var.job_timeout_minutes
  }

  tags = var.tags
}
