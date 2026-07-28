###############################################################################
# Dev environment
#
# Composes the reusable modules. Deployed by CI through the OIDC role created
# in bootstrap; nothing here is applied from a workstation.
###############################################################################

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }

  backend "s3" {
    bucket         = "melbourne-footfall-tfstate-782208973566"
    key            = "envs/dev/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "melbourne-footfall-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

module "storage" {
  source = "../../modules/storage"

  project_name = var.project_name
  environment  = var.environment
  account_id   = data.aws_caller_identity.current.account_id

  # Dev tiers aggressively: this data is small and re-fetchable from the
  # upstream API, so there is no reason to hold it in Standard for long.
  bronze_ia_transition_days     = 30
  silver_ia_transition_days     = 60
  athena_results_retention_days = 3
}

module "streaming" {
  source = "../../modules/streaming"

  project_name    = var.project_name
  environment     = var.environment
  data_bucket_arn = module.storage.data_bucket_arn

  shard_count             = 1
  buffer_interval_seconds = 60
  buffer_size_mb          = 5
}

module "ingestion" {
  source = "../../modules/ingestion"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region

  kinesis_stream_name = module.streaming.stream_name
  kinesis_stream_arn  = module.streaming.stream_arn

  schedule_expression = "rate(5 minutes)"
  max_records_per_run = 500
}

module "processing" {
  source = "../../modules/processing"

  project_name       = var.project_name
  environment        = var.environment
  data_bucket_name   = module.storage.data_bucket_name
  data_bucket_arn    = module.storage.data_bucket_arn
  scripts_bucket     = "melbourne-footfall-tfstate-782208973566"
  glue_database_name = module.storage.glue_database_name
}

module "observability" {
  source = "../../modules/observability"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  alert_email  = var.alert_email

  producer_function_name = module.ingestion.function_name
  kinesis_stream_name    = module.streaming.stream_name
  firehose_name          = module.streaming.firehose_name
  glue_job_name          = module.processing.glue_job_name
}

module "orchestration" {
  source = "../../modules/orchestration"

  project_name  = var.project_name
  environment   = var.environment
  glue_job_name = module.processing.glue_job_name
  ops_topic_arn = module.observability.ops_topic_arn

  schedule_expression = "rate(1 hour)"
}