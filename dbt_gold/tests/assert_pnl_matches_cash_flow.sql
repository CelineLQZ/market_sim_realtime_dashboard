-- 独立验算：总盈亏（本币）= 现金流 + 持仓 x 价格。
-- 这个公式不依赖平均成本法，所以能检查 int_positions 的递归逻辑有没有算错。
-- 只检查最新的整点；返回的每一行都是对不上的股票。

with latest as (
    select *
    from {{ ref('stock_hourly') }}
    where snap_time = (select max(snap_time) from {{ ref('stock_hourly') }})
),

cash_flow as (
    select l.instrument_id, coalesce(sum(-t.signed_qty * t.price), 0) as cash
    from latest l
    left join {{ ref('int_trades_ordered') }} t
      on t.instrument_id = l.instrument_id
     and t.event_time   <= l.snap_time
    group by l.instrument_id
)

select
    l.instrument_id,
    l.realized_local + l.unrealized_local as total_by_avg_cost,
    c.cash + l.position * l.price         as total_by_cash_flow
from latest l
join cash_flow c using (instrument_id)
where abs((l.realized_local + l.unrealized_local) - (c.cash + l.position * l.price)) > 0.01
