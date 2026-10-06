"""SQL 集成测试：用一个临时数据库，把 raw → clean → gold 和质量相关的表跑一遍。
需要本机有 PostgreSQL（能 createdb）；没有就整体跳过。运行：pytest tests/test_pipeline_sql.py
"""
import json
import os
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

import pytest

psycopg = pytest.importorskip("psycopg")
ROOT = Path(__file__).resolve().parent.parent
pytestmark = pytest.mark.skipif(shutil.which("createdb") is None, reason="no local PostgreSQL client")

TLPV = "eccd7e6f-8b1b-5baa-a744-091c1690363d"
EURUSD, GBPUSD, USDJPY = "90687094-e834-5deb-9de9-78cf761a91ee", "4f7ebd5e-97b4-5ee8-a434-2a0adca06c65", "904be1e7-ca56-5523-a74f-96576c8fc0c9"
DAY = "2025-01-06"          # a Monday


def price(iid, px, hhmmss):
    return json.dumps({"type": "price", "data": {"instrument_id": iid, "price": px, "date": f"{DAY}T{hhmmss}Z"}})


def trade(tid, px, qty, hhmmss, side="BUY"):
    return json.dumps({"type": "trade", "data": {"trade_id": tid, "instrument_id": TLPV, "price": px, "volume": qty,
                                                 "side": side, "currency": "EUR", "date": f"{DAY}T{hhmmss}Z"}})


@pytest.fixture(scope="module")
def conn():
    name = "t_" + uuid.uuid4().hex[:10]
    subprocess.run(["createdb", name], check=True)
    env = {**os.environ, "DATABASE_URL": f"dbname={name}", "PGOPTIONS": "-c client_min_messages=warning"}
    subprocess.run([sys.executable, "ingest/ingest.py", "--init"], cwd=ROOT, env=env, check=True)
    for f in ("clean", "gold"):
        subprocess.run(["psql", f"dbname={name}", "-v", "ON_ERROR_STOP=1", "-q", "-f", f"sql/{f}/install.sql"], cwd=ROOT, env=env, check=True)
    c = psycopg.connect(f"dbname={name}", autocommit=True)
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


def test_bad_rows_duplicates_and_late_trade(conn):
    t1 = str(uuid.uuid4())
    # run 1: FX, a price, one trade, a later price; plus a garbled line, a bad price and an exact duplicate trade
    feed(conn, [price(EURUSD, 1.1, "08:00:00"), price(GBPUSD, 1.3, "08:00:00"), price(USDJPY, 150, "08:00:00"),
                price(TLPV, 100.0, "09:30:00"), trade(t1, 100.0, 100, "09:40:00"), trade(t1, 100.0, 100, "09:40:00"),
                "<<corrupted frame>>", price(TLPV, -5, "10:30:00"), price(TLPV, 101.0, "10:50:00"), price(TLPV, 101.0, "11:10:00")])
    clean, gold = step(conn)
    assert clean[2] == 10 and clean[3] == 2 and clean[7] == 1 and clean[8] is True       # raw, bad, duplicates, balanced

    hour11 = conn.execute("select total_eur from gold.portfolio_hourly where snap_time = %s", (f"{DAY}T11:00:00Z",)).fetchone()[0]
    assert float(hour11) == pytest.approx(100.0)                      # 100 shares, bought at 100, marked at 101

    # run 2: a trade stamped 09:20 arrives after the 09:40 one was already processed -> the instrument is replayed and the hour recomputed
    feed(conn, [trade(str(uuid.uuid4()), 100.0, 100, "09:20:00")])
    clean, gold = step(conn)

    assert gold[4] == 1                                               # late_rewinds: that instrument was replayed once
    hour11 = conn.execute("select total_eur from gold.portfolio_hourly where snap_time = %s", (f"{DAY}T11:00:00Z",)).fetchone()[0]
    assert float(hour11) == pytest.approx(200.0)                      # the hour was recomputed with both purchases
