variable "project" {
  description = "Name prefix for query-layer resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the lake CMK used to encrypt the Athena results bucket and query results."
  type        = string
}

variable "curated_database_name" {
  description = "Glue database holding the curated events table that the named queries target."
  type        = string
}

variable "curated_table_name" {
  description = "Curated events table name queried by the saved analytics queries."
  type        = string
}

variable "access_logs_bucket_id" {
  description = "Optional server-access-log bucket id for the Athena results bucket. No logging is configured when null."
  type        = string
  default     = null
}

variable "results_prefix" {
  description = "Key prefix under which Athena writes query results in the results bucket."
  type        = string
  default     = "results"
}

variable "result_retention_days" {
  description = "Days after which Athena query results expire from the results bucket."
  type        = number
  default     = 30

  validation {
    condition     = var.result_retention_days >= 1
    error_message = "result_retention_days must be at least 1."
  }
}

variable "force_destroy" {
  description = "Allow Terraform to delete the non-empty results bucket and workgroup. Keep false outside dev/test."
  type        = bool
  default     = false
}

variable "athena_engine_version" {
  description = "Athena engine version for the workgroup."
  type        = string
  default     = "AUTO"

  validation {
    condition     = contains(["AUTO", "Athena engine version 2", "Athena engine version 3"], var.athena_engine_version)
    error_message = "athena_engine_version must be AUTO, 'Athena engine version 2', or 'Athena engine version 3'."
  }
}

variable "bytes_scanned_cutoff_bytes" {
  description = "Per-query data-scanned cap (bytes) enforced by the workgroup. Null disables the cap; the minimum AWS allows is 10 MB."
  type        = number
  default     = null

  validation {
    condition     = var.bytes_scanned_cutoff_bytes == null || try(var.bytes_scanned_cutoff_bytes >= 10485760, false)
    error_message = "bytes_scanned_cutoff_bytes must be null or at least 10485760 (10 MB)."
  }
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
