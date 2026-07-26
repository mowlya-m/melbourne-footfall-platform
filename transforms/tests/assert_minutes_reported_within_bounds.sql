-- A single hour cannot contain more than 60 one-minute readings per sensor.
-- If it does, deduplication upstream has failed. Returning any rows fails the test.

select
    footfall_key,
    minutes_reported
from {{ ref('fact_footfall_hourly') }}
where minutes_reported > 60
