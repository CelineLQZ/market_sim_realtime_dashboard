-- Gold layer · 3/5 positions
-- gold.apply_new_trades: turn trades into position, average cost and realized P&L, one trade at a time.
--
-- Window: only trades with p_from < event_time <= p_to are processed (p_to is the watermark).
-- Inside the window the trades of each instrument are sorted by (event_time, raw_id), so the order
-- is always correct. State is append-only: nothing is deleted or replayed. A trade that arrives
-- after the watermark has already passed its event time is skipped (counted by gold.run()).
--
-- Rules (average-cost method, shorts allowed, one trade may cross zero):
--   same direction as the position:  new average cost = quantity-weighted average
--   opposite direction (closing):    realized = closed qty x (price - average cost) x sign(position)
--                                    a partial close leaves the average cost unchanged
--   crossing zero:                   close the old position first, open the rest at the trade price
--   flat:                            average cost = 0
--
-- Example: buy 100 @ 10, buy 100 @ 12 (avg 11, position 200), sell 50 @ 13 -> realized +100;
--          sell 250 @ 12 -> closes 150 (+150), opens short 100 @ 12, cumulative realized 250.
create or replace function gold.apply_new_trades(p_from timestamptz, p_to timestamptz,
    out o_instruments int, out o_trades int)
language plpgsql as $$
declare
    inst           record;
    t              record;
    v_position     numeric;    -- position before the trade, then after it
    v_avg_cost     numeric;
    v_realized_cum numeric;
    v_signed_qty   numeric;    -- buy is positive, sell is negative
    v_closed_qty   numeric;    -- part of the trade that closes the existing position
    v_realized_delta numeric;
    v_new_position numeric;
begin
    o_instruments := 0; o_trades := 0;

    for inst in select distinct instrument_id from clean.trades
                where event_time > p_from and event_time <= p_to loop

        -- Start from the last stored state of this instrument (flat if there is none)
        select ps.qty_after, ps.avg_cost, ps.realized_cum
          into v_position, v_avg_cost, v_realized_cum
        from gold.position_state ps
        where ps.instrument_id = inst.instrument_id
        order by ps.event_time desc, ps.raw_id desc
        limit 1;
        v_position := coalesce(v_position, 0);
        v_avg_cost := coalesce(v_avg_cost, 0);
        v_realized_cum := coalesce(v_realized_cum, 0);

        for t in select trade_id, event_time, raw_id, price, volume, side from clean.trades
                 where instrument_id = inst.instrument_id and event_time > p_from and event_time <= p_to
                 order by event_time, raw_id loop

            v_signed_qty := case when t.side = 'BUY' then t.volume else -t.volume end;
            v_realized_delta := 0;

            if v_position = 0 or sign(v_position) = sign(v_signed_qty) then
                -- opening or adding: weighted average cost
                v_new_position := v_position + v_signed_qty;
                v_avg_cost := (abs(v_position) * v_avg_cost + abs(v_signed_qty) * t.price) / abs(v_new_position);
            else
                -- closing (maybe crossing zero): only the overlapping quantity realizes P&L
                v_closed_qty := least(abs(v_signed_qty), abs(v_position));
                v_realized_delta := v_closed_qty * (t.price - v_avg_cost) * sign(v_position);
                v_new_position := v_position + v_signed_qty;
                if v_new_position = 0 then
                    v_avg_cost := 0;
                elsif sign(v_new_position) <> sign(v_position) then
                    v_avg_cost := t.price;     -- crossed zero: the remainder opens at the trade price
                end if;
            end if;

            v_position := v_new_position;
            v_realized_cum := v_realized_cum + v_realized_delta;

            insert into gold.position_state
                (trade_id, instrument_id, event_time, raw_id, price, signed_qty, qty_after, avg_cost, realized_delta, realized_cum)
            values
                (t.trade_id, inst.instrument_id, t.event_time, t.raw_id, t.price, v_signed_qty, v_position, v_avg_cost, v_realized_delta, v_realized_cum);
            o_trades := o_trades + 1;
        end loop;

        o_instruments := o_instruments + 1;
    end loop;
end $$;
