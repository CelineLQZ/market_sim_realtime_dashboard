-- Gold layer · 5/5 entry point
-- gold.run(): the incremental step the processor calls every few seconds.
--
-- Watermark = (latest event time seen) - p_lateness. Everything at or before the watermark is
-- final: its trades are appended to gold.position_state, and the hourly snapshots for hours the
-- watermark has passed are written once and never touched again. A trade that arrives behind the
-- watermark is too late for streaming; it is counted in too_late (a daily batch job is where
-- such stragglers would be corrected).
create or replace function gold.run(
    p_lateness interval default interval '5 minutes',
    out from_raw_id bigint, out to_raw_id bigint, out instruments_touched int, out trades_applied int,
    out too_late int, out hours_built int, out watermark timestamptz, out as_of timestamptz)
language plpgsql as $$
declare
    lo bigint; hi bigint; r record;
    v_old_wm timestamptz; v_max_event timestamptz;
    v_from timestamptz; v_to timestamptz;
begin
    -- for update locks the progress row: a second concurrent gold.run() waits instead of double-processing
    select last_raw_id, ps.watermark into lo, v_old_wm from gold.process_state ps for update;
    select last_raw_id into hi from clean.process_state;
    from_raw_id := lo + 1; to_raw_id := greatest(hi, lo);

    v_max_event := greatest((select max(event_time) from clean.prices), (select max(event_time) from clean.trades));
    as_of := v_max_event;
    if v_max_event is null then            -- nothing in clean yet
        watermark := v_old_wm; instruments_touched := 0; trades_applied := 0; too_late := 0; hours_built := 0;
        return;
    end if;
    watermark := greatest(v_old_wm, v_max_event - p_lateness);

    -- Trades that just arrived but are older than the previous watermark: too late, skipped
    select count(*) into too_late from clean.trades
    where raw_id > lo and raw_id <= to_raw_id and event_time <= v_old_wm;

    -- 1. Positions: append trades inside the window (old watermark, new watermark]
    select * into r from gold.apply_new_trades(v_old_wm, watermark);
    instruments_touched := r.o_instruments; trades_applied := r.o_trades;

    -- 2. Hourly snapshots: only hours the watermark has passed, starting after the last built hour
    v_to := date_trunc('hour', watermark);
    v_from := coalesce((select max(snap_time) + interval '1 hour' from gold.portfolio_hourly),
                       date_trunc('hour', (select min(event_time) from clean.prices)));
    hours_built := 0;
    if v_from <= v_to then
        perform gold.rebuild_hourly(v_from, v_to);
        select count(*) into hours_built from gold.portfolio_hourly where snap_time >= v_from;
    end if;

    -- 3. Live state
    perform gold.refresh_live();

    update gold.process_state ps
    set last_raw_id = to_raw_id, watermark = run.watermark, as_of = run.as_of,
        too_late_total = ps.too_late_total + run.too_late, updated_at = now();
end $$;
