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
