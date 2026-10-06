-- gold 层 · 2/6 持仓
-- gold.apply_new_trades：把新到的成交逐笔算成持仓、平均成本、已实现盈亏；迟到的成交会让该标的从那个时间点起重放。

-- ============ 小工具：向上取整到整点 ============
create or replace function gold.ceil_hour(t timestamptz) returns timestamptz
language sql immutable as $$
    select case when t = date_trunc('hour', t) then t else date_trunc('hour', t) + interval '1 hour' end
$$;

-- ============ 持仓状态：逐笔成交算平均成本 ============
-- 规则（平均成本法，支持空头，一笔成交可以跨过 0）：
--   同方向加仓：新平均成本 = 数量加权平均
--   反方向平仓：实现盈亏 = 平掉的数量 x (成交价 - 平均成本) x 原持仓方向；部分平仓不改变平均成本
--   跨过 0：先平掉原来的持仓，剩下的部分按成交价重新开仓
-- 迟到处理：新到的成交如果事件时间比已处理的更早，就从这个时间点起把该标的重放一遍。
create or replace function gold.apply_new_trades(p_lo bigint, p_hi bigint,
    out o_instruments int, out o_replayed int, out o_rewinds int, out o_from timestamptz)
language plpgsql as $$
declare
    inst record; f record;
    rt timestamptz; rr bigint; prev_max timestamptz;
    pos numeric; avg numeric; rc numeric; q numeric; closing numeric; rd numeric; newpos numeric;
begin
    o_instruments := 0; o_replayed := 0; o_rewinds := 0; o_from := null;
    for inst in select distinct instrument_id from clean.trades where raw_id > p_lo and raw_id <= p_hi loop
        -- 本次新到的成交里，排序键 (event_time, raw_id) 最小的一笔：从这里开始重放
        select event_time, raw_id into rt, rr from clean.trades
        where instrument_id = inst.instrument_id and raw_id > p_lo and raw_id <= p_hi
        order by event_time, raw_id limit 1;

        select max(event_time) into prev_max from gold.position_state where instrument_id = inst.instrument_id;
        if prev_max is not null and rt < prev_max then o_rewinds := o_rewinds + 1; end if;   -- 迟到
        o_from := least(coalesce(o_from, rt), rt);

        delete from gold.position_state
        where instrument_id = inst.instrument_id and (event_time, raw_id) >= (rt, rr);

        select qty_after, avg_cost, realized_cum into pos, avg, rc from gold.position_state
        where instrument_id = inst.instrument_id order by event_time desc, raw_id desc limit 1;
        pos := coalesce(pos, 0); avg := coalesce(avg, 0); rc := coalesce(rc, 0);

        for f in select trade_id, event_time, raw_id, price, volume, side from clean.trades
                 where instrument_id = inst.instrument_id and (event_time, raw_id) >= (rt, rr)
                 order by event_time, raw_id loop
            q := case when f.side = 'BUY' then f.volume else -f.volume end;
            rd := 0;
            if pos = 0 or sign(pos) = sign(q) then
                newpos := pos + q;
                avg := (abs(pos) * avg + abs(q) * f.price) / abs(newpos);
            else
                closing := least(abs(q), abs(pos));
                rd := closing * (f.price - avg) * sign(pos);
                newpos := pos + q;
                if newpos = 0 then avg := 0;
                elsif sign(newpos) <> sign(pos) then avg := f.price;
                end if;
            end if;
            pos := newpos; rc := rc + rd;
            insert into gold.position_state
                (trade_id, instrument_id, event_time, raw_id, price, signed_qty, qty_after, avg_cost, realized_delta, realized_cum)
            values (f.trade_id, inst.instrument_id, f.event_time, f.raw_id, f.price, q, pos, avg, rd, rc);
            o_replayed := o_replayed + 1;
        end loop;
        o_instruments := o_instruments + 1;
    end loop;
end $$;
