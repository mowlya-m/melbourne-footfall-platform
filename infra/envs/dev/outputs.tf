output "data_bucket_name" {
  description = "Data lake bucket holding the medallion prefixes."
  value       = module.storage.data_bucket_name
}

output "bronze_prefix" {
  description = "Where the Firehose delivery stream writes from PR #7."
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
