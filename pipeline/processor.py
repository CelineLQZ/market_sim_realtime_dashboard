"""processor：每隔几秒，按顺序处理新数据：raw → clean → gold。

它是一个一直开着的进程（和 ingest 一样），自己不做任何计算，只负责"定时调用"：
    select * from clean.run();    -- 清洗 raw 里新到的行
    select * from gold.run();     -- 更新持仓、小时快照、实时表、预警
每一轮结束后才等下一轮，所以两轮不会重叠；某一轮出错（比如数据库暂时连不上）只记日志，等一会儿重试。
另外，每当模拟时间进入新的一天，就从刚结束的那一天 00:00 起重算一次小时快照（gold.nightly_fix），
用来修正"迟到的旧报价"对历史估值的影响。

运行：  python pipeline/processor.py              一直运行，Ctrl-C 停止
        python pipeline/processor.py --once       只跑一轮就退出（测试、手动补跑）
        python pipeline/processor.py --interval 2 每 2 秒一轮（默认 5 秒，也可以用环境变量 PROCESS_INTERVAL）
前提：  PostgreSQL 已启动；sql/01、02、04、05 已经运行过（建好表和函数）。
"""
import argparse
import os
import signal
import sys
import time
from datetime import datetime, time as dtime, timezone

import psycopg
from psycopg.rows import dict_row

DB = os.environ.get("DATABASE_URL", "dbname=marketsim")   # 数据库连接串（和 ingest 一样）
HEARTBEAT_SECONDS = 60     # 没有新数据时，每隔多久打一行"还活着"
MAX_BACKOFF = 30           # 出错后最多等多少秒再重试


def log(msg):
    print(f"{datetime.now():%H:%M:%S} {msg}", flush=True)


def run_cycle(conn):
    """跑一轮：先 clean，再 gold。中间必须 commit：gold 读的是 clean 提交之后的进度。"""
    clean = conn.execute("select * from clean.run()").fetchone()
    conn.commit()
    gold = conn.execute("select * from gold.run()").fetchone()
    conn.commit()
    return clean, gold


def describe(clean, gold):
    return (f"clean: raw {clean['from_raw_id']}-{clean['to_raw_id']} 共 {clean['raw_rows']} 行"
            f"（保留 {clean['kept_rows']}，坏行 {clean['bad_rows']}，"
            f"冲突报价 {clean['conflicting_prices']}，重复 {clean['duplicates_dropped']}）"
            f" | gold: 重放成交 {gold['trades_replayed']} 笔，迟到回放 {gold['late_rewinds']} 次，"
            f"重算 {gold['hours_rebuilt']} 小时，as_of {gold['as_of']:%Y-%m-%d %H:%M}，"
            f"未解除预警 {gold['open_alerts']}")


def nightly_fix_on_new_day(conn, as_of, state):
    """模拟时间进入新的一天时，从刚结束那一天的 00:00 起重算小时快照。"""
    if as_of is None:
        return
    day = as_of.astimezone(timezone.utc).date()
    prev = state.get("day")
    state["day"] = day
    if prev is not None and day > prev:
        start = datetime.combine(prev, dtime.min, tzinfo=timezone.utc)
        n = conn.execute("select gold.nightly_fix(%s) as n", (start,)).fetchone()["n"]
        conn.commit()
        log(f"新的一天 {day}：已从 {prev} 00:00 起重算小时快照（{n}）")


def main():
    ap = argparse.ArgumentParser(description="每隔几秒处理一次新数据：clean → gold")
    ap.add_argument("--interval", type=float, default=float(os.environ.get("PROCESS_INTERVAL", "5")),
                    help="两轮之间的间隔秒数（默认 5）")
    ap.add_argument("--once", action="store_true", help="只跑一轮就退出")
    args = ap.parse_args()
    signal.signal(signal.SIGTERM, signal.default_int_handler)   # make down / docker stop：和 Ctrl-C 一样，正常收尾后退出

    conn, fails, state, last_beat = None, 0, {}, 0.0
    log(f"processor 启动：每 {args.interval:g} 秒一轮" if not args.once else "processor 启动：只跑一轮")
    while True:
        started = time.monotonic()
        try:
            if conn is None or conn.closed:
                conn = psycopg.connect(DB, row_factory=dict_row)
                log("已连接数据库")
            clean, gold = run_cycle(conn)
            nightly_fix_on_new_day(conn, gold["as_of"], state)
            fails = 0
            if not clean["balanced"]:
                log(f"警告：clean 对账不平衡！{describe(clean, gold)}")
            elif clean["raw_rows"] > 0 or gold["trades_replayed"] > 0 or gold["hours_rebuilt"] > 0:
                log(describe(clean, gold))
                last_beat = time.monotonic()
            elif time.monotonic() - last_beat >= HEARTBEAT_SECONDS or args.once:
                log(f"没有新数据（as_of {gold['as_of']:%Y-%m-%d %H:%M}，未解除预警 {gold['open_alerts']}）"
                    if gold["as_of"] else "没有新数据（数据库里还没有数据）")
                last_beat = time.monotonic()
        except KeyboardInterrupt:
            break
        except (psycopg.errors.UndefinedFunction, psycopg.errors.InvalidSchemaName,
                psycopg.errors.UndefinedTable) as e:
            # schema、表或函数还没建好：不是"稍后重试"能解决的小问题，提示该运行哪些文件
            log(f"出错：{e}\n    请先运行 sql/02_clean.sql 和 sql/05_gold.sql（建表和函数）")
            fails += 1
        except psycopg.Error as e:
            log(f"出错：{str(e).strip()}")
            fails += 1
        if fails and conn is not None:
            try:
                conn.close()          # 出错后丢掉这个连接，下一轮重新连（也能处理数据库重启）
            except psycopg.Error:
                pass
            conn = None
        if args.once:
            sys.exit(1 if fails else 0)
        wait = args.interval if not fails else min(MAX_BACKOFF, args.interval * (fails + 1))
        try:
            time.sleep(max(0.0, wait - (time.monotonic() - started)))   # 固定节奏：扣掉这一轮自己花的时间
        except KeyboardInterrupt:
            break
    if conn is not None and not conn.closed:
        conn.close()
    log("processor 已停止")


if __name__ == "__main__":
    main()
