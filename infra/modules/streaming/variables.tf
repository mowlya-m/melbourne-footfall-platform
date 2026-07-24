variable "project_name" {
  description = "Prefix applied to every resource name."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "data_bucket_arn" {
  description = "ARN of the data lake bucket Firehose writes Bronze into."
  type        = string
}

variable "shard_count" {
  description = "Kinesis shards. One shard handles 1000 records/sec, well above the expected peak of roughly 100."
  type        = number
  default     = 1
}

variable "buffer_interval_seconds" {
  description = "Firehose flush interval. Lower means fresher data and more, smaller objects."
  type        = number
  default     = 60

  validation {
    condition     = var.buffer_interval_seconds >= 60 && var.buffer_interval_seconds <= 900
    error_message = "Firehose accepts between 60 and 900 seconds."
  }
}

variable "buffer_size_mb" {
  description = "Firehose flush size. Caps small-file proliferation during busy periods."
  type        = number
  default     = 5
}
