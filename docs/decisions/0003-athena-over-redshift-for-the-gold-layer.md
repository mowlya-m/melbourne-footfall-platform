# 0003: Query the Gold layer with Athena rather than Redshift

Date: 2026-07-24
Status: Accepted

## Context

The Gold layer needs a SQL engine that dbt can build models against and that a
dashboard can query. Expected working set is a few gigabytes of Parquet, queried
a few dozen times a day with bursty, unpredictable timing. The project has a
stated cost target of under AUD 30 per month.

Options considered: Athena, Redshift Serverless, Redshift provisioned, and
DuckDB running inside a Lambda.

## Decision

Athena, backed by the Glue Data Catalog, inside a dedicated workgroup with a
per-query data scan limit of 1 GiB.

## Consequences

Positive:
- Costs nothing when idle, which matches a workload that is idle most of the day
- Reads Parquet natively and prunes partitions, so cost scales with data actually
  scanned rather than with cluster uptime
- dbt-athena is mature enough for the star schema and tests planned in PR #11
- The workgroup scan limit caps the blast radius of an accidental full-table
  scan, which is the main way Athena bills surprise people

Negative:
- No materialised views, so expensive aggregations must be persisted as Gold
  tables rather than computed on read
- Cold-start latency of roughly one to two seconds per query, which is visible in
  an interactive dashboard
- The per-query pricing model punishes unpartitioned scans, which makes partition
  discipline mandatory rather than merely advisable
- No native indexes; performance work means partitioning and file layout

## Alternatives rejected

**Redshift Serverless.** Better interactive latency and materialised view
support. Rejected on cost: the 8 RPU minimum bills continuously whenever the
endpoint is warm, which at this utilisation is roughly fifteen times the Athena
cost for no benefit the project can measure.

**Redshift provisioned.** Around AUD 280 per month for the smallest useful
cluster. Not defensible at this scale.

**DuckDB in Lambda.** Genuinely cheap and fast for a few gigabytes, and
attractive technically. Rejected because dbt integration is less mature and the
Glue Catalog would still be needed for schema management, so it adds a component
without removing one.

## Revisit if

Query latency becomes a user-facing problem, or concurrent dashboard usage grows
past what per-query cold starts can absorb.
