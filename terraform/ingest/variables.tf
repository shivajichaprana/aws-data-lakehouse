variable "project" {
  description = "Name prefix for ingest resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
}

variable "raw_bucket_arn" {
  description = "ARN of the raw landing-zone S3 bucket (from the storage module)."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the CMK used to encrypt delivered objects and the log group."
  type        = string
}

variable "buffer_size_mb" {
  description = "Firehose S3 buffer size in MiB. Min 64 when Parquet conversion is on."
  type        = number
  default     = 64

  validation {
    condition     = var.buffer_size_mb >= 1 && var.buffer_size_mb <= 128
    error_message = "buffer_size_mb must be between 1 and 128."
  }
}

variable "buffer_interval_seconds" {
  description = "Firehose S3 buffer interval (seconds). Must be >= 60 for dynamic partitioning."
  type        = number
  default     = 60

  validation {
    condition     = var.buffer_interval_seconds >= 60 && var.buffer_interval_seconds <= 900
    error_message = "buffer_interval_seconds must be between 60 and 900 (>= 60 required for dynamic partitioning)."
  }
}

variable "enable_parquet_conversion" {
  description = "Enable Glue-schema-backed Parquet conversion on ingest. Requires glue_database_name/glue_table_name."
  type        = bool
  default     = false
}

variable "glue_database_name" {
  description = "Glue database holding the raw-events table schema (used only when Parquet conversion is enabled)."
  type        = string
  default     = ""
}

variable "glue_table_name" {
  description = "Glue table describing the raw-events schema (used only when Parquet conversion is enabled)."
  type        = string
  default     = ""
}

variable "permissions_boundary_arn" {
  description = "Optional IAM permissions boundary applied to the Firehose role."
  type        = string
  default     = null
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
