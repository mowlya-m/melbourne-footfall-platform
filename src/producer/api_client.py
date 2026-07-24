"""Client for the City of Melbourne pedestrian counting API.

Deliberately uses only the standard library. The Lambda runtime already ships
boto3, so avoiding `requests` means the deployment package is just source files
with no vendored dependencies, no build step, and no supply chain to audit.
"""

from __future__ import annotations

import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime

logger = logging.getLogger(__name__)

API_BASE = "https://data.melbourne.vic.gov.au/api/explore/v2.1/catalog/datasets"
PAST_HOUR_DATASET = "pedestrian-counting-system-past-hour-counts-per-minute"

# The API caps a single page. Paginating past this is handled by the caller.
MAX_PAGE_SIZE = 100


class PedestrianApiError(RuntimeError):
    """Raised when the upstream API cannot be read after retries."""


@dataclass(frozen=True)
class SensorReading:
    """One sensor, one minute.

    Mirrors the upstream payload rather than renaming fields, so a schema
    change upstream surfaces as a parse failure rather than silently producing
    nulls downstream.
    """

    location_id: int
    sensing_datetime: str  # ISO 8601, UTC
    sensing_date: str  # Melbourne local date
    sensing_time: str  # Melbourne local HH:MM
    direction_1: int
    direction_2: int
    total_of_directions: int

    @property
    def dedupe_key(self) -> str:
        """Composite natural key. Two readings sharing this are the same event."""
        return f"{self.location_id}#{self.sensing_datetime}"

    @property
    def event_timestamp(self) -> datetime:
        return datetime.fromisoformat(self.sensing_datetime).astimezone(UTC)

    def to_record(self, ingested_at: datetime) -> dict:
        """Shape written to the stream.

        `ingested_at` is retained alongside the event time so the Silver layer
        can distinguish late-arriving data from delayed processing.
        """
        return {
            "location_id": self.location_id,
            "sensing_datetime": self.sensing_datetime,
            "sensing_date": self.sensing_date,
            "sensing_time": self.sensing_time,
            "direction_1": self.direction_1,
            "direction_2": self.direction_2,
            "total_of_directions": self.total_of_directions,
            "dedupe_key": self.dedupe_key,
            "ingested_at": ingested_at.isoformat(),
        }


def _parse_reading(raw: dict) -> SensorReading:
    """Convert one API record, coercing nulls in the count fields to zero.

    A null count means the sensor reported nothing for that minute, which is
    meaningfully zero rather than unknown. Nulls in the identity fields are not
    tolerated: those indicate a genuine upstream problem.
    """
    return SensorReading(
        location_id=int(raw["location_id"]),
        sensing_datetime=str(raw["sensing_datetime"]),
        sensing_date=str(raw["sensing_date"]),
        sensing_time=str(raw["sensing_time"]),
        direction_1=int(raw.get("direction_1") or 0),
        direction_2=int(raw.get("direction_2") or 0),
        total_of_directions=int(raw.get("total_of_directions") or 0),
    )


def parse_response(payload: dict) -> list[SensorReading]:
    """Parse an API page, skipping malformed records rather than failing the batch.

    One bad record should not cost us the other ninety-nine. Skips are logged so
    a sustained parse failure is visible in metrics rather than silent.
    """
    readings: list[SensorReading] = []
    skipped = 0

    for raw in payload.get("results", []):
        try:
            readings.append(_parse_reading(raw))
        except (KeyError, TypeError, ValueError):
            skipped += 1
            logger.warning("skipped malformed record", extra={"raw_keys": list(raw)})

    if skipped:
        logger.warning("records skipped during parse", extra={"skipped": skipped})

    return readings


def _get(url: str, timeout: int) -> dict:
    request = urllib.request.Request(  # noqa: S310 - fixed https host, not user input
        url,
        headers={"Accept": "application/json", "User-Agent": "melbourne-footfall/1.0"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
        return json.loads(response.read().decode("utf-8"))


def fetch_page(
    offset: int = 0,
    limit: int = MAX_PAGE_SIZE,
    *,
    max_attempts: int = 4,
    timeout: int = 15,
    base_delay: float = 1.0,
) -> dict:
    """Fetch one page with exponential backoff.

    Retries on 5xx and network errors, which are transient. Does not retry on
    4xx, which indicates a request we constructed wrongly and which will fail
    identically on every attempt.
    """
    query = urllib.parse.urlencode(
        {"limit": limit, "offset": offset, "order_by": "sensing_datetime"}
    )
    url = f"{API_BASE}/{PAST_HOUR_DATASET}/records?{query}"

    last_error: Exception | None = None

    for attempt in range(1, max_attempts + 1):
        try:
            return _get(url, timeout)

        except urllib.error.HTTPError as exc:
            if 400 <= exc.code < 500:
                raise PedestrianApiError(f"client error {exc.code} for offset {offset}") from exc
            last_error = exc

        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            last_error = exc

        if attempt < max_attempts:
            delay = base_delay * (2 ** (attempt - 1))
            logger.warning(
                "api call failed, retrying",
                extra={"attempt": attempt, "delay_seconds": delay, "offset": offset},
            )
            time.sleep(delay)

    raise PedestrianApiError(
        f"failed to fetch offset {offset} after {max_attempts} attempts"
    ) from last_error


def fetch_recent(max_records: int = 500) -> list[SensorReading]:
    """Fetch the most recent readings, paginating until exhausted or capped.

    The upstream dataset holds roughly the last hour across all sensors. The cap
    bounds a single invocation so one slow run cannot overrun the Lambda timeout.
    """
    readings: list[SensorReading] = []
    offset = 0

    while len(readings) < max_records:
        page_size = min(MAX_PAGE_SIZE, max_records - len(readings))
        payload = fetch_page(offset=offset, limit=page_size)

        page = parse_response(payload)
        if not page:
            break

        readings.extend(page)

        if len(page) < page_size:
            break  # last page

        offset += page_size

    logger.info("fetched readings", extra={"count": len(readings)})
    return readings
