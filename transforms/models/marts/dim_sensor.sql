-- Sensor dimension, structured as Slowly Changing Dimension Type 2.
--
-- City of Melbourne relocates and decommissions sensors over time, so a sensor
-- id alone is not a stable descriptor. SCD Type 2 versions each sensor so a
-- historical reading joins to the sensor as it was at that time, not as it is
-- now. Joining today's location to a 2019 reading would misattribute foot
-- traffic to the wrong street.
--
-- Until the sensor-locations feed is ingested, attributes are derived from
-- observed activity. The valid_from / valid_to / is_current columns are the
-- real SCD2 mechanism and will carry location and status changes once that
-- feed is added.

with observed as (
    select
        location_id,
        min(event_ts_utc) as first_seen,
        max(event_ts_utc) as last_seen,
        count(*)          as reading_count
    from {{ ref('stg_pedestrian') }}
    group by location_id
)

select
    -- Surrogate key. A hash rather than a sequence so it is stable across runs
    -- and reproducible without a stateful counter.
    {{ dbt_utils.generate_surrogate_key(['location_id', 'first_seen']) }} as sensor_key,
    location_id,
    first_seen  as valid_from,
    -- Open-ended: the current version has no end date. When a future feed
    -- detects an attribute change, this closes and a new row opens.
    cast(null as timestamp) as valid_to,
    true        as is_current,
    last_seen,
    reading_count
from observed
