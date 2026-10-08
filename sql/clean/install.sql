-- Clean layer: tables, views, functions and reference data. Safe to repeat (existing tables and data are untouched; re-run after changing function logic).
--   Run (project root): psql marketsim -v ON_ERROR_STOP=1 -f sql/clean/install.sql
--   Process new data:   psql marketsim -c "select * from clean.run()"      (the processor calls it every 5 s)
--   Recompute from scratch: sql/clean/backfill.sql
--
-- Included in order (\ir = path relative to this file):
\ir 01_instruments.sql
\ir 02_exchange_sessions.sql
\ir 03_tables.sql
\ir 04_parse.sql
\ir 05_run.sql
