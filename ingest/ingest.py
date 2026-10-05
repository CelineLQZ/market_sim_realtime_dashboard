"""ingest 层：把模拟器发来的每一行消息，原样存进 PostgreSQL 的 raw.events。

原则：不解析、不校验、不去重。收到什么就存什么（重复行、乱码行也照存）。
运行：  python ingest/ingest.py          一直接收，Ctrl-C 或 kill 停止（会先把手里的行写完）
        python ingest/ingest.py --init   只建 raw 层的表就退出（make schema 用）
前提：  PostgreSQL 已启动且数据库存在；模拟器在 localhost:1337 运行。
"""
import os
import signal
import socket
import sys
import time
from datetime import datetime, timezone

import psycopg

DB = os.environ.get("DATABASE_URL", "dbname=marketsim")   # 数据库连接串
HOST, PORT = "localhost", 1337                             # 模拟器地址
BATCH_ROWS = 100       # 攒够 100 行就写一次
BATCH_SECONDS = 1.0    # 或者距离上次写入超过 1 秒也写（流量小时不会等太久）

# 建表语句。"if not exists" 表示可以重复执行，已经存在就跳过。
SCHEMA = """
create schema if not exists raw;

-- 每次运行 loader 记一行：用来区分"哪一次加载"，并在最后对账
create table if not exists raw.ingest_runs (
    run_id        bigserial primary key,
    started_at    timestamptz not null default now(),
    ended_at      timestamptz,
    status        text        not null default 'running',  -- running / finished / stopped / failed
    rows_received bigint      not null default 0
);

-- 每收到一行消息存一行。没有业务主键，所以重复消息会被如实保留。
create table if not exists raw.events (
    raw_id      bigserial primary key,                      -- 自增编号，等于到达顺序
    run_id      bigint      not null references raw.ingest_runs,
    line_no     bigint      not null,                       -- 本次运行里的第几行
    received_at timestamptz not null,                       -- 我们收到的真实时间
    payload     text        not null                        -- 原始文本；用 text 因为乱码行不是合法 JSON
);
"""


def read_lines():
    """连上模拟器，一行一行地产出文本。连接断开时自然结束。"""
    sock = socket.create_connection((HOST, PORT))
    # makefile 会帮我们处理"TCP 一次只收到半行"的情况：攒够一整行才交给我们。
    # errors="replace"：遇到无法解码的字节用 ? 代替，保证程序不会崩。
    for line in sock.makefile("r", encoding="utf-8", errors="replace", newline="\n"):
        yield line.rstrip("\n")


def flush(conn, run_id, rows):
    """把攒好的一批行写进数据库。插入和计数放在同一个事务里，两者永远一致。"""
    if not rows:
        return
    with conn.cursor() as cur:
        cur.executemany(
            "insert into raw.events (run_id, line_no, received_at, payload) values (%s, %s, %s, %s)",
            rows)
        cur.execute("update raw.ingest_runs set rows_received = rows_received + %s where run_id = %s",
                    (len(rows), run_id))
    conn.commit()   # commit 之后这一批才真正保存


def main():
    # make down / docker stop 发来的是 SIGTERM：让它和 Ctrl-C 一样，走下面的 KeyboardInterrupt 分支，先把手里的行写完再退出
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    with psycopg.connect(DB) as conn:
        conn.execute(SCHEMA)  # 先建好库表
        if "--init" in sys.argv:
            print("raw 层已建好")
            return
        run_id = conn.execute("insert into raw.ingest_runs default values returning run_id").fetchone()[0]
        conn.commit()

        rows, n, last_flush, status = [], 0, time.time(), "finished"
        try:
            for line in read_lines():
                n += 1
                # received_at 在"读到这一行"的时刻就打上，不要等到写库时才打
                # Postgres 的 text 不允许出现 NUL 字符，遇到就换成可见的 \x00 文本，避免整批写入失败
                rows.append((run_id, n, datetime.now(timezone.utc), line.replace("\x00", "\\x00")))
                if len(rows) >= BATCH_ROWS or time.time() - last_flush >= BATCH_SECONDS:
                    flush(conn, run_id, rows)
                    rows, last_flush = [], time.time()
        except KeyboardInterrupt:   # 你按了 Ctrl-C
            status = "stopped"
        except Exception:           # 连不上模拟器、数据库出错等
            status = "failed"
            raise
        finally:
            # 不管怎么结束，都先把手里剩下的写掉，再把这次运行标记成最终状态
            conn.rollback()  # 若上一次写入失败，先清掉失败的事务
            flush(conn, run_id, rows)
            conn.execute("update raw.ingest_runs set ended_at = now(), status = %s where run_id = %s",
                         (status, run_id))
            conn.commit()

        # 对账：我们数到的行数 vs 数据库里这次运行实际存了多少行
        in_db = conn.execute("select count(*) from raw.events where run_id = %s", (run_id,)).fetchone()[0]
        print(f"run {run_id} {status}: 收到 {n} 行，库里 {in_db} 行，{'一致' if n == in_db else '不一致！'}")


if __name__ == "__main__":
    main()
