variable "project_name" {
  description = "Prefix applied to every resource name."
  type        = string
}

variable "environment" {
  description = "Deployment environment: dev or prod."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "account_id" {
  description = "AWS account ID, appended to bucket names for global uniqueness."
  type        = string
}

variable "bronze_ia_transition_days" {
  description = "Days before Bronze objects move to STANDARD_IA."
  type        = number
  default     = 90
}

variable "silver_ia_transition_days" {
  description = "Days before Silver objects move to STANDARD_IA."
  type        = number
  default     = 180
}

variable "athena_results_retention_days" {
  description = "Days before Athena query results are deleted. Results are reproducible."
  type        = number
  default     = 7
}

variable "athena_scan_limit_bytes" {
  description = "Per-query data scan ceiling. Athena cancels queries that exceed it, capping the cost of a runaway full-table scan."
  type        = number
  default     = 1073741824 # 1 GiB
}

variable "bronze_projection_start_date" {
  description = "Lower bound for Athena partition projection on the Bronze table. Should be on or before the first Firehose delivery; earlier is harmless but enumerates more empty partitions."
  type        = string
  default     = "2026-07-24"

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}$", var.bronze_projection_start_date))
    error_message = "Must be YYYY-MM-DD."
  }
}
