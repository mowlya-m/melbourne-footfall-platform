-- Fact table. Grain: one row per sensor per hour.
--
-- Minute-level readings are aggregated to the hour, which is the grain the
-- dashboard and any forecasting model actually use. Foreign keys reference the
-- date and sensor dimensions; measures are additive sums so they roll up
-- correctly across any dimension.

with hourly as (
    select
        location_id,
        event_date,
        event_hour,
        is_weekend,
        day_of_week,
        sum(pedestrian_count) as pedestrian_count,
        sum(direction_1)      as count_direction_1,
        sum(direction_2)      as count_direction_2,
        count(*)              as minutes_reported,
        -- Completeness: of the 60 minutes in an hour, how many did the sensor
        -- actually report? A partial hour is still usable but flagged.
        round(count(*) / 60.0, 3) as reading_completeness
    from {{ ref('stg_pedestrian') }}
    group by location_id, event_date, event_hour, is_weekend, day_of_week
),

sensor_current as (
    -- Join to the current version of each sensor. A full historical join would
    -- match on the reading's timestamp falling between valid_from and valid_to;
    -- with only current versions present today, this is equivalent.
    select sensor_key, location_id
    from {{ ref('dim_sensor') }}
    where is_current
)

select
    {{ dbt_utils.generate_surrogate_key(['h.location_id', 'h.event_date', 'h.event_hour']) }} as footfall_key,
    s.sensor_key,
    cast(h.event_date as date) as date_key,
    h.event_hour,
    h.is_weekend,
    h.day_of_week,
    h.pedestrian_count,
    h.count_direction_1,
    h.count_direction_2,
    h.minutes_reported,
    h.reading_completeness
from hourly h
left join sensor_current s
    on h.location_id = s.location_id
