output "enabled" {
  description = "Whether the QuickSight BI layer was provisioned."
  value       = local.qs_enabled
}

output "data_source_id" {
  description = "Id of the QuickSight Athena data source (null when disabled)."
  value       = local.qs_enabled ? aws_quicksight_data_source.athena[0].data_source_id : null
}

output "data_source_arn" {
  description = "ARN of the QuickSight Athena data source (null when disabled)."
  value       = local.qs_enabled ? aws_quicksight_data_source.athena[0].arn : null
}

output "data_set_id" {
  description = "Id of the curated SPICE dataset (null when disabled)."
  value       = local.qs_enabled ? aws_quicksight_data_set.curated[0].data_set_id : null
}

output "dashboard_id" {
  description = "Id of the curated overview dashboard (null when disabled)."
  value       = local.qs_enabled ? aws_quicksight_dashboard.curated[0].dashboard_id : null
}

output "dashboard_arn" {
  description = "ARN of the curated overview dashboard (null when disabled)."
  value       = local.qs_enabled ? aws_quicksight_dashboard.curated[0].arn : null
}
