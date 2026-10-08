-- 核心事实表。粒度：股票 x 小时。
-- 每个整点的 "as-of" 状态：取事件时间 <= 该整点的最新持仓、最新报价和汇率，再按 pnl_columns() 估值。

with equities as (
    select instrument_id, currency
    from {{ source('clean', 'instruments') }}
    where type = 'equity'
),

as_of_state as (
    select
        h.snap_time,
        e.instrument_id,
        coalesce(pos.qty_after, 0)    as position,          -- 还没成交过：空仓
        coalesce(pos.avg_cost, 0)     as avg_cost,
        px.price,
        px.event_time                 as price_time,
        coalesce(pos.realized_cum, 0) as realized_local,
        fx.rate_to_eur                as market_fx,
        ref.rate_to_eur               as constant_fx
    from {{ ref('int_hours') }} h
    cross join equities e
    join lateral (                                          -- 最新报价（还没有报价的股票不出现）
        select p.price, p.event_time
        from {{ source('clean', 'prices') }} p
        where p.instrument_id = e.instrument_id
          and p.event_time <= h.snap_time
        order by p.event_time desc
        limit 1
    ) px on true
    left join lateral (                                     -- 最新持仓
        select s.qty_after, s.avg_cost, s.realized_cum
        from {{ ref('int_positions') }} s
        where s.instrument_id = e.instrument_id
          and s.event_time <= h.snap_time
        order by s.event_time desc, s.raw_id desc
        limit 1
    ) pos on true
    join {{ ref('fx_rate_hourly') }} fx on fx.snap_time = h.snap_time and fx.ccy = e.currency
    join {{ ref('fx_reference') }}   ref on ref.ccy = e.currency
)

select
    snap_time,
    instrument_id,
    position,
    avg_cost,
    price,
    price_time,
    realized_local,
    {{ pnl_columns() }}
from as_of_state
