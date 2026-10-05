"""Dashboard server (standard library only).

  python -m dashboard.server                  # live: simulator -> P&L engine -> /api/state, page polls every 3 s
  python -m dashboard.server --export dashboard/replay.json    # write two simulated days for the static replay

In the Azure version only `Feed` changes: instead of running the simulator in-process it reads the
Gold tables through a Databricks SQL warehouse. The HTTP layer and the HTML stay the same.
"""
from __future__ import annotations

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from pipeline.pnl import Book
from simulator.market import Market, SimConfig, load_instruments

HERE = Path(__file__).resolve().parent
START = SimConfig().start
RANGE = [START.strftime("%Y-%m-%dT%H:%M:%SZ"), "2025-01-08T00:00:00Z"]    # two simulated days, Mon + Tue


def run_days(book: Book, market: Market, on_step, every: int, pace: float = 0.0) -> None:
    """Feed messages until the end of day two. `on_step(book)` is called every `every` messages."""
    k = 0
    while True:
        for line in market.next_events():
            book.on_line(line)
        k += 1
        if book.clock and book.clock.strftime("%Y-%m-%dT%H:%M:%SZ") >= RANGE[1]:
            break
        if k % every == 0:
            on_step(book)
            if pace:
                time.sleep(pace)
    on_step(book)


class Feed:
    """Runs the simulator in a thread and keeps the latest snapshot plus a P&L history."""
    def __init__(self, speed: float, every: int = 20):
        self.book = Book(load_instruments())
        self.market = Market(load_instruments(), SimConfig())
        self.lock = threading.Lock()
        self.history: list[list] = []
        self.finished = False
        self.speed, self.every = speed, every

    def _step(self, book: Book) -> None:
        s = book.snapshot()
        with self.lock:
            self.history.append([s["asof"], s["total"]])

    def start(self) -> None:
        def go():
            run_days(self.book, self.market, self._step, self.every, pace=self.every / self.speed)
            self.finished = True
        threading.Thread(target=go, daemon=True).start()

    def state(self) -> dict:
        with self.lock:
            if self.book.clock is None:
                return {"mode": "live", "range": RANGE, "asof": None, "history": [], "positions": [], "alerts": []}
            s = self.book.snapshot()
            return {**s, "mode": "live", "range": RANGE, "finished": self.finished,
                    "history": self.history[-600:]}


def export(path: str, every: int) -> None:
    book, market = Book(load_instruments()), Market(load_instruments(), SimConfig())
    frames = []
    run_days(book, market, lambda b: frames.append(b.snapshot()), every)
    Path(path).write_text(json.dumps({"range": RANGE, "frames": frames}, separators=(",", ":")))
    print(f"wrote {path}: {len(frames)} frames, {book.n} messages, final P&L {frames[-1]['total']:,.0f} EUR")


def make_handler(feed: Feed):
    class H(BaseHTTPRequestHandler):
        def _send(self, body: bytes, ctype: str) -> None:
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?")[0]
            if path == "/api/state":
                return self._send(json.dumps(feed.state()).encode(), "application/json")
            files = {"/": ("index.html", "text/html; charset=utf-8"),
                     "/replay.json": ("replay.json", "application/json")}
            if path in files and (HERE / files[path][0]).exists():
                return self._send((HERE / files[path][0]).read_bytes(), files[path][1])
            self.send_error(404)

        def log_message(self, *a):
            pass
    return H


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--speed", type=float, default=20, help="simulator messages per real second")
    ap.add_argument("--export", metavar="FILE", help="write replay JSON for the static page and exit")
    ap.add_argument("--every", type=int, default=40, help="messages between snapshots when exporting")
    a = ap.parse_args()
    if a.export:
        export(a.export, a.every)
    else:
        feed = Feed(a.speed)
        feed.start()
        print(f"http://localhost:{a.port}  (live, {a.speed:g} msg/s; two simulated days take ~{5700 / a.speed / 60:.0f} min)")
        ThreadingHTTPServer(("0.0.0.0", a.port), make_handler(feed)).serve_forever()
