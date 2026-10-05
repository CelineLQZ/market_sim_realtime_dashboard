import json

import pytest

from pipeline.pnl import Book, Position
from simulator.market import Market, SimConfig, load_instruments

INSTR = load_instruments()


def test_average_cost_by_hand():
    p = Position()
    p.fill(100, 10.0)
    p.fill(100, 12.0)            # avg 11
    assert (p.pos, p.avg) == (200, 11.0)
    p.fill(-150, 13.0)           # realize 150 * 2
    assert (p.pos, p.avg, p.realized) == (50, 11.0, 300.0)
    p.fill(-80, 9.0)             # closes 50 (-100), flips to short 30 at 9
    assert (p.pos, p.avg, p.realized) == (-30, 9.0, 200.0)
    p.fill(10, 8.0)              # short 30 @9, buy 10 @8 -> +10
    assert (p.pos, p.avg, p.realized) == (-20, 9.0, 210.0)


def test_total_pnl_equals_cash_flow_plus_position_times_mark():
    """Oracle: recompute total P&L from raw messages with no cost method at all."""
    m = Market(load_instruments(), SimConfig(late_prob=0.05, duplicate_prob=0.02, bad_prob=0.02))
    book = Book(load_instruments())
    raw = []
    for _ in range(5700):
        for line in m.next_events():
            book.on_line(line)
            raw.append(line)
    snap = book.snapshot()

    by_id = {i.instrument_id: i for i in INSTR}
    cash, pos, mark = {}, {}, {}
    seen = set()
    for line in raw:
        try:
            msg = json.loads(line)
            d = msg["data"]
            iid = d["instrument_id"]
            if iid not in by_id or d["price"] is None or d["price"] <= 0:
                continue
            if msg["type"] == "trade":
                if d["volume"] <= 0 or d["side"] not in ("BUY", "SELL") or d["trade_id"] in seen:
                    continue
                seen.add(d["trade_id"])
                q = d["volume"] if d["side"] == "BUY" else -d["volume"]
                cash[iid] = cash.get(iid, 0) - q * d["price"]
                pos[iid] = pos.get(iid, 0) + q
            if iid not in mark or d["date"] >= mark[iid][0]:
                mark[iid] = (d["date"], d["price"])
        except (ValueError, KeyError, TypeError):
            continue
    px = lambda n: mark[next(i.instrument_id for i in INSTR if i.short_name == n)][1]
    to_eur = {"EUR": 1, "USD": 1 / px("EUR/USD"), "GBP": px("GBP/USD") / px("EUR/USD"),
              "JPY": 1 / px("USD/JPY") / px("EUR/USD")}
    expected = sum((cash[i] + pos.get(i, 0) * mark[i][1]) * to_eur[by_id[i].currency] for i in cash)

    assert snap["total"] == pytest.approx(expected, rel=1e-6, abs=1.0)
    assert snap["realized"] + snap["unrealized"] == pytest.approx(snap["total"], abs=5.0)
    assert snap["rejected"] > 0 and snap["duplicates"] > 0      # the bad/duplicate switches were exercised


def test_late_message_does_not_overwrite_newer_mark():
    book = Book(INSTR)
    iid = next(i.instrument_id for i in INSTR if i.short_name == "TLPV")
    mk = lambda px, t: json.dumps({"type": "price", "data": {"instrument_id": iid, "price": px, "date": t}})
    book.on_line(mk(100.0, "2025-01-06T09:00:10Z"))
    book.on_line(mk(90.0, "2025-01-06T09:00:05Z"))      # arrives late
    assert book.mark[iid][1] == 100.0


def test_alerts_fire_on_a_constructed_book():
    book = Book(INSTR, {"notional_limit_eur": 1_000_000})
    iid = next(i.instrument_id for i in INSTR if i.short_name == "TLPV")
    t = lambda s: f"2025-01-06T09:{s}Z"
    book.on_line(json.dumps({"type": "trade", "data": {"trade_id": "a", "instrument_id": iid, "price": 100.0,
                             "volume": 20000, "side": "BUY", "currency": "EUR", "date": t("00:00")}}))
    book.on_line(json.dumps({"type": "price", "data": {"instrument_id": iid, "price": 97.0, "date": t("01:00")}}))
    alerts = {(a["rule"], a["level"]) for a in book.snapshot()["alerts"]}
    assert ("loss", "critical") in alerts            # -3% of cost
    assert ("notional", "critical") in alerts        # 1.94M vs 1M limit
