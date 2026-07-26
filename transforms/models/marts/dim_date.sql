-- Date dimension. Generated from the range of dates actually present in the
-- data rather than a fixed calendar, so it never has gaps or unused rows.

with dates as (
    select distinct cast(event_date as date) as date_day
    from {{ ref('stg_pedestrian') }}
)

select
    date_day,
    year(date_day)          as year,
    month(date_day)         as month,
    day_of_month(date_day)  as day_of_month,
    day_of_week(date_day)   as day_of_week,
    day_of_week(date_day) in (6, 7) as is_weekend
from dates