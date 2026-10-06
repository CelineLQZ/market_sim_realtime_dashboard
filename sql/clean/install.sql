-- clean 层：建表、视图、函数，载入参考数据。可以反复运行（已经存在的表和数据不会动；改了函数逻辑后重新运行即可生效）。
--   运行（项目根目录）：psql marketsim -v ON_ERROR_STOP=1 -f sql/clean/install.sql
--   处理新数据：        psql marketsim -c "select * from clean.run()"      （processor 每 5 秒调用一次）
--   从头重算：          sql/clean/backfill.sql
--
-- 按顺序引入（\ir = 相对本文件的路径）：
\ir 01_instruments.sql
\ir 02_exchange_sessions.sql
\ir 03_tables.sql
\ir 04_parse.sql
\ir 05_run.sql
