-- clean 层 · 5/5 入口
-- clean.run()：只处理上次之后新到达 raw.events 的行，分流到 trades / prices / dead_letter，并对账。
--   好的 trade  -> clean.trades
--   好的 price  -> clean.prices
--   坏的行      -> clean.dead_letter（原文 + 原因）
--   同一标的同一时刻、价格却不同的报价 -> 先到的进 clean.prices，后到的进 dead_letter（conflicting_price）

-- ============ 处理新数据：clean.run() ============
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

end;
$$;
