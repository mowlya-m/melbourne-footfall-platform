# 0005: Use partition projection instead of a Glue crawler

Date: 2026-07-24
Status: Accepted

## Context

Firehose writes Bronze objects under `dt=YYYY-MM-DD/hour=HH/`. For Athena to
prune on those partitions rather than scanning the whole prefix, they must be
registered somewhere.

Three options: a scheduled Glue crawler, manual `MSCK REPAIR TABLE`, or Athena
partition projection.

## Decision

Partition projection, configured in the Glue table properties. Athena computes
the partition set at query time from a declared pattern rather than reading it
from the catalog.

## Consequences

Positive:
- No crawler to schedule, pay for, or monitor
- No window where data exists in S3 but is invisible to queries because the
  crawler has not run yet
- New days and hours are queryable the moment Firehose writes them
- The `dt` range is open-ended at `NOW`, so the table needs no maintenance as
  time passes

Negative:
- The partition layout is now encoded in two places: the Firehose prefix and the
  projection template. Changing one without the other breaks queries silently
- Queries against a range where no data exists still enumerate the projected
  partitions, so an unbounded scan over months of empty days is slower than it
  would be with a catalog listing
- Schema evolution is manual: a crawler would notice a new column, projection
  will not

## Alternatives rejected

**Glue crawler on a schedule.** Handles schema evolution automatically and is
the path most tutorials take. Rejected because it introduces a lag between data
landing and being queryable, costs money per run, and is one more thing that can
silently stop working.

**Manual MSCK REPAIR.** Free and simple. Rejected because it requires remembering
to run it, which is the same failure mode as any manual step.

## Note

The partition projection template and the Firehose prefix must be kept in sync.
Both live in `infra/modules/storage/` and `infra/modules/streaming/`
respectively, and this coupling is called out in the module comments.
