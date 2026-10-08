"""processor: every few seconds, process new data in order: raw -> clean -> gold.

A long-running process (like ingest). It does no calculation itself, it only calls on a timer:
    select * from clean.run();    -- clean the rows that arrived in raw
    select * from gold.run();     -- append positions behind the watermark, write finished hourly snapshots, refresh live state
A cycle only starts after the previous one has finished, so cycles never overlap. If a cycle fails
(for example the database is briefly unreachable) it is logged and retried after a pause.

Run:    python pipeline/processor.py              run forever, stop with Ctrl-C
        python pipeline/processor.py --once       run one cycle and exit (tests, manual catch-up)
        python pipeline/processor.py --interval 2 one cycle every 2 seconds (default 5, or env PROCESS_INTERVAL)
Needs:  PostgreSQL running; sql/clean/install.sql and sql/gold/install.sql already applied (tables and functions exist).
"""
import argparse
import os
import signal
import sys
import time
from datetime import datetime

import psycopg
from psycopg.rows import dict_row

DB = os.environ.get("DATABASE_URL", "dbname=marketsim")   # database connection string (same as ingest)
HEARTBEAT_SECONDS = 60     # when idle, log a "still alive" line this often (seconds)
MAX_BACKOFF = 30           # longest pause (seconds) before retrying after an error


def log(msg):
    print(f"{datetime.now():%H:%M:%S} {msg}", flush=True)


def run_cycle(conn):
    """Run one cycle: clean first, then gold. The commit in between is required: gold reads clean's committed progress."""
    clean = conn.execute("select * from clean.run()").fetchone()
    conn.commit()
    gold = conn.execute("select * from gold.run()").fetchone()
    conn.commit()
    return clean, gold


def describe(clean, gold):
    return (f"clean: raw {clean['from_raw_id']}-{clean['to_raw_id']}, {clean['raw_rows']} rows"
            f" (kept {clean['kept_rows']}, bad {clean['bad_rows']},"
            f" conflicting prices {clean['conflicting_prices']}, duplicates {clean['duplicates_dropped']})"
            f" | gold: {gold['trades_applied']} trades applied, {gold['too_late']} too late,"
            f" {gold['hours_built']} hours built, watermark {gold['watermark']:%Y-%m-%d %H:%M}"
            if gold['as_of'] else f"clean: raw {clean['from_raw_id']}-{clean['to_raw_id']}, {clean['raw_rows']} rows")


def main():
    ap = argparse.ArgumentParser(description="Process new data every few seconds: clean -> gold")
    ap.add_argument("--interval", type=float, default=float(os.environ.get("PROCESS_INTERVAL", "5")),
                    help="seconds between cycles (default 5)")
    ap.add_argument("--once", action="store_true", help="run one cycle and exit")
    args = ap.parse_args()
    signal.signal(signal.SIGTERM, signal.default_int_handler)   # make down / docker stop: same as Ctrl-C, finish cleanly and exit

    conn, fails, last_beat = None, 0, 0.0
    log(f"processor started: one cycle every {args.interval:g} s" if not args.once else "processor started: single cycle")
    while True:
        started = time.monotonic()
        try:
            if conn is None or conn.closed:
                conn = psycopg.connect(DB, row_factory=dict_row)
                log("connected to the database")
            clean, gold = run_cycle(conn)
            fails = 0
            if not clean["balanced"]:
                log(f"WARNING: clean reconciliation does not balance! {describe(clean, gold)}")
            elif clean["raw_rows"] > 0 or gold["trades_applied"] > 0 or gold["hours_built"] > 0:
                log(describe(clean, gold))
                last_beat = time.monotonic()
            elif time.monotonic() - last_beat >= HEARTBEAT_SECONDS or args.once:
                log(f"no new data (as_of {gold['as_of']:%Y-%m-%d %H:%M}, watermark {gold['watermark']:%Y-%m-%d %H:%M})"
                    if gold["as_of"] else "no new data (the database is still empty)")
                last_beat = time.monotonic()
        except KeyboardInterrupt:
            break
        except (psycopg.errors.UndefinedFunction, psycopg.errors.InvalidSchemaName,
                psycopg.errors.UndefinedTable) as e:
            # schema, table or function missing: retrying will not fix it, so say which files to run
            log(f"error: {e}\n    run sql/clean/install.sql and sql/gold/install.sql first (tables and functions)")
            fails += 1
        except psycopg.Error as e:
            log(f"error: {str(e).strip()}")
            fails += 1
        if fails and conn is not None:
            try:
                conn.close()          # drop the connection after an error and reconnect next cycle (also handles a database restart)
            except psycopg.Error:
                pass
            conn = None
        if args.once:
            sys.exit(1 if fails else 0)
        wait = args.interval if not fails else min(MAX_BACKOFF, args.interval * (fails + 1))
        try:
            time.sleep(max(0.0, wait - (time.monotonic() - started)))   # fixed cadence: subtract the time this cycle took
        except KeyboardInterrupt:
            break
    if conn is not None and not conn.closed:
        conn.close()
    log("processor stopped")


if __name__ == "__main__":
    main()
