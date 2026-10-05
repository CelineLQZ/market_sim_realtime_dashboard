"""TCP server: every client gets its own stream of newline-delimited JSON messages."""
from __future__ import annotations

import asyncio
import random
import sys

from .market import Market, SimConfig, load_instruments


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


async def _handle(reader, writer, cfg: SimConfig, args) -> None:
    peer = writer.get_extra_info("peername")
    _log(f"client connected: {peer}")
    market = Market(load_instruments(), cfg)
    pace = random.Random(cfg.seed ^ 0xBEEF)     # timing only; never touches message content
    sent = 0
    try:
        while args.max_messages == 0 or sent < args.max_messages:
            for line in market.next_events():
                writer.write((line + "\n").encode())
                sent += 1
            await writer.drain()
            delay_ms = pace.uniform(args.interval_min, args.interval_max)
            await asyncio.sleep(max(delay_ms, 0) / 1000)
    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        writer.close()
        _log(f"client disconnected: {peer} after {sent} messages")


async def serve(cfg: SimConfig, args) -> None:
    server = await asyncio.start_server(
        lambda r, w: _handle(r, w, cfg, args), args.host, args.port)
    _log(f"market-sim listening on {args.host}:{args.port} "
         f"(interval {args.interval_min}-{args.interval_max} ms, seed {cfg.seed})")
    async with server:
        await server.serve_forever()
