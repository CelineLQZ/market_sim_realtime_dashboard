-- gold 层：看板直接读取的表，以及把 clean 层算成这些表的函数
--
-- 表（对应看板的各个模块）
--   gold.fx_reference     固定参考汇率（Constant FX 用），只写一次
--   gold.fx_rate_hourly   每小时一个汇率：币种 x 小时
--   gold.position_state   每笔成交之后的持仓、平均成本、累计已实现盈亏（本币）
--   gold.stock_hourly     核心事实表：标的 x 小时（持仓、价格、盈亏，本币 + 两种口径的欧元）
--   gold.portfolio_hourly 全组合：每小时的盈亏、敞口、历史最高点和回撤
--   gold.live_state       每个标的一行的"当前状态"，每次运行覆盖写（实时模块读它）
--   gold.alert_rules      预警规则（回撤、单只股票大亏，阈值可以改）
--   gold.alerts           预警事件：触发时间、解除时间
--   gold.process_state    进度：处理到 clean 的哪一行
--
-- 函数
--   gold.run()            日常运行入口，增量处理新数据（实时循环里反复调用）
--   gold.nightly_fix(t)   收盘后批处理：从 t 起重算小时快照，补上迟到的报价
--   gold.apply_new_trades / gold.rebuild_hourly / gold.refresh_live / gold.evaluate_alerts   run() 内部用
--   gold.fx_rates_at / gold.value_position   小时与实时路径共用的汇率和估值公式
--   gold.rebuild_fx_hourly / rebuild_stock_hourly / rebuild_portfolio_hourly   小时重算的三个可独立测试步骤
--
-- 运行：psql marketsim -v ON_ERROR_STOP=1 -f sql/gold/install.sql     （建表和函数，可重复运行）
--       psql marketsim -c "select * from gold.run()"             （处理新数据）

-- 代码按职责拆在 sql/gold/ 下，这里按顺序引入（\ir = 相对本文件的路径）：
\ir 01_tables.sql
\ir 02_valuation.sql
\ir 02_positions.sql
\ir 03_hourly.sql
\ir 04_live.sql
\ir 05_alerts.sql
\ir 06_run.sql
