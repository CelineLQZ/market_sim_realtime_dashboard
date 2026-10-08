-- 每只股票一行的"当前状态"（实时看板读它）。粒度：股票。
-- as_of = 数据里最新的事件时间；估值公式和 stock_hourly 共用 pnl_columns()。

with as_of as (
    select greatest(
        (select max(event_time) from {{ source('clean', 'prices') }}),
        (select max(event_time) from {{ source('clean', 'trades') }})
    ) as as_of
),

latest_fx_quotes as (
    select
        max(price) filter (where short_name = 'EUR/USD') as eurusd,
        max(price) filter (where short_name = 'GBP/USD') as gbpusd,
        max(price) filter (where short_name = 'USD/JPY') as usdjpy
    from (
        select distinct on (i.short_name) i.short_name, p.price
        from {{ source('clean', 'prices') }} p
        join {{ source('clean', 'instruments') }} i using (instrument_id)
        where i.short_name in ('EUR/USD', 'GBP/USD', 'USD/JPY')
        order by i.short_name, p.event_time desc
    ) latest
),

current_fx as (
    select fx.ccy, fx.rate_to_eur
    from latest_fx_quotes q
    cross join lateral {{ fx_to_eur('q.eurusd', 'q.gbpusd', 'q.usdjpy') }} as fx(ccy, rate_to_eur)
),

current_state as (
    select
        i.instrument_id,
        i.exchange,
        coalesce(pos.qty_after, 0)                 as position,
        coalesce(pos.avg_cost, 0)                  as avg_cost,
        px.price,
        px.event_time                              as price_time,
        coalesce(pos.realized_cum, 0)              as realized_local,
        fx.rate_to_eur                             as market_fx,
        coalesce(ref.rate_to_eur, fx.rate_to_eur)  as constant_fx
    from {{ source('clean', 'instruments') }} i
    join lateral (
        select p.price, p.event_time
        from {{ source('clean', 'prices') }} p
        where p.instrument_id = i.instrument_id
        order by p.event_time desc
        limit 1
    ) px on true
    left join lateral (
        select s.qty_after, s.avg_cost, s.realized_cum
        from {{ ref('int_positions') }} s
        where s.instrument_id = i.instrument_id
        order by s.event_time desc, s.raw_id desc
        limit 1
    ) pos on true
    join current_fx fx on fx.ccy = i.currency
    left join {{ ref('fx_reference') }} ref on ref.ccy = i.currency
    where i.type = 'equity'
)

select
    s.instrument_id,
    s.position,
    s.avg_cost,
    s.price                                              as last_price,
    s.price_time,
    extract(epoch from (a.as_of - s.price_time)) / 60    as price_age_min,   -- 模拟时间（分钟）
    exists (
        select 1
        from {{ source('clean', 'exchange_sessions') }} session
        where session.exchange = s.exchange
          and extract(isodow from a.as_of) <= 5
          and (a.as_of at time zone 'UTC')::time >= session.open_utc
          and (a.as_of at time zone 'UTC')::time <  session.close_utc
    )                                                    as in_session,
    s.realized_local,
    {{ pnl_columns() }},
    a.as_of
from current_state s
cross join as_of a
