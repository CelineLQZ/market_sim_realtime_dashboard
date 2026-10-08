-- 给每个标的的成交按 (事件时间, 到达顺序) 编号：1, 2, 3 ...
-- 下一步 int_positions 按这个编号一笔接一笔地往下算。

{{ config(indexes=[{'columns': ['instrument_id', 'trade_seq'], 'unique': True}]) }}

select
    trade_id,
    instrument_id,
    event_time,
    raw_id,
    price,
    case when side = 'BUY' then volume else -volume end as signed_qty,   -- 买为正，卖为负
    row_number() over (
        partition by instrument_id
        order by event_time, raw_id
    )                                                   as trade_seq
from {{ source('clean', 'trades') }}
