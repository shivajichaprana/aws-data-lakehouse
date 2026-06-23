variable "project" {
  description = "Project/name prefix applied to all resources (lower-case, hyphenated)."
  type        = string
  default     = "lakehouse"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.project))
    error_message = "project must be 2-31 chars, lower-case alphanumeric or hyphen, starting with a letter."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region to deploy the lakehouse into."
  type        = string
  default     = "us-east-1"
}

variable "kms_deletion_window_days" {
  description = "Waiting period (days) before a scheduled KMS key deletion completes."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

variable "force_destroy_buckets" {
  description = "Allow Terraform to delete non-empty buckets. Keep false outside dev/test."
  type        = bool
  default     = false
}

variable "raw_lifecycle" {
  description = "Lifecycle transition/expiration schedule (in days) for the raw layer."
  type = object({
    transition_ia_days      = number
    transition_glacier_days = number
    expiration_days         = number
    noncurrent_expire_days  = number
  })
  default = {
    transition_ia_days      = 30
    transition_glacier_days = 90
    expiration_days         = 365
    noncurrent_expire_days  = 30
  }
}

variable "firehose_buffer_size_mb" {
  description = "Firehose S3 buffer size in MiB (must be >= 64 when format conversion is enabled)."
  type        = number
  default     = 64
}

variable "firehose_buffer_interval_seconds" {
  description = "Firehose S3 buffer interval in seconds (>= 60 required for dynamic partitioning)."
  type        = number
  default     = 60
}

variable "enable_parquet_conversion" {
  description = <<-DESC
    Convert records to Parquet on ingest using a Glue table schema. Left false
    until the Glue catalog (catalog module) exists; raw lands as GZIP JSON by
    default, and the raw->curated job produces Parquet downstream.
  DESC
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for Firehose delivery error logs."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
