variable "project" {
  description = "Name prefix for all storage resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
}

variable "kms_deletion_window_days" {
  description = "Waiting period (days) before scheduled KMS key deletion completes."
  type        = number
  default     = 30
}

variable "force_destroy" {
  description = "Allow deletion of non-empty buckets (keep false outside dev/test)."
  type        = bool
  default     = false
}

variable "raw_lifecycle" {
  description = "Day-based lifecycle schedule for the raw layer."
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

  validation {
    condition = (
      var.raw_lifecycle.transition_ia_days < var.raw_lifecycle.transition_glacier_days &&
      var.raw_lifecycle.transition_glacier_days < var.raw_lifecycle.expiration_days
    )
    error_message = "raw_lifecycle days must satisfy: transition_ia < transition_glacier < expiration."
  }
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
