-- gold 层 · 1/6 表
-- 看板直接读取的表。表之间的关系见 README 的数据模型图。

create schema if not exists gold;

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
    threshold       numeric not null,          -- 触发阈值：占总敞口的百分比
    clear_threshold numeric not null,          -- 解除阈值：回到这里才算解除，避免在阈值附近反复触发
    severity        text    not null,
    unit            text                       -- '%gross' = 占总敞口的百分比
);
-- 阈值按"模拟器默认参数（做市策略）下的正常波动"校准；重跑脚本不会改回你调过的值
insert into gold.alert_rules (rule_id, description, threshold, clear_threshold, severity, unit) values
    ('drawdown',   'Total P&L fell from its peak (% of gross exposure)',  0.6,  0.4, 'high',   '%gross'),
    ('stock_loss', 'One stock total P&L below -x% of gross exposure',     0.3,  0.2, 'medium', '%gross')
on conflict (rule_id) do nothing;

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

-- 只保留两条最重要的规则；旧版本留下的其他规则和它们的预警记录一并清掉
delete from gold.alerts      where rule_id not in ('drawdown', 'stock_loss');
delete from gold.alert_rules where rule_id not in ('drawdown', 'stock_loss');

create table if not exists gold.process_state (
    id          int primary key default 1 check (id = 1),
    last_raw_id bigint      not null default 0,    -- 已处理到 clean 的哪一行（和 clean.process_state 同一个刻度）
    as_of       timestamptz,
    updated_at  timestamptz not null default now()
);
insert into gold.process_state (id) values (1) on conflict do nothing;
