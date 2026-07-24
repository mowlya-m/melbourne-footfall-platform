output "data_bucket_name" {
  description = "Bucket holding the bronze, silver and gold prefixes."
  value       = aws_s3_bucket.data.id
}

output "data_bucket_arn" {
  description = "ARN of the data lake bucket, for IAM policies in later modules."
  value       = aws_s3_bucket.data.arn
}

output "athena_results_bucket_name" {
  description = "Bucket holding Athena query output."
  value       = aws_s3_bucket.athena_results.id
}

output "glue_database_name" {
  description = "Glue Data Catalog database backing Athena."
  value       = aws_glue_catalog_database.main.name
}

output "athena_workgroup_name" {
  description = "Athena workgroup with the scan limit enforced."
  value       = aws_athena_workgroup.main.name
}

output "bronze_prefix" {
  description = "Full S3 URI of the Bronze layer."
  value       = "s3://${aws_s3_bucket.data.id}/bronze/"
}

output "silver_prefix" {
  description = "Full S3 URI of the Silver layer."
  value       = "s3://${aws_s3_bucket.data.id}/silver/"
}

output "gold_prefix" {
  description = "Full S3 URI of the Gold layer."
  value       = "s3://${aws_s3_bucket.data.id}/gold/"
}

output "bronze_table_name" {
  description = "Glue catalog table over the Bronze layer, queryable from Athena."
  value       = aws_glue_catalog_table.bronze_pedestrian.name
}
