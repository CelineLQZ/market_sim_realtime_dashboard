import json
import math
from collections import Counter
from datetime import datetime

import pytest

from simulator.market import (BAD_KINDS, SESSIONS_UTC, Market, SimConfig,
                              load_instruments)

INSTRUMENTS = load_instruments()
BY_ID = {i.instrument_id: i for i in INSTRUMENTS}


def run(n, **kw):
    kw.setdefault("bad_prob", 0.0)       # the default stream has about 1% bad rows; most tests want clean ones
    m = Market(load_instruments(), SimConfig(**kw))
    lines = []
    while len(lines) < n:
        lines.extend(m.next_events())
    return lines[:n]


def parse(lines):
    return [json.loads(l) for l in lines]


def ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")


def test_reference_data_is_consistent():
    assert len(INSTRUMENTS) == 33
    assert len({i.instrument_id for i in INSTRUMENTS}) == 33
    assert len({i.short_name for i in INSTRUMENTS}) == 33
    assert Counter(i.type for i in INSTRUMENTS) == {"equity": 30, "currency": 3}
    assert {i.exchange for i in INSTRUMENTS} <= set(SESSIONS_UTC)
    assert all(i.start_price > 0 and i.annual_vol > 0 for i in INSTRUMENTS)


def test_same_seed_same_stream_different_seed_differs():
    assert run(500, seed=1) == run(500, seed=1)
    assert run(500, seed=1) != run(500, seed=2)


def test_message_schema():
    for m in parse(run(2000)):
        assert m["type"] in ("trade", "price")
        d = m["data"]
        assert d["instrument_id"] in BY_ID
        assert isinstance(d["price"], float) and d["price"] > 0
        ts(d["date"])
        if m["type"] == "trade":
            assert set(d) == {"trade_id", "instrument_id", "price", "volume", "side", "currency", "date"}
            assert d["side"] in ("BUY", "SELL") and isinstance(d["volume"], int) and d["volume"] > 0
        else:
            assert set(d) == {"instrument_id", "price", "date"}


def test_fx_has_prices_only_and_trade_currency_matches_instrument():
    msgs = parse(run(5000))
    for m in msgs:
        inst = BY_ID[m["data"]["instrument_id"]]
        if m["type"] == "trade":
            assert inst.is_equity
            assert m["data"]["currency"] == inst.currency
    assert any(BY_ID[m["data"]["instrument_id"]].type == "currency" for m in msgs if m["type"] == "price")


def test_messages_respect_trading_sessions_and_weekends():
    for m in parse(run(8000, late_prob=0.0)):
        t = ts(m["data"]["date"])
        assert t.weekday() < 5, "no messages on weekends"
        secs = t.hour * 3600 + t.minute * 60 + t.second
        lo, hi = SESSIONS_UTC[BY_ID[m["data"]["instrument_id"]].exchange]
        # the clock is rounded down to whole seconds when formatted, so allow < hi
        assert lo <= secs < hi


def test_clock_skips_weekend():
    msgs = parse(run(30000, late_prob=0.0, sim_seconds_per_message=60))
    days = {ts(m["data"]["date"]).date().isoformat() for m in msgs}
    assert "2025-01-11" not in days and "2025-01-12" not in days   # Sat, Sun
    assert "2025-01-13" in days                                      # following Monday


def test_late_events_appear_only_when_enabled():
    def out_of_order(lines):
        stamps = [ts(m["data"]["date"]) for m in parse(lines)]
        return sum(b < a for a, b in zip(stamps, stamps[1:]))
    assert out_of_order(run(3000, late_prob=0.0)) == 0
    n = out_of_order(run(3000, late_prob=0.05))
    assert 30 < n < 400   # roughly 5% late, each can also push the next one "early"


def test_duplicates_repeat_the_same_line():
    lines = run(2000, duplicate_prob=0.2)
    repeats = sum(a == b for a, b in zip(lines, lines[1:]))
    assert 200 < repeats < 600
    # with duplicates off, the generator never repeats a line by accident
    assert len(set(run(20000, duplicate_prob=0.0))) == 20000
    # and trade ids are always unique
    ids = [m["data"]["trade_id"] for m in parse(run(20000)) if m["type"] == "trade"]
    assert len(ids) == len(set(ids))


def test_fx_quote_precision_follows_market_convention():
    for m in parse(run(5000)):
        inst = BY_ID[m["data"]["instrument_id"]]
        if m["type"] == "price" and not inst.is_equity:
            dp = 3 if inst.currency == "JPY" else 5
            assert round(m["data"]["price"], dp) == m["data"]["price"]


def test_bad_messages_are_actually_invalid():
    def is_bad(line):
        try:
            m = json.loads(line)
        except ValueError:
            return True
        d = m["data"]
        return (d["price"] is None or d["price"] <= 0 or d["instrument_id"] not in BY_ID
                or d.get("volume", 1) <= 0 or d.get("side", "BUY") not in ("BUY", "SELL"))
    clean = run(3000, bad_prob=0.0)
    assert not any(is_bad(l) for l in clean)
    dirty = run(3000, bad_prob=0.1)
    share = sum(is_bad(l) for l in dirty) / len(dirty)
    assert 0.06 < share < 0.14
    assert len(BAD_KINDS) == 6


def test_prices_stay_in_a_sane_range_over_a_long_run():
    msgs = parse(run(60000, sim_seconds_per_message=60))
    first, last = {}, {}
    for m in msgs:
        if m["type"] == "price":
            first.setdefault(m["data"]["instrument_id"], m["data"]["price"])
            last[m["data"]["instrument_id"]] = m["data"]["price"]
    for iid, p0 in first.items():
        assert 0.5 < last[iid] / p0 < 2.0, BY_ID[iid].short_name


def test_trade_prices_stay_close_to_mid():
    msgs = parse(run(20000))
    last_mid = {}
    gaps = []
    for m in msgs:
        d = m["data"]
        if m["type"] == "price":
            last_mid[d["instrument_id"]] = d["price"]
        elif d["instrument_id"] in last_mid:
            gaps.append(abs(d["price"] / last_mid[d["instrument_id"]] - 1))
    assert gaps and sorted(gaps)[int(len(gaps) * 0.95)] < 0.02   # 95% within 2% of last quote


def test_late_events_still_fall_inside_their_own_session():
    for m in parse(run(20000, late_prob=0.2, late_max_seconds=900)):
        t = ts(m["data"]["date"])
        assert t.weekday() < 5
        secs = t.hour * 3600 + t.minute * 60 + t.second
        lo, hi = SESSIONS_UTC[BY_ID[m["data"]["instrument_id"]].exchange]
        assert lo <= secs < hi


def test_realised_volatility_matches_configured_volatility():
    import numpy as np
    msgs = parse(run(120000, sim_seconds_per_message=30, late_prob=0.0))
    last = {}
    for m in msgs:
        if m["type"] == "price":
            d = m["data"]
            last.setdefault(d["instrument_id"], {})[d["date"][:10]] = d["price"]
    ratios = []
    for iid, by_day in last.items():
        prices = np.array([by_day[k] for k in sorted(by_day)])
        if len(prices) < 20:
            continue
        realised = np.log(prices[1:] / prices[:-1]).std() * np.sqrt(252)
        ratios.append(realised / BY_ID[iid].annual_vol)
    assert len(ratios) >= 25
    assert 0.85 < float(np.mean(ratios)) < 1.3     # calibrated, with sampling noise


def test_activity_follows_the_sun():
    msgs = parse(run(60000, late_prob=0.0))
    by_hour = Counter(ts(m["data"]["date"]).hour for m in msgs)
    asia = sum(by_hour[h] for h in range(0, 6)) / 6
    overlap = sum(by_hour[h] for h in (14, 15, 16)) / 3     # Amsterdam/London + New York open
    dead = sum(by_hour[h] for h in (6, 7, 21, 22, 23)) / 5   # only FX trades
    assert overlap > asia > dead


# ---------------------------------------------------------------- strategies

def _signed_cost_bp(strategy, n=30000, **kw):
    """Average (side * (trade price / mid - 1)) in basis points: positive = we pay above mid."""
    m = Market(load_instruments(), SimConfig(strategy=strategy, bad_prob=0.0, **kw))
    mids, orig = [], m._touch
    def touch(inst):
        v = orig(inst)
        mids.append(v)
        return v
    m._touch = touch
    cost = []
    for _ in range(n):
        for line in m.next_events():
            d = json.loads(line)
            if d["type"] == "trade":
                sign = 1 if d["data"]["side"] == "BUY" else -1
                cost.append(sign * (d["data"]["price"] / mids[-1] - 1) * 1e4)
    return sum(cost) / len(cost)


def test_market_maker_earns_the_spread_and_random_pays_it():
    assert _signed_cost_bp("market_maker") < -2.0     # buys below mid, sells above mid: about -2.5 bp
    assert _signed_cost_bp("random") > 2.0            # the old behaviour: buys above mid


def test_market_maker_respects_the_position_limit():
    limit = 1_000_000
    m = Market(load_instruments(), SimConfig(bad_prob=0.0, position_limit_eur=limit))
    by_id = {i.instrument_id: i for i in m.instruments}
    worst = 0.0
    for _ in range(40000):
        m.next_events()
        for iid, qty in m.inventory.items():
            if by_id[iid].is_equity and qty:
                worst = max(worst, abs(qty) * m.price[iid] * m._to_eur(by_id[iid].currency))
    # the cap is applied when the trade is made; afterwards the price can still move a little
    assert worst < 1.5 * limit
    assert worst > 0.3 * limit        # and the limit is actually being used


def test_market_maker_inventory_matches_the_valid_trades_it_sent():
    # about 1% of rows are corrupted; a corrupted trade is rejected downstream, so it must not count in the inventory
    m = Market(load_instruments(), SimConfig(bad_prob=0.02))
    pos = Counter()
    for _ in range(20000):
        for line in m.next_events():
            try:
                d = json.loads(line)["data"]
            except ValueError:
                continue
            valid = (d.get("price") is not None and d["price"] > 0 and d["instrument_id"] in BY_ID
                     and d.get("volume", 1) > 0 and d.get("side", "BUY") in ("BUY", "SELL"))
            if "volume" in d and valid:
                pos[d["instrument_id"]] += d["volume"] * (1 if d["side"] == "BUY" else -1)
    assert {k: v for k, v in pos.items() if v} == {k: v for k, v in m.inventory.items() if v}


def test_informed_clients_move_the_price_against_the_market_maker():
    def pnl_per_trade(informed_prob):
        # mark each fill to the next mid we see for that stock: spread earned minus what the price did afterwards
        m = Market(load_instruments(), SimConfig(bad_prob=0.0, late_prob=0.0, informed_prob=informed_prob, informed_bps=20.0))
        pending, total, n = {}, 0.0, 0
        for _ in range(40000):
            for line in m.next_events():
                d = json.loads(line)["data"]
                if "volume" in d:
                    pending[d["instrument_id"]] = (d["price"], 1 if d["side"] == "BUY" else -1)
                elif d["instrument_id"] in pending:
                    px, sign = pending.pop(d["instrument_id"])
                    total += sign * (d["price"] / px - 1) * 1e4
                    n += 1
        return total / n
    assert pnl_per_trade(0.0) > pnl_per_trade(0.5) + 1.0      # informed flow costs the market maker several bp per trade


def test_default_stream_has_about_one_percent_bad_rows():
    m = Market(load_instruments(), SimConfig())
    bad, total = 0, 0
    for _ in range(20000):
        for line in m.next_events():
            total += 1
            try:
                d = json.loads(line)["data"]
                bad += d["price"] is None or d["price"] <= 0 or d["instrument_id"] not in BY_ID \
                    or d.get("volume", 1) <= 0 or d.get("side", "BUY") not in ("BUY", "SELL")
            except ValueError:
                bad += 1
    assert 0.005 < bad / total < 0.016


def test_unknown_strategy_is_rejected():
    with pytest.raises(ValueError):
        Market(load_instruments(), SimConfig(strategy="momentum"))
