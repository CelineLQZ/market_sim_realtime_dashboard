-- gold 层 · 5/6 预警
-- gold.evaluate_alerts：只有两条规则（回撤、单只股票大亏），都用占总敞口的百分比。

-- ============ 预警：触发和解除分开，各有阈值 ============
create or replace function gold.evaluate_alerts() returns int
language plpgsql as $$
declare v_asof timestamptz; n int; v_gross numeric;
begin
    select max(as_of) into v_asof from gold.live_state;
    if v_asof is null then return 0; end if;

    drop table if exists _cand;
    create temp table _cand (rule_id text, scope text, value numeric, breached boolean, ok boolean);

    -- 相对口径的分母：总敞口（持仓市值绝对值之和）。太小（刚开盘、几乎没有仓位）时百分比没有意义，不评估。
    select coalesce(sum(abs(mv_eur)), 0) into v_gross from gold.live_state;
    if v_gross >= 1000000 then
        -- 组合层：现在的总盈亏比历史最高点低了多少（占总敞口的百分比，负数）
        insert into _cand
        select r.rule_id, 'portfolio', round(v.dd / v_gross * 100, 3),
               v.dd / v_gross * 100 <= -r.threshold, v.dd / v_gross * 100 > -r.clear_threshold
        from gold.alert_rules r
        cross join (
            select l.tot - greatest(pk.m, l.tot) as dd
            from (select sum(total_eur) tot from gold.live_state) l,
                 (select greatest(0, coalesce(max(total_eur), 0)) m from gold.portfolio_hourly) pk
            where exists (select 1 from gold.portfolio_hourly)
        ) v
        where r.rule_id = 'drawdown';

        -- 标的层：单只股票亏损过大（占总敞口的百分比，负数）
        insert into _cand
        select r.rule_id, i.short_name, round(l.total_eur / v_gross * 100, 3),
               l.total_eur / v_gross * 100 <= -r.threshold, l.total_eur / v_gross * 100 > -r.clear_threshold
        from gold.live_state l
        join clean.instruments i using (instrument_id)
        join gold.alert_rules r on r.rule_id = 'stock_loss';
    end if;

    update gold.alerts a set cleared_at = v_asof, last_value = c.value
    from _cand c where a.cleared_at is null and a.rule_id = c.rule_id and a.scope = c.scope and c.ok;

    update gold.alerts a set last_value = c.value
    from _cand c where a.cleared_at is null and a.rule_id = c.rule_id and a.scope = c.scope and not c.ok;

    insert into gold.alerts (rule_id, scope, fired_at, fired_value, last_value, threshold, severity)
    select c.rule_id, c.scope, v_asof, c.value, c.value, r.threshold, r.severity
    from _cand c join gold.alert_rules r using (rule_id)
    where c.breached and not exists (select 1 from gold.alerts a
                                     where a.cleared_at is null and a.rule_id = c.rule_id and a.scope = c.scope);

    select count(*) into n from gold.alerts where cleared_at is null;
    drop table if exists _cand;
    return n;
end $$;
