variable "project" {
  description = "Name prefix for visualization-layer resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
}

variable "enable_quicksight" {
  description = "Master switch for the QuickSight BI layer. Requires an active QuickSight account subscription in this region."
  type        = bool
  default     = false
}

variable "quicksight_principal_arn" {
  description = "QuickSight user or group ARN that owns and can manage the data source, dataset, and dashboard. No QuickSight resources are created when null."
  type        = string
  default     = null

  validation {
    condition     = var.quicksight_principal_arn == null || can(regex("^arn:[a-z-]+:quicksight:", var.quicksight_principal_arn))
    error_message = "quicksight_principal_arn must be a QuickSight user/group ARN (arn:<partition>:quicksight:...) or null."
  }
}

variable "athena_workgroup_name" {
  description = "Athena workgroup the QuickSight data source queries through (inherits result location, encryption, and cost guardrails)."
  type        = string
}

variable "curated_database_name" {
  description = "Glue database holding the curated events table surfaced in the dashboard."
  type        = string
}

variable "curated_table_name" {
  description = "Curated events table name imported into SPICE."
  type        = string
}

variable "spice_import_mode" {
  description = "Dataset import mode: SPICE for in-memory acceleration, or DIRECT_QUERY to hit Athena live."
  type        = string
  default     = "SPICE"

  validation {
    condition     = contains(["SPICE", "DIRECT_QUERY"], var.spice_import_mode)
    error_message = "spice_import_mode must be SPICE or DIRECT_QUERY."
  }
}

variable "refresh_time_of_day" {
  description = "Local time of day (HH:MM) for the daily SPICE full refresh."
  type        = string
  default     = "05:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.refresh_time_of_day))
    error_message = "refresh_time_of_day must be HH:MM in 24-hour form, e.g. 05:00."
  }
}

variable "refresh_timezone" {
  description = "IANA timezone for the SPICE refresh schedule."
  type        = string
  default     = "Etc/UTC"
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
