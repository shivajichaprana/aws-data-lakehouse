# ---------------------------------------------------------------------------
# Data-quality alerting.
#
# The Glue job emits these custom metrics (namespace = var.metric_namespace,
# dimension JobName = local.job_name) on every run:
#
#   ConstraintsFailed  count of error-level constraints that failed
#   ConstraintsTotal   total constraints evaluated
#   CheckSuccess       1 when all error-level constraints passed, else 0
#   RowsVerified       number of curated rows examined
#
# Three alarms turn those metrics into pages: a failed-constraint alarm, a
# run-level failure alarm, and an optional staleness alarm that fires when no
# result is reported within the expected window.
# ---------------------------------------------------------------------------

# --------------------------- Alerts SNS topic -----------------------------
resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-data-quality-alerts"
  kms_master_key_id = var.alarm_sns_kms_key_id
  tags              = var.tags
}

# Allow CloudWatch alarms in this account to publish to the topic.
data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid     = "AllowCloudWatchAlarms"
    effect  = "Allow"
    actions = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
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

# --------------------------- Alarms ---------------------------------------
# Any error-level constraint failure in the latest run.
resource "aws_cloudwatch_metric_alarm" "constraints_failed" {
  alarm_name          = "${local.job_name}-constraints-failed"
  alarm_description   = "One or more error-level data-quality constraints failed on the curated events table."
  namespace           = var.metric_namespace
  metric_name         = "ConstraintsFailed"
  dimensions          = { JobName = local.job_name }
  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = var.alarm_treat_missing_data

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# A run that explicitly reported failure (CheckSuccess = 0).
resource "aws_cloudwatch_metric_alarm" "check_failed" {
  alarm_name          = "${local.job_name}-check-failed"
  alarm_description   = "The latest data-quality verification run reported an overall failure."
  namespace           = var.metric_namespace
  metric_name         = "CheckSuccess"
  dimensions          = { JobName = local.job_name }
  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = var.alarm_treat_missing_data

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# No result reported within the expected window => the job stopped running.
resource "aws_cloudwatch_metric_alarm" "stale_results" {
  count = var.enable_staleness_alarm ? 1 : 0

  alarm_name          = "${local.job_name}-stale-results"
  alarm_description   = "No data-quality result reported within the expected window; the verification job may have stopped running."
  namespace           = var.metric_namespace
  metric_name         = "CheckSuccess"
  dimensions          = { JobName = local.job_name }
  statistic           = "SampleCount"
  period              = var.staleness_period_seconds
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  # Missing data IS the failure mode here, so a gap should breach.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}
