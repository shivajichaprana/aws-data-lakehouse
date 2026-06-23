output "bucket_ids" {
  description = "Map of layer name -> S3 bucket id (raw/staging/curated)."
  value       = { for k, b in aws_s3_bucket.layer : k => b.id }
}

output "bucket_arns" {
  description = "Map of layer name -> S3 bucket ARN."
  value       = { for k, b in aws_s3_bucket.layer : k => b.arn }
}

output "raw_bucket_id" {
  description = "Raw landing-zone bucket id."
  value       = aws_s3_bucket.layer["raw"].id
}

output "raw_bucket_arn" {
  description = "Raw landing-zone bucket ARN."
  value       = aws_s3_bucket.layer["raw"].arn
}

output "access_logs_bucket_id" {
  description = "Server-access-log bucket id."
  value       = aws_s3_bucket.logs.id
}

output "kms_key_arn" {
  description = "ARN of the lakehouse CMK used for SSE-KMS."
  value       = aws_kms_key.lake.arn
}

output "kms_key_id" {
  description = "Key id of the lakehouse CMK."
  value       = aws_kms_key.lake.key_id
}
