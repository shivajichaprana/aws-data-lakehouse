# ---------------------------------------------------------------------------
# Step Functions state machine + its execution role, log group, and the
# pipeline-failure SNS topic.
# ---------------------------------------------------------------------------

# --------------------------- Failure notifications ------------------------
resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-pipeline-alerts"
  kms_master_key_id = var.alarm_sns_kms_key_id
  tags              = var.tags
}

# Let Step Functions in this account publish failure notifications.
data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "AllowStepFunctionsPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# --------------------------- Execution log group --------------------------
# Vended-logs path so Step Functions can deliver execution history here.
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${local.state_machine_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# --------------------------- Execution role -------------------------------
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    # Confused-deputy guard: only this account's state machines may assume it.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name                 = "${local.name_prefix}-pipeline-sfn"
  assume_role_policy   = data.aws_iam_policy_document.sfn_assume.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}

data "aws_iam_policy_document" "sfn_inline" {
  # Drive the raw crawler.
  statement {
    sid       = "RawCrawler"
    effect    = "Allow"
    actions   = ["glue:StartCrawler", "glue:GetCrawler"]
    resources = [local.raw_crawler_arn]
  }

  # Run the curated ETL and quality jobs via the .sync integration, which
  # polls GetJobRun and may BatchStopJobRun on abort.
  statement {
    sid    = "GlueJobRuns"
    effect = "Allow"
    actions = [
      "glue:StartJobRun",
      "glue:GetJobRun",
      "glue:GetJobRuns",
      "glue:BatchStopJobRun",
    ]
    resources = [local.etl_job_arn, local.quality_job_arn]
  }

  # Publish pipeline-failure notifications.
  statement {
    sid       = "PublishAlerts"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  # CloudWatch Logs vending for the state machine's execution logs. These
  # delivery actions do not support resource-level scoping.
  statement {
    sid    = "ExecutionLogDelivery"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sfn_inline" {
  name   = "pipeline-permissions"
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn_inline.json
}

# QuickSight SPICE refresh permissions, attached only when the refresh tail
# is part of the definition.
data "aws_iam_policy_document" "sfn_quicksight" {
  count = local.refresh_enabled ? 1 : 0

  statement {
    sid       = "RefreshDataset"
    effect    = "Allow"
    actions   = ["quicksight:CreateIngestion", "quicksight:DescribeIngestion"]
    resources = [local.dataset_arn, "${local.dataset_arn}/ingestion/*"]
  }
}

resource "aws_iam_role_policy" "sfn_quicksight" {
  count = local.refresh_enabled ? 1 : 0

  name   = "pipeline-quicksight-refresh"
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn_quicksight[0].json
}

# X-Ray tracing permissions, attached only when tracing is enabled.
data "aws_iam_policy_document" "sfn_xray" {
  count = var.enable_xray_tracing ? 1 : 0

  statement {
    sid    = "XRayTracing"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sfn_xray" {
  count = var.enable_xray_tracing ? 1 : 0

  name   = "pipeline-xray"
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn_xray[0].json
}

# --------------------------- State machine --------------------------------
resource "aws_sfn_state_machine" "pipeline" {
  name     = local.state_machine_name
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD"

  definition = local.pipeline_definition

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = var.sfn_log_level
  }

  tracing_configuration {
    enabled = var.enable_xray_tracing
  }

  tags = var.tags

  # The execution role must carry its log-delivery permissions before the
  # state machine's logging configuration can be created.
  depends_on = [aws_iam_role_policy.sfn_inline]
}
