-- Clean layer · 4/5 parse and check
-- clean.v_parsed: parses every raw row into fields and decides what is wrong with it (empty reason = good row). The view itself stores no data.

-- ============ Parse and check (one view keeps the logic in one place) ============
-- A view is just a saved query and stores no data. It is used below with a raw_id range, so only new rows are parsed.
create or replace view clean.v_parsed as
with step1 as (      -- step 1: can this row be parsed as JSON? (garbled rows become null here)
    select raw_id, received_at, payload,
           case when pg_input_is_valid(payload, 'jsonb') then payload::jsonb end as j
    from raw.events
),
step2 as (           -- step 2: extract the fields and cast them; anything missing or malformed becomes null
    select raw_id, received_at, payload, j,
           j->>'type'                                                       as type,
           j->'data'->>'side'                                               as side,
           j->'data'->>'currency'                                           as currency,
           case when pg_input_is_valid(j->'data'->>'trade_id', 'uuid')
                then (j->'data'->>'trade_id')::uuid end                     as trade_id,
           case when pg_input_is_valid(j->'data'->>'instrument_id', 'uuid')
                then (j->'data'->>'instrument_id')::uuid end                as instrument_id,
           case when pg_input_is_valid(j->'data'->>'price', 'numeric')
                then (j->'data'->>'price')::numeric end                     as price,
           case when pg_input_is_valid(j->'data'->>'volume', 'bigint')
                then (j->'data'->>'volume')::bigint end                     as volume,
           case when pg_input_is_valid(j->'data'->>'date', 'timestamptz')
                then (j->'data'->>'date')::timestamptz end                  as event_time
    from step1
)
select s.raw_id, s.received_at, s.payload, s.type, s.trade_id, s.instrument_id,
       s.price, s.volume, s.side, s.currency, s.event_time,
       -- step 3: decide what is wrong. case goes top to bottom and stops at the first match, so a row gets exactly one reason.
       -- a null reason means the row is good.
       case
           when s.j is null                                   then 'not_json'            -- format problem
           when s.type is null or s.type not in ('trade','price') then 'unknown_type'
           when s.instrument_id is null                       then 'bad_instrument_id'
           when s.event_time is null                          then 'bad_date'
           when s.price is null                               then 'null_price'          -- value problem
           when s.price <= 0                                  then 'non_positive_price'
           when s.type = 'trade' and s.trade_id is null       then 'bad_trade_id'
           when s.type = 'trade' and (s.volume is null or s.volume <= 0) then 'bad_volume'
           when s.type = 'trade' and s.side is null           then 'bad_side'
           when s.type = 'trade' and s.side not in ('BUY','SELL') then 'bad_side'
           when i.instrument_id is null                       then 'unknown_instrument'  -- lookup problem: not found in the dimension table
           when s.type = 'trade' and s.currency is distinct from i.currency then 'currency_mismatch'  -- currency differs from the instrument's own currency (null counts as different)
       end as reason
from step2 s
left join clean.instruments i on i.instrument_id = s.instrument_id;
