-- Backfill: drop the clean layer and recompute everything from the first raw row
--
-- When to use:
--   1. the cleaning rules changed (e.g. a new check) and history must be reprocessed under the new rules
--   2. the clean table structure changed (e.g. a new primary key); create table if not exists does not alter existing tables
--   3. an earlier processing error needs to be repaired
-- Not for daily use; daily runs only need: select * from clean.run();
--
-- Run (from the project root, because of the relative paths below):
--   psql marketsim -v ON_ERROR_STOP=1 -f sql/clean/backfill.sql
--
-- Safety: only clean-layer tables are dropped; raw data is never touched;
--         clean.instruments (the instrument table) is not touched either, it is managed by sql/clean/01_instruments.sql.
-- Every clean row can be recomputed from raw, so dropping and rebuilding is safe.
 
drop table if exists clean.trades;
drop table if exists clean.prices;
drop table if exists clean.dead_letter;
drop table if exists clean.process_state;   -- progress back to zero: the next step starts from the first raw row
 
-- Recreate tables, views and functions (structure only, no data processing), then call clean.run().
-- Because the progress table is new, it treats all raw rows as "new data".
\ir 03_tables.sql
\ir 04_parse.sql
\ir 05_run.sql
select * from clean.run();
