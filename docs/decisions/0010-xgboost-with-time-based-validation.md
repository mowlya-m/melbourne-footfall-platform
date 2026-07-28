# 0010: Forecast footfall with XGBoost and time-based validation

Date: 2026-07-28
Status: Accepted

## Context

The Gold layer produces hourly foot-traffic facts. The motivating use case is
staffing: a retailer wants next-hour pedestrian volume to roster by. That makes
this a supervised regression on time-series data, one model across all sensors.

Two decisions matter: the model family, and how to validate it.

## Decision

**Model: XGBoost regression.** Gradient-boosted trees over a linear model,
because foot traffic is nonlinear and interaction-heavy: the effect of hour
depends on whether it is a weekend, the effect of a recent lag depends on the
sensor's baseline. Trees capture those interactions without hand-built terms.

**Validation: a chronological split, never random.** The earliest 80% of the
timeline trains; the latest 20% tests. A random split would let the model see
future rows while predicting past ones — target leakage that inflates the score
and never happens in production.

**Features from Gold only.** Cyclical encodings of hour and day-of-week, a
weekend flag, per-sensor lags (1, 2, 3, and 24 hours), and rolling means. All are
derived from the fact table's grain of one row per sensor per hour.

## Consequences

Positive:
- The forecaster consumes the Gold star schema directly, which is the payoff of
  building the medallion layers: the dimensional model is the feature source
- Time-based validation gives an honest error estimate that reflects deployment
- Feature engineering is pure functions, unit tested without AWS, with explicit
  tests that lags do not leak across sensors and no feature leaks the target
- The 24-hour lag ("same hour yesterday") is typically the strongest single
  predictor of foot traffic, and comes for free from the hourly grain

Negative:
- One global model treats all sensors together; a busy CBD sensor and a quiet
  side-street sensor share parameters. A per-sensor or hierarchical model could
  do better at the cost of much more complexity
- XGBoost does not extrapolate: it cannot predict a volume higher than anything
  in training, which matters for one-off events
- No exogenous features yet (weather, public holidays); the Silver job already
  has hooks for them, so they are a natural next iteration

## Alternatives rejected

**Linear regression / SARIMA.** Interpretable and light. Rejected because the
daily and weekly seasonality interacts with the weekend flag and per-sensor
baselines in ways a linear model captures poorly without extensive manual
feature construction.

**A deep sequence model (LSTM/Temporal Fusion Transformer).** State of the art
for large multivariate series. Rejected as disproportionate: the data volume is
modest, XGBoost is a strong baseline that trains in seconds, and the marginal
accuracy would not justify the complexity or the training cost for this project.

## Note on leakage

The single most important correctness property here is no target leakage. Two
tests enforce it: rolling means are shifted so they never include the current
row, and the lag features are computed within each sensor after sorting, so a
lag never borrows a value from a different sensor or from the future. These are
exactly the mistakes that make an offline model look excellent and a deployed one
fail.
