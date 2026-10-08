-- Clean layer · 5/5 entry point
-- clean.run(): processes only the rows that arrived in raw.events since the last run, routes them to trades / prices / dead_letter, and reconciles.
--   good trade  -> clean.trades
--   good price  -> clean.prices
--   bad row     -> clean.dead_letter (original text + reason)
--   same instrument and time but a different price -> the first one goes to clean.prices, the later one to dead_letter (conflicting_price)

-- ============ Process new data: clean.run() ============
-- The function is one unit: everything succeeds or nothing counts (same effect as the old begin ... commit).
-- Returns one reconciliation row: which raw_id range was processed, how many rows of each kind, and whether it balances.
create or replace function clean.run(
    out from_raw_id        bigint,
    out to_raw_id          bigint,
    out raw_rows           bigint,
    out bad_rows           bigint,
    out good_rows          bigint,
    out kept_rows          bigint,
    out conflicting_prices bigint,
    out duplicates_dropped bigint,
    out balanced           boolean
) language plpgsql as $$
declare
    v_lo bigint;   -- last position processed (from the progress table)
    v_hi bigint;   -- highest raw_id in raw right now
begin
    -- Fix the range for this run: (v_lo, v_hi], i.e. raw_id greater than v_lo and not above v_hi.
    -- v_hi is fixed first: rows ingest writes while this runs are left for the next run.
    -- for update locks the progress row: if two clean.run() calls overlap, the later one waits for the earlier one,
    -- then continues from the updated progress, so the same range is never processed twice and no extra lock is needed.
    select s.last_raw_id into v_lo from clean.process_state s where s.id = 1 for update;
    select greatest(v_lo, coalesce(max(e.raw_id), 0)) into v_hi from raw.events e;

    ---- route the rows ----
    -- on conflict do nothing: if the primary key exists the row is skipped, which is the de-duplication. The key covers all history,
    -- so a duplicate message arriving the next day also conflicts with rows written on earlier days and is dropped.
    -- order by raw_id: among duplicates in the same batch, the earliest arrival is kept.
    insert into clean.trades (trade_id, instrument_id, event_time, price, volume, side, currency, raw_id)
    select trade_id, instrument_id, event_time, price, volume, side, currency, raw_id
    from clean.v_parsed
    where reason is null and type = 'trade'
      and raw_id >  v_lo
      and raw_id <= v_hi
    order by raw_id
    on conflict do nothing;

    insert into clean.prices (instrument_id, event_time, price, raw_id)
    select instrument_id, event_time, price, raw_id
    from clean.v_parsed
    where reason is null and type = 'price'
      and raw_id >  v_lo
      and raw_id <= v_hi
    order by raw_id
    on conflict do nothing;

    -- bad rows: format or value problems
    insert into clean.dead_letter (raw_id, reason, payload, received_at)
    select raw_id, reason, payload, received_at
    from clean.v_parsed
    where reason is not null
      and raw_id >  v_lo
      and raw_id <= v_hi
    on conflict do nothing;

    -- conflicting price: this instrument already has a price at this time (from today or an earlier day), and this one differs.
    -- A price that is also identical is a "full duplicate": the on conflict above dropped it silently, it is not a conflict and does not go to dead_letter.
    insert into clean.dead_letter (raw_id, reason, payload, received_at)
    select v.raw_id, 'conflicting_price', v.payload, v.received_at
    from clean.v_parsed v
    join clean.prices p on p.instrument_id = v.instrument_id and p.event_time = v.event_time
    where v.reason is null and v.type = 'price'
      and v.raw_id >  v_lo
      and v.raw_id <= v_hi
      and v.raw_id <> p.raw_id          -- not the kept row itself
      and v.price   <> p.price          -- a different price is what makes it a conflict
    on conflict do nothing;

    -- Record how far we got. It is in the same transaction as the writes above, so "written but progress not updated" cannot happen.
    update clean.process_state set last_raw_id = v_hi, updated_at = now() where id = 1;

    ---- reconciliation: every raw row of this run must end up somewhere ----
    -- level 1: raw rows of this run = bad rows + good rows
    -- level 2: good rows = newly kept + conflicting prices + full duplicates (counted independently, not derived by subtraction)
    with raw_new as (
        select e.raw_id from raw.events e where e.raw_id > v_lo and e.raw_id <= v_hi
    ),
    good as (
        select v.* from clean.v_parsed v
        where v.reason is null and v.raw_id > v_lo and v.raw_id <= v_hi
    ),
    bad as (
        select d.raw_id from clean.dead_letter d
        where d.reason <> 'conflicting_price' and d.raw_id > v_lo and d.raw_id <= v_hi
    ),
    confl as (
        select d.raw_id from clean.dead_letter d
        where d.reason = 'conflicting_price' and d.raw_id > v_lo and d.raw_id <= v_hi
    ),
    kept as (
        select t.raw_id from clean.trades t where t.raw_id > v_lo and t.raw_id <= v_hi
        union all
        select p.raw_id from clean.prices p where p.raw_id > v_lo and p.raw_id <= v_hi
    ),
    dups as (
        select g.raw_id from good g join clean.trades t on t.trade_id = g.trade_id
        where g.type = 'trade' and g.raw_id <> t.raw_id
        union all
        select g.raw_id from good g
        join clean.prices p on p.instrument_id = g.instrument_id and p.event_time = g.event_time
        where g.type = 'price' and g.raw_id <> p.raw_id and g.price = p.price
    )
    select v_lo + 1,
           v_hi,
           (select count(*) from raw_new),
           (select count(*) from bad),
           (select count(*) from good),
           (select count(*) from kept),
           (select count(*) from confl),
           (select count(*) from dups),
           (select count(*) from raw_new) = (select count(*) from bad) + (select count(*) from good)
           and (select count(*) from good) = (select count(*) from kept) + (select count(*) from confl)
                                           + (select count(*) from dups)
    into from_raw_id, to_raw_id, raw_rows, bad_rows, good_rows, kept_rows,
         conflicting_prices, duplicates_dropped, balanced;

end;
$$;
