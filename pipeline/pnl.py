"""Local P&L engine: the same logic the Databricks Silver/Gold layers will implement.

Feed it raw simulator lines with `Book.on_line`; read the state with `Book.snapshot`.

Rules (kept deliberately simple, see README):
  * Every `trade` message is one of OUR fills: BUY adds shares, SELL removes them (shorting allowed).
  * Position cost uses the average-cost method, in the instrument's own currency.
  * Mark price = latest price by EVENT time (a late message never overwrites a newer mark).
  * Everything is converted to EUR at the latest FX rate (no FX P&L split).
  * Total P&L = realized + unrealized = cumulative cash flow + position x mark.
    The second form needs no cost method, which is what makes it a good independent check.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from simulator.market import SESSIONS_UTC

DEFAULT_LIMITS = {
    "loss_warn": 0.01,         # unrealized loss, share of cost basis
    "loss_crit": 0.02,
    "notional_limit_eur": 40_000_000,   # per-instrument position limit; warning at 80%
    "stale_minutes": 30,       # open position whose mark is older than this while its market is open
}


def parse_ts(s: str) -> datetime:
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def eur(x: float) -> str:
    sign = "\u2212" if x < 0 else ""
    a = abs(x)
    return f"{sign}€{a / 1e6:.2f}M" if a >= 1e6 else f"{sign}€{a / 1e3:.0f}k" if a >= 1e3 else f"{sign}€{a:.0f}"


@dataclass
class Position:
    pos: int = 0
    avg: float = 0.0        # average cost per share of the open position
    realized: float = 0.0   # local currency
    cash: float = 0.0       # cumulative signed cash flow, local currency

    def fill(self, qty: int, price: float) -> None:
        """qty > 0 buys, qty < 0 sells."""
        self.cash -= qty * price
        if self.pos == 0 or (self.pos > 0) == (qty > 0):          # opening or adding
            new = self.pos + qty
            self.avg = (abs(self.pos) * self.avg + abs(qty) * price) / abs(new)
            self.pos = new
            return
        closing = min(abs(qty), abs(self.pos))                     # reducing, closing or flipping
        self.realized += closing * (price - self.avg) * (1 if self.pos > 0 else -1)
        new = self.pos + qty
        if new == 0:
            self.avg = 0.0
        elif (new > 0) != (self.pos > 0):                          # flipped through zero
            self.avg = price
        self.pos = new


class Book:
    def __init__(self, instruments, limits: dict | None = None):
        self.limits = {**DEFAULT_LIMITS, **(limits or {})}
        self.inst = {i.instrument_id: i for i in instruments}
        self.fx_id = {i.short_name: i.instrument_id for i in instruments if not i.is_equity}
        self.mark: dict[str, tuple[datetime | None, float]] = {
            i.instrument_id: (None, i.start_price) for i in instruments}
        self.positions = {i.instrument_id: Position() for i in instruments if i.is_equity}
        self.seen_trades: set[str] = set()
        self.clock: datetime | None = None
        self.t0: datetime | None = None
        self.n = self.rejected = self.duplicates = 0

    # ---- ingest -------------------------------------------------------------
    def on_line(self, line: str) -> None:
        self.n += 1
        try:
            m = json.loads(line)
            d, kind = m["data"], m["type"]
            iid, price, ts = d["instrument_id"], d["price"], parse_ts(d["date"])
            if iid not in self.inst or not isinstance(price, (int, float)) or price <= 0 or kind not in ("price", "trade"):
                raise ValueError
            if kind == "trade":
                vol, side, tid = d["volume"], d["side"], d["trade_id"]
                if vol <= 0 or side not in ("BUY", "SELL") or iid not in self.positions:
                    raise ValueError
        except (ValueError, KeyError, TypeError):
            self.rejected += 1
            return
        if kind == "trade":
            if tid in self.seen_trades:
                self.duplicates += 1
                return
            self.seen_trades.add(tid)
            self.positions[iid].fill(vol if side == "BUY" else -vol, price)
        self.clock = ts if self.clock is None else max(self.clock, ts)
        self.t0 = self.t0 or ts
        old_ts, _ = self.mark[iid]
        if old_ts is None or ts >= old_ts:
            self.mark[iid] = (ts, price)

    # ---- FX -----------------------------------------------------------------
    def to_eur(self, ccy: str) -> float:
        px = lambda name: self.mark[self.fx_id[name]][1]
        if ccy == "EUR":
            return 1.0
        if ccy == "USD":
            return 1 / px("EUR/USD")
        if ccy == "GBP":
            return px("GBP/USD") / px("EUR/USD")
        if ccy == "JPY":
            return 1 / px("USD/JPY") / px("EUR/USD")
        raise ValueError(ccy)

    # ---- output -------------------------------------------------------------
    def _market_open(self, exchange: str) -> bool:
        lo, hi = SESSIONS_UTC[exchange]
        c = self.clock
        return lo <= c.hour * 3600 + c.minute * 60 + c.second < hi

    def snapshot(self) -> dict:
        L = self.limits
        rows, alerts = [], []
        tot = real = unreal = gross = 0.0
        for iid, p in self.positions.items():
            if p.pos == 0 and p.cash == 0:
                continue
            i = self.inst[iid]
            fx = self.to_eur(i.currency)
            mt, mp = self.mark[iid]
            age = (self.clock - (mt or self.t0)).total_seconds() / 60
            unreal_l = p.pos * (mp - p.avg)
            # staleness counts from the later of the last mark and today's session open (no overnight false alarms)
            open_t = self.clock.replace(hour=0, minute=0, second=0) + timedelta(seconds=SESSIONS_UTC[i.exchange][0])
            idle = (self.clock - max(mt or self.t0, open_t)).total_seconds() / 60
            stale = bool(p.pos) and idle > self.limits["stale_minutes"] and self._market_open(i.exchange)
            notional = abs(p.pos) * mp * fx
            rows.append({
                "name": i.short_name, "country": i.country, "ccy": i.currency, "pos": p.pos,
                "avg": round(p.avg, 4), "mark": round(mp, 4), "age_min": round(age, 1), "stale": stale,
                "notional": round(notional, 2), "unreal": round(unreal_l * fx, 2),
                "real": round(p.realized * fx, 2), "total": round((p.realized + unreal_l) * fx, 2)})
            tot += (p.realized + unreal_l) * fx
            real += p.realized * fx
            unreal += unreal_l * fx
            gross += notional
            if p.pos == 0:
                continue
            cost = abs(p.pos) * p.avg
            loss = -unreal_l / cost if cost else 0.0
            if loss >= L["loss_warn"]:
                alerts.append({"level": "critical" if loss >= L["loss_crit"] else "warning", "rule": "loss",
                               "instrument": i.short_name,
                               "text": f"{i.short_name}: unrealized loss {loss:.1%} of cost ({eur(unreal_l * fx)})"})
            if notional >= 0.8 * L["notional_limit_eur"]:
                alerts.append({"level": "critical" if notional >= L["notional_limit_eur"] else "warning",
                               "rule": "notional", "instrument": i.short_name,
                               "text": f"{i.short_name}: position {eur(notional)} is {notional / L['notional_limit_eur']:.0%} of the {eur(L['notional_limit_eur'])} limit"})
            if stale:
                alerts.append({"level": "warning", "rule": "stale", "instrument": i.short_name,
                               "text": f"{i.short_name}: no price for {idle:.0f} min while the market is open"})
        rows.sort(key=lambda r: -r["notional"])
        alerts.sort(key=lambda a: (a["level"] != "critical", a["instrument"]))
        return {
            "asof": self.clock.strftime("%Y-%m-%dT%H:%M:%SZ") if self.clock else None,
            "n": self.n, "rejected": self.rejected, "duplicates": self.duplicates,
            "total": round(tot, 2), "realized": round(real, 2), "unrealized": round(unreal, 2),
            "gross": round(gross, 2), "positions": rows, "alerts": alerts, "limits": L,
        }
