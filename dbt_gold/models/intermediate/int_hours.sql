-- 小时轴：所有要做快照的整点。
-- 从第一条报价之后的第一个整点开始，到最新数据所在的整点为止；只保留交易日
-- （减 1 秒再看星期几：周六 00:00 算作周五的最后一个快照）。

with bounds as (
    select
        (select min(event_time) from {{ source('clean', 'prices') }}) as first_price_at,
        greatest(
            (select max(event_time) from {{ source('clean', 'prices') }}),
            (select max(event_time) from {{ source('clean', 'trades') }})
        )                                                             as latest_at
),

first_hour as (
    select
        case
            when first_price_at = date_trunc('hour', first_price_at) then first_price_at
            else date_trunc('hour', first_price_at) + interval '1 hour'
        end                            as first_snap,
        date_trunc('hour', latest_at)  as last_snap
    from bounds
)

select snap_time
from first_hour,
     generate_series(first_snap, last_snap, interval '1 hour') as snap_time
where extract(isodow from snap_time - interval '1 second') <= 5
