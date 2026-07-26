# 0007: Model the sensor dimension as Slowly Changing Dimension Type 2

Date: 2026-07-26
Status: Accepted

## Context

The Gold layer needs a sensor dimension to join foot-traffic facts against. The
naive choice is a Type 1 dimension: one row per sensor, overwritten whenever an
attribute changes.

City of Melbourne relocates and decommissions sensors over time. The sensor
locations dataset explicitly notes that sensors have been moved or removed since
2009. A sensor id is therefore not a stable descriptor of a physical location:
sensor 34 in 2019 may sit on a different street than sensor 34 today.

## Decision

Model `dim_sensor` as Slowly Changing Dimension Type 2. Each sensor version is a
separate row with `valid_from`, `valid_to`, and `is_current`. A historical fact
joins to the sensor version that was current at the reading's timestamp.

## Consequences

Positive:
- A 2019 reading attributes to the sensor's 2019 location, not its current one
- Analytical questions like "how did traffic at this corner change after the
  sensor moved" become answerable
- The surrogate key is a hash of natural key plus valid_from, so it is stable
  across runs and needs no stateful sequence

Negative:
- The fact-to-dimension join is a range join on timestamp between valid_from and
  valid_to, which is more expensive than an equality join
- Type 2 dimensions grow over time as versions accumulate
- Until the sensor-locations feed is ingested, versions are derived from observed
  activity rather than actual attribute changes; the mechanism is in place but
  carries no attribute history yet

## Alternatives rejected

**Type 1 (overwrite).** Simplest and smallest. Rejected because it makes every
historical reading join to the sensor's current location, silently
misattributing foot traffic across street relocations. This is exactly the class
of error that looks correct in a dashboard and is wrong in fact.

**Type 3 (previous-value column).** Keeps only the prior value, not full history.
Rejected because sensors can move more than once and the analytical value is in
the full timeline.

## Note

This is the single decision most worth being able to defend in interview: it is
driven by a real property of the source data, documented in the dataset itself,
not modelling for its own sake.
