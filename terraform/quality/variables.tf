variable "project" {
  description = "Name prefix for data-quality resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
}

variable "curated_database_name" {
  description = "Glue database holding the curated events table (used for metric dimensions and labelling)."
  type        = string
}

variable "curated_table_name" {
  description = "Curated events table name verified by the quality job."
  type        = string
}

variable "curated_bucket_id" {
  description = "Curated bucket id. The quality job reads Parquet from this bucket."
  type        = string
}

variable "curated_bucket_arn" {
  description = "Curated bucket ARN (for the job's read policy)."
  type        = string
}

variable "staging_bucket_id" {
  description = "Staging bucket id. Holds the quality script asset, temp dir, and persisted verification results."
  type        = string
}

variable "staging_bucket_arn" {
  description = "Staging bucket ARN (for the job's read/write policy)."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the lake CMK used to encrypt curated reads, results, and Glue job output."
  type        = string
}

variable "security_configuration_name" {
  description = "Glue security configuration encrypting job output, bookmarks, and logs with the lake CMK."
  type        = string
}

variable "events_prefix" {
  description = "Key prefix under which curated events Parquet is written (matches the catalog/ingest layout)."
  type        = string
  default     = "events"
}

# --------------------------- Glue runtime ---------------------------------
variable "glue_version" {
  description = "Glue runtime version for the quality job. Deequ jar must match the bundled Spark version (Glue 4.0 = Spark 3.3)."
  type        = string
  default     = "4.0"
}

variable "worker_type" {
  description = "Glue worker type (Standard, G.1X, G.2X, G.4X, G.8X)."
  type        = string
  default     = "G.1X"

  validation {
    condition     = contains(["Standard", "G.1X", "G.2X", "G.4X", "G.8X"], var.worker_type)
    error_message = "worker_type must be one of: Standard, G.1X, G.2X, G.4X, G.8X."
  }
}

variable "number_of_workers" {
  description = "Number of Glue workers for the quality job."
  type        = number
  default     = 2

  validation {
    condition     = var.number_of_workers >= 2 && var.number_of_workers <= 100
    error_message = "number_of_workers must be between 2 and 100."
  }
}

variable "max_concurrent_runs" {
  description = "Maximum concurrent executions of the quality job."
  type        = number
  default     = 1
}

variable "job_timeout_minutes" {
  description = "Timeout (minutes) after which a running quality job is stopped."
  type        = number
  default     = 60
}

variable "job_max_retries" {
  description = "Number of times Glue retries the quality job on failure."
  type        = number
  default     = 0
}

variable "permissions_boundary_arn" {
  description = "Optional IAM permissions boundary applied to the quality job role."
  type        = string
  default     = null
}

variable "additional_python_modules" {
  description = "Comma-separated pip specifiers Glue installs before the job runs (PyDeequ wrapper)."
  type        = string
  default     = "pydeequ==1.2.0"
}

variable "deequ_jar_s3_uri" {
  description = "S3 URI of the Deequ Scala assembly jar matching the Glue Spark version. Added to the job classpath as --extra-jars. The job still plans without it, but PyDeequ requires it at runtime."
  type        = string
  default     = null

  validation {
    condition     = var.deequ_jar_s3_uri == null || can(regex("^s3://", var.deequ_jar_s3_uri))
    error_message = "deequ_jar_s3_uri must be an s3:// URI or null."
  }
}

# --------------------------- Schedule -------------------------------------
variable "enable_job_schedule" {
  description = "Create a scheduled trigger that runs the quality job on job_schedule."
  type        = bool
  default     = true
}

variable "job_schedule" {
  description = "Cron expression (UTC) for the scheduled quality job. Default runs after the daily curated ETL (02:00)."
  type        = string
  default     = "cron(0 3 * * ? *)"

  validation {
    condition     = can(regex("^cron\\(.+\\)$", var.job_schedule))
    error_message = "job_schedule must be a Glue cron() expression, e.g. cron(0 3 * * ? *)."
  }
}

# --------------------------- Check thresholds -----------------------------
variable "fail_on_error" {
  description = "Fail the Glue job (non-zero) when any error-level constraint fails, after metrics are emitted. Set false to alarm-only without failing the run."
  type        = bool
  default     = true
}

variable "required_completeness" {
  description = "Minimum completeness (0-1) required for mandatory columns event_id, event_ts, event_type."
  type        = number
  default     = 1.0

  validation {
    condition     = var.required_completeness > 0 && var.required_completeness <= 1
    error_message = "required_completeness must be in (0, 1]."
  }
}

variable "min_user_id_completeness" {
  description = "Minimum completeness (0-1) tolerated for user_id before the check fails (warning-level)."
  type        = number
  default     = 0.9

  validation {
    condition     = var.min_user_id_completeness >= 0 && var.min_user_id_completeness <= 1
    error_message = "min_user_id_completeness must be in [0, 1]."
  }
}

variable "allowed_event_types" {
  description = "Optional closed set of valid event_type values. When non-empty, the job asserts event_type is contained in this set."
  type        = list(string)
  default     = []
}

variable "max_quantity" {
  description = "Optional inclusive upper bound asserted on quantity. Null disables the upper-bound check (non-negativity is always checked)."
  type        = number
  default     = null
}

variable "metric_namespace" {
  description = "CloudWatch namespace for the custom data-quality metrics."
  type        = string
  default     = "Lakehouse/DataQuality"
}

# --------------------------- Alerting -------------------------------------
variable "alarm_email" {
  description = "Optional email address subscribed to the quality alerts SNS topic. No subscription is created when null."
  type        = string
  default     = null
}

variable "alarm_sns_kms_key_id" {
  description = "KMS key id/alias used to encrypt the alerts SNS topic. Defaults to the AWS-managed SNS key, which already permits CloudWatch to publish."
  type        = string
  default     = "alias/aws/sns"
}

variable "enable_staleness_alarm" {
  description = "Create an alarm that fires when no quality result is reported within staleness_period_seconds (detects a job that stopped running)."
  type        = bool
  default     = true
}

variable "staleness_period_seconds" {
  description = "Evaluation period (seconds) for the staleness alarm. Should comfortably exceed the run interval."
  type        = number
  default     = 86400

  validation {
    condition     = var.staleness_period_seconds >= 3600
    error_message = "staleness_period_seconds must be at least 3600 (1 hour)."
  }
}

variable "alarm_treat_missing_data" {
  description = "How constraint alarms treat missing data points."
  type        = string
  default     = "notBreaching"

  validation {
    condition     = contains(["missing", "ignore", "breaching", "notBreaching"], var.alarm_treat_missing_data)
    error_message = "alarm_treat_missing_data must be one of: missing, ignore, breaching, notBreaching."
  }
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
