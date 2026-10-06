-- gold 层：看板直接读取的表，以及把 clean 层算成这些表的函数
--
-- 表（对应看板的各个模块）
--   gold.fx_reference     固定参考汇率（Constant FX 用），只写一次
--   gold.fx_rate_hourly   每小时一个汇率：币种 x 小时
--   gold.position_state   每笔成交之后的持仓、平均成本、累计已实现盈亏（本币）
--   gold.stock_hourly     核心事实表：标的 x 小时（持仓、价格、盈亏，本币 + 两种口径的欧元）
--   gold.portfolio_hourly 全组合：每小时的盈亏、敞口、历史最高点和回撤
--   gold.live_state       每个标的一行的"当前状态"，每次运行覆盖写（实时模块读它）
--   gold.alert_rules      预警规则（阈值可以改）
--   gold.alerts           预警事件：触发时间、解除时间
--   gold.process_state    进度：处理到 clean 的哪一行
--
-- 函数
--   gold.run()            日常运行入口，增量处理新数据（实时循环里反复调用）
--   gold.nightly_fix(t)   收盘后批处理：从 t 起重算小时快照，补上迟到的报价
--   gold.apply_new_trades / gold.rebuild_hourly / gold.refresh_live / gold.evaluate_alerts   run() 内部用
--
-- 运行：psql marketsim -v ON_ERROR_STOP=1 -f sql/05_gold.sql     （建表和函数，可重复运行）
--       psql marketsim -c "select * from gold.run()"             （处理新数据）

create schema if not exists gold;

-- ============ 1. 表 ============
create table if not exists gold.fx_reference (
    ccy         text primary key,
    rate_to_eur numeric     not null,        -- 1 单位该币种 = 多少欧元
    as_of       timestamptz not null
);

create table if not exists gold.fx_rate_hourly (
    snap_time   timestamptz not null,
    ccy         text        not null,
    rate_to_eur numeric     not null,
    primary key (snap_time, ccy)
);

create table if not exists gold.position_state (
    trade_id      uuid primary key,
    instrument_id uuid        not null,
    event_time    timestamptz not null,
    raw_id        bigint      not null,
    price         numeric     not null,
    signed_qty    numeric     not null,      -- 买为正，卖为负
    qty_after     numeric     not null,      -- 这笔成交之后的持仓（空头为负）
    avg_cost      numeric     not null,      -- 这笔成交之后的平均成本
    realized_delta numeric    not null,      -- 这笔成交实现的盈亏（本币）
    realized_cum  numeric     not null,      -- 该标的累计已实现盈亏（本币）
    unique (instrument_id, event_time, raw_id)
);
create index if not exists position_state_order on gold.position_state (instrument_id, event_time desc, raw_id desc);

create table if not exists gold.stock_hourly (
    snap_time          timestamptz not null,   -- 快照时刻：这个整点时的状态
    instrument_id      uuid        not null,
    position           numeric     not null,
    avg_cost           numeric     not null,
    price              numeric     not null,   -- 截至该时刻的最新报价
    price_time         timestamptz not null,
    realized_local     numeric     not null,   -- 本币
    unrealized_local   numeric     not null,
    mv_local           numeric     not null,   -- 持仓市值 = 持仓 x 价格
    fx_rate            numeric     not null,   -- 该时刻的汇率
    realized_eur       numeric     not null,   -- 市场汇率口径（每个时刻用当时的汇率）
    unrealized_eur     numeric     not null,
    total_eur          numeric     not null,
    mv_eur             numeric     not null,
    realized_eur_cfx   numeric     not null,   -- 固定汇率口径（Constant FX）
    unrealized_eur_cfx numeric     not null,
    total_eur_cfx      numeric     not null,
    primary key (snap_time, instrument_id)
);
create index if not exists stock_hourly_by_instrument on gold.stock_hourly (instrument_id, snap_time);

create table if not exists gold.portfolio_hourly (
    snap_time          timestamptz primary key,
    realized_eur       numeric not null,
    unrealized_eur     numeric not null,
    total_eur          numeric not null,
    realized_eur_cfx   numeric not null,
    unrealized_eur_cfx numeric not null,
    total_eur_cfx      numeric not null,
    long_mv_eur        numeric not null,
    short_mv_eur       numeric not null,       -- 负数
    gross_eur          numeric not null,
    net_eur            numeric not null,
    peak_total_eur     numeric,                -- 到这个时刻为止的历史最高总盈亏（起点 0）
    drawdown_eur       numeric                 -- 总盈亏 - 历史最高点，<= 0
);

create table if not exists gold.live_state (
    instrument_id    uuid primary key,
    position         numeric     not null,
    avg_cost         numeric     not null,
    last_price       numeric     not null,
    price_time       timestamptz not null,
    price_age_min    numeric     not null,     -- 距上次报价多少分钟（模拟时间）
    in_session       boolean     not null,
    realized_local   numeric     not null,
    unrealized_local numeric     not null,
    mv_local         numeric     not null,
    fx_rate          numeric     not null,
    realized_eur     numeric     not null,
    unrealized_eur   numeric     not null,
    total_eur        numeric     not null,
    mv_eur           numeric     not null,
    as_of            timestamptz not null,     -- 这批数字算到哪一条数据（模拟时间）
    realized_eur_cfx   numeric   not null default 0,   -- 固定汇率口径（Constant FX），和 stock_hourly 的同名列口径一致
    unrealized_eur_cfx numeric   not null default 0,
    total_eur_cfx      numeric   not null default 0
);
-- 旧版本建的表没有最后三列：补上（已经有就跳过）。live_state 每次运行都会整体重写，所以不需要迁移数据。
alter table gold.live_state add column if not exists realized_eur_cfx   numeric not null default 0;
alter table gold.live_state add column if not exists unrealized_eur_cfx numeric not null default 0;
alter table gold.live_state add column if not exists total_eur_cfx      numeric not null default 0;

create table if not exists gold.alert_rules (
    rule_id         text primary key,
    description     text    not null,
    threshold       numeric not null,          -- 触发阈值（单位见 unit）
    clear_threshold numeric not null,          -- 解除阈值：回到这里才算解除，避免在阈值附近反复触发
    severity        text    not null,
    unit            text                       -- '%gross' = 占总敞口的百分比；'%' = 百分比；'min' = 分钟
);
alter table gold.alert_rules add column if not exists unit text;

-- 旧版本的两条规则是欧元绝对值：发现 unit 为空就迁移成相对值，并清掉按旧口径产生的预警
do $$ begin
    if exists (select 1 from gold.alert_rules where rule_id in ('drawdown', 'unrealized_drop') and unit is null) then
        delete from gold.alerts where rule_id in ('drawdown', 'unrealized_drop');
        delete from gold.alert_rules where rule_id in ('drawdown', 'unrealized_drop');
    end if;
    update gold.alert_rules set unit = 'min' where rule_id = 'stale_price' and unit is null;
end $$;

-- 阈值按"模拟器默认参数（做市策略、坏行 1%）下的正常波动"校准；相对阈值不会因为组合变大变小而失效。
insert into gold.alert_rules (rule_id, description, threshold, clear_threshold, severity, unit) values
    ('drawdown',        'Total P&L fell from its peak (% of gross exposure)',            0.6,  0.4,  'high',   '%gross'),
    ('unrealized_drop', 'Unrealized P&L fell since last snapshot (% of gross exposure)', 0.2,  0.12, 'medium', '%gross'),
    ('stock_loss',      'One stock total P&L below -x% of gross exposure',               0.3,  0.2,  'medium', '%gross'),
    ('concentration',   'One stock market value above x% of gross exposure',             12,   10,   'high', '%gross'),
    ('price_jump',      'Latest quote moved more than x% from the previous one',         1.5,  1.0,  'low', '%'),
    ('bad_rows_spike',  'Rejected share of the last 1000 raw rows above x%',             3,    2,    'high',   '%'),
    ('stale_price',     'Price stale during trading session (minutes)',                  90,   60,   'low', 'min')
on conflict (rule_id) do nothing;     -- 阈值被你改过之后，重跑脚本不会改回去

create table if not exists gold.alerts (
    alert_id    bigserial primary key,
    rule_id     text        not null references gold.alert_rules,
    scope       text        not null,          -- 'portfolio' 或标的代码
    fired_at    timestamptz not null,          -- 模拟时间
    cleared_at  timestamptz,                   -- 空 = 仍在触发
    fired_value numeric     not null,
    last_value  numeric     not null,
    threshold   numeric     not null,
    severity    text        not null
);
create index if not exists alerts_open on gold.alerts (rule_id, scope) where cleared_at is null;

-- 运行日志：每次处理了新数据就记一行（没有新数据的空转不记）。质量看板用它来展示"处理了多少、迟到回放了多少次"。
create table if not exists gold.run_log (
    run_id             bigserial primary key,
    run_at             timestamptz not null default now(),   -- 真实时间
    from_raw_id        bigint      not null,
    to_raw_id          bigint      not null,
    instruments_touched int        not null,
    trades_replayed    int         not null,
    late_rewinds       int         not null,                 -- 事件时间比已处理的更早的成交：该标的从那个时间起被重放
    hours_rebuilt      int         not null,
    as_of              timestamptz,                          -- 模拟时间
    open_alerts        int         not null
);
create index if not exists gold_run_log_at on gold.run_log (run_at);

-- 修正记录：某个小时的总盈亏被重算后，数字变了多少（迟到成交回放、收盘后批处理）
create table if not exists gold.restatement (
    restated_id bigserial primary key,
    restated_at timestamptz not null default now(),          -- 真实时间
    snap_time   timestamptz not null,                        -- 被修正的是哪个小时（模拟时间）
    cause       text        not null,                        -- 'late_trade' 或 'nightly_fix'
    total_before numeric    not null,
    total_after  numeric    not null
);
create index if not exists gold_restatement_at on gold.restatement (restated_at);

create table if not exists gold.process_state (
    id          int primary key default 1 check (id = 1),
    last_raw_id bigint      not null default 0,    -- 已处理到 clean 的哪一行（和 clean.process_state 同一个刻度）
    as_of       timestamptz,
    updated_at  timestamptz not null default now()
);
insert into gold.process_state (id) values (1) on conflict do nothing;

-- ============ 2. 小工具：向上取整到整点 ============
create or replace function gold.ceil_hour(t timestamptz) returns timestamptz
language sql immutable as $$
    select case when t = date_trunc('hour', t) then t else date_trunc('hour', t) + interval '1 hour' end
$$;

-- ============ 3. 持仓状态：逐笔成交算平均成本 ============
-- 规则（平均成本法，支持空头，一笔成交可以跨过 0）：
--   同方向加仓：新平均成本 = 数量加权平均
--   反方向平仓：实现盈亏 = 平掉的数量 x (成交价 - 平均成本) x 原持仓方向；部分平仓不改变平均成本
--   跨过 0：先平掉原来的持仓，剩下的部分按成交价重新开仓
-- 迟到处理：新到的成交如果事件时间比已处理的更早，就从这个时间点起把该标的重放一遍。
create or replace function gold.apply_new_trades(p_lo bigint, p_hi bigint,
    out o_instruments int, out o_replayed int, out o_rewinds int, out o_from timestamptz)
language plpgsql as $$
declare
    inst record; f record;
    rt timestamptz; rr bigint; prev_max timestamptz;
    pos numeric; avg numeric; rc numeric; q numeric; closing numeric; rd numeric; newpos numeric;
begin
    o_instruments := 0; o_replayed := 0; o_rewinds := 0; o_from := null;
    for inst in select distinct instrument_id from clean.trades where raw_id > p_lo and raw_id <= p_hi loop
        -- 本次新到的成交里，排序键 (event_time, raw_id) 最小的一笔：从这里开始重放
        select event_time, raw_id into rt, rr from clean.trades
        where instrument_id = inst.instrument_id and raw_id > p_lo and raw_id <= p_hi
        order by event_time, raw_id limit 1;

        select max(event_time) into prev_max from gold.position_state where instrument_id = inst.instrument_id;
        if prev_max is not null and rt < prev_max then o_rewinds := o_rewinds + 1; end if;   -- 迟到
        o_from := least(coalesce(o_from, rt), rt);

        delete from gold.position_state
        where instrument_id = inst.instrument_id and (event_time, raw_id) >= (rt, rr);

        select qty_after, avg_cost, realized_cum into pos, avg, rc from gold.position_state
        where instrument_id = inst.instrument_id order by event_time desc, raw_id desc limit 1;
        pos := coalesce(pos, 0); avg := coalesce(avg, 0); rc := coalesce(rc, 0);

        for f in select trade_id, event_time, raw_id, price, volume, side from clean.trades
                 where instrument_id = inst.instrument_id and (event_time, raw_id) >= (rt, rr)
                 order by event_time, raw_id loop
            q := case when f.side = 'BUY' then f.volume else -f.volume end;
            rd := 0;
            if pos = 0 or sign(pos) = sign(q) then
                newpos := pos + q;
                avg := (abs(pos) * avg + abs(q) * f.price) / abs(newpos);
            else
                closing := least(abs(q), abs(pos));
                rd := closing * (f.price - avg) * sign(pos);
                newpos := pos + q;
                if newpos = 0 then avg := 0;
                elsif sign(newpos) <> sign(pos) then avg := f.price;
                end if;
            end if;
            pos := newpos; rc := rc + rd;
            insert into gold.position_state
                (trade_id, instrument_id, event_time, raw_id, price, signed_qty, qty_after, avg_cost, realized_delta, realized_cum)
            values (f.trade_id, inst.instrument_id, f.event_time, f.raw_id, f.price, q, pos, avg, rd, rc);
            o_replayed := o_replayed + 1;
        end loop;
        o_instruments := o_instruments + 1;
    end loop;
end $$;

-- ============ 4. 小时快照：重算从 p_from 起的所有小时 ============
-- 快照时刻 h 的状态 = 事件时间 <= h 的最新持仓、最新报价、最新汇率（"as-of"）。
-- 只生成周一到周五的小时。因为按事件时间取"最新"，迟到的旧报价也会在这里被正确放回去，
-- 所以重算（nightly_fix）可以修正历史。
drop function if exists gold.rebuild_hourly(timestamptz, timestamptz);
create or replace function gold.rebuild_hourly(p_from timestamptz, p_to timestamptz, p_cause text default null) returns int
language plpgsql as $$
declare
    n int;
    v_eurusd uuid; v_gbpusd uuid; v_usdjpy uuid;
begin
    p_from := date_trunc('hour', p_from);
    -- 指定了原因（日常迟到回放、收盘批处理）就先把旧的小时总盈亏留一份，重算后对比，数字变了的记进 gold.restatement
    drop table if exists _old_hours;
    if p_cause is not null then
        create temp table _old_hours as select snap_time, total_eur from gold.portfolio_hourly where snap_time >= p_from;
    end if;
    delete from gold.stock_hourly     where snap_time >= p_from;
    delete from gold.portfolio_hourly where snap_time >= p_from;
    delete from gold.fx_rate_hourly   where snap_time >= p_from;

    drop table if exists _h;
    create temp table _h as
    select h as snap_time from generate_series(p_from, date_trunc('hour', p_to), interval '1 hour') h
    where extract(isodow from h - interval '1 second') <= 5;      -- 周六 00:00 属于周五的最后一个快照

    -- 汇率：三个汇率标的各取最新报价，再经美元换成"1 单位币种 = 多少欧元"
    select instrument_id into v_eurusd from clean.instruments where short_name = 'EUR/USD';
    select instrument_id into v_gbpusd from clean.instruments where short_name = 'GBP/USD';
    select instrument_id into v_usdjpy from clean.instruments where short_name = 'USD/JPY';
    insert into gold.fx_rate_hourly (snap_time, ccy, rate_to_eur)
    select t.snap_time, v.ccy, v.rate
    from (
        select h.snap_time,
          (select price from clean.prices where instrument_id = v_eurusd and event_time <= h.snap_time order by event_time desc limit 1) as eurusd,
          (select price from clean.prices where instrument_id = v_gbpusd and event_time <= h.snap_time order by event_time desc limit 1) as gbpusd,
          (select price from clean.prices where instrument_id = v_usdjpy and event_time <= h.snap_time order by event_time desc limit 1) as usdjpy
        from _h h
    ) t
    cross join lateral (values ('EUR', 1::numeric), ('USD', 1 / t.eurusd), ('GBP', t.gbpusd / t.eurusd), ('JPY', 1 / t.usdjpy / t.eurusd)) v(ccy, rate)
    where t.eurusd is not null and t.gbpusd is not null and t.usdjpy is not null;

    -- 固定参考汇率 = 数据里第一个有完整汇率的小时。只写一次，之后不再改。
    insert into gold.fx_reference (ccy, rate_to_eur, as_of)
    select ccy, rate_to_eur, snap_time from gold.fx_rate_hourly
    where snap_time = (select min(snap_time) from gold.fx_rate_hourly)
    on conflict (ccy) do nothing;

    -- 标的 x 小时
    insert into gold.stock_hourly
    select h.snap_time, i.instrument_id,
           coalesce(ps.qty_after, 0), coalesce(ps.avg_cost, 0), px.price, px.event_time,
           coalesce(ps.realized_cum, 0),
           coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0)),
           coalesce(ps.qty_after, 0) * px.price,
           fx.rate_to_eur,
           coalesce(ps.realized_cum, 0) * fx.rate_to_eur,
           coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0)) * fx.rate_to_eur,
           (coalesce(ps.realized_cum, 0) + coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0))) * fx.rate_to_eur,
           coalesce(ps.qty_after, 0) * px.price * fx.rate_to_eur,
           coalesce(ps.realized_cum, 0) * ref.rate_to_eur,
           coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0)) * ref.rate_to_eur,
           (coalesce(ps.realized_cum, 0) + coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0))) * ref.rate_to_eur
    from _h h
    cross join clean.instruments i
    join lateral (select price, event_time from clean.prices p
                  where p.instrument_id = i.instrument_id and p.event_time <= h.snap_time
                  order by p.event_time desc limit 1) px on true
    left join lateral (select qty_after, avg_cost, realized_cum from gold.position_state s
                       where s.instrument_id = i.instrument_id and s.event_time <= h.snap_time
                       order by s.event_time desc, s.raw_id desc limit 1) ps on true
    join gold.fx_rate_hourly fx on fx.snap_time = h.snap_time and fx.ccy = i.currency
    join gold.fx_reference ref on ref.ccy = i.currency
    where i.type = 'equity';
    get diagnostics n = row_count;

    -- 全组合
    insert into gold.portfolio_hourly
        (snap_time, realized_eur, unrealized_eur, total_eur, realized_eur_cfx, unrealized_eur_cfx, total_eur_cfx,
         long_mv_eur, short_mv_eur, gross_eur, net_eur)
    select snap_time, sum(realized_eur), sum(unrealized_eur), sum(total_eur),
           sum(realized_eur_cfx), sum(unrealized_eur_cfx), sum(total_eur_cfx),
           sum(greatest(mv_eur, 0)), sum(least(mv_eur, 0)), sum(abs(mv_eur)), sum(mv_eur)
    from gold.stock_hourly where snap_time >= p_from group by snap_time;

    -- 历史最高点和回撤：要看所有更早的小时，所以对整张表做窗口
    update gold.portfolio_hourly p
    set peak_total_eur = w.pk, drawdown_eur = p.total_eur - w.pk
    from (select snap_time, greatest(0, max(total_eur) over (order by snap_time)) as pk from gold.portfolio_hourly) w
    where w.snap_time = p.snap_time and p.snap_time >= p_from;

    if p_cause is not null then
        insert into gold.restatement (snap_time, cause, total_before, total_after)
        select o.snap_time, p_cause, o.total_eur, nw.total_eur
        from _old_hours o join gold.portfolio_hourly nw using (snap_time)
        where abs(nw.total_eur - o.total_eur) >= 0.01;
        drop table if exists _old_hours;
    end if;
    drop table if exists _h;
    return n;
end $$;

-- ============ 5. 实时状态：每个标的一行，每次运行覆盖 ============
-- 价格取"事件时间最新"的报价，所以迟到的旧报价不会改变当前估值。
create or replace function gold.refresh_live() returns timestamptz
language plpgsql as $$
declare v_asof timestamptz;
        v_eurusd uuid; v_gbpusd uuid; v_usdjpy uuid;
        eurusd numeric; gbpusd numeric; usdjpy numeric;
begin
    select greatest((select max(event_time) from clean.prices), (select max(event_time) from clean.trades)) into v_asof;
    if v_asof is null then return null; end if;
    select instrument_id into v_eurusd from clean.instruments where short_name = 'EUR/USD';
    select instrument_id into v_gbpusd from clean.instruments where short_name = 'GBP/USD';
    select instrument_id into v_usdjpy from clean.instruments where short_name = 'USD/JPY';
    select price into eurusd from clean.prices where instrument_id = v_eurusd order by event_time desc limit 1;
    select price into gbpusd from clean.prices where instrument_id = v_gbpusd order by event_time desc limit 1;
    select price into usdjpy from clean.prices where instrument_id = v_usdjpy order by event_time desc limit 1;
    delete from gold.live_state;
    if eurusd is null or gbpusd is null or usdjpy is null then return v_asof; end if;

    -- 写明列名：旧表的新增列在最后，不能靠位置对应
    insert into gold.live_state
        (instrument_id, position, avg_cost, last_price, price_time, price_age_min, in_session,
         realized_local, unrealized_local, mv_local, fx_rate, realized_eur, unrealized_eur, total_eur, mv_eur, as_of,
         realized_eur_cfx, unrealized_eur_cfx, total_eur_cfx)
    select i.instrument_id, coalesce(ps.qty_after, 0), coalesce(ps.avg_cost, 0), px.price, px.event_time,
           extract(epoch from (v_asof - px.event_time)) / 60,
           exists (select 1 from clean.exchange_sessions s
                   where s.exchange = i.exchange and extract(isodow from v_asof) <= 5
                     and (v_asof at time zone 'UTC')::time >= s.open_utc and (v_asof at time zone 'UTC')::time < s.close_utc),
           coalesce(ps.realized_cum, 0),
           coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0)),
           coalesce(ps.qty_after, 0) * px.price,
           r.rate,
           coalesce(ps.realized_cum, 0) * r.rate,
           coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0)) * r.rate,
           (coalesce(ps.realized_cum, 0) + coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0))) * r.rate,
           coalesce(ps.qty_after, 0) * px.price * r.rate,
           v_asof,
           -- 固定汇率口径：用 gold.fx_reference 里的参考汇率（还没有参考汇率时，退回当前汇率）
           coalesce(ps.realized_cum, 0) * coalesce(ref.rate_to_eur, r.rate),
           coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0)) * coalesce(ref.rate_to_eur, r.rate),
           (coalesce(ps.realized_cum, 0) + coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0)))
               * coalesce(ref.rate_to_eur, r.rate)
    from clean.instruments i
    join lateral (select price, event_time from clean.prices p where p.instrument_id = i.instrument_id
                  order by p.event_time desc limit 1) px on true
    left join lateral (select qty_after, avg_cost, realized_cum from gold.position_state s
                       where s.instrument_id = i.instrument_id order by s.event_time desc, s.raw_id desc limit 1) ps on true
    join (values ('EUR', 1::numeric), ('USD', 1 / eurusd), ('GBP', gbpusd / eurusd), ('JPY', 1 / usdjpy / eurusd)) r(ccy, rate)
         on r.ccy = i.currency
    left join gold.fx_reference ref on ref.ccy = i.currency
    where i.type = 'equity';
    return v_asof;
end $$;

-- ============ 6. 预警：触发和解除分开，各有阈值 ============
create or replace function gold.evaluate_alerts() returns int
language plpgsql as $$
declare v_asof timestamptz; n int; v_gross numeric; v_ok boolean;
begin
    select max(as_of) into v_asof from gold.live_state;
    if v_asof is null then return 0; end if;

    drop table if exists _cand;
    create temp table _cand (rule_id text, scope text, value numeric, breached boolean, ok boolean);

    -- 相对口径的分母：总敞口（持仓市值绝对值之和）。太小（刚开盘、几乎没有仓位）时百分比没有意义，不评估。
    select coalesce(sum(abs(mv_eur)), 0) into v_gross from gold.live_state;
    v_ok := v_gross >= 1000000;

    -- 组合层：回撤、未实现盈亏下降（和最近一个已完成的小时快照比），都换成占总敞口的百分比（负数）
    if v_ok then
        insert into _cand
        select r.rule_id, 'portfolio', round(v.value / v_gross * 100, 3),
               v.value / v_gross * 100 <= -r.threshold, v.value / v_gross * 100 > -r.clear_threshold
        from gold.alert_rules r
        join (
            select 'drawdown' as rule_id, l.tot - greatest(pk.m, l.tot) as value
            from (select sum(total_eur) tot from gold.live_state) l,
                 (select greatest(0, coalesce(max(total_eur), 0)) m from gold.portfolio_hourly) pk
            where exists (select 1 from gold.portfolio_hourly)
            union all
            select 'unrealized_drop', l.unr - s.unrealized_eur
            from (select sum(unrealized_eur) unr from gold.live_state) l,
                 (select unrealized_eur from gold.portfolio_hourly order by snap_time desc limit 1) s
        ) v on v.rule_id = r.rule_id;

        -- 标的层：亏损过大（占总敞口的百分比）、集中度（市值占总敞口的百分比）
        insert into _cand
        select r.rule_id, i.short_name, round(l.total_eur / v_gross * 100, 3),
               l.total_eur / v_gross * 100 <= -r.threshold, l.total_eur / v_gross * 100 > -r.clear_threshold
        from gold.live_state l
        join clean.instruments i using (instrument_id)
        join gold.alert_rules r on r.rule_id = 'stock_loss';

        insert into _cand
        select r.rule_id, i.short_name, round(abs(l.mv_eur) / v_gross * 100, 2),
               abs(l.mv_eur) / v_gross * 100 >= r.threshold, abs(l.mv_eur) / v_gross * 100 < r.clear_threshold
        from gold.live_state l
        join clean.instruments i using (instrument_id)
        join gold.alert_rules r on r.rule_id = 'concentration';
    end if;

    -- 标的层：最新一条报价相对上一条报价跳了多少（%）
    insert into _cand
    select r.rule_id, i.short_name, round(abs(p.p1 / p.p0 - 1) * 100, 3),
           abs(p.p1 / p.p0 - 1) * 100 >= r.threshold, abs(p.p1 / p.p0 - 1) * 100 < r.clear_threshold
    from clean.instruments i
    join gold.alert_rules r on r.rule_id = 'price_jump'
    cross join lateral (
        select (array_agg(price order by event_time desc))[1] p1, (array_agg(price order by event_time desc))[2] p0
        from (select price, event_time from clean.prices where instrument_id = i.instrument_id
              order by event_time desc limit 2) q
    ) p
    where i.type = 'equity' and p.p0 is not null and p.p0 > 0;

    -- 数据层：最近 1000 条原始行里被拒绝的比例（%）
    insert into _cand
    select r.rule_id, 'pipeline', round(x.share, 2), x.share >= r.threshold, x.share < r.clear_threshold
    from gold.alert_rules r
    cross join lateral (
        select 100.0 * (select count(*) from clean.dead_letter d where d.raw_id > ps.last_raw_id - 1000)
               / greatest(least(ps.last_raw_id, 1000), 1) as share
        from clean.process_state ps
    ) x
    where r.rule_id = 'bad_rows_spike';

    -- 标的层：交易时段内价格太久没更新
    insert into _cand
    select r.rule_id, i.short_name, l.price_age_min,
           l.in_session and l.price_age_min > r.threshold,
           (not l.in_session) or l.price_age_min <= r.clear_threshold
    from gold.live_state l
    join clean.instruments i using (instrument_id)
    join gold.alert_rules r on r.rule_id = 'stale_price';

    update gold.alerts a set cleared_at = v_asof, last_value = c.value
    from _cand c where a.cleared_at is null and a.rule_id = c.rule_id and a.scope = c.scope and c.ok;

    update gold.alerts a set last_value = c.value
    from _cand c where a.cleared_at is null and a.rule_id = c.rule_id and a.scope = c.scope and not c.ok;

    insert into gold.alerts (rule_id, scope, fired_at, fired_value, last_value, threshold, severity)
    select c.rule_id, c.scope, v_asof, c.value, c.value, r.threshold, r.severity
    from _cand c join gold.alert_rules r using (rule_id)
    where c.breached and not exists (select 1 from gold.alerts a
                                     where a.cleared_at is null and a.rule_id = c.rule_id and a.scope = c.scope);

    select count(*) into n from gold.alerts where cleared_at is null;
    drop table if exists _cand;
    return n;
end $$;

-- ============ 7. 日常入口：增量处理 ============
create or replace function gold.run(
    out from_raw_id bigint, out to_raw_id bigint, out instruments_touched int, out trades_replayed int,
    out late_rewinds int, out hours_rebuilt int, out as_of timestamptz, out open_alerts int)
language plpgsql as $$
declare
    lo bigint; hi bigint; r record;
    v_from timestamptz; v_to timestamptz; first_unbuilt timestamptz;
begin
    -- for update 锁住进度行：同时有两个 gold.run()（或 nightly_fix）时，后来的会等前一个跑完，不会重复处理
    select last_raw_id into lo from gold.process_state for update;
    select last_raw_id into hi from clean.process_state;
    from_raw_id := lo + 1; to_raw_id := greatest(hi, lo);
    select * into r from gold.apply_new_trades(lo, to_raw_id);
    instruments_touched := r.o_instruments; trades_replayed := r.o_replayed; late_rewinds := r.o_rewinds;

    -- 需要重算的小时：还没算过的新小时，加上被迟到成交影响到的旧小时
    as_of := greatest((select max(event_time) from clean.prices), (select max(event_time) from clean.trades));
    v_to := date_trunc('hour', as_of);
    first_unbuilt := coalesce((select max(snap_time) + interval '1 hour' from gold.portfolio_hourly),
                              gold.ceil_hour((select min(event_time) from clean.prices)));
    v_from := first_unbuilt;
    if r.o_from is not null then v_from := least(v_from, gold.ceil_hour(r.o_from)); end if;
    hours_rebuilt := 0;
    if v_from <= v_to then
        perform gold.rebuild_hourly(v_from, v_to, case when r.o_rewinds > 0 then 'late_trade' end);
        select count(distinct snap_time) into hours_rebuilt from gold.stock_hourly where snap_time >= date_trunc('hour', v_from);
    end if;

    perform gold.refresh_live();
    open_alerts := gold.evaluate_alerts();

    update gold.process_state set last_raw_id = to_raw_id, as_of = run.as_of, updated_at = now();

    if to_raw_id >= from_raw_id then      -- 这一轮真的处理了新数据才记
        insert into gold.run_log (from_raw_id, to_raw_id, instruments_touched, trades_replayed, late_rewinds, hours_rebuilt, as_of, open_alerts)
        values (from_raw_id, to_raw_id, instruments_touched, trades_replayed, late_rewinds, hours_rebuilt, run.as_of, open_alerts);
    end if;
end $$;

-- ============ 8. 收盘后批处理：从某个时间起重算小时快照 ============
-- 日常的增量运行只修正"迟到的成交"。迟到的旧报价会改变历史上某些小时的估值，留给这里修正。
-- 用法：select gold.nightly_fix('2025-01-23');   -- 从这一天 00:00 起重算
create or replace function gold.nightly_fix(p_from timestamptz) returns int
language plpgsql as $$
declare v_to timestamptz;
begin
    perform 1 from gold.process_state for update;    -- 和 gold.run() 互斥：不会和日常增量同时重算小时快照
    v_to := date_trunc('hour', greatest((select max(event_time) from clean.prices), (select max(event_time) from clean.trades)));
    return gold.rebuild_hourly(p_from, v_to, 'nightly_fix');
end $$;
