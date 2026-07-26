variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "data_bucket_name" {
  type = string
}

variable "data_bucket_arn" {
  type = string
}

variable "scripts_bucket" {
  description = "Bucket holding the Glue job script. Reuses the tfstate bucket to avoid creating another."
  type        = string
}

variable "glue_database_name" {
  type = string
}

variable "number_of_workers" {
  description = "Glue workers. Two is the floor; the dataset does not need more."
  type        = number
  default     = 2
}

variable "timeout_minutes" {
  type    = number
  default = 20
}

variable "silver_projection_start_date" {
  type    = string
  default = "2026-07-24"
}
