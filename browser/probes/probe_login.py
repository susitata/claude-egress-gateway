"""Trace what happens after clicking a third-party login button.

Answers "I clicked Continue with Google and nothing happened": is the popup
blocked, delayed, or opening into a captcha? Prints new pages, navigations, and
requests to the identity provider for N seconds.

    python probes/probe_login.py --config config.local.json
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from patchright.sync_api import sync_playwright  # noqa: E402

from launch import build_kwargs, load_config, preflight, verify_browser_egress  # noqa: E402

LOGIN_URL = "https://claude.ai/login"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config.local.json")
    ap.add_argument("--profile", default="probe")
    ap.add_argument("--button", default="Continue with Google")
    ap.add_argument("--timeout", type=float, default=150.0, help="seconds to wait for the button")
    ap.add_argument("--observe", type=float, default=60.0, help="seconds to observe after the click")
    ap.add_argument("--screenshot", default="", help="optional output png path")
    args = ap.parse_args()

    cfg = load_config(args.config)
    preflight(cfg)  # probes must not bypass the fail-closed gates
    kwargs = build_kwargs(cfg, args.profile, None)  # headed: some popups need a real window
    with sync_playwright() as p:
        context = p.chromium.launch_persistent_context(**kwargs)
        if cfg.get("fail_closed", True):
            verify_browser_egress(context, cfg["expected_ip"])
        page = context.pages[0] if context.pages else context.new_page()

        context.on("page", lambda pg: print(f"[newpage] {pg.url or '(blank)'}"))
        page.on("framenavigated", lambda f: print(f"[nav] {f.url[:140]}") if f == page.main_frame else None)
        page.on("request", lambda r: print(f"[req] {r.url[:140]}")
                if any(k in r.url for k in ("accounts.google.com", "gstatic.com", "recaptcha"))
                else None)

        try:
            page.goto(LOGIN_URL, wait_until="domcontentloaded", timeout=60000)
        except Exception as exc:  # noqa: BLE001
            print(f"[warn] goto: {type(exc).__name__}: {exc}")

        print(f"[info] waiting up to {args.timeout:.0f}s for '{args.button}' ...")
        try:
            page.get_by_text(args.button, exact=False).first.click(timeout=int(args.timeout * 1000))
            print("[ok] clicked")
        except Exception as exc:  # noqa: BLE001
            print(f"[fail] button not clickable: {type(exc).__name__}: {exc}")
            if args.screenshot:
                page.screenshot(path=args.screenshot, full_page=False)
            context.close()
            return

        page.wait_for_timeout(int(args.observe * 1000))
        print("[info] observed pages:")
        for i, pg in enumerate(context.pages):
            print(f"  [{i}] {pg.url[:140]}")
        if args.screenshot:
            page.screenshot(path=args.screenshot, full_page=False)
            print(f"[ok] screenshot -> {args.screenshot}")
        context.close()


if __name__ == "__main__":
    main()
