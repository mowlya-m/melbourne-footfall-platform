# 0009: Orchestrate the batch path with Step Functions

Date: 2026-07-27
Status: Accepted

## Context

The batch layers ran independently: the Silver Glue job by manual trigger, Gold
by dbt inside CD. Nothing chained them, waited for completion, retried transient
failures, or alerted on the outcome. For the pipeline to run itself, something
has to sequence the steps and react to their results.

Options: a single orchestrating Lambda, AWS Step Functions, or a managed Airflow
(MWAA).

## Decision

AWS Step Functions, running an hourly state machine that starts the Silver Glue
job, waits for it with the .sync integration, and publishes success or failure
to the ops SNS topic. Transient Glue errors retry with backoff; application
failures do not.

## Consequences

Positive:
- Native waiting on a long-running Glue job. A Lambda would have to either block
  (and risk its 15-minute timeout) or poll in a loop, both worse
- Declarative retries: the retry-on-transient, fail-on-application distinction is
  expressed in the definition, not hand-coded
- Visual execution history makes a failed run obvious and its failure point clear
- Pay-per-transition, effectively free at hourly cadence

Negative:
- The state machine definition is JSON embedded in Terraform, which is verbose
  and awkward to read compared to imperative code
- Step Functions has its own error-handling semantics (Retry vs Catch, ResultPath)
  that are a learning curve
- Gold is not orchestrated here: it stays CI-owned, because packaging dbt into a
  Lambda or container for the state machine adds significant weight for a rebuild
  that CI already does well on every deploy

## Alternatives rejected

**Single orchestrating Lambda.** Simplest to write. Rejected because the Glue job
runs for minutes; a Lambda waiting on it either blocks toward its timeout or
polls in a loop, and neither gives the retry semantics or execution history that
Step Functions provides natively.

**MWAA (managed Airflow).** The industry-standard orchestrator, and what a larger
team would likely use. Rejected on cost: MWAA has a floor around AUD 500/month,
roughly fifty times this entire project's budget, for orchestration this simple.
Airflow earns its cost with dozens of interdependent DAGs, not a two-step refresh.

## Note on scope

The state machine deliberately orchestrates only the Silver refresh and its
alerting, since that is the part that genuinely needs waiting and retries. Gold
remains rebuilt and tested by dbt in CD, where it already runs on every deploy.
Pulling Gold into the state machine would mean packaging dbt for Lambda, which is
weight without benefit given CI covers it.
