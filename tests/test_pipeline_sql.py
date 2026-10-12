"""SQL integration tests: run raw -> clean -> gold and the quality tables in a throw-away database.
Needs a local PostgreSQL (createdb must work); skipped otherwise. Run: pytest tests/test_pipeline_sql.py
The tests share one database and build on each other, so they run in file order.
"""
import json
import os
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

import pytest
from psycopg.rows import namedtuple_row

psycopg = pytest.importorskip("psycopg")
ROOT = Path(__file__).resolve().parent.parent
pytestmark = pytest.mark.skipif(shutil.which("createdb") is None, reason="no local PostgreSQL client")

TLPV = "eccd7e6f-8b1b-5baa-a744-091c1690363d"
EURUSD, GBPUSD, USDJPY = "90687094-e834-5deb-9de9-78cf761a91ee", "4f7ebd5e-97b4-5ee8-a434-2a0adca06c65", "904be1e7-ca56-5523-a74f-96576c8fc0c9"
DAY = "2025-01-06"          # a Monday


def price(iid, px, hhmmss):
    return json.dumps({"type": "price", "data": {"instrument_id": iid, "price": px, "date": f"{DAY}T{hhmmss}Z"}})


def trade(tid, px, qty, hhmmss, side="BUY", iid=TLPV):
    return json.dumps({"type": "trade", "data": {"trade_id": tid, "instrument_id": iid, "price": px, "volume": qty,
                                                 "side": side, "currency": "EUR", "date": f"{DAY}T{hhmmss}Z"}})


@pytest.fixture(scope="module")
def conn():
    name = "t_" + uuid.uuid4().hex[:10]
    subprocess.run(["createdb", name], check=True)
    env = {**os.environ, "DATABASE_URL": f"dbname={name}", "PGOPTIONS": "-c client_min_messages=warning"}
    subprocess.run([sys.executable, "ingest/ingest.py", "--init"], cwd=ROOT, env=env, check=True)
    for f in ("clean", "gold"):
        subprocess.run(["psql", f"dbname={name}", "-v", "ON_ERROR_STOP=1", "-q", "-f", f"sql/{f}/install.sql"], cwd=ROOT, env=env, check=True)
    # Keep timestamp rendering deterministic on developer machines in any timezone.
    c = psycopg.connect(f"dbname={name}", autocommit=True, row_factory=namedtuple_row,
                        options="-c timezone=UTC")
    yield c
    c.close()
    subprocess.run(["dropdb", "--if-exists", name], check=False)


def feed(c, lines):
    run_id = c.execute("select max(run_id) from raw.ingest_runs").fetchone()[0]
    if run_id is None:
        run_id = c.execute("insert into raw.ingest_runs default values returning run_id").fetchone()[0]
    n = c.execute("select coalesce(max(line_no), 0) from raw.events").fetchone()[0]
    for i, line in enumerate(lines, start=n + 1):
        c.execute("insert into raw.events (run_id, line_no, received_at, payload) values (%s, %s, now(), %s)", (run_id, i, line))


def step(c):
    clean = c.execute("select * from clean.run()").fetchone()
    gold = c.execute("select * from gold.run()").fetchone()
    return clean, gold


def hour_total(c, hhmm):
    row = c.execute("select total_eur from gold.portfolio_hourly where snap_time = %s", (f"{DAY}T{hhmm}:00Z",)).fetchone()
    return None if row is None else float(row[0])


def test_bad_rows_duplicates_and_hourly_snapshot(conn):
    t1 = str(uuid.uuid4())
    # FX, a price, one trade, later prices; plus a garbled line, a bad price and an exact duplicate trade
    feed(conn, [price(EURUSD, 1.1, "08:00:00"), price(GBPUSD, 1.3, "08:00:00"), price(USDJPY, 150, "08:00:00"),
                price(TLPV, 100.0, "09:30:00"), trade(t1, 100.0, 100, "09:40:00"), trade(t1, 100.0, 100, "09:40:00"),
                "<<corrupted frame>>", price(TLPV, -5, "10:30:00"), price(TLPV, 101.0, "10:50:00"), price(TLPV, 101.0, "11:10:00")])
    clean, gold = step(conn)
    assert clean[2] == 10 and clean[3] == 2 and clean[7] == 1 and clean[8] is True       # raw, bad, duplicates, balanced

    assert gold.watermark.isoformat().startswith(f"{DAY}T11:05")                           # latest event 11:10 minus 5 minutes
    assert gold.trades_applied == 1 and gold.too_late == 0
    assert hour_total(conn, "11:00") == pytest.approx(100.0)          # 100 shares bought at 100, marked at 101
    assert hour_total(conn, "12:00") is None                          # the watermark has not reached 12:00 yet


def test_too_late_trade_is_skipped_and_history_is_not_rewritten(conn):
    # A trade stamped 09:20 arrives after the watermark (11:05) has long passed 09:20
    feed(conn, [trade(str(uuid.uuid4()), 100.0, 100, "09:20:00")])
    clean, gold = step(conn)
    assert gold.too_late == 1 and gold.trades_applied == 0
    assert hour_total(conn, "11:00") == pytest.approx(100.0)          # finished hours are never recomputed
    assert conn.execute("select too_late_total from gold.process_state").fetchone()[0] == 1


def test_out_of_order_trades_inside_the_window_are_sorted(conn):
    # Both trades arrive in the wrong order, but both are behind the latest event by less than 5 minutes
    feed(conn, [price(TLPV, 102.0, "11:30:00")])
    step(conn)
    feed(conn, [trade(str(uuid.uuid4()), 103.0, 150, "11:28:00", side="SELL"),
                trade(str(uuid.uuid4()), 101.0, 100, "11:26:00", side="BUY")])
    _, gold = step(conn)
    assert gold.trades_applied == 0                                   # still inside the 5-minute window: not final yet
    feed(conn, [price(TLPV, 103.0, "11:40:00")])
    _, gold = step(conn)
    assert gold.trades_applied == 2 and gold.too_late == 0

    rows = conn.execute("select signed_qty, qty_after, avg_cost, realized_cum from gold.position_state "
                        "where instrument_id = %s order by event_time, raw_id", (TLPV,)).fetchall()
    assert [float(r.qty_after) for r in rows] == [100, 200, 50]       # BUY 11:26 is processed before SELL 11:28
    assert float(rows[1].avg_cost) == pytest.approx(100.5)            # (100 x 100 + 100 x 101) / 200
    assert float(rows[2].realized_cum) == pytest.approx(375.0)        # 150 x (103 - 100.5)


def test_hour_is_written_once_the_watermark_passes_it(conn):
    feed(conn, [price(TLPV, 104.0, "12:10:00")])
    _, gold = step(conn)
    assert gold.hours_built == 1
    # 50 shares at avg 100.5 marked at 103 (12:00 snapshot uses the 11:40 price) + realized 375
    assert hour_total(conn, "12:00") == pytest.approx(375.0 + 50 * (103.0 - 100.5))
    assert hour_total(conn, "11:00") == pytest.approx(100.0)          # unchanged


def test_average_cost_through_zero_crossing(conn):
    other = conn.execute("select instrument_id::text from clean.instruments where type = 'equity' and instrument_id::text <> %s "
                         "order by instrument_id limit 1", (TLPV,)).fetchone()[0]
    feed(conn, [trade(str(uuid.uuid4()), 10.0, 100, "12:20:00", iid=other),
                trade(str(uuid.uuid4()), 12.0, 100, "12:21:00", iid=other),
                trade(str(uuid.uuid4()), 13.0, 50, "12:22:00", side="SELL", iid=other),
                trade(str(uuid.uuid4()), 12.0, 250, "12:23:00", side="SELL", iid=other),
                price(TLPV, 104.0, "12:40:00")])
    step(conn)
    rows = conn.execute("select qty_after, avg_cost, realized_delta, realized_cum from gold.position_state "
                        "where instrument_id = %s order by event_time, raw_id", (other,)).fetchall()
    assert [float(r.qty_after) for r in rows] == [100, 200, 150, -100]
    assert float(rows[2].realized_delta) == pytest.approx(100.0)      # 50 x (13 - 11)
    assert float(rows[3].realized_delta) == pytest.approx(150.0)      # closes 150 at 12: 150 x (12 - 11)
    assert float(rows[3].avg_cost) == 12.0 and float(rows[3].realized_cum) == pytest.approx(250.0)   # the remaining short opens at 12


def test_live_state_matches_final_positions(conn):
    n = conn.execute("select count(*) from gold.live_state").fetchone()[0]
    assert n >= 1
    row = conn.execute("select position, realized_local from gold.live_state where instrument_id = %s", (TLPV,)).fetchone()
    assert float(row.position) == 50 and float(row.realized_local) == pytest.approx(375.0)
