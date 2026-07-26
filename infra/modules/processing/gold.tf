###############################################################################
# Gold layer catalog registration
#
# dbt-athena creates the Gold tables when it runs, and registers them in the
# Glue catalog itself via CREATE TABLE AS. So unlike Bronze and Silver, Gold
# needs no aws_glue_catalog_table resource here: dbt owns that schema.
#
# What Terraform provides is the S3 location dbt writes to, which already exists
# as the gold/ prefix on the data bucket, and the IAM permissions the CD role
# needs to run dbt. Those permissions are already granted by the github-actions
# role in bootstrap (glue:*, athena:*, s3:* on the data bucket), so no new
# resource is required.
#
# This file is intentionally a documentation placeholder recording that
# decision, so a reader looking for "where is the Gold table defined" finds the
# answer: in dbt, under transforms/models/marts/.
###############################################################################
