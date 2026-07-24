# 0002: Provision the billing alarm before any billable resource

Date: 2026-07-24
Status: Accepted

## Context

This is a personal project with a stated cost target of under AUD 30 per month.
Several AWS services in the intended architecture have cost profiles that are
easy to misjudge — MWAA has a floor around AUD 500/month, Redshift provisioned
around AUD 280/month, and a NAT Gateway around AUD 50/month for capability this
project does not need.

The common failure mode is discovering the mistake on the monthly invoice.

## Decision

The bootstrap configuration creates the CloudWatch billing alarm and its SNS
subscription as the first resources, before the Terraform state backend and
before the IAM role that lets CI provision anything else.

The threshold defaults to USD 10.

## Consequences

Positive:
- An overspend surfaces within roughly six hours rather than at month end
- The ordering is visible in the code, which makes the intent legible to a reader
- Gives a concrete, verifiable cost story rather than an assertion

Negative:
- The alarm requires the account-level "Receive CloudWatch billing alerts"
  preference, which cannot be set by Terraform and must be enabled manually first
- Billing metrics publish only to us-east-1, so the configuration needs a second
  aliased provider purely for this alarm, which is mildly confusing to read
- Metric granularity is roughly six hours, so this detects sustained overspend
  rather than a single expensive action

## Alternatives rejected

**AWS Budgets.** Richer forecasting and per-service breakdown. Rejected for now
because CloudWatch alarms were sufficient for a single threshold and reuse the
same SNS topic the pipeline alarms will use from PR #9. Worth revisiting if
per-service attribution becomes necessary.

**No alarm, manual console checks.** Rejected: it depends on remembering.
