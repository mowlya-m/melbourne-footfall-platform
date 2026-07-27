variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "alert_email" {
  description = "Address that receives operational alerts."
  type        = string
}

variable "producer_function_name" {
  type = string
}

variable "kinesis_stream_name" {
  type = string
}

variable "firehose_name" {
  type = string
}

variable "glue_job_name" {
  type = string
}
