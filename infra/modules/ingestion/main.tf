###############################################################################
# Ingestion module
#
# The poll-to-stream adapter: a scheduled Lambda that reads the City of
# Melbourne API, discards anything already published, and emits new readings to
# Kinesis. State lives in a DynamoDB watermark so the schedule can be changed
# without producing duplicates or gaps.
###############################################################################

###############################################################################
# Watermark
###############################################################################

resource "aws_dynamodb_table" "watermark" {
  name         = "${var.project_name}-watermark-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  # The watermark is the only thing preventing duplicate emission. Losing it
  # means reprocessing an hour of data, which is survivable but noisy.
  point_in_time_recovery {
    enabled = var.environment == "prod"
  }
}

###############################################################################
# Lambda
###############################################################################

data "archive_file" "producer" {
  type        = "zip"
  source_dir  = "${path.root}/../../../src"
  output_path = "${path.module}/.build/producer.zip"

  excludes = [
    "**/__pycache__/**",
    "**/*.pyc",
    "**/requirements.txt",
  ]
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "producer" {
  name               = "${var.project_name}-producer-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Scoped to the exact stream and table this function needs. Broad wildcards here
# would be the easiest thing to write and the hardest thing to justify.
data "aws_iam_policy_document" "producer" {
  statement {
    effect    = "Allow"
    actions   = ["kinesis:PutRecord", "kinesis:PutRecords"]
    resources = [var.kinesis_stream_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.watermark.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["kinesis.${var.aws_region}.amazonaws.com"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "producer" {
  name   = "${var.project_name}-producer-policy-${var.environment}"
  role   = aws_iam_role.producer.id
  policy = data.aws_iam_policy_document.producer.json
}

resource "aws_cloudwatch_log_group" "producer" {
  name              = "/aws/lambda/${var.project_name}-producer-${var.environment}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "producer" {
  function_name = "${var.project_name}-producer-${var.environment}"
  description   = "Polls the CoM pedestrian API and emits new readings to Kinesis."

  filename         = data.archive_file.producer.output_path
  source_code_hash = data.archive_file.producer.output_base64sha256

  role    = aws_iam_role.producer.arn
  handler = "producer.handler.handler"
  runtime = "python3.12"

  # The function is network-bound, not CPU-bound. More memory buys proportionally
  # more CPU and network throughput, and 512 MB is the point where the run
  # finishes fast enough that the extra memory costs nothing net.
  memory_size = var.memory_mb
  timeout     = var.timeout_seconds

  environment {
    variables = {
      KINESIS_STREAM_NAME  = var.kinesis_stream_name
      WATERMARK_TABLE_NAME = aws_dynamodb_table.watermark.name
      MAX_RECORDS_PER_RUN  = tostring(var.max_records_per_run)
      LOG_LEVEL            = var.log_level
    }
  }

  depends_on = [
    aws_iam_role_policy.producer,
    aws_cloudwatch_log_group.producer,
  ]
}

###############################################################################
# Schedule
###############################################################################

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.project_name}-scheduler-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${var.project_name}-scheduler-policy-${var.environment}"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.producer.arn
    }]
  })
}

resource "aws_scheduler_schedule" "producer" {
  name       = "${var.project_name}-producer-${var.environment}"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  # The upstream API refreshes roughly every fifteen minutes. Polling more often
  # than that costs invocations without producing new data; polling less often
  # risks the rolling window advancing past unread records.
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = "Australia/Melbourne"

  target {
    arn      = aws_lambda_function.producer.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 300
    }
  }
}
