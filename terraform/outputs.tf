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
