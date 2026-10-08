-- Gold layer · 1/5 tables
-- The tables the dashboard reads. See the data-model diagram in the README.

create schema if not exists gold;

-- ============ Clean-up of the previous design (safe to run repeatedly) ============
-- Constant-FX columns, alerts, drawdown and exposure were removed, and gold.run() now works
-- with an event-time watermark. Old derived tables are dropped and rebuilt by the next gold.run().
drop function if exists gold.run();
drop function if exists gold.nightly_fix(timestamptz);
drop function if exists gold.evaluate_alerts();
drop function if exists gold.ceil_hour(timestamptz);
drop function if exists gold.apply_new_trades(bigint, bigint);
drop function if exists gold.value_position(numeric, numeric, numeric, numeric, numeric, numeric);
drop table if exists gold.alerts, gold.alert_rules, gold.fx_reference cascade;
do $$
begin
    if exists (select 1 from information_schema.columns
               where table_schema = 'gold' and column_name in ('total_eur_cfx', 'price_age_min')) then
        drop table if exists gold.stock_hourly, gold.portfolio_hourly, gold.live_state,
                             gold.position_state, gold.fx_rate_hourly cascade;
        if to_regclass('gold.process_state') is not null then
            delete from gold.process_state;
        end if;
    end if;
end $$;

-- ============ Tables ============
create table if not exists gold.fx_rate_hourly (
    snap_time   timestamptz not null,
    ccy         text        not null,
    rate_to_eur numeric     not null,          -- 1 unit of this currency = how many EUR
    primary key (snap_time, ccy)
);

-- One row per trade, appended in event-time order once the watermark has passed the trade.
create table if not exists gold.position_state (
    trade_id       uuid primary key,
    instrument_id  uuid        not null,
    event_time     timestamptz not null,
    raw_id         bigint      not null,
    price          numeric     not null,
    signed_qty     numeric     not null,       -- buy is positive, sell is negative
    qty_after      numeric     not null,       -- position after this trade (short is negative)
    avg_cost       numeric     not null,       -- average cost after this trade
    realized_delta numeric     not null,       -- P&L realized by this trade (local currency)
    realized_cum   numeric     not null,       -- cumulative realized P&L of the instrument (local currency)
    unique (instrument_id, event_time, raw_id)
);
create index if not exists position_state_order on gold.position_state (instrument_id, event_time desc, raw_id desc);

-- Core fact table: instrument x hour. A snapshot is written only after the watermark has passed the hour.
create table if not exists gold.stock_hourly (
    snap_time        timestamptz not null,     -- the full hour this snapshot describes
    instrument_id    uuid        not null,
    position         numeric     not null,
    avg_cost         numeric     not null,
    price            numeric     not null,     -- latest price at or before snap_time
    price_time       timestamptz not null,
    realized_local   numeric     not null,     -- local currency
    unrealized_local numeric     not null,
    mv_local         numeric     not null,     -- market value = position x price
    fx_rate          numeric     not null,     -- FX rate at snap_time
    realized_eur     numeric     not null,
    unrealized_eur   numeric     not null,
    total_eur        numeric     not null,
    mv_eur           numeric     not null,
    primary key (snap_time, instrument_id)
);
create index if not exists stock_hourly_by_instrument on gold.stock_hourly (instrument_id, snap_time);

create table if not exists gold.portfolio_hourly (
    snap_time      timestamptz primary key,
    realized_eur   numeric not null,
    unrealized_eur numeric not null,
    total_eur      numeric not null
);

-- One current row per equity, rewritten on every run. The live cards of the dashboard read this.
create table if not exists gold.live_state (
    instrument_id    uuid primary key,
    position         numeric     not null,
    avg_cost         numeric     not null,
    last_price       numeric     not null,
    price_time       timestamptz not null,
    realized_local   numeric     not null,
    unrealized_local numeric     not null,
    mv_local         numeric     not null,
    fx_rate          numeric     not null,
    realized_eur     numeric     not null,
    unrealized_eur   numeric     not null,
    total_eur        numeric     not null,
    mv_eur           numeric     not null,
    as_of            timestamptz not null      -- latest event time seen (simulated time)
);

-- Progress. watermark = trades with event_time <= watermark are final in gold.position_state.
create table if not exists gold.process_state (
    id             int primary key default 1 check (id = 1),
    last_raw_id    bigint      not null default 0,            -- how far into clean we have read (same scale as clean.process_state)
    watermark      timestamptz not null default '-infinity',  -- event time up to which positions are final
    too_late_total bigint      not null default 0,            -- trades that arrived behind the watermark and were skipped
    as_of          timestamptz,
    updated_at     timestamptz not null default now()
);
insert into gold.process_state (id) values (1) on conflict do nothing;
