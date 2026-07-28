variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "glue_job_name" {
  description = "Bronze to Silver Glue job the state machine runs."
  type        = string
}

variable "ops_topic_arn" {
  description = "SNS topic for success and failure notifications."
  type        = string
}

variable "schedule_expression" {
  description = "How often the batch refresh runs."
  type        = string
  default     = "rate(1 hour)"
}
