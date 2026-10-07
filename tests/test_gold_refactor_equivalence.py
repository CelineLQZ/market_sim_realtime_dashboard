"""Golden-master comparison for the Gold SQL refactor.

The legacy implementation is read from the last commit before the refactor and
installed in one temporary database.  The working-tree implementation is
installed in a second database.  Both databases receive the same deterministic
events, including a late trade and a late price, and all business-facing Gold
tables are compared row for row.

This is intentionally a migration test rather than a permanent implementation
oracle.  Set GOLD_LEGACY_REF when comparing against a different baseline.
"""

from __future__ import annotations

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
LEGACY_REF = os.environ.get("GOLD_LEGACY_REF", "7820916")
GOLD_FILES = (
    "01_tables.sql",
    "02_positions.sql",
    "03_hourly.sql",
    "04_live.sql",
    "05_alerts.sql",
    "06_run.sql",
)
COMPARE_TABLES = (
    "fx_reference",
    "fx_rate_hourly",
    "position_state",
    "stock_hourly",
    "portfolio_hourly",
    "live_state",
    "alert_rules",
    "alerts",
)

pytestmark = pytest.mark.skipif(
    shutil.which("createdb") is None or shutil.which("git") is None,
    reason="requires PostgreSQL client tools and git",
)

TLPV = "eccd7e6f-8b1b-5baa-a744-091c1690363d"
NGRT = "49adbebf-11bc-57e2-9944-40758487be3a"
EURUSD = "90687094-e834-5deb-9de9-78cf761a91ee"
GBPUSD = "4f7ebd5e-97b4-5ee8-a434-2a0adca06c65"
USDJPY = "904be1e7-ca56-5523-a74f-96576c8fc0c9"
DAY = "2025-01-06"


def price(instrument_id: str, value: float, hhmmss: str) -> str:
    return json.dumps({
        "type": "price",
        "data": {"instrument_id": instrument_id, "price": value, "date": f"{DAY}T{hhmmss}Z"},
    })


def trade(trade_id: str, instrument_id: str, value: float, quantity: int,
          side: str, currency: str, hhmmss: str) -> str:
    return json.dumps({
        "type": "trade",
        "data": {
            "trade_id": trade_id,
            "instrument_id": instrument_id,
            "price": value,
            "volume": quantity,
            "side": side,
            "currency": currency,
            "date": f"{DAY}T{hhmmss}Z",
        },
    })


def run(command: list[str], *, db: str | None = None, sql: str | None = None) -> None:
    env = {**os.environ, "PGOPTIONS": "-c client_min_messages=warning"}
    if db:
        env["DATABASE_URL"] = f"dbname={db}"
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        input=sql,
        text=True,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise AssertionError(
            f"command failed ({result.returncode}): {' '.join(command)}\n{result.stderr}"
        )


def install_common(db: str) -> None:
    run([sys.executable, "ingest/ingest.py", "--init"], db=db)
    run(["psql", f"dbname={db}", "-v", "ON_ERROR_STOP=1", "-q", "-f", "sql/clean/install.sql"])


def install_legacy_gold(db: str) -> None:
    for filename in GOLD_FILES:
        path = f"sql/gold/{filename}"
        result = subprocess.run(
            ["git", "show", f"{LEGACY_REF}:{path}"],
            cwd=ROOT,
            text=True,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        run(["psql", f"dbname={db}", "-v", "ON_ERROR_STOP=1", "-q"], sql=result.stdout)


def install_current_gold(db: str) -> None:
    run(["psql", f"dbname={db}", "-v", "ON_ERROR_STOP=1", "-q", "-f", "sql/gold/install.sql"])


def feed(conn, lines: list[str]) -> None:
    run_id = conn.execute(
        "insert into raw.ingest_runs default values returning run_id"
    ).fetchone()[0]
    for line_no, payload in enumerate(lines, 1):
        conn.execute(
            "insert into raw.events (run_id, line_no, received_at, payload) "
            "values (%s, %s, now(), %s)",
            (run_id, line_no, payload),
        )


def exercise(db: str) -> None:
    initial = [
        price(EURUSD, 1.10, "08:00:00"),
        price(GBPUSD, 1.30, "08:00:00"),
        price(USDJPY, 150.0, "08:00:00"),
        price(TLPV, 100.0, "09:00:00"),
        price(NGRT, 50.0, "09:00:00"),
        trade("00000000-0000-0000-0000-000000000001", TLPV, 100.0, 20_000, "BUY", "EUR", "09:10:00"),
        trade("00000000-0000-0000-0000-000000000002", TLPV, 102.0, 5_000, "BUY", "EUR", "09:20:00"),
        trade("00000000-0000-0000-0000-000000000003", NGRT, 50.0, 30_000, "SELL", "GBP", "09:25:00"),
        price(EURUSD, 1.12, "10:00:00"),
        price(GBPUSD, 1.28, "10:00:00"),
        price(USDJPY, 151.0, "10:00:00"),
        price(TLPV, 104.0, "10:00:00"),
        price(NGRT, 48.0, "10:00:00"),
        trade("00000000-0000-0000-0000-000000000004", TLPV, 105.0, 24_000, "SELL", "EUR", "10:10:00"),
        trade("00000000-0000-0000-0000-000000000005", TLPV, 99.0, 3_000, "SELL", "EUR", "10:30:00"),
        price(TLPV, 98.0, "11:00:00"),
        price(NGRT, 52.0, "11:00:00"),
    ]
    late = [
        trade("00000000-0000-0000-0000-000000000006", TLPV, 101.0, 2_000, "BUY", "EUR", "09:15:00"),
        price(TLPV, 103.0, "09:45:00"),
    ]

    with psycopg.connect(f"dbname={db}") as conn:
        feed(conn, initial)
        conn.execute("select * from clean.run()")
        conn.execute("select * from gold.run()")
        feed(conn, late)
        conn.execute("select * from clean.run()")
        conn.execute("select * from gold.run()")
        conn.execute("select gold.nightly_fix(%s)", (f"{DAY}T00:00:00Z",))


def table_rows(conn, table: str):
    columns = [
        row[0]
        for row in conn.execute(
            "select column_name from information_schema.columns "
            "where table_schema = 'gold' and table_name = %s order by ordinal_position",
            (table,),
        )
    ]
    order = ", ".join(str(index) for index in range(1, len(columns) + 1))
    rows = conn.execute(f"select * from gold.{table} order by {order}").fetchall()
    return columns, rows


def test_refactored_gold_matches_legacy_row_for_row():
    try:
        subprocess.run(
            ["git", "cat-file", "-e", f"{LEGACY_REF}^{{commit}}"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError:
        pytest.skip(f"legacy ref {LEGACY_REF} is not available")

    legacy_db = "t_gold_old_" + uuid.uuid4().hex[:8]
    current_db = "t_gold_new_" + uuid.uuid4().hex[:8]
    try:
        for db in (legacy_db, current_db):
            run(["createdb", db])
            install_common(db)
        install_legacy_gold(legacy_db)
        install_current_gold(current_db)
        exercise(legacy_db)
        exercise(current_db)

        with psycopg.connect(f"dbname={legacy_db}") as old, psycopg.connect(f"dbname={current_db}") as new:
            for table in COMPARE_TABLES:
                assert table_rows(new, table) == table_rows(old, table), table
    finally:
        for db in (legacy_db, current_db):
            subprocess.run(["dropdb", "--if-exists", db], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
