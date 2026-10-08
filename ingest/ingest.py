"""ingest layer: store every line the simulator sends, unchanged, in raw.events in PostgreSQL.

Principle: no parsing, no validation, no de-duplication. Whatever arrives is stored (duplicate and garbled lines too).
Run:    python ingest/ingest.py          receive until Ctrl-C or kill (the rows in hand are written first)
        python ingest/ingest.py --init   only create the raw tables and exit (used by make schema)
Needs:  PostgreSQL running and the database existing; the simulator listening on localhost:1337.
"""
import os
import signal
import socket
import sys
import time
from datetime import datetime, timezone

import psycopg

DB = os.environ.get("DATABASE_URL", "dbname=marketsim")   # database connection string
HOST = os.environ.get("SIM_HOST", "localhost")           # simulator address (docker compose sets SIM_HOST=simulator)
PORT = int(os.environ.get("SIM_PORT", "1337"))
BATCH_ROWS = 100       # write once 100 rows have piled up
BATCH_SECONDS = 1.0    # or when more than 1 second has passed since the last write (so low traffic never waits long)

# Table definitions. "if not exists" makes them safe to repeat: existing tables are skipped.
SCHEMA = """
create schema if not exists raw;

-- one row per loader run: tells loads apart and is reconciled at the end
create table if not exists raw.ingest_runs (
    run_id        bigserial primary key,
    started_at    timestamptz not null default now(),
    ended_at      timestamptz,
    status        text        not null default 'running',  -- running / finished / stopped / failed
    rows_received bigint      not null default 0
);

-- one row per received message. No business key, so duplicate messages are kept as they came.
create table if not exists raw.events (
    raw_id      bigserial primary key,                      -- auto-increment number = arrival order
    run_id      bigint      not null references raw.ingest_runs,
    line_no     bigint      not null,                       -- which line of this run
    received_at timestamptz not null,                       -- real time at which we received it
    payload     text        not null                        -- original text; text because garbled lines are not valid JSON
);
"""


def read_lines():
    """Connect to the simulator and yield the text line by line. Ends naturally when the connection closes."""
    sock = socket.create_connection((HOST, PORT))
    # the makefile helper handles "TCP delivered only half a line": it only hands us complete lines.
    # errors="replace": undecodable bytes become ?, so the program never crashes.
    for line in sock.makefile("r", encoding="utf-8", errors="replace", newline="\n"):
        yield line.rstrip("\n")


def flush(conn, run_id, rows):
    """Write the collected batch to the database. Insert and count are in one transaction, so they always agree."""
    if not rows:
        return
    with conn.cursor() as cur:
        cur.executemany(
            "insert into raw.events (run_id, line_no, received_at, payload) values (%s, %s, %s, %s)",
            rows)
        cur.execute("update raw.ingest_runs set rows_received = rows_received + %s where run_id = %s",
                    (len(rows), run_id))
    conn.commit()   # only after commit is the batch really saved


def main():
    # make down / docker stop send SIGTERM: treat it like Ctrl-C (go to the KeyboardInterrupt branch below) so the rows in hand are written before exiting
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    with psycopg.connect(DB) as conn:
        conn.execute(SCHEMA)  # create the tables first
        if "--init" in sys.argv:
            print("raw 层已建好")
            return
        run_id = conn.execute("insert into raw.ingest_runs default values returning run_id").fetchone()[0]
        conn.commit()

        rows, n, last_flush, status = [], 0, time.time(), "finished"
        try:
            for line in read_lines():
                n += 1
                # received_at is stamped at the moment the line is read, not later when it is written to the database
                # Postgres text cannot hold NUL characters; replace them with the visible text \x00 so the whole batch does not fail
                rows.append((run_id, n, datetime.now(timezone.utc), line.replace("\x00", "\\x00")))
                if len(rows) >= BATCH_ROWS or time.time() - last_flush >= BATCH_SECONDS:
                    flush(conn, run_id, rows)
                    rows, last_flush = [], time.time()
        except KeyboardInterrupt:   # you pressed Ctrl-C
            status = "stopped"
        except Exception:           # cannot reach the simulator, database error, etc.
            status = "failed"
            raise
        finally:
            # however the run ends, write what is left first, then mark the run with its final status
            conn.rollback()  # if the previous write failed, clear the failed transaction first
            flush(conn, run_id, rows)
            conn.execute("update raw.ingest_runs set ended_at = now(), status = %s where run_id = %s",
                         (status, run_id))
            conn.commit()

        # reconciliation: lines we counted vs rows actually stored for this run
        in_db = conn.execute("select count(*) from raw.events where run_id = %s", (run_id,)).fetchone()[0]
        print(f"run {run_id} {status}: 收到 {n} 行，库里 {in_db} 行，{'一致' if n == in_db else '不一致！'}")


if __name__ == "__main__":
    main()
