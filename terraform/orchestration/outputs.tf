output "state_machine_arn" {
  description = "ARN of the daily-pipeline Step Functions state machine."
  value       = aws_sfn_state_machine.pipeline.arn
}

output "state_machine_name" {
  description = "Name of the daily-pipeline Step Functions state machine."
  value       = aws_sfn_state_machine.pipeline.name
}

output "role_arn" {
  description = "IAM role assumed by the state machine."
  value       = aws_iam_role.sfn.arn
}

output "log_group_name" {
  description = "CloudWatch Logs group receiving state-machine execution logs."
  value       = aws_cloudwatch_log_group.sfn.name
}

output "alerts_topic_arn" {
  description = "ARN of the SNS topic notified on pipeline failure."
  value       = aws_sns_topic.alerts.arn
}

output "schedule_name" {
  description = "Name of the EventBridge schedule triggering the pipeline (null when disabled)."
  value       = var.enable_schedule ? aws_scheduler_schedule.pipeline[0].name : null
}

output "dashboard_refresh_enabled" {
  description = "Whether the pipeline includes a QuickSight SPICE refresh step."
  value       = local.refresh_enabled
}
