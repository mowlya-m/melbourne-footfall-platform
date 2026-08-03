# Melbourne Foot Traffic Intelligence

## Two views

- **melbourne-footfall-dashboard.html** — a self-contained, animated dashboard
  (Leaflet map, live charts, forecast overlay, Apple-style UI). Opens in any
  browser with no server. Data is embedded; refresh it from live Athena with
  `python export_gold.py --embed melbourne-footfall-dashboard.html`.
- **app.py** — a Streamlit app that queries Athena directly for interactive use.

The HTML view is the shareable snapshot; the Streamlit view is the live analyst
tool.

A production-style streaming data platform on AWS built on live City of Melbourne
pedestrian sensor data, forecasting hourly foot traffic to support CBD retail and
hospitality staffing decisions.

![CI](https://github.com/mowlya-m/melbourne-footfall-platform/actions/workflows/ci.yml/badge.svg)
![Python](https://img.shields.io/badge/python-3.12-blue)
![Terraform](https://img.shields.io/badge/terraform-1.9-purple)
![License](https://img.shields.io/badge/license-MIT-green)

---

## The problem

CBD hospitality and retail venues roster staff a week ahead using intuition.
Foot traffic swings heavily with weather, public holidays, and events.
Overstaffing burns wage cost on quiet days; understaffing loses revenue on busy
ones.

This platform ingests live pedestrian sensor readings, enriches them with weather
and calendar data, and produces a 7-day hourly foot traffic forecast per location
along with a derived staffing recommendation.

---

## A note on "streaming"

The upstream City of Melbourne API publishes on a ~15 minute cadence. It is not a
native event stream.

This project implements a **poll-to-stream adapter**: a scheduled Lambda polls the
API, deduplicates against a high-water mark held in DynamoDB, and emits each new
sensor reading as an individual event onto Kinesis. Everything downstream of
Kinesis is genuinely stream-processed.

This is a standard pattern for integrating batch-published sources into
event-driven platforms, and it is documented here rather than glossed over.

---

## Architecture

```mermaid
flowchart TD
    subgraph sources["Data sources"]
        S1["CoM Pedestrian API<br/>past hour, per minute"]
        S2["Open-Meteo<br/>weather forecast"]
        S3["data.gov.au<br/>public holidays"]
    end

    subgraph hot["Hot path — streaming"]
        EB["EventBridge Scheduler<br/>every 5 min"]
        PROD["Lambda: producer<br/>poll, dedupe, emit"]
        WM[("DynamoDB<br/>watermark")]
        KDS["Kinesis Data Streams<br/>1 shard"]
        CONS["Lambda: hot consumer<br/>rolling aggregates"]
        STATE[("DynamoDB<br/>current state")]
    end

    subgraph cold["Cold path — batch"]
        FH["Kinesis Firehose<br/>buffer to Parquet"]
        BRONZE[("S3 Bronze<br/>raw, immutable")]
        GLUE["Glue ETL<br/>bronze_to_silver"]
        SILVER[("S3 Silver<br/>cleaned, typed")]
        DBT["dbt-athena<br/>star schema + tests"]
        GOLD[("S3 Gold<br/>Glue Catalog")]
    end

    subgraph serve["Serving"]
        DASH["Streamlit<br/>App Runner"]
    end

    S1 --> PROD
    EB --> PROD
    PROD <--> WM
    PROD --> KDS
    KDS --> CONS
    KDS --> FH
    CONS --> STATE
    FH --> BRONZE
    BRONZE --> GLUE
    GLUE --> SILVER
    S2 --> GLUE
    S3 --> GLUE
    SILVER --> DBT
    DBT --> GOLD
    STATE --> DASH
    GOLD --> DASH
```

### Batch orchestration DAG

The cold path runs as a Step Functions state machine, hourly:

```mermaid
flowchart LR
    START(["Start"]) --> FRESH["Check Bronze<br/>freshness"]
    FRESH --> DECIDE{"New data<br/>available?"}
    DECIDE -->|no| SKIP(["Skip run"])
    DECIDE -->|yes| SILVER["Glue job<br/>bronze to silver"]
    SILVER --> QUAL{"Row count<br/>reconciles?"}
    QUAL -->|no| ALERT["SNS alert"]
    QUAL -->|yes| DBTRUN["dbt run<br/>gold models"]
    DBTRUN --> DBTTEST["dbt test"]
    DBTTEST --> PASS{"Tests<br/>pass?"}
    PASS -->|no| ALERT
    PASS -->|yes| DONE(["Success"])
    ALERT --> FAIL(["Fail"])
```

Every task is idempotent — the Silver and Gold writes overwrite their target
partition rather than appending, so any date range can be safely re-run or
backfilled.

---

## Tech stack

| Layer | Service | Why |
|---|---|---|
| Schedule | EventBridge Scheduler | Cron without a server; free |
| Ingest | Lambda (Python 3.12) | Bursty workload, no idle cost |
| Watermark | DynamoDB on-demand | Single-digit ms reads, pay per request |
| Stream | Kinesis Data Streams | On-demand mode has a higher floor at this volume |
| Stream to S3 | Kinesis Firehose | Native Parquet conversion and partitioning |
| Batch transform | Glue ETL (PySpark) | Distributed cleaning at Bronze to Silver |
| Modelling | dbt-athena | SQL transformations with lineage and tests |
| Query | Athena + Glue Catalog | Pay per TB scanned; no idle cluster |
| Orchestration | Step Functions | MWAA costs ~AUD 500/mo and is unjustifiable here |
| Observability | CloudWatch + SNS | Alarms on freshness, failure, and cost |
| Serving | Streamlit on App Runner | Scale to zero |
| IaC | Terraform | Everything as code, no ClickOps |

Architecture decisions and the alternatives rejected are recorded in
[`docs/decisions/`](docs/decisions/).

---

## Data model

Star schema in the Gold layer.

**`fact_footfall_hourly`** — grain: one row per sensor per hour

Foreign keys to `dim_sensor`, `dim_date`, `dim_weather`, `dim_event`.
Measures: `pedestrian_count`, `count_direction_1`, `count_direction_2`,
`reading_completeness_pct`.

**`dim_sensor`** is a **Slowly Changing Dimension Type 2**. City of Melbourne
documents that sensors have been relocated or removed since 2009. A Type 1
overwrite would retroactively attribute historical foot traffic to the wrong
street, so location history is versioned with `valid_from`, `valid_to`, and
`is_current`.

---

## Quickstart

```bash
git clone https://github.com/mowlya-m/melbourne-footfall-platform.git
cd melbourne-footfall-platform

python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pre-commit install

cp .env.example .env          # fill in your AWS account ID and region

cd infra/envs/dev
terraform init
terraform plan
```

---

## Repository layout

```
.
├── .github/workflows/   CI and CD pipelines
├── docs/                design doc, ADRs, runbook, cost analysis
├── infra/               Terraform modules and environments
├── src/                 Lambda functions and Glue jobs
├── transforms/          dbt project
├── dashboard/           Streamlit app
├── tests/               unit, integration, fixtures
└── scripts/             backfill and teardown utilities
```

---

## Cost

Target: under **AUD 30/month**. A billing alarm is provisioned at AUD 15 by
Terraform before any other resource.

Run `scripts/teardown.sh` to destroy the Kinesis shard and App Runner service
while preserving S3 and the Glue Catalog when not actively developing.

Full breakdown in [`docs/cost-analysis.md`](docs/cost-analysis.md).

---

## Data sources and attribution

- Pedestrian counts and sensor locations: **City of Melbourne Open Data**,
  licensed CC BY 4.0
- Weather: **Open-Meteo**
- Public holidays: **data.gov.au**

---

## Verify it works

**Ingest a batch** — invoke the producer and watch it emit to Kinesis:

```bash
aws lambda invoke --function-name melbourne-footfall-producer-dev \
  --region ap-southeast-2 --cli-binary-format raw-in-base64-out \
  --payload '{}' /tmp/out.json && cat /tmp/out.json
```

**Query the Bronze layer** through Athena:

```bash
bash scripts/query_bronze.sh
```

**Run the Silver transformation** — the Glue job that cleans and deduplicates:

```bash
aws glue start-job-run \
  --job-name melbourne-footfall-bronze-to-silver-dev \
  --region ap-southeast-2
```

**Build the Gold star schema** with dbt, running every data test:

```bash
cd transforms
export DBT_PROFILES_DIR=$(pwd)
dbt deps
dbt build --profiles-dir .
```

`dbt build` materialises the dimensions and fact, then runs uniqueness,
not-null, referential-integrity and a custom grain test. If any test fails, the
build fails — Gold does not publish wrong data.

---

## Status

| Component | Status |
|---|---|
| Repository scaffold, CI, CD | Done |
| AWS bootstrap: OIDC, remote state, billing alarm | Done |
| Storage: S3 medallion layout, Glue catalog, Athena workgroup | Done |
| Ingestion: producer Lambda, Kinesis, Firehose to Bronze | Done |
| Bronze catalog table, queryable via Athena | Done |
| Silver: Glue PySpark job, cleaning and deduplication | Done |
| Gold: dbt star schema with SCD Type 2 | Done |
| Orchestration: Step Functions batch pipeline | Done |
| Observability: alarms, dashboard, runbook | Done |
| Dashboard (Streamlit) | Done |
| Forecasting model (XGBoost on Gold) | Done |

The pipeline is complete and self-running: ingestion every five minutes, an
hourly Step Functions batch refresh with retries and SNS alerting, and Gold
rebuilt and tested by dbt on every deploy. Seven CloudWatch alarms and a health
dashboard cover the failure modes, each with a runbook entry. Verified end to
end — a full orchestrated execution succeeded, producing 876 deduplicated Silver
readings and a Gold star schema of 245 hourly facts across 89 sensor versions,
with all dbt data tests passing.

---

## Forecasting

A next-hour pedestrian-count forecaster trained on the Gold fact table. It uses
XGBoost with a chronological train/test split — the earliest 80% of the timeline
trains, the latest 20% tests — because a random split would leak future
information and inflate the score.

Features are derived entirely from `fact_footfall_hourly`: cyclical encodings of
hour and day, a weekend flag, per-sensor lags at 1, 2, 3, and 24 hours, and
rolling means. The 24-hour lag (same hour yesterday) is typically the strongest
predictor.

The feature engineering is pure functions, unit tested without AWS, with
explicit tests that lags never leak across sensors and that no feature leaks the
target — the two mistakes that make an offline model look good and a deployed one
fail.

Train it:

```bash
cd src && python -m forecasting.train --output model.json
```

This reads Gold via Athena, builds features, trains, and reports MAE and MAPE on
the held-out tail. See ADR 0010 for the modelling decisions.

## Licence

MIT — see [LICENSE](LICENSE).
