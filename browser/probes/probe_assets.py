"""Dump resource timings for a page.

This is the tool that answers "the challenge page is stuck -- is it failing, or
just slow?". A page can show zero failed requests and still be unusable because
every asset took 15 seconds.

    python probes/probe_assets.py --config config.local.json --url https://claude.ai/
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from patchright.sync_api import sync_playwright  # noqa: E402

from launch import build_kwargs, load_config, preflight, verify_browser_egress  # noqa: E402

JS = """() => performance.getEntriesByType('resource').map(r => ({
  name: r.name,
  type: r.initiatorType,
  status: r.responseStatus ?? null,
  transferSize: r.transferSize,
  decodedSize: r.decodedBodySize,
  durationMs: Math.round(r.duration),
}))"""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config.local.json")
    ap.add_argument("--profile", default="probe")
    ap.add_argument("--url", default="https://claude.ai/")
    ap.add_argument("--wait", type=float, default=45.0, help="seconds to let the page settle")
    ap.add_argument("--top", type=int, default=30, help="show the slowest N resources")
    args = ap.parse_args()

    cfg = load_config(args.config)
    preflight(cfg)  # probes must not bypass the fail-closed gates
    kwargs = build_kwargs(cfg, args.profile, True)
    with sync_playwright() as p:
        context = p.chromium.launch_persistent_context(**kwargs)
        if cfg.get("fail_closed", True):
            verify_browser_egress(context, cfg["expected_ip"])
        page = context.pages[0] if context.pages else context.new_page()
        try:
            page.goto(args.url, wait_until="domcontentloaded", timeout=60000)
        except Exception as exc:  # noqa: BLE001
            print(f"[warn] goto: {type(exc).__name__}: {exc}")
        page.wait_for_timeout(int(args.wait * 1000))

        rows = page.evaluate(JS)
        rows.sort(key=lambda r: r["durationMs"], reverse=True)
        total = len(rows)
        failed = [r for r in rows if r["status"] not in (None, 200, 204, 304)]
        slow = [r for r in rows if r["durationMs"] > 5000]

        print(f"resources: {total}  failed: {len(failed)}  slower-than-5s: {len(slow)}")
        print(f"{'dur(ms)':>8} {'status':>6} {'KB':>7}  url")
        for r in rows[: args.top]:
            kb = (r["transferSize"] or r["decodedSize"] or 0) / 1024
            print(f"{r['durationMs']:>8} {str(r['status']):>6} {kb:>7.1f}  {r['name'][:110]}")
        if failed:
            print("\nfailed:")
            for r in failed:
                print(f"  {r['status']} {r['name'][:110]}")
        context.close()


if __name__ == "__main__":
    main()
