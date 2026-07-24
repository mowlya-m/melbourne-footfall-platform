output "stream_name" {
  description = "Kinesis stream the producer publishes to."
  value       = aws_kinesis_stream.main.name
}

output "stream_arn" {
  description = "ARN of the Kinesis stream, for the producer's IAM policy."
  value       = aws_kinesis_stream.main.arn
}

output "firehose_name" {
  description = "Delivery stream writing Bronze."
  value       = aws_kinesis_firehose_delivery_stream.bronze.name
}

output "bronze_path" {
  description = "Where Firehose lands raw records."
  value       = "bronze/pedestrian/dt=YYYY-MM-DD/hour=HH/"
}
