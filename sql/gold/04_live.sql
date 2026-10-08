-- Gold layer · 4/5 live snapshot
-- One current row per equity, replaced on every run. Which inputs to take is live-specific
-- (latest price, latest final position state); the FX and valuation formulas are shared with
-- the hourly path through gold.fx_rates_at() and gold.value_position().
-- Positions only include trades the watermark has passed; prices are the very latest.

create or replace function gold.refresh_live() returns timestamptz
language plpgsql as $$
declare v_as_of timestamptz;
begin
    select greatest(
        (select max(event_time) from clean.prices),
        (select max(event_time) from clean.trades)
    ) into v_as_of;

    if v_as_of is null then
        return null;
    end if;

    delete from gold.live_state;

    insert into gold.live_state (
        instrument_id, position, avg_cost, last_price, price_time,
        realized_local, unrealized_local, mv_local, fx_rate,
        realized_eur, unrealized_eur, total_eur, mv_eur, as_of
    )
    with current_state as (
        select
            i.instrument_id,
            coalesce(ps.qty_after, 0)    as position,
            coalesce(ps.avg_cost, 0)     as avg_cost,
            px.price,
            px.event_time                as price_time,
            coalesce(ps.realized_cum, 0) as realized_local,
            fx.rate_to_eur               as fx_rate
        from clean.instruments i
        join lateral (
            select p.price, p.event_time
            from clean.prices p
            where p.instrument_id = i.instrument_id
            order by p.event_time desc
            limit 1
        ) px on true
        left join lateral (
            select s.qty_after, s.avg_cost, s.realized_cum
            from gold.position_state s
            where s.instrument_id = i.instrument_id
            order by s.event_time desc, s.raw_id desc
            limit 1
        ) ps on true
        join gold.fx_rates_at(v_as_of) fx on fx.ccy = i.currency
        where i.type = 'equity'
    )
    select
        s.instrument_id, s.position, s.avg_cost, s.price, s.price_time,
        s.realized_local, v.unrealized_local, v.mv_local, s.fx_rate,
        v.realized_eur, v.unrealized_eur, v.total_eur, v.mv_eur, v_as_of
    from current_state s
    cross join lateral gold.value_position(
        s.position, s.avg_cost, s.price, s.realized_local, s.fx_rate
    ) v;

    return v_as_of;
end $$;
