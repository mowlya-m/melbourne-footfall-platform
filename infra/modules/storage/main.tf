###############################################################################
# Storage module
#
# The data lake and its catalog. One bucket holds all three medallion layers as
# prefixes rather than three separate buckets: lifecycle rules and permissions
# are expressible per-prefix, and a single bucket keeps cross-layer Glue and
# Athena configuration simpler. Query results get their own bucket because they
# are disposable and should not share a retention policy with the lake.
###############################################################################

locals {
  data_bucket_name    = "${var.project_name}-data-${var.environment}-${var.account_id}"
  results_bucket_name = "${var.project_name}-athena-results-${var.environment}-${var.account_id}"
}

###############################################################################
# Data lake
###############################################################################

resource "aws_s3_bucket" "data" {
  bucket = local.data_bucket_name
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bronze is append-only and rarely re-read after the Silver job runs, so it is
# the cheapest layer to move to infrequent access. Gold is queried constantly by
# the dashboard and stays in Standard.
resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    id     = "bronze-tiering"
    status = "Enabled"

    filter {
      prefix = "bronze/"
    }

    transition {
      days          = var.bronze_ia_transition_days
      storage_class = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "silver-tiering"
    status = "Enabled"

    filter {
      prefix = "silver/"
    }

    transition {
      days          = var.silver_ia_transition_days
      storage_class = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  # Gold has no transition rule on purpose: it is small and read constantly.
  rule {
    id     = "gold-version-cleanup"
    status = "Enabled"

    filter {
      prefix = "gold/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

###############################################################################
# Athena query results
###############################################################################

resource "aws_s3_bucket" "athena_results" {
  bucket = local.results_bucket_name
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Query results are reproducible by re-running the query. Keeping them costs
# money for no benefit.
resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-query-results"
    status = "Enabled"

    filter {}

    expiration {
      days = var.athena_results_retention_days
    }
  }
}

###############################################################################
# Glue Data Catalog
#
# The catalog is the schema layer Athena queries through. Tables are registered
# from PR #7 onward as data starts landing.
###############################################################################

resource "aws_glue_catalog_database" "main" {
  name        = replace("${var.project_name}_${var.environment}", "-", "_")
  description = "Catalog for Melbourne foot traffic medallion layers."

  location_uri = "s3://${aws_s3_bucket.data.id}/"
}

###############################################################################
# Athena workgroup
#
# A dedicated workgroup lets us enforce a per-query data scan limit, which is
# the main defence against an accidental full-table scan running up a bill.
###############################################################################

resource "aws_athena_workgroup" "main" {
  name        = "${var.project_name}-${var.environment}"
  description = "Workgroup with a scan limit and enforced result location."

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_scan_limit_bytes

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/output/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  force_destroy = true
}
