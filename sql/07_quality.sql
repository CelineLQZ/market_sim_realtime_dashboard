-- 数据质量视图：给质量看板用（/api/quality/*）。只读，不存数据。
-- 运行：psql marketsim -f sql/07_quality.sql      （make schema 会自动运行）

-- 迟到事件：同一个标的里，这一条的事件时间比"先到的某一条"还早，就是迟到。
-- 迟到多久 = 先到的最晚事件时间 - 这一条的事件时间（模拟时间，不是真实时间）。
create or replace view clean.v_late as
select 'trade' as kind, raw_id, instrument_id, event_time, late_by
from (
    select raw_id, instrument_id, event_time,
           max(event_time) over (partition by instrument_id order by raw_id
                                 rows between unbounded preceding and 1 preceding) - event_time as late_by
    from clean.trades
) t where late_by > interval '0'
union all
select 'price', raw_id, instrument_id, event_time, late_by
from (
    select raw_id, instrument_id, event_time,
           max(event_time) over (partition by instrument_id order by raw_id
                                 rows between unbounded preceding and 1 preceding) - event_time as late_by
    from clean.prices
) p where late_by > interval '0';
