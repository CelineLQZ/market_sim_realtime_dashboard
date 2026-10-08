-- 修正审计：某个小时的总盈亏被迟到数据改了，就会留下两行 —— 修正前和修正后。
-- 对应原版的 gold.restatement。
{% snapshot snap_portfolio_hourly %}
{{ config(target_schema='gold_dbt_snapshots', unique_key='snap_time',
          strategy='check', check_cols=['total_eur']) }}
select snap_time, total_eur from {{ ref('portfolio_hourly') }}
{% endsnapshot %}
