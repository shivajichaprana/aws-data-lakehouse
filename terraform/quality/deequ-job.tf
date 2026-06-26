# ---------------------------------------------------------------------------
# PyDeequ data-quality Glue job.
#
# Ships the quality script to the staging bucket, grants a least-privilege role
# (read curated, read/write staging, use the lake CMK, publish custom metrics),
# and defines the Glue job plus an optional daily trigger that runs after the
# curated ETL.
# ---------------------------------------------------------------------------

# --------------------------- Quality script asset -------------------------
resource "aws_s3_object" "quality_script" {
  bucket = var.staging_bucket_id
  key    = local.script_key
  source = local.script_source
  # Use a content hash (not etag) so SSE-KMS objects still redeploy on change.
  source_hash = filemd5(local.script_source)

  tags = merge(var.tags, { Asset = "glue-quality-script" })
}

# --------------------------- Job IAM role ---------------------------------
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

resource "aws_iam_role" "quality" {
  name                 = "${local.name_prefix}-glue-quality"
  assume_role_policy   = data.aws_iam_policy_document.job_assume.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "quality_service" {
  role       = aws_iam_role.quality.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "quality_inline" {
  # Read curated Parquet and the job script (curated read-only).
  statement {
    sid    = "ReadCuratedAndScript"
    effect = "Allow"
    actions = [
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

  # Persist verification results + temp data to staging.
  statement {
    sid    = "WriteResultsAndTemp"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${var.staging_bucket_arn}/quality/*",
      "${var.staging_bucket_arn}/glue-temp/*",
    ]
  }

  # Decrypt curated input, encrypt results, all under the lake CMK.
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

  # Publish custom data-quality metrics, scoped to the configured namespace.
  statement {
    sid    = "PublishQualityMetrics"
    effect = "Allow"
    actions = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.metric_namespace]
    }
  }
}

resource "aws_iam_role_policy" "quality_inline" {
  name   = "lake-quality"
  role   = aws_iam_role.quality.id
  policy = data.aws_iam_policy_document.quality_inline.json
}

# --------------------------- Glue job -------------------------------------
resource "aws_glue_job" "quality" {
  name              = local.job_name
  description       = "PyDeequ data-quality verification of the curated events table."
  role_arn          = aws_iam_role.quality.arn
  glue_version      = var.glue_version
  worker_type       = var.worker_type
  number_of_workers = var.number_of_workers
  timeout           = var.job_timeout_minutes
  max_retries       = var.job_max_retries

  security_configuration = var.security_configuration_name

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${var.staging_bucket_id}/${aws_s3_object.quality_script.key}"
  }

  execution_property {
    max_concurrent_runs = var.max_concurrent_runs
  }

  default_arguments = local.job_arguments

  tags = var.tags
}

# --------------------------- Scheduled trigger ----------------------------
resource "aws_glue_trigger" "quality_daily" {
  count = var.enable_job_schedule ? 1 : 0

  name        = "${local.job_name}-daily"
  description = "Runs the data-quality job on a daily schedule, after the curated ETL."
  type        = "SCHEDULED"
  schedule    = var.job_schedule
  enabled     = true

  actions {
    job_name = aws_glue_job.quality.name
    timeout  = var.job_timeout_minutes
  }

  tags = var.tags
}
