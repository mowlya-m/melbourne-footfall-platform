output "function_name" {
  description = "Producer Lambda name, for manual invocation and alarms."
  value       = aws_lambda_function.producer.function_name
}

output "function_arn" {
  description = "Producer Lambda ARN."
  value       = aws_lambda_function.producer.arn
}

output "watermark_table_name" {
  description = "DynamoDB table holding the producer high-water mark."
  value       = aws_dynamodb_table.watermark.name
}

output "schedule_name" {
  description = "EventBridge schedule driving the producer."
  value       = aws_scheduler_schedule.producer.name
}

output "log_group_name" {
  description = "CloudWatch log group for the producer."
  value       = aws_cloudwatch_log_group.producer.name
}
