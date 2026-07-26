###############################################################################
# Processing module
#
# The Glue PySpark job that transforms Bronze into Silver, its IAM role, the S3
# upload of the job script, and the Silver catalog table. Deployed by CI; run by
# Step Functions from a later PR, or on demand during verification.
###############################################################################

###############################################################################
# Job script upload
#
# The script lives in the repo and is uploaded to S3 on every apply, keyed by a
# hash of its contents so Glue picks up changes automatically.
###############################################################################

resource "aws_s3_object" "job_script" {
  bucket = var.scripts_bucket
  key    = "glue/bronze_to_silver.py"
  source = "${path.root}/../../../src/glue_jobs/bronze_to_silver.py"
  etag   = filemd5("${path.root}/../../../src/glue_jobs/bronze_to_silver.py")
}

###############################################################################
# IAM
###############################################################################

data "aws_iam_policy_document" "glue_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_job" {
  name               = "${var.project_name}-glue-silver-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

# Read Bronze and the script, write Silver and quarantine. Scoped to the data
# bucket rather than granting blanket S3 access.
data "aws_iam_policy_document" "glue_job" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      var.data_bucket_arn,
      "${var.data_bucket_arn}/bronze/*",
      "arn:aws:s3:::${var.scripts_bucket}",
      "arn:aws:s3:::${var.scripts_bucket}/glue/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${var.data_bucket_arn}/silver/*",
      "${var.data_bucket_arn}/quarantine/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:/aws-glue/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["glue:GetTable", "glue:GetDatabase", "glue:GetPartitions"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "glue_job" {
  name   = "${var.project_name}-glue-silver-policy-${var.environment}"
  role   = aws_iam_role.glue_job.id
  policy = data.aws_iam_policy_document.glue_job.json
}

###############################################################################
# Glue job
###############################################################################

resource "aws_glue_job" "bronze_to_silver" {
  name         = "${var.project_name}-bronze-to-silver-${var.environment}"
  description  = "Cleans, deduplicates and types Bronze into Silver."
  role_arn     = aws_iam_role.glue_job.arn
  glue_version = "4.0"

  # Two workers is the practical floor. The dataset is small, so this is about
  # not paying for idle capacity rather than needing throughput.
  worker_type       = "G.1X"
  number_of_workers = var.number_of_workers

  command {
    name            = "glueetl"
    script_location = "s3://${var.scripts_bucket}/${aws_s3_object.job_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--job-bookmark-option"              = "job-bookmark-disable"
    "--bronze_path"                      = "s3://${var.data_bucket_name}/bronze/pedestrian/"
    "--silver_path"                      = "s3://${var.data_bucket_name}/silver/pedestrian/"
    "--quarantine_path"                  = "s3://${var.data_bucket_name}/quarantine/pedestrian/"
    # Glue 4 defaults to ANSI SQL; the job relies on try_to_timestamp to tolerate
    # malformed input rather than aborting. Left explicit as documentation.
    "--conf" = "spark.sql.ansi.enabled=false"
  }

  # A single retry covers transient Glue capacity errors without masking a real
  # code failure behind repeated attempts.
  max_retries = 1
  timeout     = var.timeout_minutes
}

###############################################################################
# Silver catalog table
#
# Same partition-projection approach as Bronze: no crawler. Silver is Parquet,
# partitioned by event_date.
###############################################################################

resource "aws_glue_catalog_table" "silver_pedestrian" {
  name          = "silver_pedestrian"
  database_name = var.glue_database_name
  description   = "Cleaned, deduplicated, typed pedestrian readings."
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL                              = "TRUE"
    "classification"                      = "parquet"
    "projection.enabled"                  = "true"
    "projection.event_date.type"          = "date"
    "projection.event_date.format"        = "yyyy-MM-dd"
    "projection.event_date.range"         = "${var.silver_projection_start_date},NOW"
    "projection.event_date.interval"      = "1"
    "projection.event_date.interval.unit" = "DAYS"
    "storage.location.template"           = "s3://${var.data_bucket_name}/silver/pedestrian/event_date=$${event_date}"
  }

  partition_keys {
    name = "event_date"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${var.data_bucket_name}/silver/pedestrian/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "location_id"
      type = "int"
    }
    columns {
      name = "event_ts_utc"
      type = "timestamp"
    }
    columns {
      name = "event_ts_local"
      type = "timestamp"
    }
    columns {
      name = "event_hour"
      type = "int"
    }
    columns {
      name = "day_of_week"
      type = "int"
    }
    columns {
      name = "is_weekend"
      type = "boolean"
    }
    columns {
      name = "direction_1"
      type = "int"
    }
    columns {
      name = "direction_2"
      type = "int"
    }
    columns {
      name = "total_of_directions"
      type = "int"
    }
    columns {
      name = "dedupe_key"
      type = "string"
    }
    columns {
      name = "ingested_ts_utc"
      type = "timestamp"
    }
  }
}
