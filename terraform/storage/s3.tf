# ---------------------------------------------------------------------------
# Layered lakehouse object storage.
#
#   raw      immutable, source-fidelity landing zone (JSON/GZIP)
#   staging  cleansed, de-duplicated intermediate (Parquet)
#   curated  analytics-ready, partitioned tables (Parquet)
#
# All three layers share a single customer-managed KMS key, enforce bucket
# ownership, block all public access, version objects, and ship server access
# logs to a dedicated, hardened log bucket.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Data layers and whether each gets the raw-layer lifecycle schedule.
  layers = {
    raw     = { lifecycle = true }
    staging = { lifecycle = false }
    curated = { lifecycle = false }
  }

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

# --------------------------- KMS ------------------------------------------
data "aws_iam_policy_document" "lake_kms" {
  # Account administrators retain full control of the key.
  statement {
    sid       = "EnableRootAccount"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # Allow S3 to use the key for SSE-KMS on this account's behalf.
  statement {
    sid    = "AllowS3Service"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "lake" {
  description             = "CMK for ${local.name_prefix} data lakehouse buckets"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.lake_kms.json
  tags                    = var.tags
}

resource "aws_kms_alias" "lake" {
  name          = "alias/${local.name_prefix}-lake"
  target_key_id = aws_kms_key.lake.key_id
}

# --------------------------- Access-log bucket ----------------------------
resource "aws_s3_bucket" "logs" {
  bucket        = "${local.name_prefix}-access-logs-${local.account_id}"
  force_destroy = var.force_destroy
  tags          = merge(var.tags, { Layer = "logs" })
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 server access logging requires SSE-S3 (AES256) on the log destination.
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Permit the S3 logging service principal to write into the log bucket.
data "aws_iam_policy_document" "logs" {
  statement {
    sid    = "S3ServerAccessLogsPolicy"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json
}

# --------------------------- Data buckets ---------------------------------
resource "aws_s3_bucket" "layer" {
  for_each = local.layers

  bucket        = "${local.name_prefix}-${each.key}-${local.account_id}"
  force_destroy = var.force_destroy
  tags          = merge(var.tags, { Layer = each.key })
}

resource "aws_s3_bucket_ownership_controls" "layer" {
  for_each = aws_s3_bucket.layer

  bucket = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "layer" {
  for_each = aws_s3_bucket.layer

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "layer" {
  for_each = aws_s3_bucket.layer

  bucket = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "layer" {
  for_each = aws_s3_bucket.layer

  bucket = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.lake.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_logging" "layer" {
  for_each = aws_s3_bucket.layer

  bucket        = each.value.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access/${each.key}/"
}

# Lifecycle: only the raw layer ages into colder tiers and expires; staging and
# curated keep a lighter policy (clean up old versions + aborted uploads).
resource "aws_s3_bucket_lifecycle_configuration" "layer" {
  for_each = aws_s3_bucket.layer

  bucket = each.value.id

  dynamic "rule" {
    for_each = local.layers[each.key].lifecycle ? [1] : []
    content {
      id     = "raw-tiering"
      status = "Enabled"
      filter {}

      transition {
        days          = var.raw_lifecycle.transition_ia_days
        storage_class = "STANDARD_IA"
      }
      transition {
        days          = var.raw_lifecycle.transition_glacier_days
        storage_class = "GLACIER"
      }
      expiration {
        days = var.raw_lifecycle.expiration_days
      }
      noncurrent_version_expiration {
        noncurrent_days = var.raw_lifecycle.noncurrent_expire_days
      }
      abort_incomplete_multipart_upload {
        days_after_initiation = 7
      }
    }
  }

  dynamic "rule" {
    for_each = local.layers[each.key].lifecycle ? [] : [1]
    content {
      id     = "housekeeping"
      status = "Enabled"
      filter {}

      noncurrent_version_expiration {
        noncurrent_days = 90
      }
      abort_incomplete_multipart_upload {
        days_after_initiation = 7
      }
    }
  }
}
