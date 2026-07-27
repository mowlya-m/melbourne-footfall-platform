output "ops_topic_arn" {
  description = "SNS topic carrying operational alerts."
  value       = aws_sns_topic.ops_alerts.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard summarising pipeline health."
  value       = aws_cloudwatch_dashboard.pipeline.dashboard_name
}
