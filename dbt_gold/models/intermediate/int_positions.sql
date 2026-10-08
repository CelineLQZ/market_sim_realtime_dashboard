-- 每笔成交之后的持仓、平均成本、已实现盈亏（本币）。对应 sql/gold 里的 gold.position_state。
--
-- 平均成本法（支持空头，一笔成交可以跨过 0）：
--   加仓（同方向或从空仓开始）：新成本 = 按数量加权平均
--   减仓（反方向）           ：实现盈亏 = 平掉的数量 x (成交价 - 平均成本) x 原持仓方向
--       部分平仓 → 成本不变；正好平完 → 成本归 0；跨过 0 → 剩下的部分按成交价开新仓
--
-- 每一笔都依赖上一笔的结果，所以用递归 CTE：先算第 1 笔，再用第 n 笔算第 n+1 笔。
-- 整表重建 + 按事件时间排序，迟到的成交自然排进正确的位置（原版需要"删掉再重放"）。

{{ config(indexes=[{'columns': ['instrument_id', 'event_time', 'raw_id']}]) }}

with recursive walk as (

    -- 第 1 笔：从空仓开始，开仓价就是平均成本
    select
        t.trade_id, t.instrument_id, t.event_time, t.raw_id, t.price, t.signed_qty, t.trade_seq,
        t.signed_qty::numeric as qty_after,
        t.price::numeric      as avg_cost,
        0::numeric            as realized_delta,
        0::numeric            as realized_cum
    from {{ ref('int_trades_ordered') }} t
    where t.trade_seq = 1

    union all

    -- 第 n+1 笔：在第 n 笔的结果（prev）上计算
    select
        t.trade_id, t.instrument_id, t.event_time, t.raw_id, t.price, t.signed_qty, t.trade_seq,
        move.new_qty::numeric,
        case
            when move.is_adding                         then (abs(prev.qty_after) * prev.avg_cost
                                                              + abs(t.signed_qty) * t.price) / abs(move.new_qty)
            when move.new_qty = 0                       then 0
            when sign(move.new_qty) <> sign(prev.qty_after) then t.price          -- 跨过 0
            else prev.avg_cost                                                     -- 部分平仓
        end::numeric,
        move.realized::numeric,
        (prev.realized_cum + move.realized)::numeric
    from walk prev
    join {{ ref('int_trades_ordered') }} t
      on t.instrument_id = prev.instrument_id
     and t.trade_seq     = prev.trade_seq + 1
    cross join lateral (
        select
            prev.qty_after = 0 or sign(prev.qty_after) = sign(t.signed_qty) as is_adding,
            prev.qty_after + t.signed_qty                                     as new_qty,
            case
                when prev.qty_after = 0 or sign(prev.qty_after) = sign(t.signed_qty) then 0
                else least(abs(t.signed_qty), abs(prev.qty_after))                     -- 平掉的数量
                     * (t.price - prev.avg_cost) * sign(prev.qty_after)
            end                                                               as realized
    ) move
)

select
    trade_id,
    instrument_id,
    event_time,
    raw_id,
    price,
    signed_qty,
    qty_after,
    avg_cost,
    realized_delta,
    realized_cum
from walk
