-- gold 层 · 3/6 小时快照
-- gold.rebuild_hourly：重算某个时间以后的小时快照（标的 x 小时、全组合、汇率）。

-- ============ 小时快照：重算从 p_from 起的所有小时 ============
-- 快照时刻 h 的状态 = 事件时间 <= h 的最新持仓、最新报价、最新汇率（"as-of"）。
-- 只生成周一到周五的小时。因为按事件时间取"最新"，迟到的旧报价也会在这里被正确放回去，
-- 所以重算（nightly_fix）可以修正历史。
create or replace function gold.rebuild_hourly(p_from timestamptz, p_to timestamptz) returns int
language plpgsql as $$
declare
    n int;
    v_eurusd uuid; v_gbpusd uuid; v_usdjpy uuid;
begin
    p_from := date_trunc('hour', p_from);
    delete from gold.stock_hourly     where snap_time >= p_from;
    delete from gold.portfolio_hourly where snap_time >= p_from;
    delete from gold.fx_rate_hourly   where snap_time >= p_from;

    drop table if exists _h;
    create temp table _h as
    select h as snap_time from generate_series(p_from, date_trunc('hour', p_to), interval '1 hour') h
    where extract(isodow from h - interval '1 second') <= 5;      -- 周六 00:00 属于周五的最后一个快照

    -- 汇率：三个汇率标的各取最新报价，再经美元换成"1 单位币种 = 多少欧元"
    select instrument_id into v_eurusd from clean.instruments where short_name = 'EUR/USD';
    select instrument_id into v_gbpusd from clean.instruments where short_name = 'GBP/USD';
    select instrument_id into v_usdjpy from clean.instruments where short_name = 'USD/JPY';
    insert into gold.fx_rate_hourly (snap_time, ccy, rate_to_eur)
    select t.snap_time, v.ccy, v.rate
    from (
        select h.snap_time,
          (select price from clean.prices where instrument_id = v_eurusd and event_time <= h.snap_time order by event_time desc limit 1) as eurusd,
          (select price from clean.prices where instrument_id = v_gbpusd and event_time <= h.snap_time order by event_time desc limit 1) as gbpusd,
          (select price from clean.prices where instrument_id = v_usdjpy and event_time <= h.snap_time order by event_time desc limit 1) as usdjpy
        from _h h
    ) t
    cross join lateral (values ('EUR', 1::numeric), ('USD', 1 / t.eurusd), ('GBP', t.gbpusd / t.eurusd), ('JPY', 1 / t.usdjpy / t.eurusd)) v(ccy, rate)
    where t.eurusd is not null and t.gbpusd is not null and t.usdjpy is not null;

    -- 固定参考汇率 = 数据里第一个有完整汇率的小时。只写一次，之后不再改。
    insert into gold.fx_reference (ccy, rate_to_eur, as_of)
    select ccy, rate_to_eur, snap_time from gold.fx_rate_hourly
    where snap_time = (select min(snap_time) from gold.fx_rate_hourly)
    on conflict (ccy) do nothing;

    -- 标的 x 小时
    insert into gold.stock_hourly
    select h.snap_time, i.instrument_id,
           coalesce(ps.qty_after, 0), coalesce(ps.avg_cost, 0), px.price, px.event_time,
           coalesce(ps.realized_cum, 0),
           coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0)),
           coalesce(ps.qty_after, 0) * px.price,
           fx.rate_to_eur,
           coalesce(ps.realized_cum, 0) * fx.rate_to_eur,
           coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0)) * fx.rate_to_eur,
           (coalesce(ps.realized_cum, 0) + coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0))) * fx.rate_to_eur,
           coalesce(ps.qty_after, 0) * px.price * fx.rate_to_eur,
           coalesce(ps.realized_cum, 0) * ref.rate_to_eur,
           coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0)) * ref.rate_to_eur,
           (coalesce(ps.realized_cum, 0) + coalesce(ps.qty_after, 0) * (px.price - coalesce(ps.avg_cost, 0))) * ref.rate_to_eur
    from _h h
    cross join clean.instruments i
    join lateral (select price, event_time from clean.prices p
                  where p.instrument_id = i.instrument_id and p.event_time <= h.snap_time
                  order by p.event_time desc limit 1) px on true
    left join lateral (select qty_after, avg_cost, realized_cum from gold.position_state s
                       where s.instrument_id = i.instrument_id and s.event_time <= h.snap_time
                       order by s.event_time desc, s.raw_id desc limit 1) ps on true
    join gold.fx_rate_hourly fx on fx.snap_time = h.snap_time and fx.ccy = i.currency
    join gold.fx_reference ref on ref.ccy = i.currency
    where i.type = 'equity';
    get diagnostics n = row_count;

    -- 全组合
    insert into gold.portfolio_hourly
        (snap_time, realized_eur, unrealized_eur, total_eur, realized_eur_cfx, unrealized_eur_cfx, total_eur_cfx,
         long_mv_eur, short_mv_eur, gross_eur, net_eur)
    select snap_time, sum(realized_eur), sum(unrealized_eur), sum(total_eur),
           sum(realized_eur_cfx), sum(unrealized_eur_cfx), sum(total_eur_cfx),
           sum(greatest(mv_eur, 0)), sum(least(mv_eur, 0)), sum(abs(mv_eur)), sum(mv_eur)
    from gold.stock_hourly where snap_time >= p_from group by snap_time;

    -- 历史最高点和回撤：要看所有更早的小时，所以对整张表做窗口
    update gold.portfolio_hourly p
    set peak_total_eur = w.pk, drawdown_eur = p.total_eur - w.pk
    from (select snap_time, greatest(0, max(total_eur) over (order by snap_time)) as pk from gold.portfolio_hourly) w
    where w.snap_time = p.snap_time and p.snap_time >= p_from;

    drop table if exists _h;
    return n;
end $$;
