output "raw_database_name" {
  description = "Glue database holding raw-layer tables."
  value       = aws_glue_catalog_database.raw.name
}

output "staging_database_name" {
  description = "Glue database holding staging-layer tables."
  value       = aws_glue_catalog_database.staging.name
}

output "curated_database_name" {
  description = "Glue database holding curated-layer tables."
  value       = aws_glue_catalog_database.curated.name
}

output "raw_events_table_name" {
  description = "Canonical raw-events table (used by Firehose Parquet conversion and the ETL job)."
  value       = aws_glue_catalog_table.raw_events.name
}

output "curated_events_table_name" {
  description = "Curated analytics-ready events table."
  value       = aws_glue_catalog_table.curated_events.name
}

output "raw_crawler_name" {
  description = "Name of the crawler maintaining raw-events partitions."
  value       = aws_glue_crawler.raw.name
}

output "curated_crawler_name" {
  description = "Name of the crawler maintaining curated-events partitions."
  value       = aws_glue_crawler.curated.name
}

output "etl_job_name" {
  description = "Name of the raw -> curated PySpark ETL job."
  value       = aws_glue_job.raw_to_curated.name
}

output "crawler_role_arn" {
  description = "IAM role assumed by the Glue crawlers."
  value       = aws_iam_role.crawler.arn
}

output "job_role_arn" {
  description = "IAM role assumed by the Glue ETL job."
  value       = aws_iam_role.job.arn
}

output "security_configuration_name" {
  description = "Glue security configuration encrypting catalog output, bookmarks, and logs."
  value       = aws_glue_security_configuration.this.name
}
