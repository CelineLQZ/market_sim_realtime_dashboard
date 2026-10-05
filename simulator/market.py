"""Market model: reference data, trading sessions, price process, event generation.

Pure standard library. All randomness comes from one seeded `random.Random`, so the
same seed always produces the same stream (timing between messages is handled
separately in server.py and does not affect content).
"""
from __future__ import annotations

import copy
import csv
import json
import math
import random
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# Trading sessions in seconds after 00:00 UTC, Monday to Friday.
# Winter (standard) time only: daylight saving is not modelled.
SESSIONS_UTC = {
    "XTKS": (0, 6 * 3600),                      # Tokyo 09:00-15:00 JST (lunch break ignored)
    "XAMS": (8 * 3600, 16 * 3600 + 1800),       # Amsterdam 09:00-17:30 CET
    "XETR": (8 * 3600, 16 * 3600 + 1800),       # Frankfurt (Xetra) 09:00-17:30 CET
    "XPAR": (8 * 3600, 16 * 3600 + 1800),       # Paris 09:00-17:30 CET
    "XLON": (8 * 3600, 16 * 3600 + 1800),       # London 08:00-16:30 GMT
    "XNYS": (14 * 3600 + 1800, 21 * 3600),      # New York 09:30-16:00 EST
    "FX": (0, 24 * 3600),                       # FX trades around the clock on weekdays
}

EQUITY_YEAR_SECONDS = 252 * 6.5 * 3600   # trading seconds per year, for equities
FX_YEAR_SECONDS = 252 * 24 * 3600        # weekday seconds per year, for FX and the market factor
MAX_STEP_SECONDS = 3600                  # cap on elapsed time per price step (overnight gaps)
MARKET_VOL = 0.16                        # annual volatility of the common market factor (moves around the clock)
SPREAD_BPS = 5.0                         # equity trades execute around mid +/- half spread

BAD_KINDS = ("null_price", "negative_price", "zero_volume",
             "unknown_instrument", "bad_side", "garbage_line")


@dataclass
class Instrument:
    instrument_id: str
    long_name: str
    short_name: str
    country: str
    sector: str
    industry: str
    exchange: str
    type: str
    currency: str
    start_price: float
    annual_vol: float
    beta: float
    liquidity: int

    @property
    def is_equity(self) -> bool:
        return self.type == "equity"


@dataclass
class SimConfig:
    seed: int = 42
    start: datetime = datetime(2025, 1, 6, 0, 0, 0, tzinfo=timezone.utc)  # a Monday
    sim_seconds_per_message: float = 30.0   # mean simulated gap between messages
    trade_ratio: float = 0.55               # share of messages that are trades
    late_prob: float = 0.03                 # chance an event is stamped earlier than "now"
    late_max_seconds: float = 300.0         # how far back a late event can be stamped
    duplicate_prob: float = 0.0             # chance a message is sent twice (off by default)
    bad_prob: float = 0.0                   # chance a message is corrupted (off by default)


def load_instruments(data_dir: Path = DATA_DIR) -> list[Instrument]:
    """Read reference data (instruments.csv) and simulation parameters (sim_params.csv)."""
    with open(data_dir / "sim_params.csv", newline="") as f:
        params = {r["short_name"]: r for r in csv.DictReader(f)}
    out = []
    with open(data_dir / "instruments.csv", newline="") as f:
        for r in csv.DictReader(f):
            p = params[r["short_name"]]
            out.append(Instrument(**r, start_price=float(p["start_price"]),
                                  annual_vol=float(p["annual_vol"]), beta=float(p["beta"]),
                                  liquidity=int(p["liquidity"])))
    return out


def _fmt(ts: datetime) -> str:
    return ts.strftime("%Y-%m-%dT%H:%M:%SZ")


class Market:
    def __init__(self, instruments: list[Instrument], cfg: SimConfig):
        self.cfg = cfg
        self.rng = random.Random(cfg.seed)
        self.instruments = list(instruments)
        self.now = cfg.start
        self.price = {i.instrument_id: i.start_price for i in self.instruments}
        self.last_touch = {i.instrument_id: cfg.start for i in self.instruments}
        self.factor_at_touch = {i.instrument_id: 0.0 for i in self.instruments}
        self.last_sign = {i.instrument_id: 0 for i in self.instruments}
        self.factor = 0.0                    # cumulative log-return of the common market factor
        self.last_factor_time = cfg.start
        self._last_quote: dict[str, tuple[float, str]] = {}   # last (price, date) published per instrument
        self.ref_liquidity = self._mean_open_liquidity()      # average open liquidity over a weekday

    # ---- clock and sessions -------------------------------------------------
    def _mean_open_liquidity(self) -> float:
        """Average, over the minutes of a weekday, of the summed liquidity of open instruments."""
        total = 0
        for minute in range(1440):
            secs = minute * 60
            total += sum(i.liquidity for i in self.instruments
                         if SESSIONS_UTC[i.exchange][0] <= secs < SESSIONS_UTC[i.exchange][1])
        return total / 1440

    def _advance_clock(self) -> None:
        # More liquidity open -> shorter simulated gap -> more messages per hour.
        # The average gap stays close to --sim-seconds-per-message.
        open_liq = max(sum(i.liquidity for i in self._open_instruments()), 1)
        mean_gap = self.cfg.sim_seconds_per_message * self.ref_liquidity / open_liq
        gap = self.rng.expovariate(1.0 / mean_gap)
        self.now += timedelta(seconds=gap)
        if self.now.weekday() >= 5:          # weekend: jump to Monday 00:00 UTC
            days = 7 - self.now.weekday()
            self.now = (self.now + timedelta(days=days)).replace(
                hour=0, minute=0, second=0, microsecond=0)

    def _open_instruments(self) -> list[Instrument]:
        secs = self.now.hour * 3600 + self.now.minute * 60 + self.now.second
        return [i for i in self.instruments
                if SESSIONS_UTC[i.exchange][0] <= secs < SESSIONS_UTC[i.exchange][1]]

    # ---- price process --------------------------------------------------------
    def _step_factor(self) -> None:
        dt = min((self.now - self.last_factor_time).total_seconds(), MAX_STEP_SECONDS)
        self.factor += MARKET_VOL * math.sqrt(dt / FX_YEAR_SECONDS) * self.rng.gauss(0, 1)
        self.last_factor_time = self.now

    def _touch(self, inst: Instrument) -> float:
        """Move the instrument's mid price forward to 'now' and return it.

        return = beta * (market factor move since last touch) + own noise,
        so equities with high beta move together; FX has beta 0 and moves alone.
        """
        iid = inst.instrument_id
        # Own noise accrues only while the instrument's market is open: measure from today's open.
        day_open = self.now.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(
            seconds=SESSIONS_UTC[inst.exchange][0])
        dt = min((self.now - max(self.last_touch[iid], day_open)).total_seconds(), MAX_STEP_SECONDS)
        year = EQUITY_YEAR_SECONDS if inst.is_equity else FX_YEAR_SECONDS
        # annual_vol is TOTAL volatility: own noise = what is left after the market-factor part
        idio = math.sqrt(max(inst.annual_vol ** 2 - (inst.beta * MARKET_VOL) ** 2,
                             (0.3 * inst.annual_vol) ** 2))
        ret = (inst.beta * (self.factor - self.factor_at_touch[iid])
               + idio * math.sqrt(dt / year) * self.rng.gauss(0, 1))
        self.price[iid] *= math.exp(ret)
        self.last_sign[iid] = (ret > 0) - (ret < 0)
        self.last_touch[iid] = self.now
        self.factor_at_touch[iid] = self.factor
        return self.price[iid]

    # ---- message builders -----------------------------------------------------
    def _uuid(self) -> str:
        return str(uuid.UUID(int=self.rng.getrandbits(128), version=4))

    def _event_time(self, inst: Instrument) -> datetime:
        if self.rng.random() < self.cfg.late_prob:
            back = self.rng.uniform(1.0, self.cfg.late_max_seconds)
            day_open = self.now.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(
                seconds=SESSIONS_UTC[inst.exchange][0])
            return max(self.now - timedelta(seconds=back), day_open, self.cfg.start)
        return self.now

    def _weighted(self, pool: list[Instrument]) -> Instrument:
        return self.rng.choices(pool, weights=[i.liquidity for i in pool], k=1)[0]

    @staticmethod
    def _decimals(inst: Instrument) -> int:
        """Quote precision: equities 4 dp; FX follows market convention (JPY pairs 3 dp, others 5 dp)."""
        if inst.is_equity:
            return 4
        return 3 if inst.currency == "JPY" else 5

    def _price_msg(self, inst: Instrument) -> dict:
        mid = self._touch(inst)
        dp = self._decimals(inst)
        price, date = round(mid, dp), _fmt(self._event_time(inst))
        # Never emit an identical (instrument, price, second) by accident: a legitimate
        # repeat would be indistinguishable from a duplicate, which only the
        # --duplicate-prob switch should produce. Nudge by one tick instead.
        if self._last_quote.get(inst.instrument_id) == (price, date):
            price = round(price + 10 ** -dp, dp)
        self._last_quote[inst.instrument_id] = (price, date)
        return {"type": "price", "data": {
            "instrument_id": inst.instrument_id, "price": price, "date": date}}

    def _trade_msg(self, inst: Instrument) -> dict:
        mid = self._touch(inst)
        p_buy = 0.5 + 0.1 * self.last_sign[inst.instrument_id]   # slight momentum
        side = "BUY" if self.rng.random() < p_buy else "SELL"
        sign = 1 if side == "BUY" else -1
        px = mid * (1 + sign * SPREAD_BPS / 2e4 + self.rng.gauss(0, 0.0001))
        volume = int(min(100_000, max(100, self.rng.lognormvariate(math.log(8000), 1.0))))
        return {"type": "trade", "data": {
            "trade_id": self._uuid(), "instrument_id": inst.instrument_id,
            "price": round(px, 4), "volume": volume, "side": side,
            "currency": inst.currency, "date": _fmt(self._event_time(inst))}}

    def _corrupt(self, msg: dict) -> str:
        """Return a bad message line. The kind is chosen among those that apply."""
        is_trade = msg["type"] == "trade"
        kinds = [k for k in BAD_KINDS
                 if is_trade or k not in ("zero_volume", "bad_side")]
        kind = self.rng.choice(kinds)
        if kind == "garbage_line":
            return "<<corrupted frame " + self._uuid()[:8] + ">>"
        bad = copy.deepcopy(msg)
        d = bad["data"]
        if kind == "null_price":
            d["price"] = None
        elif kind == "negative_price":
            d["price"] = -abs(d["price"])
        elif kind == "zero_volume":
            d["volume"] = 0
        elif kind == "unknown_instrument":
            d["instrument_id"] = self._uuid()
        elif kind == "bad_side":
            d["side"] = "HOLD"
        return json.dumps(bad, separators=(",", ":"))

    # ---- public ---------------------------------------------------------------
    def next_events(self) -> list[str]:
        """Return the next message line(s) (more than one only if duplicated)."""
        self._advance_clock()
        self._step_factor()
        open_now = self._open_instruments()
        equities = [i for i in open_now if i.is_equity]
        if equities and self.rng.random() < self.cfg.trade_ratio:
            msg = self._trade_msg(self._weighted(equities))
        else:
            msg = self._price_msg(self._weighted(open_now))   # FX is always open on weekdays
        if self.rng.random() < self.cfg.bad_prob:
            line = self._corrupt(msg)
        else:
            line = json.dumps(msg, separators=(",", ":"))
        lines = [line]
        if self.rng.random() < self.cfg.duplicate_prob:
            lines.append(line)
        return lines
