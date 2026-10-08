-- Gold layer · 4/5 hourly snapshots
--
-- The public entry point is gold.rebuild_hourly(). Its three steps are separate functions so
-- FX, instrument valuation and portfolio aggregation can be read, tested and rerun on their own.
-- gold.run() only asks for hours the watermark has already passed, so history is never rewritten.


-- Step 1: one EUR conversion rate per currency and hour.
create or replace function gold.rebuild_fx_hourly(
    p_from timestamptz,
    p_to   timestamptz
) returns int
language plpgsql as $$
declare n int;
begin
    p_from := date_trunc('hour', p_from);
    p_to   := date_trunc('hour', p_to);

    delete from gold.fx_rate_hourly where snap_time >= p_from;

    insert into gold.fx_rate_hourly (snap_time, ccy, rate_to_eur)
    select h.snap_time, fx.ccy, fx.rate_to_eur
    from (
        select value as snap_time
        from generate_series(p_from, p_to, interval '1 hour') value
        where extract(isodow from value - interval '1 second') <= 5   -- skip weekends
    ) h
    cross join lateral gold.fx_rates_at(h.snap_time) fx;
    get diagnostics n = row_count;

    return n;
end $$;


-- Step 2: one as-of valuation per equity and hour.
create or replace function gold.rebuild_stock_hourly(
    p_from timestamptz,
    p_to   timestamptz
) returns int
language plpgsql as $$
declare n int;
begin
    p_from := date_trunc('hour', p_from);
    p_to   := date_trunc('hour', p_to);

    delete from gold.stock_hourly where snap_time >= p_from;

    insert into gold.stock_hourly (
        snap_time, instrument_id, position, avg_cost, price, price_time,
        realized_local, unrealized_local, mv_local, fx_rate,
        realized_eur, unrealized_eur, total_eur, mv_eur
    )
    with hours as (
        select value as snap_time
        from generate_series(p_from, p_to, interval '1 hour') value
        where extract(isodow from value - interval '1 second') <= 5
    ),
    as_of_state as (
        select
            h.snap_time,
            i.instrument_id,
            coalesce(ps.qty_after, 0)     as position,
            coalesce(ps.avg_cost, 0)      as avg_cost,
            px.price,
            px.event_time                 as price_time,
            coalesce(ps.realized_cum, 0)  as realized_local,
            fx.rate_to_eur                as fx_rate
        from hours h
        cross join clean.instruments i
        -- latest price at or before the snapshot time
        join lateral (
            select p.price, p.event_time
            from clean.prices p
            where p.instrument_id = i.instrument_id
              and p.event_time <= h.snap_time
            order by p.event_time desc
            limit 1
        ) px on true
        -- latest position state at or before the snapshot time (none = flat)
        left join lateral (
            select s.qty_after, s.avg_cost, s.realized_cum
            from gold.position_state s
            where s.instrument_id = i.instrument_id
              and s.event_time <= h.snap_time
            order by s.event_time desc, s.raw_id desc
            limit 1
        ) ps on true
        join gold.fx_rate_hourly fx
          on fx.snap_time = h.snap_time and fx.ccy = i.currency
        where i.type = 'equity'
    )
    select
        s.snap_time, s.instrument_id, s.position, s.avg_cost, s.price, s.price_time,
        s.realized_local, v.unrealized_local, v.mv_local, s.fx_rate,
        v.realized_eur, v.unrealized_eur, v.total_eur, v.mv_eur
    from as_of_state s
    cross join lateral gold.value_position(
        s.position, s.avg_cost, s.price, s.realized_local, s.fx_rate
    ) v;
    get diagnostics n = row_count;

    return n;
end $$;


-- Step 3: add up the instrument snapshots into one portfolio row per hour.
create or replace function gold.rebuild_portfolio_hourly(
    p_from timestamptz
) returns int
language plpgsql as $$
declare n int;
begin
    p_from := date_trunc('hour', p_from);
    delete from gold.portfolio_hourly where snap_time >= p_from;

    insert into gold.portfolio_hourly (snap_time, realized_eur, unrealized_eur, total_eur)
    select snap_time, sum(realized_eur), sum(unrealized_eur), sum(total_eur)
    from gold.stock_hourly
    where snap_time >= p_from
    group by snap_time;
    get diagnostics n = row_count;

    return n;
end $$;


-- Orchestration entry point. All steps run in the caller's transaction.
create or replace function gold.rebuild_hourly(
    p_from timestamptz,
    p_to   timestamptz
) returns int
language plpgsql as $$
declare stock_rows int;
begin
    p_from := date_trunc('hour', p_from);
    perform gold.rebuild_fx_hourly(p_from, p_to);
    stock_rows := gold.rebuild_stock_hourly(p_from, p_to);
    perform gold.rebuild_portfolio_hourly(p_from);
    return stock_rows;
end $$;
