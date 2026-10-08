-- Backfill the gold layer: clear gold's computed results and recompute from the first clean row.
--
-- When to use: after changing formulas or gold table structure, or after a clean-layer backfill.
-- Not for daily use; daily runs call: select * from gold.run();
-- Run (project root): psql marketsim -v ON_ERROR_STOP=1 -f sql/gold/backfill.sql
--
-- Safety: only gold's computed tables are touched.

truncate gold.fx_rate_hourly, gold.position_state, gold.stock_hourly,
         gold.portfolio_hourly, gold.live_state;
update gold.process_state
set last_raw_id = 0, watermark = '-infinity', too_late_total = 0, as_of = null, updated_at = now();

select * from gold.run();
