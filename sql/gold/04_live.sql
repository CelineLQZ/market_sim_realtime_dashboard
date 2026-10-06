-- gold 层 · 4/6 实时状态
-- gold.refresh_live：每个标的一行的"现在"，每次运行覆盖。

-- ============ 实时状态：每个标的一行，每次运行覆盖 ============
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
