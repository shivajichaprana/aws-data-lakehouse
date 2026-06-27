# ---------------------------------------------------------------------------
# Orchestration module inputs.
#
# The module stitches the already-provisioned Glue crawler, curated ETL job,
# data-quality job, and (optional) QuickSight dataset into a single Step
# Functions state machine and an EventBridge Scheduler trigger. It takes the
# resource *names* of those upstream components and derives their ARNs locally,
# so the caller never has to thread ARNs through.
# ---------------------------------------------------------------------------

variable "project" {
  description = "Project/name prefix applied to all resources (lower-case, hyphenated)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.project))
    error_message = "project must be 2-31 chars, lower-case alphanumeric or hyphen, starting with a letter."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}

# --------------------------- Pipeline step targets ------------------------
variable "raw_crawler_name" {
  description = "Name of the raw-layer Glue crawler started at the head of the pipeline."
  type        = string
}

variable "etl_job_name" {
  description = "Name of the raw->curated PySpark ETL Glue job (run synchronously)."
  type        = string
}

variable "quality_job_name" {
  description = "Name of the PyDeequ data-quality Glue job (run synchronously after the ETL)."
  type        = string
}

# --------------------------- Dashboard refresh (QuickSight) ---------------
variable "enable_dashboard_refresh" {
  description = "Append a QuickSight SPICE refresh step after data quality. Effective only when quicksight_data_set_id is also set."
  type        = bool
  default     = true
}

variable "quicksight_data_set_id" {
  description = "Id of the curated QuickSight SPICE dataset to refresh. Null (QuickSight disabled) drops the refresh step entirely."
  type        = string
  default     = null
}

# --------------------------- Crawler polling ------------------------------
variable "crawler_poll_interval_seconds" {
  description = "Seconds the state machine waits between raw-crawler status checks."
  type        = number
  default     = 30

  validation {
    condition     = var.crawler_poll_interval_seconds >= 5 && var.crawler_poll_interval_seconds <= 300
    error_message = "crawler_poll_interval_seconds must be between 5 and 300."
  }
}

variable "crawler_max_poll_attempts" {
  description = "Maximum number of status polls before the pipeline declares a crawler timeout (budget = interval x attempts)."
  type        = number
  default     = 60

  validation {
    condition     = var.crawler_max_poll_attempts >= 1 && var.crawler_max_poll_attempts <= 1000
    error_message = "crawler_max_poll_attempts must be between 1 and 1000."
  }
}

# --------------------------- Synchronous-run timeouts ---------------------
variable "etl_timeout_seconds" {
  description = "Hard timeout for the synchronous curated ETL job run state."
  type        = number
  default     = 3600

  validation {
    condition     = var.etl_timeout_seconds >= 60
    error_message = "etl_timeout_seconds must be at least 60."
  }
}

variable "quality_timeout_seconds" {
  description = "Hard timeout for the synchronous data-quality job run state."
  type        = number
  default     = 1800

  validation {
    condition     = var.quality_timeout_seconds >= 60
    error_message = "quality_timeout_seconds must be at least 60."
  }
}

variable "pipeline_timeout_seconds" {
  description = "Overall execution timeout for a single pipeline run."
  type        = number
  default     = 10800

  validation {
    condition     = var.pipeline_timeout_seconds >= 300
    error_message = "pipeline_timeout_seconds must be at least 300."
  }
}

# --------------------------- Schedule -------------------------------------
variable "enable_schedule" {
  description = "Create the EventBridge Scheduler trigger that runs the pipeline on a cron."
  type        = bool
  default     = true
}

variable "pipeline_schedule" {
  description = "Schedule expression (cron/rate) controlling pipeline cadence. Default 04:00 UTC daily, after the curated ETL and quality job windows."
  type        = string
  default     = "cron(0 4 * * ? *)"
}

variable "schedule_timezone" {
  description = "IANA timezone the schedule expression is evaluated in."
  type        = string
  default     = "UTC"
}

variable "schedule_flexible_window_minutes" {
  description = "Flexible delivery window (minutes) for the schedule. 0 disables the window (fire at the exact time)."
  type        = number
  default     = 0

  validation {
    condition     = var.schedule_flexible_window_minutes >= 0 && var.schedule_flexible_window_minutes <= 1440
    error_message = "schedule_flexible_window_minutes must be between 0 and 1440."
  }
}

# --------------------------- Failure notifications ------------------------
variable "alarm_email" {
  description = "Optional email subscribed to the pipeline-failure SNS topic."
  type        = string
  default     = null
}

variable "alarm_sns_kms_key_id" {
  description = "KMS key id/alias encrypting the failure SNS topic. Defaults to the AWS-managed SNS key, which already lets Step Functions publish."
  type        = string
  default     = "alias/aws/sns"
}

# --------------------------- Observability --------------------------------
variable "log_retention_days" {
  description = "CloudWatch Logs retention (days) for the state-machine execution log group."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value supported by CloudWatch Logs."
  }
}

variable "sfn_log_level" {
  description = "Step Functions execution log level (ALL, ERROR, FATAL, OFF)."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ALL", "ERROR", "FATAL", "OFF"], var.sfn_log_level)
    error_message = "sfn_log_level must be one of: ALL, ERROR, FATAL, OFF."
  }
}

variable "enable_xray_tracing" {
  description = "Enable AWS X-Ray tracing on the state machine."
  type        = bool
  default     = true
}

# --------------------------- IAM ------------------------------------------
variable "permissions_boundary_arn" {
  description = "Optional IAM permissions boundary applied to the module's roles."
  type        = string
  default     = null
}
