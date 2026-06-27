# ---------------------------------------------------------------------------
# EventBridge Scheduler trigger.
#
# A single schedule starts one pipeline execution per tick. EventBridge
# Scheduler (rather than a classic CloudWatch Events rule) gives a native
# timezone, a flexible delivery window, and a dedicated invocation role with a
# tight confused-deputy guard.
# ---------------------------------------------------------------------------

# --------------------------- Invocation role ------------------------------
data "aws_iam_policy_document" "scheduler_assume" {
  count = var.enable_schedule ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    # Only this account's schedules may assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:scheduler:${local.region}:${local.account_id}:schedule/*/${local.state_machine_name}"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count = var.enable_schedule ? 1 : 0

  name                 = "${local.name_prefix}-pipeline-scheduler"
  assume_role_policy   = data.aws_iam_policy_document.scheduler_assume[0].json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}

data "aws_iam_policy_document" "scheduler_invoke" {
  count = var.enable_schedule ? 1 : 0

  statement {
    sid       = "StartPipelineExecution"
    effect    = "Allow"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.pipeline.arn]
  }
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  count = var.enable_schedule ? 1 : 0

  name   = "start-execution"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler_invoke[0].json
}

# --------------------------- Schedule -------------------------------------
resource "aws_scheduler_schedule" "pipeline" {
  count = var.enable_schedule ? 1 : 0

  name       = "${local.name_prefix}-daily-pipeline"
  group_name = "default"

  flexible_time_window {
    mode                      = var.schedule_flexible_window_minutes > 0 ? "FLEXIBLE" : "OFF"
    maximum_window_in_minutes = var.schedule_flexible_window_minutes > 0 ? var.schedule_flexible_window_minutes : null
  }

  schedule_expression          = var.pipeline_schedule
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = aws_sfn_state_machine.pipeline.arn
    role_arn = aws_iam_role.scheduler[0].arn

    # Empty object: the pipeline derives everything it needs internally.
    input = jsonencode({})

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 0
    }
  }
}
