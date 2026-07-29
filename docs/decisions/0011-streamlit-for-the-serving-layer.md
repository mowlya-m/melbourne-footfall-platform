# 0011: Streamlit for the serving layer

Date: 2026-07-28
Status: Accepted

## Context

The Gold layer holds analysis-ready foot-traffic data, but nothing surfaces it
to a human. The motivating user is a retail operator who wants to see patterns,
not write SQL. A serving layer is needed.

Options: Streamlit, a managed BI tool (QuickSight, Tableau), or a custom
React/Flask app.

## Decision

Streamlit, reading Gold from Athena. Data access is isolated in a queries module
so the presentation and the pure transforms carry no AWS dependency and are unit
tested without a warehouse.

## Consequences

Positive:
- A working data app in pure Python, no separate frontend stack, no JavaScript
- The transforms that feed each chart are pure functions, unit tested exactly
  like the Silver and forecasting code
- Runs locally for demos and deploys to App Runner or ECS when hosting is wanted
- Caches Athena results with a TTL, so interaction does not re-query on every
  click and Athena cost stays bounded

Negative:
- Streamlit re-runs the whole script on each interaction; fine at this scale but
  not how a high-traffic production app would be built
- No authentication out of the box; a real deployment needs a proxy or App Runner
  auth in front
- Charts are functional rather than pixel-perfect; a BI tool would look more
  polished with less control

## Alternatives rejected

**QuickSight / Tableau.** Polished dashboards with little code. Rejected because
they add a licensed tool and move the logic out of the repo into a GUI, which
makes it un-reviewable and un-testable. The point of this project is
code-defined, tested components; a drag-and-drop dashboard breaks that.

**Custom React + API.** Full control and production-grade. Rejected as
disproportionate: it is a second application to build and maintain for a serving
layer that Streamlit covers in a hundred lines of testable Python.

## Note

Data access is deliberately confined to queries.py. Everything else, the whole
of transforms.py and the chart-shaping logic, is pure and tested. This is the
same separation used in the Silver Glue job and the forecasting features: keep
the I/O at the edge, keep the logic pure and testable in the middle.
