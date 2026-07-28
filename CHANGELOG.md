# Changelog

All notable changes to this project are documented here.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Repository scaffold: README with architecture and orchestration DAGs,
  directory structure, pre-commit hooks, PR and issue templates, MIT licence.
- CI pipeline: lint, unit tests, secret scanning, and Terraform validation
  on every pull request.
- AWS bootstrap: CloudWatch billing alarm, Terraform S3 state backend with
  DynamoDB locking, and GitHub OIDC federation for keyless deployment.
- ADR 0001: GitHub OIDC federation over stored access keys.

- ADR 0002: Billing alarm provisioned before any billable resource.

- Producer Lambda polling the City of Melbourne pedestrian API, deduplicating against a DynamoDB watermark, and emitting readings to Kinesis.
- Kinesis Data Stream and Firehose delivery landing gzipped JSON in Bronze, partitioned by date and hour.
- ADR 0004: ingestion implemented as a poll-to-stream adapter.

- Glue catalog table over Bronze using Athena partition projection, queryable without a crawler.
- Verification script running row counts, top sensors, duplicate checks and ingestion lag through Athena.
- ADR 0005: partition projection over a Glue crawler.

- Bronze to Silver Glue job: cleaning, null coercion, deduplication, quarantine, timezone-correct date derivation. Structured as pure functions and unit tested locally.
- Silver catalog table via partition projection.
- ADR 0006: pure-function PySpark transforms for testability.

- Gold layer: dbt star schema — dim_date, SCD Type 2 dim_sensor, fact_footfall_hourly. Tested against live data: 245 facts, 89 sensor versions, all schema and referential tests passing.
- ADR 0007: SCD Type 2 on the sensor dimension.

- Observability: CloudWatch alarms for producer errors and silence, Kinesis throttling, Firehose delivery, and Glue failure, wired to SNS email, plus a pipeline health dashboard.
- Operational runbook with a diagnose-and-fix procedure for every alarm.
- ADR 0008: monitoring shipped with a runbook, not just alarms.

- Orchestration: Step Functions state machine running the hourly Silver refresh with native Glue waiting, transient-error retries, and success/failure SNS alerts. Hourly schedule and an execution-failure alarm.
- ADR 0009: Step Functions over a Lambda or MWAA for batch orchestration.

### Fixed
- OIDC trust policy now matches subject claims containing GitHub's numeric owner and repository IDs.