variable "project" {
  description = "Name prefix for catalog resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
}

variable "raw_bucket_id" {
  description = "Raw landing-zone bucket id (from the storage module)."
  type        = string
}

variable "raw_bucket_arn" {
  description = "Raw landing-zone bucket ARN."
  type        = string
}

variable "staging_bucket_id" {
  description = "Staging bucket id. Holds the ETL script asset and quarantined records."
  type        = string
}

variable "staging_bucket_arn" {
  description = "Staging bucket ARN."
  type        = string
}

variable "curated_bucket_id" {
  description = "Curated bucket id. Receives the analytics-ready Parquet output."
  type        = string
}

variable "curated_bucket_arn" {
  description = "Curated bucket ARN."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the lake CMK used to encrypt catalog output, bookmarks, and logs."
  type        = string
}

variable "crawler_schedule" {
  description = "Cron expression (UTC) controlling how often the crawlers run."
  type        = string
  default     = "cron(0 1 * * ? *)"

  validation {
    condition     = can(regex("^cron\\(.+\\)$", var.crawler_schedule))
    error_message = "crawler_schedule must be a Glue cron() expression, e.g. cron(0 1 * * ? *)."
  }
}

variable "enable_job_schedule" {
  description = "Create a scheduled trigger that runs the raw->curated job on job_schedule."
  type        = bool
  default     = true
}

variable "job_schedule" {
  description = "Cron expression (UTC) for the scheduled ETL job trigger. Runs after the raw crawler."
  type        = string
  default     = "cron(0 2 * * ? *)"

  validation {
    condition     = can(regex("^cron\\(.+\\)$", var.job_schedule))
    error_message = "job_schedule must be a Glue cron() expression, e.g. cron(0 2 * * ? *)."
  }
}

variable "glue_version" {
  description = "Glue runtime version for the ETL job."
  type        = string
  default     = "4.0"
}

variable "worker_type" {
  description = "Glue worker type for the ETL job (Standard, G.1X, G.2X, G.4X, G.8X)."
  type        = string
  default     = "G.1X"

  validation {
    condition     = contains(["Standard", "G.1X", "G.2X", "G.4X", "G.8X"], var.worker_type)
    error_message = "worker_type must be one of: Standard, G.1X, G.2X, G.4X, G.8X."
  }
}

variable "number_of_workers" {
  description = "Number of Glue workers allocated to the ETL job."
  type        = number
  default     = 2

  validation {
    condition     = var.number_of_workers >= 2 && var.number_of_workers <= 100
    error_message = "number_of_workers must be between 2 and 100."
  }
}

variable "max_concurrent_runs" {
  description = "Maximum concurrent executions of the ETL job."
  type        = number
  default     = 1
}

variable "job_timeout_minutes" {
  description = "Timeout (minutes) after which a running ETL job is stopped."
  type        = number
  default     = 60
}

variable "job_max_retries" {
  description = "Number of times Glue retries the ETL job on failure."
  type        = number
  default     = 0
}

variable "permissions_boundary_arn" {
  description = "Optional IAM permissions boundary applied to the crawler and job roles."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
