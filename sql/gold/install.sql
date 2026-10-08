-- Gold layer: the tables the dashboard reads, and the functions that build them from clean
--
-- Tables
--   gold.fx_rate_hourly    one FX rate per currency and hour
--   gold.position_state    position, average cost and cumulative realized P&L after each trade (local currency)
--   gold.stock_hourly      core fact table: instrument x hour (position, price, P&L in local currency and EUR)
--   gold.portfolio_hourly  whole portfolio: P&L per hour
--   gold.live_state        one "current state" row per instrument, rewritten on every run (the live cards read it)
--   gold.process_state     progress: how far into clean we have read, and the event-time watermark
--
-- Functions
--   gold.run()             the entry point; processes new data incrementally (called in a loop)
--   gold.apply_new_trades / gold.rebuild_hourly / gold.refresh_live   used inside run()
--   gold.fx_rates_at / gold.value_position   FX and valuation formulas shared by the hourly and live paths
--   gold.rebuild_fx_hourly / rebuild_stock_hourly / rebuild_portfolio_hourly   the three independently testable hourly steps
--
-- Run: psql marketsim -v ON_ERROR_STOP=1 -f sql/gold/install.sql     (creates tables and functions; safe to repeat)
--      psql marketsim -c "select * from gold.run()"                   (process new data)

-- The code is split by responsibility under sql/gold/ and included in order (\ir = path relative to this file):
\ir 01_tables.sql
\ir 02_valuation.sql
\ir 02_positions.sql
\ir 03_hourly.sql
\ir 04_live.sql
\ir 05_run.sql
