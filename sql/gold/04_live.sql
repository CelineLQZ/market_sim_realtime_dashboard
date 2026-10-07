-- Gold live snapshot: one current row per equity, replaced on every run.
-- Input selection is live-specific; FX and valuation formulas are shared with
-- the hourly path through gold.fx_rates_at() and gold.value_position().

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
        price_age_min, in_session, realized_local, unrealized_local,
        mv_local, fx_rate, realized_eur, unrealized_eur, total_eur,
        mv_eur, as_of, realized_eur_cfx, unrealized_eur_cfx, total_eur_cfx
    )
    with current_state as (
        select
            i.instrument_id,
            i.exchange,
            coalesce(ps.qty_after, 0) as position,
            coalesce(ps.avg_cost, 0) as avg_cost,
            px.price,
            px.event_time as price_time,
            coalesce(ps.realized_cum, 0) as realized_local,
            fx.rate_to_eur as market_fx,
            coalesce(ref.rate_to_eur, fx.rate_to_eur) as constant_fx
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
        left join gold.fx_reference ref on ref.ccy = i.currency
        where i.type = 'equity'
    )
    select
        s.instrument_id,
        s.position,
        s.avg_cost,
        s.price,
        s.price_time,
        extract(epoch from (v_as_of - s.price_time)) / 60,
        exists (
            select 1
            from clean.exchange_sessions session
            where session.exchange = s.exchange
              and extract(isodow from v_as_of) <= 5
              and (v_as_of at time zone 'UTC')::time >= session.open_utc
              and (v_as_of at time zone 'UTC')::time < session.close_utc
        ),
        s.realized_local,
        v.unrealized_local,
        v.mv_local,
        s.market_fx,
        v.realized_eur,
        v.unrealized_eur,
        v.total_eur,
        v.mv_eur,
        v_as_of,
        v.realized_eur_cfx,
        v.unrealized_eur_cfx,
        v.total_eur_cfx
    from current_state s
    cross join lateral gold.value_position(
        s.position, s.avg_cost, s.price, s.realized_local,
        s.market_fx, s.constant_fx
    ) v;

    return v_as_of;
end $$;
