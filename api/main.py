"""后端 API：把 gold 层的表查出来，给看板用。

原则：只读 gold，不做任何盈亏计算（所有数字在 gold 里算好了）。这里只做三件事：
  1. 按参数筛选（日期、维度、汇率口径）
  2. 把"期末值 - 期初值"这类简单的差值算出来
  3. 整理成前端好用的 JSON
所有 SQL 里能变的部分（维度、汇率口径、排序列）都来自下面的白名单，用户传来的值只作为参数传给数据库。

运行（项目根目录）：  uvicorn api.main:app --port 8000
接口文档（自动生成）：  http://localhost:8000/docs
环境变量：  DATABASE_URL（默认 dbname=marketsim）
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

QUALITY_WINDOW = 2000     # 数据质量：看最近多少行原始数据

# ---- 白名单 ----
# 汇率口径 -> (总盈亏, 已实现, 未实现) 在 stock_hourly / live_state / portfolio_hourly 里的列名（三张表同名）
FX = {
    "market":   ("total_eur",     "realized_eur",     "unrealized_eur"),
    "constant": ("total_eur_cfx", "realized_eur_cfx", "unrealized_eur_cfx"),
}
# 分组维度 -> SQL 表达式（i = clean.instruments）
DIMS = {"country": "i.country", "sector": "i.sector", "exchange": "i.exchange",
        "currency": "i.currency", "stock": "i.short_name"}
# 个股表可以按哪些列排序 -> SQL 表达式
STOCK_SORTS = {
    "ticker": "i.short_name", "name": "i.long_name", "country": "i.country", "sector": "i.sector",
    "position": "e.position", "price": "e.last_price", "unrealized": "e.unrealized", "realized": "e.realized",
    "total": "e.total", "mv": "e.mv_eur", "change": "change", "age": "e.price_age_min",
}

FxMode = Annotated[str, Query(pattern="^(market|constant)$", description="market = 每个时刻用当时的汇率；constant = 固定参考汇率")]
Dim = Annotated[str, Query(pattern="^(country|sector|exchange|currency|stock)$")]


@asynccontextmanager
async def lifespan(app: FastAPI):
    # 连接池：几个连接反复使用，不用每个请求都重新连数据库。会话时区固定 UTC，输出的时间都是 UTC。
    app.state.pool = ConnectionPool(DB, min_size=1, max_size=6, open=False,
                                    kwargs={"row_factory": dict_row, "options": "-c timezone=UTC"})
    app.state.pool.open(wait=True, timeout=15)
    yield
    app.state.pool.close()


app = FastAPI(title="market-sim API", lifespan=lifespan)


def q(sql, params=()):
    """执行一条查询，返回全部行（每行是 dict）。"""
    with app.state.pool.connection() as conn:
        return conn.execute(sql, params).fetchall()


def q1(sql, params=()):
    rows = q(sql, params)
    return rows[0] if rows else None


def inst_filters(country, sector, exchange, currency, ticker=None):
    """把"只看某个国家/行业/交易所/币种/某只股票"变成 SQL 片段 + 参数。要求查询里 clean.instruments 的别名是 i。"""
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
Ticker = Annotated[Optional[str], Query(description="只看这一只股票（看板里点选某只股票时用）")]


def values_source(fx, at):
    """某一时刻每个标的的盈亏。at=None 表示"现在"（读 live_state），否则读 at 之前最近的一个整点快照。"""
    tot, real, unr = FX[fx]
    if at is None:
        return (f"select instrument_id, position, last_price, price_age_min, mv_eur, "
                f"{tot} as total, {real} as realized, {unr} as unrealized from gold.live_state"), []
    return (f"select instrument_id, position, price as last_price, 0 as price_age_min, mv_eur, "
            f"{tot} as total, {real} as realized, {unr} as unrealized from gold.stock_hourly "
            f"where snap_time = (select max(snap_time) from gold.stock_hourly where snap_time <= %s)"), [at]


def snapshot_sums(fx, at, filt_sql, filt_params):
    """at 之前最近一个整点快照的 总/已实现/未实现 盈亏（按筛选条件汇总）。at=None 返回 0（即"从开始算起"）。"""
    if at is None:
        return {"total": 0.0, "realized": 0.0, "unrealized": 0.0}
    src, p = values_source(fx, at)
    return q1(f"select coalesce(sum(s.total), 0)::float8 as total, coalesce(sum(s.realized), 0)::float8 as realized, "
              f"       coalesce(sum(s.unrealized), 0)::float8 as unrealized "
              f"from ({src}) s join clean.instruments i on i.instrument_id = s.instrument_id "
              f"where true {filt_sql}", p + filt_params)


# =============== 1. meta：页面加载时取一次 ===============
@app.get("/api/meta")
def meta():
    """维度的可选值、日期范围、固定参考汇率。"""
    inst = q("select short_name as ticker, long_name as name, country, sector, industry, exchange, currency "
             "from clean.instruments where type = 'equity' order by short_name")
    dims = {d: sorted({r[d] for r in inst}) for d in ("country", "sector", "exchange", "currency")}
    rng = q1("select min(snap_time) as first_snapshot, max(snap_time) as last_snapshot, count(*) as snapshots "
             "from gold.portfolio_hourly")
    ref = q("select ccy, rate_to_eur::float8 as rate_to_eur from gold.fx_reference order by ccy")
    return {"dimensions": dims, "instruments": inst, "range": rng, "fx_reference": ref}


# =============== 2. status：右上角的"as of"和数据健康，5 秒一次 ===============
@app.get("/api/status")
def status():
    """as_of = 数据里最新的事件时间（模拟时间）。数据源/处理器是否正常用真实时钟判断。"""
    r = q1("select (select as_of from gold.process_state) as as_of, "
           "       (select last_raw_id from clean.process_state) as clean_to_id, "
           "       (select coalesce(max(raw_id), 0) from raw.events) as raw_max_id, "
           "       (select count(*) from clean.dead_letter where raw_id > "
           "          (select last_raw_id from clean.process_state) - %s) as recent_rejected, "
           "       (select updated_at from gold.process_state) as processed_at, "
           "       (select received_at from raw.events order by raw_id desc limit 1) as last_message_at, "
           "       (select count(*) from gold.alerts where cleared_at is null) as open_alerts, "
           "       now() as server_time", [QUALITY_WINDOW])
    def age(t):
        return None if t is None else round((r["server_time"] - t).total_seconds(), 1)
    feed_age, proc_age = age(r["last_message_at"]), age(r["processed_at"])
    def state(a, ok, warn):
        return "unknown" if a is None else "ok" if a <= ok else "delayed" if a <= warn else "stale"
    window = min(QUALITY_WINDOW, r["clean_to_id"] or 0)      # 最近 N 行里被拒绝的比例：一个数字就能看出数据质量
    quality = {"window_rows": window, "rejected": r["recent_rejected"] if window else 0,
               "reject_rate": round(r["recent_rejected"] / window * 100, 2) if window else None,
               "backlog_rows": r["raw_max_id"] - (r["clean_to_id"] or 0)}
    return {"as_of": r["as_of"], "server_time": r["server_time"], "open_alerts": r["open_alerts"], "quality": quality,
            "feed": {"seconds_since_last_message": feed_age, "state": state(feed_age, 15, 60)},
            "processor": {"seconds_since_last_run": proc_age, "state": state(proc_age, 20, 120)}}


# =============== 3. kpis：顶部指标卡，5 秒一次 ===============
@app.get("/api/kpis")
def kpis(fx: FxMode = "market", date_from: Annotated[Optional[datetime], Query(alias="from")] = None,
         country: Country = None, sector: Sector = None, exchange: Exchange = None, currency: Currency = None,
         ticker: Ticker = None):
    tot, real, unr = FX[fx]
    fsql, fp = inst_filters(country, sector, exchange, currency, ticker)
    live = q1(f"select coalesce(sum(l.{tot}), 0)::float8 as total, coalesce(sum(l.{real}), 0)::float8 as realized, "
              f"       coalesce(sum(l.{unr}), 0)::float8 as unrealized, "
              f"       coalesce(sum(l.mv_eur) filter (where l.mv_eur > 0), 0)::float8 as long_mv, "
              f"       coalesce(sum(l.mv_eur) filter (where l.mv_eur < 0), 0)::float8 as short_mv, "
              f"       count(*) filter (where l.position <> 0) as open_positions, max(l.as_of) as as_of "
              f"from gold.live_state l join clean.instruments i on i.instrument_id = l.instrument_id where true {fsql}", fp)
    as_of = live["as_of"]
    out = {"fx": fx, "as_of": as_of, "total": live["total"], "realized": live["realized"],
           "unrealized": live["unrealized"], "long_mv": live["long_mv"], "short_mv": live["short_mv"],
           "gross": live["long_mv"] - live["short_mv"], "net": live["long_mv"] + live["short_mv"],
           "open_positions": live["open_positions"]}
    # 区间变化 = 现在 - 区间开始时的快照（不选开始日期就是"从头算起"）
    out["change_period"] = live["total"] - snapshot_sums(fx, date_from, fsql, fp)["total"]
    # 最近一小时的变化 = 现在 - 一小时之前的快照（未实现盈亏是"重点监控"的指标，单独给一份）
    if as_of is not None:
        h = snapshot_sums(fx, as_of - timedelta(hours=1), fsql, fp)
        out["change_1h"] = live["total"] - h["total"]
        out["unrealized_change_1h"] = live["unrealized"] - h["unrealized"]
    else:
        out["change_1h"] = out["unrealized_change_1h"] = None
    # 回撤：和预警规则一致，始终按"市场汇率、整个组合"算，不受筛选和汇率口径影响
    dd = q1("select peak_total_eur::float8 as peak, (select coalesce(sum(total_eur), 0)::float8 from gold.live_state) as live_total "
            "from gold.portfolio_hourly order by snap_time desc limit 1")
    if dd:
        peak = max(dd["peak"] or 0.0, dd["live_total"])
        out["peak_eur"], out["drawdown_eur"] = peak, dd["live_total"] - peak
    else:
        out["peak_eur"], out["drawdown_eur"] = None, None
    out["open_alerts"] = q1("select count(*) as n from gold.alerts where cleared_at is null")["n"]
    return out


# =============== 4. pnl-curve：主曲线，每小时一次（末尾附上"现在"这一点） ===============
@app.get("/api/pnl-curve")
def pnl_curve(dim: Annotated[str, Query(pattern="^(none|country|sector|exchange|currency)$")] = "none",
              fx: FxMode = "market",
              date_from: Annotated[Optional[datetime], Query(alias="from")] = None,
              date_to: Annotated[Optional[datetime], Query(alias="to")] = None,
              rebase: bool = False,
              country: Country = None, sector: Sector = None, exchange: Exchange = None, currency: Currency = None,
              ticker: Ticker = None):
    """每小时一个点：总盈亏、已实现、未实现（欧元）。dim=none 是整个组合，否则每个分组一条线。
    没选结束日期时，最后一个点是"现在"（来自 live_state，live_index 指出它的位置）。
    rebase=true：每条线减去自己的第一个点，让区间从 0 开始（看"这段时间赚了多少"）。"""
    tot, real, unr = FX[fx]
    fsql, fp = inst_filters(country, sector, exchange, currency, ticker)
    grp = "'all'" if dim == "none" else DIMS[dim]
    t_sql, t_p = "", []
    if date_from is not None:
        t_sql += " and h.snap_time >= %s"; t_p.append(date_from)
    if date_to is not None:
        t_sql += " and h.snap_time <= %s"; t_p.append(date_to)
    rows = q(f"select h.snap_time as t, {grp} as key, sum(h.{tot})::float8 as total, "
             f"       sum(h.{real})::float8 as realized, sum(h.{unr})::float8 as unrealized "
             f"from gold.stock_hourly h join clean.instruments i on i.instrument_id = h.instrument_id "
             f"where true {t_sql} {fsql} group by 1, 2 order by 1, 2", t_p + fp)
    last_snap = rows[-1]["t"] if rows else None
    live_index = None
    if date_to is None:
        live = q(f"select max(l.as_of) as t, {grp} as key, sum(l.{tot})::float8 as total, "
                 f"       sum(l.{real})::float8 as realized, sum(l.{unr})::float8 as unrealized "
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
    return {"fx": fx, "dim": dim, "rebased": rebase, "t": times, "live_index": live_index,
            "series": [{"key": k, **v} for k, v in series.items()]}


# =============== 5. contributors：谁贡献了这段时间的盈亏，每小时一次 ===============
@app.get("/api/contributors")
def contributors(dim: Dim = "country", fx: FxMode = "market",
                 date_from: Annotated[Optional[datetime], Query(alias="from")] = None,
                 date_to: Annotated[Optional[datetime], Query(alias="to")] = None,
                 country: Country = None, sector: Sector = None, exchange: Exchange = None, currency: Currency = None,
                 ticker: Ticker = None):
    """按维度分组的区间盈亏变化 = 区间末 - 区间初，从大到小排序。
    下钻：先 dim=country，点某个国家后用 dim=stock&country=Netherlands 看这个国家里每只股票。"""
    e_sql, e_p = values_source(fx, date_to)
    fsql, fp = inst_filters(country, sector, exchange, currency, ticker)
    if date_from is not None:
        s_sql, s_p = values_source(fx, date_from)
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
        r["share"] = abs(r["change"]) / gross      # 占"所有分组变化的绝对值之和"的比例，用来画条的长度
    return {"fx": fx, "dim": dim, "total_change": sum(r["change"] for r in rows), "items": rows}


# =============== 6. stocks：个股表，5 秒一次 ===============
@app.get("/api/stocks")
def stocks(fx: FxMode = "market", sort: Annotated[str, Query(pattern="^(" + "|".join(STOCK_SORTS) + ")$")] = "total",
           direction: Annotated[str, Query(alias="dir", pattern="^(asc|desc)$")] = "desc",
           date_from: Annotated[Optional[datetime], Query(alias="from")] = None,
           country: Country = None, sector: Sector = None, exchange: Exchange = None, currency: Currency = None,
           ticker: Ticker = None):
    e_sql, e_p = values_source(fx, None)
    fsql, fp = inst_filters(country, sector, exchange, currency, ticker)
    if date_from is not None:
        s_sql, s_p = values_source(fx, date_from)
        start_join, t0 = f"left join ({s_sql}) s on s.instrument_id = e.instrument_id", "coalesce(s.total, 0)"
    else:
        start_join, s_p, t0 = "", [], "0"
    rows = q(f"select i.short_name as ticker, i.long_name as name, i.country, i.sector, i.exchange, i.currency, "
             f"       e.position::float8 as position, l.avg_cost::float8 as avg_cost, e.last_price::float8 as price, "
             f"       e.price_age_min::float8 as price_age_min, l.in_session, e.mv_eur::float8 as mv_eur, "
             f"       e.realized::float8 as realized, e.unrealized::float8 as unrealized, e.total::float8 as total, "
             f"       (e.total - {t0})::float8 as change "
             f"from ({e_sql}) e join clean.instruments i on i.instrument_id = e.instrument_id "
             f"join gold.live_state l on l.instrument_id = e.instrument_id {start_join} "
             f"where true {fsql} order by {STOCK_SORTS[sort]} {direction}, i.short_name", e_p + s_p + fp)
    return {"fx": fx, "items": rows}


# =============== 7. 单只股票：点击个股时取 ===============
@app.get("/api/stocks/{ticker}")
def stock_detail(ticker: str, fx: FxMode = "market",
                 date_from: Annotated[Optional[datetime], Query(alias="from")] = None,
                 date_to: Annotated[Optional[datetime], Query(alias="to")] = None):
    tot, real, unr = FX[fx]
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
             f"       {tot}::float8 as total, {real}::float8 as realized, {unr}::float8 as unrealized "
             f"from gold.stock_hourly where instrument_id = %s {t_sql} order by snap_time", [iid] + t_p)
    live = q1(f"select position::float8 as position, avg_cost::float8 as avg_cost, last_price::float8 as price, "
              f"       price_time, price_age_min::float8 as price_age_min, in_session, {tot}::float8 as total, "
              f"       {real}::float8 as realized, {unr}::float8 as unrealized, fx_rate::float8 as fx_rate, as_of "
              f"from gold.live_state where instrument_id = %s", (iid,))
    return {"fx": fx, "info": info, "live": live, "history": hist}


# =============== 8. alerts：预警面板，5 秒一次 ===============
@app.get("/api/alerts")
def alerts(status: Annotated[str, Query(pattern="^(open|all)$")] = "open", limit: Annotated[int, Query(ge=1, le=500)] = 50):
    where = "where a.cleared_at is null" if status == "open" else ""
    rows = q(f"select a.alert_id, a.rule_id, r.description, a.scope, a.fired_at, a.cleared_at, "
             f"       a.fired_value::float8 as fired_value, a.last_value::float8 as last_value, "
             f"       a.threshold::float8 as threshold, a.severity, r.unit "
             f"from gold.alerts a join gold.alert_rules r using (rule_id) {where} "
             f"order by (a.cleared_at is null) desc, a.fired_at desc limit %s", (limit,))
    return {"status": status, "items": rows}


# 前端页面：dashboard/ 文件夹里的静态文件。放在最后，这样不会盖住上面的 /api/ 路径。
if os.path.isdir(DASHBOARD_DIR):
    app.mount("/", StaticFiles(directory=DASHBOARD_DIR, html=True), name="dashboard")
