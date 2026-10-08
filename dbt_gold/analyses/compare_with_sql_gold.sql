-- 对比 dbt 版（gold_dbt）和手写版（gold）在共同时间范围内的结果。每行一张表：差异行数应该都是 0。
-- 运行：dbt compile --select compare_with_sql_gold
--      psql marketsim -f target/compiled/market_gold/analyses/compare_with_sql_gold.sql

select 'position_state' as table_name, count(*) as mismatched_rows
from {{ ref('int_positions') }} d
full join gold.position_state g using (trade_id)
where d.trade_id is null or g.trade_id is null
   or d.qty_after <> g.qty_after
   or abs(d.avg_cost - g.avg_cost) > 1e-9
   or abs(d.realized_cum - g.realized_cum) > 1e-6

union all

select 'stock_hourly', count(*)
from {{ ref('stock_hourly') }} d
join gold.stock_hourly g using (snap_time, instrument_id)
where abs(d.total_eur - g.total_eur) > 1e-6
   or abs(d.total_eur_cfx - g.total_eur_cfx) > 1e-6
   or d.position <> g.position

union all

select 'portfolio_hourly', count(*)
from {{ ref('portfolio_hourly') }} d
join gold.portfolio_hourly g using (snap_time)
where abs(d.total_eur - g.total_eur) > 1e-6
   or abs(d.drawdown_eur - g.drawdown_eur) > 1e-6
   or abs(d.gross_eur - g.gross_eur) > 1e-6

union all

select 'fx_rate_hourly', count(*)
from {{ ref('fx_rate_hourly') }} d
join gold.fx_rate_hourly g using (snap_time, ccy)
where abs(d.rate_to_eur - g.rate_to_eur) > 1e-12
