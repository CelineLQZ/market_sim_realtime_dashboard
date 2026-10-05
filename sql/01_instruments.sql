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

truncate clean.instruments;                                   -- 先清空，重复执行不会出现重复行
\copy clean.instruments from 'data/instruments.csv' csv header   -- 把 CSV 读进表（第一行是列名，跳过）
