-- 预警历史：每次 dbt snapshot，状态有变化就新开一行。
-- dbt_valid_from = 进入这个状态的时间，dbt_valid_to = 离开的时间（空 = 现在仍是这个状态）。
{% snapshot snap_alert_status %}
{{ config(target_schema='gold_dbt_snapshots', unique_key='alert_key',
          strategy='check', check_cols=['status']) }}
select * from {{ ref('alert_status') }}
{% endsnapshot %}
