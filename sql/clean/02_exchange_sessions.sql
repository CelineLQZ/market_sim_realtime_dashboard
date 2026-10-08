-- Clean layer · 2/5 reference data: trading sessions of each exchange (UTC, Monday to Friday).
-- Purpose: tell whether a stock is "in session" right now. Only inside a session does a price that stops updating count as stale.
-- Static reference data like instruments, safe to run repeatedly. The values match SESSIONS_UTC in simulator/market.py.
-- Run: psql marketsim -v ON_ERROR_STOP=1 -f sql/clean/02_exchange_sessions.sql

create schema if not exists clean;

create table if not exists clean.exchange_sessions (
    exchange  text primary key,
    open_utc  time not null,
    close_utc time not null
);

insert into clean.exchange_sessions (exchange, open_utc, close_utc) values
    ('XTKS', '00:00', '06:00'),   -- Tokyo
    ('XAMS', '08:00', '16:30'),   -- Amsterdam
    ('XETR', '08:00', '16:30'),   -- Frankfurt
    ('XPAR', '08:00', '16:30'),   -- Paris
    ('XLON', '08:00', '16:30'),   -- London
    ('XNYS', '14:30', '21:00')    -- New York
on conflict (exchange) do update
    set open_utc = excluded.open_utc, close_utc = excluded.close_utc;
