variable "project_name" {
  description = "Prefix applied to every resource name."
  type        = string
  default     = "melbourne-footfall"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens only."
  }
}

variable "aws_region" {
  description = "Region for all resources except the billing alarm, which must live in us-east-1."
  type        = string
  default     = "ap-southeast-2"
}

variable "alert_email" {
  description = "Address that receives billing and pipeline alerts. Requires confirming the SNS subscription email."
  type        = string
}

variable "billing_alarm_threshold_usd" {
  description = "Estimated monthly charge in USD that triggers an alert."
  type        = number
  default     = 10

  validation {
    condition     = var.billing_alarm_threshold_usd > 0
    error_message = "Threshold must be greater than zero."
  }
}

variable "github_owner" {
  description = "GitHub account that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "Repository name. The OIDC trust policy is scoped to this repo only."
  type        = string
}
