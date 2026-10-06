"""Command line entry point: python -m simulator [options]"""
from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timezone

from .market import STRATEGIES, Market, SimConfig, load_instruments
from .server import serve


def _parse_start(text: str) -> datetime:
    ts = datetime.fromisoformat(text.replace("Z", "+00:00"))
    return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="simulator", description="Simulated multi-country market feed.")
    p.add_argument("--mode", choices=["tcp", "stdout"], default="tcp",
                   help="tcp: serve a live stream; stdout: print messages and exit")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=1337)
    p.add_argument("--interval-min", type=float, default=400, help="min real delay between messages (ms)")
    p.add_argument("--interval-max", type=float, default=800, help="max real delay between messages (ms)")
    p.add_argument("--max-messages", type=int, default=0, help="stop after N messages (0 = endless)")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--start", default="2025-01-06T00:00:00Z", help="simulated start time (UTC, use a Monday)")
    p.add_argument("--sim-seconds-per-message", type=float, default=30.0,
                   help="mean simulated seconds between messages (time speed-up)")
    p.add_argument("--trade-ratio", type=float, default=0.55)
    p.add_argument("--late-prob", type=float, default=0.03, help="share of out-of-order timestamps")
    p.add_argument("--late-max-seconds", type=float, default=300.0)
    p.add_argument("--duplicate-prob", type=float, default=0.0, help="share of duplicated messages")
    p.add_argument("--bad-prob", type=float, default=0.01, help="share of corrupted messages (default 1%%)")
    p.add_argument("--strategy", choices=STRATEGIES, default="market_maker",
                   help="how our own trades are made: market_maker (earn the spread) or random (old behaviour)")
    p.add_argument("--position-limit-eur", type=float, default=5_000_000,
                   help="market maker: largest position per stock in EUR market value")
    p.add_argument("--informed-prob", type=float, default=0.10,
                   help="market maker: share of client orders that are informed (adverse selection)")
    p.add_argument("--informed-bps", type=float, default=8.0,
                   help="market maker: how far the price moves after an informed order (basis points)")
    return p


def main() -> None:
    args = build_parser().parse_args()
    cfg = SimConfig(seed=args.seed, start=_parse_start(args.start),
                    sim_seconds_per_message=args.sim_seconds_per_message,
                    trade_ratio=args.trade_ratio, late_prob=args.late_prob,
                    late_max_seconds=args.late_max_seconds,
                    duplicate_prob=args.duplicate_prob, bad_prob=args.bad_prob,
                    strategy=args.strategy, position_limit_eur=args.position_limit_eur,
                    informed_prob=args.informed_prob, informed_bps=args.informed_bps)
    if args.mode == "stdout":
        market = Market(load_instruments(), cfg)
        sent = 0
        while args.max_messages == 0 or sent < args.max_messages:
            for line in market.next_events():
                print(line)
                sent += 1
        return
    try:
        asyncio.run(serve(cfg, args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
