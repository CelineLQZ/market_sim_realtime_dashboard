"""Backend API: reads the gold tables for the dashboard.

Principle: read-only on gold, no P&L calculation here (all numbers are computed in gold). This file only:
  1. filters by parameters (date, dimension)
  2. computes simple differences such as "end value - start value"
  3. shapes the result into JSON the front end can use
Everything variable inside the SQL (dimension, sort column) comes from the whitelists below;
values from the user are only ever passed to the database as parameters.

Run (project root):   uvicorn api.main:app --port 8000
Interactive docs:     http://localhost:8000/docs
Environment:          DATABASE_URL (default dbname=marketsim)
"""
import os
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from typing import Annotated, Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.staticfiles import StaticFiles
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

DB = os.environ.get("DATABASE_URL", "dbname=marketsim")
DASHBOARD_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "dashboard")

QUALITY_WINDOW = 2000     # data quality: look at the last N raw rows

# ---- whitelists ----
# grouping dimension -> SQL expression (i = clean.instruments)
DIMS = {"country": "i.country", "sector": "i.sector", "exchange": "i.exchange",
        "currency": "i.currency", "stock": "i.short_name"}
# columns the instrument table can be sorted by -> SQL expression
STOCK_SORTS = {
    "ticker": "i.short_name", "name": "i.long_name", "country": "i.country", "sector": "i.sector",
    "position": "e.position", "price": "e.last_price", "unrealized": "e.unrealized", "realized": "e.realized",
    "total": "e.total", "mv": "e.mv_eur", "change": "change",
}

Dim = Annotated[str, Query(pattern="^(country|sector|exchange|currency|stock)$")]


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Connection pool: a few connections are reused instead of reconnecting per request. Session time zone is UTC, so all times are UTC.
    app.state.pool = ConnectionPool(DB, min_size=1, max_size=6, open=False,
                                    kwargs={"row_factory": dict_row, "options": "-c timezone=UTC"})
    app.state.pool.open(wait=True, timeout=15)
    yield
    app.state.pool.close()


app = FastAPI(title="market-sim API", lifespan=lifespan)


def q(sql, params=()):
    """Run one query and return all rows (each row is a dict)."""
    with app.state.pool.connection() as conn:
        return conn.execute(sql, params).fetchall()


def q1(sql, params=()):
    rows = q(sql, params)
    return rows[0] if rows else None


def inst_filters(country, sector, exchange, currency, ticker=None):
    """Turn "only this country/sector/exchange/currency/stock" into an SQL fragment + parameters. The query must alias clean.instruments as i."""
    sql, params = "", []
    for col, val in (("i.country", country), ("i.sector", sector), ("i.exchange", exchange),
                     ("i.currency", currency), ("i.short_name", ticker)):
        if val is not None:
            sql += f" and {col} = %s"
            params.append(val)
    return sql, params


Country = Annotated[Optional[str], Query()]
Sector = Annotated[Optional[str], Query()]
Exchange = Annotated[Optional[str], Query()]
Currency = Annotated[Optional[str], Query()]
Ticker = Annotated[Optional[str], Query(description="Only this stock (used when a stock is picked in the dashboard)")]


def values_source(at):
    """Per-instrument P&L at one moment. at=None means "now" (reads live_state); otherwise the last hourly snapshot at or before `at`."""
    if at is None:
        return ("select instrument_id, position, last_price, mv_eur, "
                "total_eur as total, realized_eur as realized, unrealized_eur as unrealized from gold.live_state"), []
    return ("select instrument_id, position, price as last_price, mv_eur, "
            "total_eur as total, realized_eur as realized, unrealized_eur as unrealized from gold.stock_hourly "
            "where snap_time = (select max(snap_time) from gold.stock_hourly where snap_time <= %s)"), [at]


def snapshot_sums(at, filt_sql, filt_params):
    """Total / realized / unrealized P&L of the last hourly snapshot at or before `at`, summed over the filter. at=None returns 0 (meaning "since the start")."""
    if at is None:
        return {"total": 0.0, "realized": 0.0, "unrealized": 0.0}
    src, p = values_source(at)
    return q1(f"select coalesce(sum(s.total), 0)::float8 as total, coalesce(sum(s.realized), 0)::float8 as realized, "
              f"       coalesce(sum(s.unrealized), 0)::float8 as unrealized "
              f"from ({src}) s join clean.instruments i on i.instrument_id = s.instrument_id "
              f"where true {filt_sql}", p + filt_params)


# =============== 1. meta: fetched once when the page loads ===============
@app.get("/api/meta")
def meta():
    """Possible values of each dimension, and the snapshot date range."""
    inst = q("select short_name as ticker, long_name as name, country, sector, industry, exchange, currency "
             "from clean.instruments where type = 'equity' order by short_name")
    dims = {d: sorted({r[d] for r in inst}) for d in ("country", "sector", "exchange", "currency")}
    rng = q1("select min(snap_time) as first_snapshot, max(snap_time) as last_snapshot, count(*) as snapshots "
             "from gold.portfolio_hourly")
    return {"dimensions": dims, "instruments": inst, "range": rng}


# =============== 2. status: the "as of" time and data health, every 5 s ===============
@app.get("/api/status")
def status():
    """as_of = latest event time in the data (simulated time); watermark = positions are final up to here. Feed / processor health uses the real clock."""
    r = q1("select (select as_of from gold.process_state) as as_of, "
           "       (select watermark from gold.process_state) as watermark, "
           "       (select too_late_total from gold.process_state) as too_late_total, "
           "       (select last_raw_id from clean.process_state) as clean_to_id, "
           "       (select coalesce(max(raw_id), 0) from raw.events) as raw_max_id, "
           "       (select count(*) from clean.dead_letter where raw_id > "
           "          (select last_raw_id from clean.process_state) - %s) as recent_rejected, "
           "       (select updated_at from gold.process_state) as processed_at, "
           "       (select received_at from raw.events order by raw_id desc limit 1) as last_message_at, "
           "       now() as server_time", [QUALITY_WINDOW])
    def age(t):
        return None if t is None else round((r["server_time"] - t).total_seconds(), 1)
    feed_age, proc_age = age(r["last_message_at"]), age(r["processed_at"])
    def state(a, ok, warn):
        return "unknown" if a is None else "ok" if a <= ok else "delayed" if a <= warn else "stale"
    window = min(QUALITY_WINDOW, r["clean_to_id"] or 0)      # share of the last N rows that were rejected: one number that shows data quality
    quality = {"window_rows": window, "rejected": r["recent_rejected"] if window else 0,
               "reject_rate": round(r["recent_rejected"] / window * 100, 2) if window else None,
               "backlog_rows": r["raw_max_id"] - (r["clean_to_id"] or 0)}
    return {"as_of": r["as_of"], "watermark": r["watermark"], "too_late_total": r["too_late_total"],
            "server_time": r["server_time"], "quality": quality,
            "feed": {"seconds_since_last_message": feed_age, "state": state(feed_age, 15, 60)},
            "processor": {"seconds_since_last_run": proc_age, "state": state(proc_age, 20, 120)}}


# =============== 3. kpis: the cards at the top, every 5 s ===============
@app.get("/api/kpis")
def kpis(date_from: Annotated[Optional[datetime], Query(alias="from")] = None,
         country: Country = None, sector: Sector = None, exchange: Exchange = None, currency: Currency = None,
         ticker: Ticker = None):
    fsql, fp = inst_filters(country, sector, exchange, currency, ticker)
    live = q1("select coalesce(sum(l.total_eur), 0)::float8 as total, coalesce(sum(l.realized_eur), 0)::float8 as realized, "
              "       coalesce(sum(l.unrealized_eur), 0)::float8 as unrealized, "
              "       count(*) filter (where l.position <> 0) as open_positions, max(l.as_of) as as_of "
              f"from gold.live_state l join clean.instruments i on i.instrument_id = l.instrument_id where true {fsql}", fp)
    as_of = live["as_of"]
    out = {"as_of": as_of, "total": live["total"], "realized": live["realized"],
           "unrealized": live["unrealized"], "open_positions": live["open_positions"]}
    # period change = now - snapshot at the start of the period (no start date = "since the beginning")
    out["change_period"] = live["total"] - snapshot_sums(date_from, fsql, fp)["total"]
    # last-hour change = now - snapshot one hour ago (unrealized P&L is the watched metric, so it gets its own number)
    if as_of is not None:
        h = snapshot_sums(as_of - timedelta(hours=1), fsql, fp)
        out["change_1h"] = live["total"] - h["total"]
        out["unrealized_change_1h"] = live["unrealized"] - h["unrealized"]
    else:
        out["change_1h"] = out["unrealized_change_1h"] = None
    return out


# =============== 4. pnl-curve: the main curve, hourly (with a "now" point at the end) ===============
@app.get("/api/pnl-curve")
def pnl_curve(dim: Annotated[str, Query(pattern="^(none|country|sector|exchange|currency)$")] = "none",
              date_from: Annotated[Optional[datetime], Query(alias="from")] = None,
              date_to: Annotated[Optional[datetime], Query(alias="to")] = None,
              rebase: bool = False,
              country: Country = None, sector: Sector = None, exchange: Exchange = None, currency: Currency = None,
              ticker: Ticker = None):
    """One point per hour: total, realized, unrealized P&L (EUR). dim=none is the whole portfolio, otherwise one line per group.
    Without an end date the last point is "now" (from live_state; live_index says where it is).
    rebase=true: every line minus its own first point, so the period starts at 0 ("how much did we make in this period")."""
    fsql, fp = inst_filters(country, sector, exchange, currency, ticker)
    grp = "'all'" if dim == "none" else DIMS[dim]
    t_sql, t_p = "", []
    if date_from is not None:
        t_sql += " and h.snap_time >= %s"; t_p.append(date_from)
    if date_to is not None:
        t_sql += " and h.snap_time <= %s"; t_p.append(date_to)
    rows = q(f"select h.snap_time as t, {grp} as key, sum(h.total_eur)::float8 as total, "
             f"       sum(h.realized_eur)::float8 as realized, sum(h.unrealized_eur)::float8 as unrealized "
             f"from gold.stock_hourly h join clean.instruments i on i.instrument_id = h.instrument_id "
             f"where true {t_sql} {fsql} group by 1, 2 order by 1, 2", t_p + fp)
    last_snap = rows[-1]["t"] if rows else None
    live_index = None
    if date_to is None:
        live = q(f"select max(l.as_of) as t, {grp} as key, sum(l.total_eur)::float8 as total, "
                 f"       sum(l.realized_eur)::float8 as realized, sum(l.unrealized_eur)::float8 as unrealized "
                 f"from gold.live_state l join clean.instruments i on i.instrument_id = l.instrument_id "
                 f"where true {fsql} group by 2", fp)
        if live and live[0]["t"] is not None and (last_snap is None or live[0]["t"] > last_snap):
            rows += live
            live_index = len({r["t"] for r in rows}) - 1
    times = sorted({r["t"] for r in rows})
    pos = {t: k for k, t in enumerate(times)}
    series = {}
    for r in rows:
        s = series.setdefault(r["key"], {m: [None] * len(times) for m in ("total", "realized", "unrealized")})
        for m in ("total", "realized", "unrealized"):
            s[m][pos[r["t"]]] = r[m]
    if rebase:
        for s in series.values():
            for m, vals in s.items():
                base = next((v for v in vals if v is not None), 0.0)
                s[m] = [None if v is None else v - base for v in vals]
    return {"dim": dim, "rebased": rebase, "t": times, "live_index": live_index,
            "series": [{"key": k, **v} for k, v in series.items()]}


# =============== 5. contributors: who contributed the P&L of the period ===============
@app.get("/api/contributors")
def contributors(dim: Dim = "country",
                 date_from: Annotated[Optional[datetime], Query(alias="from")] = None,
                 date_to: Annotated[Optional[datetime], Query(alias="to")] = None,
                 country: Country = None, sector: Sector = None, exchange: Exchange = None, currency: Currency = None,
                 ticker: Ticker = None):
    """P&L change per group = end of period - start of period, largest first.
    Drill-down: first dim=country, then after picking a country dim=stock&country=Netherlands shows each stock in it."""
    e_sql, e_p = values_source(date_to)
    fsql, fp = inst_filters(country, sector, exchange, currency, ticker)
    if date_from is not None:
        s_sql, s_p = values_source(date_from)
        start_join = f"left join ({s_sql}) s on s.instrument_id = e.instrument_id"
        t0, r0, u0 = "coalesce(s.total, 0)", "coalesce(s.realized, 0)", "coalesce(s.unrealized, 0)"
    else:
        start_join, s_p = "", []
        t0 = r0 = u0 = "0"
    rows = q(f"select {DIMS[dim]} as key, sum(e.total - {t0})::float8 as change, "
             f"       sum(e.realized - {r0})::float8 as realized_change, sum(e.unrealized - {u0})::float8 as unrealized_change, "
             f"       sum(e.total)::float8 as total_now, count(*) filter (where e.position <> 0) as open_positions "
             f"from ({e_sql}) e join clean.instruments i on i.instrument_id = e.instrument_id {start_join} "
             f"where true {fsql} group by 1 order by change desc", e_p + s_p + fp)
    gross = sum(abs(r["change"]) for r in rows) or 1.0
    for r in rows:
        r["share"] = abs(r["change"]) / gross      # share of the sum of absolute group changes, used for the bar length
    return {"dim": dim, "total_change": sum(r["change"] for r in rows), "items": rows}


# =============== 6. stocks: the instrument table, every 5 s ===============
@app.get("/api/stocks")
def stocks(sort: Annotated[str, Query(pattern="^(" + "|".join(STOCK_SORTS) + ")$")] = "total",
           direction: Annotated[str, Query(alias="dir", pattern="^(asc|desc)$")] = "desc",
           date_from: Annotated[Optional[datetime], Query(alias="from")] = None,
           country: Country = None, sector: Sector = None, exchange: Exchange = None, currency: Currency = None,
           ticker: Ticker = None):
    e_sql, e_p = values_source(None)
    fsql, fp = inst_filters(country, sector, exchange, currency, ticker)
    if date_from is not None:
        s_sql, s_p = values_source(date_from)
        start_join, t0 = f"left join ({s_sql}) s on s.instrument_id = e.instrument_id", "coalesce(s.total, 0)"
    else:
        start_join, s_p, t0 = "", [], "0"
    rows = q(f"select i.short_name as ticker, i.long_name as name, i.country, i.sector, i.exchange, i.currency, "
             f"       e.position::float8 as position, l.avg_cost::float8 as avg_cost, e.last_price::float8 as price, "
             f"       l.price_time, e.mv_eur::float8 as mv_eur, "
             f"       e.realized::float8 as realized, e.unrealized::float8 as unrealized, e.total::float8 as total, "
             f"       (e.total - {t0})::float8 as change "
             f"from ({e_sql}) e join clean.instruments i on i.instrument_id = e.instrument_id "
             f"join gold.live_state l on l.instrument_id = e.instrument_id {start_join} "
             f"where true {fsql} order by {STOCK_SORTS[sort]} {direction}, i.short_name", e_p + s_p + fp)
    return {"items": rows}


# =============== 7. one stock: fetched when a stock is clicked ===============
@app.get("/api/stocks/{ticker}")
def stock_detail(ticker: str,
                 date_from: Annotated[Optional[datetime], Query(alias="from")] = None,
                 date_to: Annotated[Optional[datetime], Query(alias="to")] = None):
    info = q1("select instrument_id, short_name as ticker, long_name as name, country, sector, industry, exchange, currency "
              "from clean.instruments where short_name = %s and type = 'equity'", (ticker,))
    if info is None:
        raise HTTPException(404, f"unknown ticker {ticker}")
    iid = info.pop("instrument_id")
    t_sql, t_p = "", []
    if date_from is not None:
        t_sql += " and snap_time >= %s"; t_p.append(date_from)
    if date_to is not None:
        t_sql += " and snap_time <= %s"; t_p.append(date_to)
    hist = q(f"select snap_time as t, price::float8 as price, position::float8 as position, avg_cost::float8 as avg_cost, "
             f"       total_eur::float8 as total, realized_eur::float8 as realized, unrealized_eur::float8 as unrealized "
             f"from gold.stock_hourly where instrument_id = %s {t_sql} order by snap_time", [iid] + t_p)
    live = q1(f"select position::float8 as position, avg_cost::float8 as avg_cost, last_price::float8 as price, "
              f"       price_time, total_eur::float8 as total, "
              f"       realized_eur::float8 as realized, unrealized_eur::float8 as unrealized, fx_rate::float8 as fx_rate, as_of "
              f"from gold.live_state where instrument_id = %s", (iid,))
    return {"info": info, "live": live, "history": hist}


# Front end: static files from the dashboard/ folder. Mounted last so it does not shadow the /api/ routes above.
if os.path.isdir(DASHBOARD_DIR):
    app.mount("/", StaticFiles(directory=DASHBOARD_DIR, html=True), name="dashboard")
