###############################################################################
# Orchestration module
#
# A Step Functions state machine that runs the batch path end to end: it starts
# the Silver Glue job, waits for it to finish, and on success triggers the Gold
# rebuild. On any failure it publishes to the ops SNS topic. An EventBridge
# schedule runs it hourly.
#
# Why Step Functions rather than a single Lambda calling each step: the Glue job
# runs for minutes, longer than a Lambda should block on. Step Functions waits
# natively with .sync integration, handles retries declaratively, and gives a
# visual execution history that makes a failed run obvious at a glance.
###############################################################################

###############################################################################
# Gold rebuild Lambda
#
# dbt needs a Python runtime. Rather than run dbt inside the state machine
# directly, a small Lambda shells out to it. The dbt project is packaged with
# the function. This keeps Gold rebuildable from orchestration, not only from CI.
#
# NOTE: dbt-athena plus the project is sizeable, so this Lambda uses a container
# image in a production setup. For this project it is scaffolded but the actual
# dbt invocation is left to CI, which already runs `dbt build` on every deploy.
# The state machine below therefore treats Gold as CI-owned and focuses on
# orchestrating the Silver refresh and its alerting, which is the part that
# genuinely needs waiting and retries.
###############################################################################

data "aws_iam_policy_document" "sfn_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "state_machine" {
  name               = "${var.project_name}-orchestrator-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

data "aws_iam_policy_document" "state_machine" {
  # Start and monitor the Glue job. The .sync integration polls Glue, so the
  # state machine needs GetJobRun in addition to StartJobRun.
  statement {
    effect = "Allow"
    actions = [
      "glue:StartJobRun",
      "glue:GetJobRun",
      "glue:GetJobRuns",
      "glue:BatchStopJobRun",
    ]
    resources = ["*"]
  }

  # Publish success and failure notifications.
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [var.ops_topic_arn]
  }

  # Step Functions .sync integrations require these EventBridge-managed-rule
  # permissions to receive completion callbacks from Glue.
  statement {
    effect = "Allow"
    actions = [
      "events:PutTargets",
      "events:PutRule",
      "events:DescribeRule",
    ]
    resources = ["arn:aws:events:*:*:rule/StepFunctionsGetEventsForGlueJobRule"]
  }

  # Step Functions logging requires these on "*". AWS manages the log-delivery
  # resources itself, so the actions cannot be scoped to a specific log group.
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "state_machine" {
  name   = "${var.project_name}-orchestrator-policy-${var.environment}"
  role   = aws_iam_role.state_machine.id
  policy = data.aws_iam_policy_document.state_machine.json
}

###############################################################################
# State machine definition
###############################################################################

locals {
  definition = jsonencode({
    Comment = "Hourly batch refresh: run Silver, alert on outcome."
    StartAt = "RunSilverJob"
    States = {
      RunSilverJob = {
        Type     = "Task"
        Resource = "arn:aws:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = var.glue_job_name
        }
        # Retry transient Glue capacity errors, but not application failures:
        # a job that fails because the code is wrong will fail identically on
        # retry, so retrying only wastes time. Concurrent-run and resource
        # errors are the retryable class.
        Retry = [
          {
            ErrorEquals = [
              "Glue.ConcurrentRunsExceededException",
              "Glue.ResourceNumberLimitExceededException",
            ]
            IntervalSeconds = 60
            MaxAttempts     = 3
            BackoffRate     = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "NotifyFailure"
            ResultPath  = "$.error"
          }
        ]
        Next = "NotifySuccess"
      }

      NotifySuccess = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = var.ops_topic_arn
          Subject  = "Pipeline refresh succeeded"
          Message  = "The hourly Silver refresh completed. Gold is rebuilt by CI on deploy."
        }
        End = true
      }

      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = var.ops_topic_arn
          Subject     = "Pipeline refresh FAILED"
          "Message.$" = "States.Format('The hourly Silver refresh failed. See runbook: glue-failure. Error: {}', $.error.Cause)"
        }
        # After notifying, fail the execution so it shows red in the console
        # and the execution-level alarm can catch it.
        Next = "FailState"
      }

      FailState = {
        Type  = "Fail"
        Error = "SilverRefreshFailed"
        Cause = "The Silver Glue job did not complete successfully."
      }
    }
  })
}

resource "aws_cloudwatch_log_group" "state_machine" {
  name              = "/aws/states/${var.project_name}-orchestrator-${var.environment}"
  retention_in_days = 14
}

resource "aws_sfn_state_machine" "orchestrator" {
  name     = "${var.project_name}-orchestrator-${var.environment}"
  role_arn = aws_iam_role.state_machine.arn

  definition = local.definition

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.state_machine.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }
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
  name               = "${var.project_name}-orch-scheduler-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${var.project_name}-orch-scheduler-policy-${var.environment}"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.orchestrator.arn
    }]
  })
}

resource "aws_scheduler_schedule" "orchestrator" {
  name       = "${var.project_name}-orchestrator-${var.environment}"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  # Hourly. The Silver job is idempotent (partition overwrite), so a run that
  # overlaps new Bronze data simply reprocesses; there is no harm in running it
  # on a fixed cadence rather than triggering on Bronze arrival.
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = "Australia/Melbourne"

  target {
    arn      = aws_sfn_state_machine.orchestrator.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

###############################################################################
# Execution failure alarm
###############################################################################

resource "aws_cloudwatch_metric_alarm" "execution_failed" {
  alarm_name          = "${var.project_name}-orchestrator-failed-${var.environment}"
  alarm_description   = "The batch orchestrator had a failed execution. See runbook: glue-failure."
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.orchestrator.arn
  }

  alarm_actions = [var.ops_topic_arn]
}
