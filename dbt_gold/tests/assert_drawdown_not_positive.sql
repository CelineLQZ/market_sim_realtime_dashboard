-- 回撤 = 总盈亏 - 历史最高点，永远 <= 0
select snap_time, drawdown_eur
from {{ ref('portfolio_hourly') }}
where drawdown_eur > 0
