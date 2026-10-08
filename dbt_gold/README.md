# dbt_gold：用 dbt 改写的 gold 层

读 `clean` 层，算出和 `sql/gold/` 一样的表，写进 `gold_dbt` schema。原来的 `gold` schema 不受影响，两版可以并存、对比。

## 运行

```bash
cd dbt_gold
python3.12 -m venv .venv && .venv/bin/pip install dbt-postgres   # 第一次
.venv/bin/dbt build          # seed → 模型 → 测试 → 快照，按依赖顺序一次跑完
.venv/bin/dbt docs generate && .venv/bin/dbt docs serve           # 看血缘图
```

前提：本机 PostgreSQL 里已经有 `marketsim` 库和 clean 层的数据（`make up` 跑过一段时间即可）。

## 文件和原版的对应关系

| dbt 文件 | 做什么 | 原版（sql/gold/） |
|---|---|---|
| `models/intermediate/int_hours.sql` | 要做快照的整点（只保留交易日） | `generate_series` 散落在各个 rebuild 函数里 |
| `models/intermediate/int_trades_ordered.sql` | 给每个标的的成交编号 1, 2, 3 … | — |
| `models/intermediate/int_positions.sql` | 平均成本法，逐笔算持仓（递归 CTE） | `gold.apply_new_trades()` → `gold.position_state` |
| `models/gold/fx_rate_hourly.sql` | 币种 × 小时的欧元汇率 | `gold.rebuild_fx_hourly()` + `gold.fx_rates_at()` |
| `models/gold/fx_reference.sql` | 固定参考汇率 | `gold.fx_reference` |
| `models/gold/stock_hourly.sql` | 核心事实表：股票 × 小时 | `gold.rebuild_stock_hourly()` |
| `models/gold/portfolio_hourly.sql` | 组合、敞口、回撤 | `gold.rebuild_portfolio_hourly()` |
| `models/gold/live_state.sql` | 每只股票的当前状态 | `gold.refresh_live()` |
| `models/gold/alert_status.sql` + `seeds/alert_rules.csv` | 预警当前状态；阈值在 CSV 里改 | `gold.evaluate_alerts()` + `gold.alert_rules` |
| `snapshots/snap_alert_status.sql` | 预警什么时候触发、什么时候解除 | `gold.alerts` |
| `snapshots/snap_portfolio_hourly.sql` | 哪个小时被迟到数据改过 | 早期版本的 `gold.restatement` |
| `macros/pnl_columns.sql` | 估值公式，只写一处 | `gold.value_position()` |
| `macros/fx_to_eur.sql` | 经美元中转的汇率换算 | `gold.fx_rates_at()` 里的 `values` |
| `models/gold/gold.yml` + `tests/` | 20 个数据测试 | — |
| `analyses/compare_with_sql_gold.sql` | 和原版逐行对比 | — |

不再需要的：`gold.run()`、`gold.nightly_fix()`、`gold.process_state`。执行顺序由 `ref()` 自动推导，见下一节。

## 和原版最大的不同：整表重建，不做增量

原版为了每 5 秒跑一次，需要记录进度（`process_state`），遇到迟到的成交就"删掉、从那一笔起重放"，收盘后再用 `nightly_fix` 修正迟到的报价。

dbt 版每次 **整表重建**：所有成交按事件时间排好序，从头算一遍。迟到的数据自然落进正确的位置，所以重放和收盘修正这两套逻辑都不需要了。代价是数据量很大时会变慢；到那时可以把 `int_positions` 改成 `incremental` 模型。

## 两处值得注意的写法

**1. 递归 CTE 代替循环**（`int_positions.sql`）

平均成本取决于上一笔的结果，没法用普通的 `GROUP BY` 或窗口函数算。递归 CTE 先算第 1 笔，再用第 n 笔的结果算第 n+1 笔，作用相当于原版 plpgsql 里的 `for` 循环，但写出来仍然是一条 `SELECT`。

**2. 有状态的预警交给 snapshot**

"触发后要回到解除阈值以内才算解除"需要记住上一次的状态，而 dbt 模型每次只看得到"现在"。所以拆成两部分：
- `alert_status` 只判断当前值落在哪个区间：`firing`、`holding`（在两个阈值之间）、`ok`；
- `snap_alert_status` 在状态变化时新开一行。`dbt_valid_from` 就是触发或解除的时间。

局限：快照只在运行 `dbt snapshot` 或 `dbt build` 时记录，所以时间精度取决于你多久跑一次 dbt。

## 验证结果（2026-10-08，本机数据：1535 笔成交、1354 条报价）

- `dbt build`：32 项全部通过（1 个 seed、9 个模型、20 个测试、2 个快照）。
- 和手写版逐行对比，差异行数全部为 0：`position_state` / `int_positions`、`stock_hourly`（513 行）、`portfolio_hourly`（24 行）、`fx_rate_hourly`、`live_state`。
- 预警：这批数据两版都没有触发预警，所以只验证了"都不触发"这一种情况。

自己复查：

```bash
.venv/bin/dbt compile --select compare_with_sql_gold
psql marketsim -f target/compiled/market_gold/analyses/compare_with_sql_gold.sql
```
