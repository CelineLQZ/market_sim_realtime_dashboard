-- 每小时一组汇率："1 单位该币种 = 多少欧元"。粒度：币种 x 小时。
-- 三个汇率对都有报价之后才开始有数据（缺一个就没法换算）。

with fx_pairs as (
    select instrument_id, short_name
    from {{ source('clean', 'instruments') }}
    where short_name in ('EUR/USD', 'GBP/USD', 'USD/JPY')
),

latest_quotes as (
    -- 每个小时、每个汇率对：事件时间 <= 该小时的最新报价
    select h.snap_time, f.short_name, q.price
    from {{ ref('int_hours') }} h
    cross join fx_pairs f
    join lateral (
        select p.price
        from {{ source('clean', 'prices') }} p
        where p.instrument_id = f.instrument_id
          and p.event_time <= h.snap_time
        order by p.event_time desc
        limit 1
    ) q on true
),

quotes_by_hour as (
    select
        snap_time,
        max(price) filter (where short_name = 'EUR/USD') as eurusd,
        max(price) filter (where short_name = 'GBP/USD') as gbpusd,
        max(price) filter (where short_name = 'USD/JPY') as usdjpy
    from latest_quotes
    group by snap_time
)

select q.snap_time, fx.ccy, fx.rate_to_eur
from quotes_by_hour q
cross join lateral {{ fx_to_eur('q.eurusd', 'q.gbpusd', 'q.usdjpy') }} as fx(ccy, rate_to_eur)
where q.eurusd is not null
  and q.gbpusd is not null
  and q.usdjpy is not null
