# Dashboard

A Streamlit app that reads the Gold layer from Athena and shows Melbourne CBD
foot-traffic patterns: busiest sensors, hourly rhythm, and weekday versus
weekend profiles.

## Run locally

Needs AWS credentials with Athena and S3 read access (your normal local profile
works):

```bash
pip install -r dashboard/requirements.txt
streamlit run dashboard/app.py
```

Opens at http://localhost:8501.

## Structure

- `app.py` — Streamlit layout and charts. No AWS logic.
- `queries.py` — the only module that touches Athena.
- `transforms.py` — pure DataFrame functions feeding each chart. Unit tested.

The data-access-at-the-edge, pure-logic-in-the-middle split is the same pattern
used in the Silver Glue job and the forecasting features, which is why the
transforms are testable without a warehouse.

## Deploy (optional)

Streamlit deploys to AWS App Runner or ECS Fargate behind the same OIDC-based
CI. Not wired up here; the app runs locally for demos, which is enough to show
the serving layer working end to end.
