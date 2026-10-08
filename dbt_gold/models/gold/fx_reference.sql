-- 固定参考汇率（Constant FX 口径用）：数据里第一个有完整汇率的小时。粒度：币种。
-- 用同一组汇率折算所有时刻的盈亏，就能把"汇率变动带来的盈亏"单独分出来。

select ccy, rate_to_eur, snap_time as as_of
from {{ ref('fx_rate_hourly') }}
where snap_time = (select min(snap_time) from {{ ref('fx_rate_hourly') }})
