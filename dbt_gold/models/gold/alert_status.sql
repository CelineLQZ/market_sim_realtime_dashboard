-- 两条预警规则的当前状态。阈值在 seeds/alert_rules.csv 里改。粒度：规则 x 范围。
--
-- dbt 每次运行只能看到"现在"，所以这里只判断当前值落在哪个区间：
--   firing  ：越过触发阈值
--   ok      ：回到解除阈值以内
--   holding ：在两个阈值之间 —— 保持上一次的状态，避免在阈值附近来回跳
-- "什么时候触发、什么时候解除"的历史由 snapshots/snap_alert_status 记录。
-- 两条规则都用"占总敞口的百分比"（负数 = 亏损）；总敞口不到 100 万欧元时百分比没有意义，不评估。

with gross as (
    select sum(abs(mv_eur)) as gross_eur
    from {{ ref('live_state') }}
),

checks as (
    -- 组合层：现在的总盈亏比历史最高点低了多少
    select
        'drawdown'  as rule_id,
        'portfolio' as scope,
        (live.total_eur - greatest(hist.peak_eur, live.total_eur)) / g.gross_eur * 100 as value_pct
    from (select sum(total_eur) as total_eur from {{ ref('live_state') }}) live,
         (select greatest(0, max(total_eur)) as peak_eur from {{ ref('portfolio_hourly') }}) hist,
         gross g
    where exists (select 1 from {{ ref('portfolio_hourly') }})

    union all

    -- 股票层：单只股票的总盈亏
    select
        'stock_loss',
        i.short_name,
        l.total_eur / g.gross_eur * 100
    from {{ ref('live_state') }} l
    join {{ source('clean', 'instruments') }} i using (instrument_id)
    cross join gross g
)

select
    c.rule_id || ':' || c.scope  as alert_key,
    c.rule_id,
    c.scope,
    round(c.value_pct, 3)        as value_pct,
    r.threshold,
    r.clear_threshold,
    r.severity,
    case
        when c.value_pct <= -r.threshold       then 'firing'
        when c.value_pct >  -r.clear_threshold then 'ok'
        else 'holding'
    end                          as status
from checks c
join {{ ref('alert_rules') }} r using (rule_id)
where (select gross_eur from gross) >= 1000000
