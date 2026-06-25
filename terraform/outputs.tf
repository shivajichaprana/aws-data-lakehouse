output "raw_bucket" {
  description = "Raw landing-zone bucket id."
  value       = module.storage.raw_bucket_id
}

output "data_buckets" {
  description = "Map of layer -> bucket id (raw/staging/curated)."
  value       = module.storage.bucket_ids
}

output "lake_kms_key_arn" {
  description = "ARN of the lakehouse CMK."
  value       = module.storage.kms_key_arn
}

output "firehose_stream_name" {
  description = "Name of the ingest Firehose delivery stream."
  value       = module.ingest.stream_name
}

output "firehose_stream_arn" {
  description = "ARN of the ingest Firehose delivery stream."
  value       = module.ingest.stream_arn
}

output "glue_databases" {
  description = "Glue databases for the raw, staging, and curated layers."
  value = {
    raw     = module.catalog.raw_database_name
    staging = module.catalog.staging_database_name
    curated = module.catalog.curated_database_name
  }
}

output "raw_events_table" {
  description = "Canonical raw-events Glue table name."
  value       = module.catalog.raw_events_table_name
}

output "curated_events_table" {
  description = "Curated events Glue table name."
  value       = module.catalog.curated_events_table_name
}

output "etl_job_name" {
  description = "Name of the raw->curated PySpark ETL job."
  value       = module.catalog.etl_job_name
}

output "glue_crawlers" {
  description = "Names of the raw and curated Glue crawlers."
  value = {
    raw     = module.catalog.raw_crawler_name
    curated = module.catalog.curated_crawler_name
  }
}

output "athena_workgroup_name" {
  description = "Name of the Athena workgroup for curated-layer analytics."
  value       = module.query.workgroup_name
}

output "athena_results_bucket" {
  description = "Bucket id holding Athena query results."
  value       = module.query.results_bucket_id
}

output "athena_named_queries" {
  description = "Map of saved Athena named-query name -> id."
  value       = module.query.named_query_ids
}

output "lake_formation_admins" {
  description = "Principal ARNs registered as Lake Formation administrators."
  value       = module.catalog.data_lake_admins
}
