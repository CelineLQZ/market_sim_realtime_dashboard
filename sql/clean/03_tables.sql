-- clean 层 · 3/5 表
-- 好的成交和报价、被拒绝的行、处理进度。已经存在的表不会动，里面的数据也不会动。

create schema if not exists clean;

create table if not exists clean.trades (
    trade_id      uuid primary key,          -- 主键：同一个 trade_id 只能有一行，重复消息靠它去掉
    instrument_id uuid        not null,
    event_time    timestamptz not null,      -- 消息里的事件时间（模拟时间）
    price         numeric     not null,
    volume        bigint      not null,
    side          text        not null,      -- BUY 或 SELL
    currency      text        not null,
    raw_id        bigint      not null       -- 来自 raw.events 的哪一行（方便追溯）
);

create table if not exists clean.prices (
    instrument_id uuid        not null,
    event_time    timestamptz not null,
    price         numeric     not null,
    raw_id        bigint      not null,
    primary key (instrument_id, event_time)   -- 报价没有自己的 id：同一标的、同一时刻只保留一个价格
);

create table if not exists clean.dead_letter (
    raw_id      bigint primary key,          -- 每条坏行只记一次
    reason      text        not null,        -- 为什么是坏的
    payload     text        not null,        -- 原文，一个字都不改
    received_at timestamptz not null
);

-- 进度表：永远只有一行，记录"raw_id 处理到多少了"。下次运行从它后面接着处理。
create table if not exists clean.process_state (
    id          int primary key default 1 check (id = 1),   -- check 保证只能有这一行
    last_raw_id bigint      not null default 0,
    updated_at  timestamptz not null default now()
);
insert into clean.process_state (id) values (1) on conflict do nothing;
