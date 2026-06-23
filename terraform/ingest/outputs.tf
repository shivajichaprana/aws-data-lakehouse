output "stream_name" {
  description = "Name of the Firehose delivery stream."
  value       = aws_kinesis_firehose_delivery_stream.this.name
}

output "stream_arn" {
  description = "ARN of the Firehose delivery stream."
  value       = aws_kinesis_firehose_delivery_stream.this.arn
}

output "firehose_role_arn" {
  description = "ARN of the IAM role assumed by Firehose."
  value       = aws_iam_role.firehose.arn
}

output "log_group_name" {
  description = "CloudWatch log group capturing delivery errors."
  value       = aws_cloudwatch_log_group.firehose.name
}
