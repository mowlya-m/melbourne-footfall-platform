-- Staging: a thin, renamed view over Silver. No business logic here, just a
-- stable interface so downstream models do not reference the source directly.

with source as (
    select * from {{ source('silver', 'silver_pedestrian') }}
)

select
    location_id,
    event_ts_utc,
    event_ts_local,
    event_date,
    event_hour,
    day_of_week,
    is_weekend,
    direction_1,
    direction_2,
    total_of_directions   as pedestrian_count,
    dedupe_key,
    ingested_ts_utc
from source
