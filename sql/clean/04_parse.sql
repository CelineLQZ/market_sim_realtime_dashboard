-- clean 层 · 4/5 解析和检查
-- clean.v_parsed：把 raw 的每一行解析成字段，并判断坏在哪里（reason 为空 = 好行）。视图本身不存数据。

-- ============ 解析和检查（用一个视图把逻辑集中在一处） ============
-- 视图只是一段"保存下来的查询"，本身不存数据。下面用的时候会加上 raw_id 范围，所以只会解析新行。
create or replace view clean.v_parsed as
with step1 as (      -- 第 1 步：这一行能不能解析成 JSON？（乱码行在这里变成 null）
    select raw_id, received_at, payload,
           case when pg_input_is_valid(payload, 'jsonb') then payload::jsonb end as j
    from raw.events
),
step2 as (           -- 第 2 步：取出字段并转成正确类型；取不到或格式不对的，结果是 null
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
       -- 第 3 步：判断坏在哪里。case 从上往下，遇到第一个成立的就停，所以一行只会有一个原因。
       -- reason 为 null 表示这一行是好的。
       case
           when s.j is null                                   then 'not_json'            -- 格式问题
           when s.type is null or s.type not in ('trade','price') then 'unknown_type'
           when s.instrument_id is null                       then 'bad_instrument_id'
           when s.event_time is null                          then 'bad_date'
           when s.price is null                               then 'null_price'          -- 值的问题
           when s.price <= 0                                  then 'non_positive_price'
           when s.type = 'trade' and s.trade_id is null       then 'bad_trade_id'
           when s.type = 'trade' and (s.volume is null or s.volume <= 0) then 'bad_volume'
           when s.type = 'trade' and s.side is null           then 'bad_side'
           when s.type = 'trade' and s.side not in ('BUY','SELL') then 'bad_side'
           when i.instrument_id is null                       then 'unknown_instrument'  -- 关联问题：dim 表里查不到
           when s.type = 'trade' and s.currency is distinct from i.currency then 'currency_mismatch'  -- 币种和标的自己的币种不一致（null 也算不一致）
       end as reason
from step2 s
left join clean.instruments i on i.instrument_id = s.instrument_id;
