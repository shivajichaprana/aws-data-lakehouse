output "job_name" {
  description = "Name of the PyDeequ data-quality Glue job."
  value       = aws_glue_job.quality.name
}

output "job_arn" {
  description = "ARN of the PyDeequ data-quality Glue job."
  value       = aws_glue_job.quality.arn
}

output "job_role_arn" {
  description = "IAM role assumed by the quality job."
  value       = aws_iam_role.quality.arn
}

output "results_path" {
  description = "S3 URI prefix where verification results are persisted."
  value       = local.results_path
}

output "alerts_topic_arn" {
  description = "ARN of the SNS topic receiving data-quality alarm notifications."
  value       = aws_sns_topic.alerts.arn
}

output "metric_namespace" {
  description = "CloudWatch namespace the quality metrics are published under."
  value       = var.metric_namespace
}

output "alarm_names" {
  description = "Names of the data-quality CloudWatch alarms."
  value = compact([
    aws_cloudwatch_metric_alarm.constraints_failed.alarm_name,
    aws_cloudwatch_metric_alarm.check_failed.alarm_name,
    var.enable_staleness_alarm ? aws_cloudwatch_metric_alarm.stale_results[0].alarm_name : "",
  ])
}
