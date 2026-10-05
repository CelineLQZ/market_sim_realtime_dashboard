-- 参考数据：把 instruments.csv 载入数据库（一次性，可重复执行）
-- 运行：在 market-sim 文件夹里执行  psql marketsim -f sql/01_instruments.sql

create schema if not exists clean;

-- 每个股票/汇率一行，是后面 trades 和 prices 的"说明书"（维度表）
create table if not exists clean.instruments (
    instrument_id uuid primary key,
    long_name     text,
    short_name    text,
    country       text,
    sector        text,
    industry      text,
    exchange      text,
    type          text,     -- equity 或 currency（汇率）
    currency      text
);

-- 清空和导入放在同一个事务里：truncate 会锁住这张表直到提交，所以 processor 同时在跑时，
-- 它要么等一下，要么看到完整的新数据，不会撞上"表是空的"那一瞬间而把行误判成未知标的。
begin;
truncate clean.instruments;                                   -- 先清空，重复执行不会出现重复行
\copy clean.instruments from 'data/instruments.csv' csv header   -- 把 CSV 读进表（第一行是列名，跳过）
commit;
