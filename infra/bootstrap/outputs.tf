output "tfstate_bucket" {
  description = "S3 bucket holding Terraform state for all non-bootstrap configurations."
  value       = aws_s3_bucket.tfstate.id
}

output "tflock_table" {
  description = "DynamoDB table used for Terraform state locking."
  value       = aws_dynamodb_table.tflock.name
}

output "github_actions_role_arn" {
  description = "Role ARN for the GitHub Actions OIDC trust. Add this as the AWS_ROLE_ARN repository variable."
  value       = aws_iam_role.github_actions.arn
}

output "alerts_topic_arn" {
  description = "SNS topic receiving billing alarms."
  value       = aws_sns_topic.alerts.arn
}

output "backend_config" {
  description = "Paste this into the backend block of infra/envs/*/ configurations."
  value       = <<-EOT
    backend "s3" {
      bucket         = "${aws_s3_bucket.tfstate.id}"
      key            = "envs/dev/terraform.tfstate"
      region         = "${var.aws_region}"
      dynamodb_table = "${aws_dynamodb_table.tflock.name}"
      encrypt        = true
    }
  EOT
}
