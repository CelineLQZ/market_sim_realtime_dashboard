{#
  估值公式：只写在这一处，stock_hourly 和 live_state 共用，两边不会算得不一样。
  调用它的查询里必须有这几列：
    position, avg_cost, price, realized_local（本币）, market_fx, constant_fx（1 单位本币 = 多少欧元）
  两种欧元口径：
    market_fx   = 当时的市场汇率
    constant_fx = 固定参考汇率（两者之差 = 汇率带来的盈亏）
#}
{% macro pnl_columns() %}
    position * (price - avg_cost)                                  as unrealized_local,
    position * price                                               as mv_local,
    market_fx                                                      as fx_rate,
    realized_local * market_fx                                     as realized_eur,
    position * (price - avg_cost) * market_fx                      as unrealized_eur,
    (realized_local + position * (price - avg_cost)) * market_fx   as total_eur,
    position * price * market_fx                                   as mv_eur,
    realized_local * constant_fx                                   as realized_eur_cfx,
    position * (price - avg_cost) * constant_fx                    as unrealized_eur_cfx,
    (realized_local + position * (price - avg_cost)) * constant_fx as total_eur_cfx
{% endmacro %}
