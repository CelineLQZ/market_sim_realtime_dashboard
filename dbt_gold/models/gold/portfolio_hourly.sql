-- 全组合。粒度：小时。
-- 把每只股票加总，再算历史最高点（peak）和回撤（drawdown = 总盈亏 - 历史最高点，<= 0）。

with totals as (
    select
        snap_time,
        sum(realized_eur)        as realized_eur,
        sum(unrealized_eur)      as unrealized_eur,
        sum(total_eur)           as total_eur,
        sum(realized_eur_cfx)    as realized_eur_cfx,
        sum(unrealized_eur_cfx)  as unrealized_eur_cfx,
        sum(total_eur_cfx)       as total_eur_cfx,
        sum(greatest(mv_eur, 0)) as long_mv_eur,
        sum(least(mv_eur, 0))    as short_mv_eur,         -- 负数
        sum(abs(mv_eur))         as gross_eur,
        sum(mv_eur)              as net_eur
    from {{ ref('stock_hourly') }}
    group by snap_time
),

with_peak as (
    select
        *,
        greatest(0, max(total_eur) over (order by snap_time)) as peak_total_eur   -- 起点是 0
    from totals
)

select
    *,
    total_eur - peak_total_eur as drawdown_eur
from with_peak
