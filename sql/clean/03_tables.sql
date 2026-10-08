-- Clean layer · 3/5 tables
-- Good trades and prices, rejected rows, and progress. Existing tables and their data are left alone.

create schema if not exists clean;

create table if not exists clean.trades (
    trade_id      uuid primary key,          -- primary key: one row per trade_id, duplicate messages are removed by it
    instrument_id uuid        not null,
    event_time    timestamptz not null,      -- event time in the message (simulated time)
    price         numeric     not null,
    volume        bigint      not null,
    side          text        not null,      -- BUY or SELL
    currency      text        not null,
    raw_id        bigint      not null       -- which raw.events row it came from (for tracing)
);

create table if not exists clean.prices (
    instrument_id uuid        not null,
    event_time    timestamptz not null,
    price         numeric     not null,
    raw_id        bigint      not null,
    primary key (instrument_id, event_time)   -- a price has no id of its own: only one price is kept per instrument and time
);

create table if not exists clean.dead_letter (
    raw_id      bigint primary key,          -- each bad row is recorded once
    reason      text        not null,        -- why it is bad
    payload     text        not null,        -- original text, unchanged
    received_at timestamptz not null
);

-- Progress table: always exactly one row, "how far into raw_id we have processed". The next run continues after it.
create table if not exists clean.process_state (
    id          int primary key default 1 check (id = 1),   -- the check guarantees there is only this one row
    last_raw_id bigint      not null default 0,
    updated_at  timestamptz not null default now()
);
insert into clean.process_state (id) values (1) on conflict do nothing;
