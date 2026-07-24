variable "project_name" {
  description = "Prefix applied to every resource name."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "aws_region" {
  description = "Region, used to scope the KMS condition on the producer policy."
  type        = string
}

variable "kinesis_stream_name" {
  description = "Stream the producer publishes to."
  type        = string
}

variable "kinesis_stream_arn" {
  description = "Stream ARN, so the producer policy grants access to that stream only."
  type        = string
}

variable "schedule_expression" {
  description = "How often to poll. The upstream API refreshes roughly every fifteen minutes."
  type        = string
  default     = "rate(5 minutes)"
}

variable "max_records_per_run" {
  description = "Upper bound on records fetched per invocation, so a slow run cannot overrun the timeout."
  type        = number
  default     = 500
}

variable "memory_mb" {
  description = "Lambda memory. The function is network-bound, so this mostly buys CPU and network throughput."
  type        = number
  default     = 512
}

variable "timeout_seconds" {
  description = "Lambda timeout. Generous enough to absorb retries against a slow upstream."
  type        = number
  default     = 120
}

variable "log_retention_days" {
  description = "CloudWatch log retention. Logs are for debugging, not archival."
  type        = number
  default     = 14
}

variable "log_level" {
  description = "Python logging level for the producer."
  type        = string
  default     = "INFO"
}
