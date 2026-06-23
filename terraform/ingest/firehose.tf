# ---------------------------------------------------------------------------
# Kinesis Data Firehose ingest into the raw lake layer.
#
# Records are JSON events of the shape:
#   { "event_type": "...", "event_id": "...", "ts": "...", "payload": {...} }
#
# The stream:
#   * extracts event_type via JQ metadata extraction
#   * dynamically partitions objects by event_type + ingestion date
#   * line-delimits JSON records (or converts to Parquet when a Glue schema
#     is available and enable_parquet_conversion = true)
#   * encrypts at rest with the lake CMK and logs delivery errors to CloudWatch
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  stream_name = "${var.project}-${var.environment}-ingest"
  region      = data.aws_region.current.name
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
}

# --------------------------- Delivery error logging -----------------------
resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${local.stream_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_cloudwatch_log_stream" "s3_delivery" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

# --------------------------- Firehose IAM role ----------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
    # Confused-deputy guard: only this account's Firehose may assume the role.
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name                 = "${local.stream_name}-firehose"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}

data "aws_iam_policy_document" "firehose" {
  statement {
    sid    = "S3Delivery"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [
      var.raw_bucket_arn,
      "${var.raw_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "KmsForS3"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [var.kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${local.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "CloudWatchLogs"
    effect    = "Allow"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.firehose.arn}:*"]
  }

  # Glue schema access is only needed when converting records to Parquet.
  dynamic "statement" {
    for_each = var.enable_parquet_conversion ? [1] : []
    content {
      sid    = "GlueSchema"
      effect = "Allow"
      actions = [
        "glue:GetTable",
        "glue:GetTableVersion",
        "glue:GetTableVersions",
      ]
      resources = [
        "arn:${local.partition}:glue:${local.region}:${local.account_id}:catalog",
        "arn:${local.partition}:glue:${local.region}:${local.account_id}:database/${var.glue_database_name}",
        "arn:${local.partition}:glue:${local.region}:${local.account_id}:table/${var.glue_database_name}/${var.glue_table_name}",
      ]
    }
  }
}

resource "aws_iam_role_policy" "firehose" {
  name   = "delivery"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose.json
}

# --------------------------- Delivery stream ------------------------------
resource "aws_kinesis_firehose_delivery_stream" "this" {
  name        = local.stream_name
  destination = "extended_s3"

  server_side_encryption {
    enabled  = true
    key_type = "CUSTOMER_MANAGED_CMK"
    key_arn  = var.kms_key_arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = var.raw_bucket_arn

    buffering_size     = var.buffer_size_mb
    buffering_interval = var.buffer_interval_seconds

    # Parquet brings its own columnar compression; raw JSON is GZIP-compressed.
    compression_format = var.enable_parquet_conversion ? "UNCOMPRESSED" : "GZIP"
    kms_key_arn        = var.kms_key_arn

    # Hive-style partitions so crawlers and Athena can prune by event/date.
    prefix              = "events/event_type=!{partitionKeyFromQuery:event_type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/result=!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    dynamic_partitioning_configuration {
      enabled        = true
      retry_duration = 300
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.s3_delivery.name
    }

    processing_configuration {
      enabled = true

      # Pull event_type out of each record to drive dynamic partitioning.
      processors {
        type = "MetadataExtraction"
        parameters {
          parameter_name  = "MetadataExtractionQuery"
          parameter_value = "{event_type:.event_type}"
        }
        parameters {
          parameter_name  = "JsonParsingEngine"
          parameter_value = "JQ-1.6"
        }
      }

      # Newline-delimit JSON records (skip when converting to Parquet).
      dynamic "processors" {
        for_each = var.enable_parquet_conversion ? [] : [1]
        content {
          type = "AppendDelimiterToRecord"
          parameters {
            parameter_name  = "Delimiter"
            parameter_value = "\\n"
          }
        }
      }
    }

    dynamic "data_format_conversion_configuration" {
      for_each = var.enable_parquet_conversion ? [1] : []
      content {
        input_format_configuration {
          deserializer {
            open_x_json_ser_de {}
          }
        }
        output_format_configuration {
          serializer {
            parquet_ser_de {
              compression = "SNAPPY"
            }
          }
        }
        schema_configuration {
          database_name = var.glue_database_name
          table_name    = var.glue_table_name
          role_arn      = aws_iam_role.firehose.arn
          region        = local.region
        }
      }
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = !var.enable_parquet_conversion || (var.glue_database_name != "" && var.glue_table_name != "")
      error_message = "enable_parquet_conversion requires both glue_database_name and glue_table_name."
    }
  }
}
