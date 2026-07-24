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
<<<<<<< HEAD
- Glue catalog table over Bronze using Athena partition projection, queryable without a crawler.
- Verification script running row counts, top sensors, duplicate checks and ingestion lag through Athena.
- ADR 0005: partition projection over a Glue crawler.
### Fixed
- OIDC trust policy now matches subject claims containing GitHub's numeric owner and repository IDs.
=======


### Fixed
- Producer now newline-delimits records so Firehose-delivered objects are valid NDJSON.
- OIDC trust policy now matches subject claims containing GitHub's numeric owner and repository IDs.
>>>>>>> origin/main
