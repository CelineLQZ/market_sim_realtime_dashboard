-- clean 层（增量版）：建表、视图、函数 clean.run()
--   每次 clean.run()，只处理上次之后新到达 raw.events 的行
--   好的 trade  -> clean.trades
--   好的 price  -> clean.prices
--   坏的行      -> clean.dead_letter（原文 + 原因）
--   同一标的同一时刻、价格却不同的报价 -> 先到的进 clean.prices，后到的进 dead_letter（conflicting_price）
--
-- 这个文件只负责"建好东西"，不处理数据。分两步用：
--   1. 建表和函数（可以反复运行，已经存在的表和里面的数据不会动；改了函数逻辑后重新运行即可生效）：
--        psql marketsim -v ON_ERROR_STOP=1 -f sql/02_clean.sql
--   2. 处理新数据（日常运行，没有新数据时什么都不会改变；由 processor 每 5 秒调用一次）：
--        psql marketsim -c "select * from clean.run()"
--   想把 clean 层从头重算（清洗规则改了、改了表结构、修复错误）：运行 sql/03_backfill.sql

-- ============ 1. 建表（已经存在就跳过，不会动里面的数据） ============
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

-- 运行日志：每次 clean.run() 处理了新行就记一行。质量看板用它来展示"进来多少、拒绝多少、重复多少"。
create table if not exists clean.run_log (
    run_id             bigserial primary key,
    run_at             timestamptz not null default now(),   -- 真实时间
    from_raw_id        bigint not null,
    to_raw_id          bigint not null,
    raw_rows           bigint not null,
    bad_rows           bigint not null,                      -- 格式或取值有问题的行
    kept_rows          bigint not null,
    conflicting_prices bigint not null,
    duplicates_dropped bigint not null,
    balanced           boolean not null                      -- 对账是否平了
);
create index if not exists clean_run_log_at on clean.run_log (run_at);

-- ============ 2. 解析和检查（用一个视图把逻辑集中在一处） ============
-- 视图只是一段"保存下来的查询"，本身不存数据。下面用的时候会加上 raw_id 范围，所以只会解析新行。
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
           when s.type = 'trade' and s.currency is distinct from i.currency then 'currency_mismatch'  -- 币种和标的自己的币种不一致（null 也算不一致）
       end as reason
from step2 s
left join clean.instruments i on i.instrument_id = s.instrument_id;

-- ============ 3. 处理新数据：clean.run() ============
-- 函数是一个整体：要么全部成功，要么全部不算（和以前 begin ... commit 的效果一样）。
-- 返回一行对账结果：处理了哪段 raw_id、每一类各多少行、是否对平（balanced）。
create or replace function clean.run(
    out from_raw_id        bigint,
    out to_raw_id          bigint,
    out raw_rows           bigint,
    out bad_rows           bigint,
    out good_rows          bigint,
    out kept_rows          bigint,
    out conflicting_prices bigint,
    out duplicates_dropped bigint,
    out balanced           boolean
) language plpgsql as $$
declare
    v_lo bigint;   -- 上次处理到哪里（来自进度表）
    v_hi bigint;   -- 现在 raw 里最大的 raw_id
begin
    -- 圈定本次要处理的范围：(v_lo, v_hi] ，即 raw_id 大于 v_lo 且不超过 v_hi。
    -- 先固定 v_hi：运行期间 ingest 又写进来的新行，留给下一次。
    -- for update 把进度行锁住：如果同时有两个 clean.run() 在跑，后来的会等前一个跑完，
    -- 然后从更新后的进度接着处理，不会重复处理同一段，也就不需要额外的锁。
    select s.last_raw_id into v_lo from clean.process_state s where s.id = 1 for update;
    select greatest(v_lo, coalesce(max(e.raw_id), 0)) into v_hi from raw.events e;

    -- ---- 分流写入 ----
    -- on conflict do nothing：主键已经存在就跳过，这就是"去重"。主键覆盖所有历史行，
    -- 所以第二天到达的重复消息，也会和前几天写入的行冲突并被去掉。
    -- order by raw_id：同一批里重复的行，保留最早到达的那一行。
    insert into clean.trades (trade_id, instrument_id, event_time, price, volume, side, currency, raw_id)
    select trade_id, instrument_id, event_time, price, volume, side, currency, raw_id
    from clean.v_parsed
    where reason is null and type = 'trade'
      and raw_id >  v_lo
      and raw_id <= v_hi
    order by raw_id
    on conflict do nothing;

    insert into clean.prices (instrument_id, event_time, price, raw_id)
    select instrument_id, event_time, price, raw_id
    from clean.v_parsed
    where reason is null and type = 'price'
      and raw_id >  v_lo
      and raw_id <= v_hi
    order by raw_id
    on conflict do nothing;

    -- 坏行：格式或取值有问题的行
    insert into clean.dead_letter (raw_id, reason, payload, received_at)
    select raw_id, reason, payload, received_at
    from clean.v_parsed
    where reason is not null
      and raw_id >  v_lo
      and raw_id <= v_hi
    on conflict do nothing;

    -- 冲突的报价：同一标的、同一时刻已经有一个价格了（可能是今天的，也可能是前几天留下的），而这一条的价格不一样。
    -- 价格也一样的是"完全重复"，上面的 on conflict 已经安静地去掉了，不算冲突，不进 dead_letter。
    insert into clean.dead_letter (raw_id, reason, payload, received_at)
    select v.raw_id, 'conflicting_price', v.payload, v.received_at
    from clean.v_parsed v
    join clean.prices p on p.instrument_id = v.instrument_id and p.event_time = v.event_time
    where v.reason is null and v.type = 'price'
      and v.raw_id >  v_lo
      and v.raw_id <= v_hi
      and v.raw_id <> p.raw_id          -- 不是留下来的那一条本身
      and v.price   <> p.price          -- 价格不同，才算冲突
    on conflict do nothing;

    -- 记下"处理到哪里了"。和上面的写入在同一个事务里，所以不会出现"写入了但进度没更新"。
    update clean.process_state set last_raw_id = v_hi, updated_at = now() where id = 1;

    -- ---- 对账：本次处理的每一行 raw 都要有去处 ----
    -- 第一层：本次的 raw 行数 = 坏行 + 好行
    -- 第二层：好行 = 新保留 + 冲突报价 + 完全重复（三个数分别独立数出来，不是用减法凑的）
    with raw_new as (
        select e.raw_id from raw.events e where e.raw_id > v_lo and e.raw_id <= v_hi
    ),
    good as (
        select v.* from clean.v_parsed v
        where v.reason is null and v.raw_id > v_lo and v.raw_id <= v_hi
    ),
    bad as (
        select d.raw_id from clean.dead_letter d
        where d.reason <> 'conflicting_price' and d.raw_id > v_lo and d.raw_id <= v_hi
    ),
    confl as (
        select d.raw_id from clean.dead_letter d
        where d.reason = 'conflicting_price' and d.raw_id > v_lo and d.raw_id <= v_hi
    ),
    kept as (
        select t.raw_id from clean.trades t where t.raw_id > v_lo and t.raw_id <= v_hi
        union all
        select p.raw_id from clean.prices p where p.raw_id > v_lo and p.raw_id <= v_hi
    ),
    dups as (
        select g.raw_id from good g join clean.trades t on t.trade_id = g.trade_id
        where g.type = 'trade' and g.raw_id <> t.raw_id
        union all
        select g.raw_id from good g
        join clean.prices p on p.instrument_id = g.instrument_id and p.event_time = g.event_time
        where g.type = 'price' and g.raw_id <> p.raw_id and g.price = p.price
    )
    select v_lo + 1,
           v_hi,
           (select count(*) from raw_new),
           (select count(*) from bad),
           (select count(*) from good),
           (select count(*) from kept),
           (select count(*) from confl),
           (select count(*) from dups),
           (select count(*) from raw_new) = (select count(*) from bad) + (select count(*) from good)
           and (select count(*) from good) = (select count(*) from kept) + (select count(*) from confl)
                                           + (select count(*) from dups)
    into from_raw_id, to_raw_id, raw_rows, bad_rows, good_rows, kept_rows,
         conflicting_prices, duplicates_dropped, balanced;

    if raw_rows > 0 then
        insert into clean.run_log (from_raw_id, to_raw_id, raw_rows, bad_rows, kept_rows, conflicting_prices, duplicates_dropped, balanced)
        values (from_raw_id, to_raw_id, raw_rows, bad_rows, kept_rows, conflicting_prices, duplicates_dropped, balanced);
    end if;
end;
$$;
