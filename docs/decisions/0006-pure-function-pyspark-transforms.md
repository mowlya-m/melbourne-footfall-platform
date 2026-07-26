# 0006: Structure the Glue job as pure DataFrame functions

Date: 2026-07-24
Status: Accepted

## Context

The Bronze to Silver transformation runs as an AWS Glue PySpark job. Glue jobs
are notoriously hard to test: the usual pattern mixes reading from S3, the
transformation, and writing back into one script that can only run inside Glue.
That means the logic is exercised only by deploying and running against real
data, which is slow and expensive to iterate on.

## Decision

The transformation is written as a set of pure functions that each take a
DataFrame and return a DataFrame: parse, quarantine split, clean counts,
deduplicate, project. Reading and writing live in a thin `_run` wrapper. The
Glue entry point does nothing but resolve arguments and call the pure pipeline.

The tests run those functions against a local SparkSession with no Glue, no AWS
and no network.

## Consequences

Positive:
- The transformation is unit tested in seconds, locally, in CI
- Each rule is tested in isolation: null coercion, quarantine, dedup ordering
- The same functions run identically on a laptop and on a Glue cluster
- A malformed-input bug was caught by a local test before any deployment

Negative:
- A local SparkSession is slow to start, so the suite has fixed overhead
- Local Spark is not byte-identical to Glue's runtime; a small class of
  Glue-specific issues can still only surface on deployment
- Splitting read/transform/write is slightly more code than one monolithic script

## Note on ANSI mode

Glue 4 runs Spark in ANSI SQL mode, where casting a malformed string to a
timestamp aborts the whole job rather than returning null. The job uses
`try_to_timestamp` so a bad record routes to quarantine instead of killing the
run. This was caught by the local test suite, which is the entire point of this
decision.
