-- Gold layer · 2/5 shared valuation
--
-- FX conversion and position valuation live in one place. The hourly history and the
-- live snapshot both call these helpers, so the formulas cannot drift apart.

-- Return "1 unit of currency = EUR" as of an event-time cut-off. No rows are returned
-- until all three FX quotes exist (all-or-nothing).
create or replace function gold.fx_rates_at(p_at timestamptz)
returns table (ccy text, rate_to_eur numeric)
language sql stable as $$
    with fx_instruments as (
        select
            max(instrument_id::text) filter (where short_name = 'EUR/USD')::uuid as eurusd_id,
            max(instrument_id::text) filter (where short_name = 'GBP/USD')::uuid as gbpusd_id,
            max(instrument_id::text) filter (where short_name = 'USD/JPY')::uuid as usdjpy_id
        from clean.instruments
    ),
    quotes as (
        select
            (select price from clean.prices
             where instrument_id = i.eurusd_id and event_time <= p_at
             order by event_time desc limit 1) as eurusd,
            (select price from clean.prices
             where instrument_id = i.gbpusd_id and event_time <= p_at
             order by event_time desc limit 1) as gbpusd,
            (select price from clean.prices
             where instrument_id = i.usdjpy_id and event_time <= p_at
             order by event_time desc limit 1) as usdjpy
        from fx_instruments i
    )
    select r.ccy, r.rate_to_eur
    from quotes q
    cross join lateral (values
        ('EUR', 1::numeric),
        ('USD', 1 / q.eurusd),
        ('GBP', q.gbpusd / q.eurusd),
        ('JPY', 1 / q.usdjpy / q.eurusd)
    ) r(ccy, rate_to_eur)
    where q.eurusd is not null and q.gbpusd is not null and q.usdjpy is not null
$$;


-- Apply the P&L formulas to an already selected position, price and FX rate.
-- Finding the correct as-of inputs is the caller's job.
--   unrealized = position x (price - average cost)
--   market value = position x price
--   realized_eur = realized_local x FX  (proceeds are treated as foreign cash, valued at the current rate)
create or replace function gold.value_position(
    p_position       numeric,
    p_avg_cost       numeric,
    p_price          numeric,
    p_realized_local numeric,
    p_fx             numeric
) returns table (
    unrealized_local numeric,
    mv_local         numeric,
    realized_eur     numeric,
    unrealized_eur   numeric,
    total_eur        numeric,
    mv_eur           numeric
)
language sql immutable as $$
    select
        p_position * (p_price - p_avg_cost),
        p_position * p_price,
        p_realized_local * p_fx,
        p_position * (p_price - p_avg_cost) * p_fx,
        (p_realized_local + p_position * (p_price - p_avg_cost)) * p_fx,
        p_position * p_price * p_fx
$$;
