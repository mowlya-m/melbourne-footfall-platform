variable "project_name" {
  description = "Prefix applied to every resource name."
  type        = string
  default     = "melbourne-footfall"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "Region for all resources in this environment."
  type        = string
  default     = "ap-southeast-2"
}

variable "alert_email" {
  description = "Address that receives operational alerts."
  type        = string
  default     = "mowlyamanjunath@gmail.com"
}