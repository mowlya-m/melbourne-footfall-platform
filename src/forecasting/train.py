"""Train a next-hour footfall forecaster.

Reads the Gold fact table from Athena, builds features, trains an XGBoost
regressor, and reports error on a held-out time period. The split is by time,
not random: a random split would let the model see future rows while predicting
past ones, which inflates the score and would never happen in production.

Run:
    python -m forecasting.train --output model.json
"""

from __future__ import annotations

import argparse
import logging

import pandas as pd

from forecasting.features import build_features, feature_columns

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger(__name__)

# Fraction of the timeline used for training; the rest is the held-out test tail.
TRAIN_FRACTION = 0.8


def time_split(df: pd.DataFrame, train_fraction: float = TRAIN_FRACTION):
    """Split chronologically: earliest rows train, latest rows test.

    Ordering by the event timestamp and cutting at a fraction means the test set
    is always strictly after the training set, which is the only honest way to
    evaluate a forecaster.
    """
    ordered = df.sort_values(["date_key", "event_hour"]).reset_index(drop=True)
    cut = int(len(ordered) * train_fraction)
    return ordered.iloc[:cut], ordered.iloc[cut:]


def train(features_df: pd.DataFrame):
    """Fit an XGBoost regressor and return it with test-set metrics.

    XGBoost rather than a linear model because foot traffic is nonlinear and
    interaction-heavy: the effect of hour depends on weekend, the effect of a lag
    depends on the sensor's baseline. Gradient-boosted trees capture that without
    hand-built interaction terms.
    """
    import xgboost as xgb
    from sklearn.metrics import mean_absolute_error, mean_absolute_percentage_error

    train_df, test_df = time_split(features_df)
    cols = feature_columns()

    x_train, y_train = train_df[cols], train_df["target_next_hour"]
    x_test, y_test = test_df[cols], test_df["target_next_hour"]

    model = xgb.XGBRegressor(
        n_estimators=300,
        max_depth=6,
        learning_rate=0.05,
        subsample=0.8,
        colsample_bytree=0.8,
        # Count data is non-negative and right-skewed; squared-log error keeps the
        # model from being dominated by a few very high-traffic hours.
        objective="reg:squaredlogerror",
        random_state=42,
    )
    model.fit(x_train, y_train)

    predictions = model.predict(x_test).clip(min=0)
    mae = mean_absolute_error(y_test, predictions)
    mape = mean_absolute_percentage_error(y_test.clip(lower=1), predictions.clip(min=1))

    logger.info("test MAE: %.2f pedestrians", mae)
    logger.info("test MAPE: %.1f%%", mape * 100)
    logger.info("train rows: %d, test rows: %d", len(train_df), len(test_df))

    return model, {"mae": mae, "mape": mape, "n_train": len(train_df), "n_test": len(test_df)}


def load_from_athena() -> pd.DataFrame:
    """Read the Gold fact table via the Athena connector.

    Kept thin and separate from the logic so tests never touch AWS.
    """
    import awswrangler as wr

    return wr.athena.read_sql_query(
        "SELECT sensor_key, date_key, event_hour, day_of_week, is_weekend, pedestrian_count "
        "FROM fact_footfall_hourly",
        database="melbourne_footfall_dev",
        workgroup="melbourne-footfall-dev",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="model.json", help="Where to save the trained model.")
    args = parser.parse_args()

    logger.info("loading Gold fact table from Athena")
    raw = load_from_athena()
    logger.info("loaded %d rows", len(raw))

    features_df = build_features(raw)
    logger.info("built %d training rows after feature engineering", len(features_df))

    model, metrics = train(features_df)
    model.save_model(args.output)
    logger.info(
        "saved model to %s (MAE %.2f, MAPE %.1f%%)",
        args.output,
        metrics["mae"],
        metrics["mape"] * 100,
    )


if __name__ == "__main__":
    main()
