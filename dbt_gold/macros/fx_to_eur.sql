{#
  三个汇率报价 → 每个币种 "1 单位 = 多少欧元"。
  GBP 和 JPY 没有直接对欧元的汇率，要经过美元中转。
  用法：cross join lateral {{ fx_to_eur('q.eurusd', 'q.gbpusd', 'q.usdjpy') }} as fx(ccy, rate_to_eur)
#}
{% macro fx_to_eur(eurusd, gbpusd, usdjpy) %}
    (values
        ('EUR', 1::numeric),
        ('USD', 1 / {{ eurusd }}),                     -- USD → EUR
        ('GBP', {{ gbpusd }} / {{ eurusd }}),          -- GBP → USD → EUR
        ('JPY', 1 / {{ usdjpy }} / {{ eurusd }})       -- JPY → USD → EUR
    )
{% endmacro %}
