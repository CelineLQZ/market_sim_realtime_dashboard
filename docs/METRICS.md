# Metric dictionary

This document is the contract for the numbers exposed by the API and dashboard. The P&L accounting rules and a worked trade-by-trade example are in [README.md](../README.md#2-how-the-pl-is-calculated).

## Conventions

- Event timestamps are UTC. `as_of` is the latest event time seen; `watermark` is the event time up to which positions are final.
- Position and market value are signed: long is positive and short is negative.
- Trade price, average cost and local-currency P&L use the instrument's trading currency.
- `fx_rate` means **EUR per one unit of local currency**. All `*_eur` values are local values multiplied by this rate.
- A stock with no quote is omitted because it cannot be valued. EUR values are produced only after all three source FX quotes exist.
- When an API receives a timestamp, it uses the latest completed hourly snapshot at or before that timestamp.

## Position and instrument-level measures

| Metric | Grain | Definition | Unit | Source |
|---|---|---|---|---|
| `position` | instrument after trade / instrument now / instrument-hour | Previous position + signed trade quantity; BUY is positive and SELL is negative | shares | `position_state`, `live_state`, `stock_hourly` |
| `avg_cost` | same as position | Quantity-weighted entry price when adding; unchanged when partially closing; zero when flat; reset to the trade price when a trade crosses zero | local currency/share | Gold |
| `realized_delta` | trade | `closed quantity × (trade price − previous average cost) × sign(previous position)` | local currency | `position_state` |
| `realized_local` | instrument snapshot | Cumulative `realized_delta` through the final position state used by the snapshot | local currency | Gold |
| `unrealized_local` | instrument snapshot | `position × (mark price − avg_cost)` | local currency | Gold |
| `mv_local` | instrument snapshot | `position × mark price`; negative for a short | local currency | Gold |
| `fx_rate` | currency-hour / currency now | EUR value of one unit of local currency | EUR/local currency | `fx_rate_hourly`, `live_state` |
| `realized_eur` | instrument snapshot | `realized_local × fx_rate` | EUR | Gold |
| `unrealized_eur` | instrument snapshot | `unrealized_local × fx_rate` | EUR | Gold |
| `total_eur` | instrument snapshot | `realized_eur + unrealized_eur` | EUR | Gold |
| `mv_eur` | instrument snapshot | `mv_local × fx_rate`; negative for a short | EUR | Gold |

`realized_eur` can change when FX changes even without a new trade. The model assumes realized foreign-currency proceeds remain in that currency and are translated at the current/snapshot spot rate.

## Portfolio and dashboard metrics

All metrics respect the active country, sector, exchange, currency and stock filters.

| Metric | Exact definition | Time behavior |
|---|---|---|
| Current total P&L | `SUM(live_state.total_eur)` | Current live value |
| Current realized P&L | `SUM(live_state.realized_eur)` | Current live value |
| Current unrealized P&L | `SUM(live_state.unrealized_eur)` | Current live value |
| Open positions | Count of instruments where `position <> 0` | Current live value |
| Period change | Current/end total P&L minus total P&L at the latest snapshot at or before the selected start | Difference, not a sum over time |
| One-hour change | Current total P&L minus total P&L at the latest snapshot at or before `as_of − 1 hour` | Live-to-snapshot difference |
| One-hour unrealized change | Current unrealized P&L minus unrealized P&L at the same one-hour start snapshot | Live-to-snapshot difference |
| P&L curve | Sum of stock-hour realized, unrealized and total P&L for every hour and selected group | One snapshot value per hour |
| Rebased curve | Each series minus its first non-null displayed value | Starts each displayed series at zero |
| Contribution change | Group end total P&L minus group start total P&L | Country, sector, exchange, currency or stock |
| Contribution share | `abs(group change) / SUM(abs(all displayed group changes))` | Visual bar length; it is not share of net portfolio change |
| Instrument period change | Instrument end/current total P&L minus its total P&L at the start snapshot | Difference, not a sum over time |

If no period start is selected, the API uses zero as the starting value ("since the beginning"). If a period end is supplied, the latest hourly snapshot at or before it is used; otherwise the live state is used.

## Data-quality and freshness metrics

| Metric | Definition |
|---|---|
| `reject_rate` | Dead-letter rows among the most recent up to 2,000 processed raw IDs, divided by that window size. Conflicting prices count as rejected; exact duplicates do not |
| `backlog_rows` | Maximum `raw_id` minus `clean.process_state.last_raw_id` |
| `too_late_total` | Cumulative trades that arrived at or behind the previous watermark and were therefore not applied to streaming positions |
| `as_of` | Latest event time found in clean prices or trades |
| `watermark` | Monotonic finality boundary, normally `as_of − 5 minutes` |
| Feed state | `ok` through 15 real seconds since the last raw message, `delayed` through 60 seconds, then `stale` |
| Processor state | `ok` through 20 real seconds since the last Gold update, `delayed` through 120 seconds, then `stale` |

The too-late counter covers trades only. A late quote remains available in `clean.prices`, but if its hour has already been finalized it does not restate that historical snapshot and is not counted separately.

## Aggregation rules

- `realized_eur`, `unrealized_eur`, `total_eur` and signed `mv_eur` are additive across instruments **at the same time**.
- Position is additive only when the business meaning of combining the instruments is clear; average cost and price are not additive.
- Snapshot P&L is **semi-additive**: never sum it across hours. Use an end-minus-start difference for a period.
- `mv_eur` is signed market value, not gross exposure. Gross/net exposure metrics are not part of the current primary pipeline.

## Exclusions

The current metrics exclude fees, commissions, dividends, financing costs, cash accounts, FX trades and bid/ask liquidation marking. They report local-currency trading P&L translated to EUR, not the full return of a euro-funded investor.
