# ---------------------------------------------------------------------------
# Athena workgroup + dedicated, hardened results bucket.
#
# The results bucket mirrors the storage module's posture: bucket-owner
# enforced, all public access blocked, versioned, SSE-KMS with the lake CMK,
# and lifecycle-expired so query spills do not accumulate forever. The
# workgroup pins the result location and encryption so individual users cannot
# write unencrypted results to arbitrary buckets.
# ---------------------------------------------------------------------------

# --------------------------- Results bucket -------------------------------
resource "aws_s3_bucket" "athena_results" {
  bucket        = "${local.name_prefix}-athena-results-${local.account_id}"
  force_destroy = var.force_destroy

  tags = merge(var.tags, { Layer = "query-results" })
}

resource "aws_s3_bucket_ownership_controls" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

# Optional server-access logging into the storage module's log bucket.
resource "aws_s3_bucket_logging" "athena_results" {
  count = var.access_logs_bucket_id == null ? 0 : 1

  bucket        = aws_s3_bucket.athena_results.id
  target_bucket = var.access_logs_bucket_id
  target_prefix = "s3-access/athena-results/"
}

# Expire query results and clean up old versions / aborted uploads.
resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-query-results"
    status = "Enabled"
    filter {}

    expiration {
      days = var.result_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Enforce TLS-only access to the results bucket.
data "aws_iam_policy_document" "athena_results" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.athena_results.arn,
      "${aws_s3_bucket.athena_results.arn}/*",
    ]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  policy = data.aws_iam_policy_document.athena_results.json
}

# --------------------------- Workgroup ------------------------------------
resource "aws_athena_workgroup" "this" {
  name          = "${local.name_prefix}-analytics"
  description   = "Curated-layer analytics workgroup for ${local.name_prefix}."
  state         = "ENABLED"
  force_destroy = var.force_destroy

  configuration {
    # Force every query to inherit the result location + encryption below.
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.bytes_scanned_cutoff_bytes

    engine_version {
      selected_engine_version = var.athena_engine_version
    }

    result_configuration {
      output_location       = "s3://${aws_s3_bucket.athena_results.id}/${var.results_prefix}/"
      expected_bucket_owner = local.account_id

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_key_arn
      }
    }
  }

  tags = var.tags
}
