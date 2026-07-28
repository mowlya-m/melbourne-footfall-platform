output "data_bucket_name" {
  description = "Data lake bucket holding the medallion prefixes."
  value       = module.storage.data_bucket_name
}

output "bronze_prefix" {
  description = "Where the Firehose delivery stream writes raw records."
  value       = module.storage.bronze_prefix
}

output "glue_database_name" {
  description = "Glue catalog database name for Athena queries."
  value       = module.storage.glue_database_name
}

output "athena_workgroup_name" {
  description = "Athena workgroup enforcing the per-query scan limit."
  value       = module.storage.athena_workgroup_name
}

output "kinesis_stream_name" {
  description = "Stream carrying individual sensor readings."
  value       = module.streaming.stream_name
}

output "firehose_name" {
  description = "Delivery stream landing records in Bronze."
  value       = module.streaming.firehose_name
}

output "producer_function_name" {
  description = "Producer Lambda, for manual invocation during verification."
  value       = module.ingestion.function_name
}

output "watermark_table_name" {
  description = "DynamoDB table holding the producer high-water mark."
  value       = module.ingestion.watermark_table_name
}

output "glue_silver_job_name" {
  description = "Bronze to Silver Glue job."
  value       = module.processing.glue_job_name
}

output "silver_table_name" {
  description = "Glue catalog table over Silver."
  value       = module.processing.silver_table_name
}

output "ops_dashboard" {
  description = "CloudWatch dashboard summarising pipeline health."
  value       = module.observability.dashboard_name
}

output "orchestrator_name" {
  description = "Step Functions state machine running the hourly batch refresh."
  value       = module.orchestration.state_machine_name
}
