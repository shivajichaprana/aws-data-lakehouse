output "workgroup_name" {
  description = "Name of the Athena analytics workgroup."
  value       = aws_athena_workgroup.this.name
}

output "workgroup_arn" {
  description = "ARN of the Athena analytics workgroup."
  value       = aws_athena_workgroup.this.arn
}

output "results_bucket_id" {
  description = "Id of the bucket holding Athena query results."
  value       = aws_s3_bucket.athena_results.id
}

output "results_bucket_arn" {
  description = "ARN of the bucket holding Athena query results."
  value       = aws_s3_bucket.athena_results.arn
}

output "named_query_ids" {
  description = "Map of saved named-query name -> Athena named-query id."
  value = {
    daily_event_counts   = aws_athena_named_query.daily_event_counts.id
    revenue_by_date      = aws_athena_named_query.revenue_by_date.id
    top_skus_by_quantity = aws_athena_named_query.top_skus_by_quantity.id
    top_search_queries   = aws_athena_named_query.top_search_queries.id
    daily_active_users   = aws_athena_named_query.daily_active_users.id
    events_by_country    = aws_athena_named_query.events_by_country.id
    hourly_event_rate    = aws_athena_named_query.hourly_event_rate.id
    partition_freshness  = aws_athena_named_query.partition_freshness.id
  }
}
