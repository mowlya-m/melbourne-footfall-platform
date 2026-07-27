###############################################################################
# Observability module
#
# CloudWatch alarms wired to the existing SNS alerts topic from bootstrap. The
# goal is that a broken pipeline pages a human before anyone downstream notices
# stale or missing data. Each alarm has a matching entry in docs/runbook.md.
###############################################################################

# The alerts topic already exists in us-east-1 from bootstrap. Alarms on
# regional metrics must live in the same region as the metric, so operational
# alarms here publish to a regional topic. A cross-region SNS subscription is
# not possible, so this module creates its own topic in the working region and
# subscribes the same email.
resource "aws_sns_topic" "ops_alerts" {
  name = "${var.project_name}-ops-alerts-${var.environment}"
}

resource "aws_sns_topic_subscription" "ops_email" {
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

###############################################################################
# Producer Lambda failure
#
# Any invocation error means new data has stopped flowing. The producer runs
# every five minutes, so a single failed run is worth knowing about; two in a
# row is a real outage.
###############################################################################

resource "aws_cloudwatch_metric_alarm" "producer_errors" {
  alarm_name          = "${var.project_name}-producer-errors-${var.environment}"
  alarm_description   = "Producer Lambda reported one or more errors. New readings may have stopped. See runbook: producer-errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.producer_function_name
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]
}

###############################################################################
# Producer not invoking
#
# A subtler failure than errors: if the schedule silently stops firing, there
# are no errors because there are no runs. Alarm if invocations drop to zero
# over a window that should contain several.
###############################################################################

resource "aws_cloudwatch_metric_alarm" "producer_not_running" {
  alarm_name          = "${var.project_name}-producer-silent-${var.environment}"
  alarm_description   = "Producer has not been invoked recently. The schedule may have stopped. See runbook: producer-silent."
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  # Missing data is exactly the failure here, so treat it as breaching.
  treat_missing_data = "breaching"

  dimensions = {
    FunctionName = var.producer_function_name
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]
}

###############################################################################
# Kinesis write throttling
#
# If the producer emits faster than the single shard accepts, records are
# throttled and, without handling, lost. A sustained nonzero value means the
# shard count needs revisiting.
###############################################################################

resource "aws_cloudwatch_metric_alarm" "kinesis_write_throttle" {
  alarm_name          = "${var.project_name}-kinesis-throttle-${var.environment}"
  alarm_description   = "Kinesis is throttling writes. The shard may be undersized for current volume. See runbook: kinesis-throttle."
  namespace           = "AWS/Kinesis"
  metric_name         = "WriteProvisionedThroughputExceeded"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    StreamName = var.kinesis_stream_name
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
}

###############################################################################
# Firehose delivery failure
#
# If Firehose cannot write to S3, records back up and eventually expire from the
# stream. Any delivery failure is worth an alert.
###############################################################################

resource "aws_cloudwatch_metric_alarm" "firehose_delivery_failure" {
  alarm_name         = "${var.project_name}-firehose-delivery-${var.environment}"
  alarm_description  = "Firehose failed to deliver records to S3 Bronze. See runbook: firehose-delivery."
  namespace          = "AWS/Firehose"
  metric_name        = "DeliveryToS3.DataFreshness"
  statistic          = "Maximum"
  period             = 300
  evaluation_periods = 2
  # Freshness is the age of the oldest undelivered record, in seconds. Buffer is
  # 60s, so anything sustained above 15 minutes means delivery is stuck.
  threshold           = 900
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DeliveryStreamName = var.firehose_name
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
}

###############################################################################
# Glue job failure
#
# The Silver transformation. A failed run means Silver and everything built on
# it are stale.
###############################################################################

resource "aws_cloudwatch_metric_alarm" "glue_job_failure" {
  alarm_name          = "${var.project_name}-glue-silver-failure-${var.environment}"
  alarm_description   = "The Bronze to Silver Glue job failed. Silver and Gold are now stale. See runbook: glue-failure."
  namespace           = "Glue"
  metric_name         = "glue.driver.aggregate.numFailedTasks"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    JobName = var.glue_job_name
    Type    = "count"
  }

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
}

###############################################################################
# Dashboard
#
# A single operational view of the pipeline, so a human can see health at a
# glance rather than hunting through six alarm pages.
###############################################################################

resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = "${var.project_name}-pipeline-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Producer invocations and errors"
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.producer_function_name, { stat = "Sum" }],
            ["AWS/Lambda", "Errors", "FunctionName", var.producer_function_name, { stat = "Sum" }],
          ]
          period = 300
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Kinesis incoming records"
          region = var.aws_region
          metrics = [
            ["AWS/Kinesis", "IncomingRecords", "StreamName", var.kinesis_stream_name, { stat = "Sum" }],
          ]
          period = 300
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Firehose delivery freshness (seconds)"
          region = var.aws_region
          metrics = [
            ["AWS/Firehose", "DeliveryToS3.DataFreshness", "DeliveryStreamName", var.firehose_name, { stat = "Maximum" }],
          ]
          period = 300
        }
      },
    ]
  })
}
