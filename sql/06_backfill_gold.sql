-- 回填 gold 层：清空 gold 的计算结果，从 clean 的第一行开始重算
--
-- 什么时候用：公式改了、gold 表结构改了、clean 层做过回填之后。日常不要用，日常运行 select * from gold.run();
-- 运行（项目根目录）：psql marketsim -v ON_ERROR_STOP=1 -f sql/06_backfill_gold.sql
--
-- 安全性：只动 gold 的计算结果表。预警规则（gold.alert_rules，阈值是你调过的）不会动；
--         固定参考汇率会被清掉，重算时重新取"数据里第一个有完整汇率的小时"。

truncate gold.fx_reference, gold.fx_rate_hourly, gold.position_state, gold.stock_hourly,
         gold.portfolio_hourly, gold.live_state, gold.alerts;
update gold.process_state set last_raw_id = 0, as_of = null, updated_at = now();

select * from gold.run();
