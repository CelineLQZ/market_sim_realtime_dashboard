-- 回填（backfill）：把 clean 层删掉，从 raw 的第一行开始全部重算一遍
--
-- 什么时候用：
--   1. 清洗规则改了（比如新增了一种检查），历史数据要按新规则重新处理
--   2. 改了 clean 表的结构（比如换主键），create table if not exists 不会修改已有的表
--   3. 发现之前处理有错，需要修复
-- 日常不要用，日常运行 select * from clean.run(); 就够了。
--
-- 运行（必须在项目根目录，因为下面用相对路径）：
--   psql marketsim -v ON_ERROR_STOP=1 -f sql/03_backfill.sql
--
-- 安全性：只删 clean 层的表，raw 层的原始数据一行都不会动；
--         clean.instruments（股票说明表）也不会动，它由 01_instruments.sql 管。
-- clean 层的每一行都能从 raw 重新算出来，所以删了可以重建。
 
drop table if exists clean.trades;
drop table if exists clean.prices;
drop table if exists clean.dead_letter;
drop table if exists clean.process_state;   -- 进度归零：下一步会从 raw 的第一行开始处理
 
-- 重新建表和函数（02 只建东西，不处理数据），然后调用 clean.run()。
-- 因为进度表是新建的，所以它会把全部 raw 行当作"新数据"处理。
\i sql/02_clean.sql
select * from clean.run();
