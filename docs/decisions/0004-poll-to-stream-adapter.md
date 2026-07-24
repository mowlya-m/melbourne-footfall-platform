# 0004: Implement ingestion as a poll-to-stream adapter

Date: 2026-07-24
Status: Accepted

## Context

The City of Melbourne pedestrian counting API is a REST endpoint that refreshes
roughly every fifteen minutes. It is not an event stream: there is no webhook, no
subscription, and no push mechanism.

The platform is designed around a streaming architecture, both because the
downstream hot path needs per-reading granularity and because the batch layer
benefits from an append-only event log it can replay from.

## Decision

A scheduled Lambda polls the API every five minutes, discards readings at or
before a high-water mark held in DynamoDB, and emits each remaining reading as an
individual record onto Kinesis Data Streams. Everything downstream of Kinesis is
genuinely stream processed.

This is documented plainly in the README rather than presented as a native
real-time feed.

## Consequences

Positive:
- Downstream components are written against a real stream, so replacing the
  upstream source with a genuine event feed later changes one component
- Per-reading granularity is preserved rather than collapsing into batch rows
- The watermark makes the poll interval a tuning parameter rather than a
  correctness concern: changing it produces neither duplicates nor gaps
- Kinesis retention provides a 24 hour replay window independently of S3

Negative:
- End-to-end latency is bounded below by the upstream refresh cadence, so calling
  this "real-time" would be misleading
- The watermark is additional state that can be lost or corrupted; losing it means
  reprocessing up to an hour of data
- A Kinesis shard costs roughly USD 11 per month whether or not data flows, which
  is the largest single line item in the project

## Alternatives rejected

**Lambda writing directly to S3.** Simpler and cheaper, with no shard cost.
Rejected because it removes the stream the hot path consumer depends on, and
would make the "streaming platform" framing dishonest.

**Firehose direct from Lambda, no Data Stream.** Cheaper still, since Firehose has
no hourly charge. Rejected because Firehose is delivery-only: it cannot be read
by a second consumer, so the hot path aggregation would have no source.

**MSK (managed Kafka).** More capable and closer to what large teams run.
Rejected on cost: a multi-broker minimum is roughly ten times the Kinesis shard
cost for throughput this project will never approach.

## Honesty note

If asked in review or interview whether this is a real-time pipeline, the correct
answer is that the ingestion is a poll-to-stream adapter over a batch-published
source, and that everything after ingestion is stream processed. Claiming
otherwise would not survive a follow-up question.
