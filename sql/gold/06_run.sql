-- gold 层 · 6/6 入口
-- gold.run()：日常增量处理（processor 每 5 秒调用）；gold.nightly_fix(t)：收盘后从 t 起重算小时快照。

-- ============ 日常入口：增量处理 ============
create or replace function gold.run(
    out from_raw_id bigint, out to_raw_id bigint, out instruments_touched int, out trades_replayed int,
    out late_rewinds int, out hours_rebuilt int, out as_of timestamptz, out open_alerts int)
language plpgsql as $$
declare
    lo bigint; hi bigint; r record;
    v_from timestamptz; v_to timestamptz; first_unbuilt timestamptz;
begin
    -- for update 锁住进度行：同时有两个 gold.run()（或 nightly_fix）时，后来的会等前一个跑完，不会重复处理
    select last_raw_id into lo from gold.process_state for update;
    select last_raw_id into hi from clean.process_state;
    from_raw_id := lo + 1; to_raw_id := greatest(hi, lo);
    select * into r from gold.apply_new_trades(lo, to_raw_id);
    instruments_touched := r.o_instruments; trades_replayed := r.o_replayed; late_rewinds := r.o_rewinds;

    -- 需要重算的小时：还没算过的新小时，加上被迟到成交影响到的旧小时
    as_of := greatest((select max(event_time) from clean.prices), (select max(event_time) from clean.trades));
    v_to := date_trunc('hour', as_of);
    first_unbuilt := coalesce((select max(snap_time) + interval '1 hour' from gold.portfolio_hourly),
                              gold.ceil_hour((select min(event_time) from clean.prices)));
    v_from := first_unbuilt;
    if r.o_from is not null then v_from := least(v_from, gold.ceil_hour(r.o_from)); end if;
    hours_rebuilt := 0;
    if v_from <= v_to then
        perform gold.rebuild_hourly(v_from, v_to);
        select count(distinct snap_time) into hours_rebuilt from gold.stock_hourly where snap_time >= date_trunc('hour', v_from);
    end if;

    perform gold.refresh_live();
    open_alerts := gold.evaluate_alerts();

    update gold.process_state set last_raw_id = to_raw_id, as_of = run.as_of, updated_at = now();

end $$;


-- ============ 收盘后批处理：从某个时间起重算小时快照 ============
-- 日常的增量运行只修正"迟到的成交"。迟到的旧报价会改变历史上某些小时的估值，留给这里修正。
-- 用法：select gold.nightly_fix('2025-01-23');   -- 从这一天 00:00 起重算
create or replace function gold.nightly_fix(p_from timestamptz) returns int
language plpgsql as $$
declare v_to timestamptz;
begin
    perform 1 from gold.process_state for update;    -- 和 gold.run() 互斥：不会和日常增量同时重算小时快照
    v_to := date_trunc('hour', greatest((select max(event_time) from clean.prices), (select max(event_time) from clean.trades)));
    return gold.rebuild_hourly(p_from, v_to);
end $$;
