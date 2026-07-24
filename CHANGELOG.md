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
