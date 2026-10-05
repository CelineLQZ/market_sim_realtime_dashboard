-- clean 层：把 raw.events 里的原始行，解析、检查、去重，分流到三张表
--   好的 trade  -> clean.trades
--   好的 price  -> clean.prices
--   坏的行      -> clean.dead_letter（原文 + 原因）
-- 运行：psql marketsim -f sql/02_clean.sql    （可以重复执行，结果不变）

-- ============ 1. 建表 ============
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
    primary key (instrument_id, event_time, price)   -- 报价没有自己的 id，所以三个字段合起来当主键
);

create table if not exists clean.dead_letter (
    raw_id      bigint primary key,          -- 每条坏行只记一次
    reason      text        not null,        -- 为什么是坏的
    payload     text        not null,        -- 原文，一个字都不改
    received_at timestamptz not null
);

-- ============ 2. 解析和检查（用一个视图把逻辑集中在一处） ============
create or replace view clean.v_parsed as
with step1 as (      -- 第 1 步：这一行能不能解析成 JSON？（乱码行在这里变成 null）
    select raw_id, received_at, payload,
           case when pg_input_is_valid(payload, 'jsonb') then payload::jsonb end as j
    from raw.events
),
step2 as (           -- 第 2 步：取出字段并转成正确类型；取不到或格式不对的，结果是 null
    select raw_id, received_at, payload, j,
           j->>'type'                                                       as type,
           j->'data'->>'side'                                               as side,
           j->'data'->>'currency'                                           as currency,
           case when pg_input_is_valid(j->'data'->>'trade_id', 'uuid')
                then (j->'data'->>'trade_id')::uuid end                     as trade_id,
           case when pg_input_is_valid(j->'data'->>'instrument_id', 'uuid')
                then (j->'data'->>'instrument_id')::uuid end                as instrument_id,
           case when pg_input_is_valid(j->'data'->>'price', 'numeric')
                then (j->'data'->>'price')::numeric end                     as price,
           case when pg_input_is_valid(j->'data'->>'volume', 'bigint')
                then (j->'data'->>'volume')::bigint end                     as volume,
           case when pg_input_is_valid(j->'data'->>'date', 'timestamptz')
                then (j->'data'->>'date')::timestamptz end                  as event_time
    from step1
)
select s.raw_id, s.received_at, s.payload, s.type, s.trade_id, s.instrument_id,
       s.price, s.volume, s.side, s.currency, s.event_time,
       -- 第 3 步：判断坏在哪里。case 从上往下，遇到第一个成立的就停，所以一行只会有一个原因。
       -- reason 为 null 表示这一行是好的。
       case
           when s.j is null                                   then 'not_json'            -- 格式问题
           when s.type is null or s.type not in ('trade','price') then 'unknown_type'
           when s.instrument_id is null                       then 'bad_instrument_id'
           when s.event_time is null                          then 'bad_date'
           when s.price is null                               then 'null_price'          -- 值的问题
           when s.price <= 0                                  then 'non_positive_price'
           when s.type = 'trade' and s.trade_id is null       then 'bad_trade_id'
           when s.type = 'trade' and (s.volume is null or s.volume <= 0) then 'bad_volume'
           when s.type = 'trade' and s.side is null           then 'bad_side'
           when s.type = 'trade' and s.side not in ('BUY','SELL') then 'bad_side'
           when i.instrument_id is null                       then 'unknown_instrument'  -- 关联问题：dim 表里查不到
       end as reason
from step2 s
left join clean.instruments i on i.instrument_id = s.instrument_id;

-- ============ 3. 分流写入 ============
-- on conflict do nothing：主键已经存在就跳过，这就是"去重"。
-- order by raw_id：重复的行里，保留最早到达的那一行。
insert into clean.trades (trade_id, instrument_id, event_time, price, volume, side, currency, raw_id)
select trade_id, instrument_id, event_time, price, volume, side, currency, raw_id
from clean.v_parsed
where reason is null and type = 'trade'
order by raw_id
on conflict do nothing;

insert into clean.prices (instrument_id, event_time, price, raw_id)
select instrument_id, event_time, price, raw_id
from clean.v_parsed
where reason is null and type = 'price'
order by raw_id
on conflict do nothing;

insert into clean.dead_letter (raw_id, reason, payload, received_at)
select raw_id, reason, payload, received_at
from clean.v_parsed
where reason is not null
on conflict do nothing;

-- ============ 4. 对账：每一行 raw 都要有去处 ============
select
    (select count(*) from raw.events)                          as raw_rows,
    (select count(*) from clean.dead_letter)                   as bad_rows,
    (select count(*) from clean.v_parsed where reason is null) as good_rows,
    (select count(*) from clean.trades) + (select count(*) from clean.prices) as kept_rows,
    (select count(*) from clean.v_parsed where reason is null)
      - (select count(*) from clean.trades) - (select count(*) from clean.prices) as duplicates_dropped,
    (select count(*) from raw.events)
      = (select count(*) from clean.dead_letter)
      + (select count(*) from clean.v_parsed where reason is null) as balanced;
