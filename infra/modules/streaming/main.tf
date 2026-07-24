###############################################################################
# Streaming module
#
# Kinesis Data Streams as the event backbone, with Firehose fanning out to S3
# Bronze. Firehose handles buffering, compression and partitioned delivery, so
# the pipeline gets durable landing without writing a consumer for it.
###############################################################################

###############################################################################
# Kinesis Data Stream
###############################################################################

resource "aws_kinesis_stream" "main" {
  name = "${var.project_name}-readings-${var.environment}"

  # Provisioned rather than on-demand: peak throughput here is roughly 100
  # records per second against a 1000 record per second shard limit, and
  # on-demand carries a higher monthly floor at this volume.
  stream_mode_details {
    stream_mode = "PROVISIONED"
  }

  shard_count = var.shard_count

  # 24 hours is the free default. Longer retention costs extra and the Bronze
  # layer already provides replay, so paying twice for durability is wasteful.
  retention_period = 24

  encryption_type = "KMS"
  kms_key_id      = "alias/aws/kinesis"

  shard_level_metrics = [
    "IncomingRecords",
    "IncomingBytes",
    "WriteProvisionedThroughputExceeded",
    "ReadProvisionedThroughputExceeded",
    "IteratorAgeMilliseconds",
  ]
}

###############################################################################
# Firehose delivery to Bronze
###############################################################################

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${var.project_name}-firehose-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
}

data "aws_iam_policy_document" "firehose_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [
      var.data_bucket_arn,
      "${var.data_bucket_arn}/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "kinesis:DescribeStream",
      "kinesis:GetShardIterator",
      "kinesis:GetRecords",
      "kinesis:ListShards",
    ]
    resources = [aws_kinesis_stream.main.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["logs:PutLogEvents", "logs:CreateLogStream"]
    resources = ["arn:aws:logs:*:*:log-group:/aws/kinesisfirehose/*"]
  }
}

resource "aws_iam_role_policy" "firehose" {
  name   = "${var.project_name}-firehose-policy-${var.environment}"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose_permissions.json
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${var.project_name}-bronze-${var.environment}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_kinesis_firehose_delivery_stream" "bronze" {
  name        = "${var.project_name}-bronze-${var.environment}"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.main.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = var.data_bucket_arn

    # Hive-style partitioning so Athena and Glue can prune by date and hour
    # without scanning the whole prefix.
    prefix              = "bronze/pedestrian/dt=!{timestamp:yyyy-MM-dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "bronze/_errors/pedestrian/dt=!{timestamp:yyyy-MM-dd}/!{firehose:error-output-type}/"

    # Firehose flushes on whichever limit is hit first. Sixty seconds keeps
    # end-to-end latency low; the size limit stops a busy period producing
    # thousands of tiny objects, which is the classic small-file problem.
    buffering_interval = var.buffer_interval_seconds
    buffering_size     = var.buffer_size_mb

    compression_format = "GZIP"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }
  }

  depends_on = [aws_iam_role_policy.firehose]
}
