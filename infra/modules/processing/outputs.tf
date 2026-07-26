output "glue_job_name" {
  description = "Bronze to Silver Glue job, for manual runs and Step Functions."
  value       = aws_glue_job.bronze_to_silver.name
}

output "silver_table_name" {
  description = "Glue catalog table over Silver."
  value       = aws_glue_catalog_table.silver_pedestrian.name
}
