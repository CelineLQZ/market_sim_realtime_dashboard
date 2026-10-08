-- Clean layer · 1/5 reference data: load instruments.csv into the database (one-off, safe to repeat)
-- Run from the market-sim folder:  psql marketsim -f sql/clean/01_instruments.sql

create schema if not exists clean;

-- One row per stock / FX pair: the "manual" (dimension table) for trades and prices
create table if not exists clean.instruments (
    instrument_id uuid primary key,
    long_name     text,
    short_name    text,
    country       text,
    sector        text,
    industry      text,
    exchange      text,
    type          text,     -- equity or currency (an FX pair)
    currency      text
);

-- Truncate and load are in one transaction: truncate locks the table until commit, so while the processor is running
-- it either waits or sees the complete new data, and never hits the moment the table is empty and mistakes rows for unknown instruments.
begin;
truncate clean.instruments;                                   -- empty first, so repeated runs do not duplicate rows
\copy clean.instruments from 'data/instruments.csv' csv header   -- read the CSV into the table (the first line is the header, skipped)
commit;
