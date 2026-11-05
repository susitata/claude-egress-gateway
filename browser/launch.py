"""Launch a visible, persistent Patchright browser behind a fixed proxy.

This is the browser half of the egress gateway: Chrome is pointed at the local
end of the SSH tunnel with a *fixed* proxy server (not a PAC file), so when the
tunnel is down the browser fails instead of silently going direct.

Usage:
    python launch.py
    python launch.py --config config.local.json --profile work
    python launch.py --headless --url https://claude.ai/

Config: JSON, see config.example.json. Relative paths resolve next to this file.
"""
from __future__ import annotations

import argparse
import json
import socket
import sys
from pathlib import Path
from urllib.parse import urlparse

from patchright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def find_config(name: str) -> Path:
    """Accept an absolute path, or a bare name resolved against ./config/."""
    p = Path(name)
    if p.is_absolute() and p.is_file():
        return p
    for candidate in (HERE / name, HERE / "config" / name, REPO / "config" / name):
        if candidate.is_file():
            return candidate
    raise SystemExit(f"[fatal] config not found: {name}")


def load_config(name: str) -> dict:
    path = find_config(name)
    with path.open(encoding="utf-8") as fh:
        cfg = json.load(fh)
    print(f"[ok] config = {path}")
    return cfg


def proxy_from_config(cfg: dict) -> dict | None:
    raw = cfg.get("proxy") or {}
    server = (raw.get("server") or "").strip()
    if not server:
        return None
    proxy: dict = {"server": server}
    # Playwright/Patchright want a bare "user:pass", not base64.
    if raw.get("username"):
        proxy["username"] = raw["username"]
    if raw.get("password"):
        proxy["password"] = raw["password"]
    return proxy


def user_data_dir(cfg: dict, profile: str) -> Path:
    base = cfg.get("user_data_dir")
    root = Path(base) if base else REPO / "profiles"
    if not root.is_absolute():
        root = (HERE / root).resolve()
    return root / profile


def require_proxy_reachable(proxy: dict | None) -> None:
    """fail_closed: abort if the proxy is unreachable — never start a direct browser."""
    if not proxy:
        print("[fatal] fail_closed=true but no proxy is configured. Aborting (no direct fallback).")
        sys.exit(2)
    server = proxy["server"]
    parsed = urlparse(server if "://" in server else f"http://{server}")
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    try:
        with socket.create_connection((host, port), timeout=5):
            pass
    except OSError as exc:
        print(f"[fatal] proxy {server} is unreachable: {exc}")
        print("[fatal] aborted: no direct fallback will be used.")
        sys.exit(2)


def build_kwargs(cfg: dict, profile: str, headless_override: bool | None) -> dict:
    kwargs: dict = {
        "user_data_dir": str(user_data_dir(cfg, profile)),
        # Use the locally installed Chrome. More credible than bundled chromium,
        # and exercises the same code paths a normal user would.
        "channel": cfg.get("channel") or "chrome",
        "headless": cfg.get("headless", False) if headless_override is None else headless_override,
        "no_viewport": bool(cfg.get("no_viewport", True)),
        "slow_mo": cfg.get("slow_mo", 0),
        "args": list(cfg.get("browser_args") or []),
    }
    proxy = proxy_from_config(cfg)
    if proxy:
        kwargs["proxy"] = proxy
    if cfg.get("locale"):
        kwargs["locale"] = cfg["locale"]
    if cfg.get("timezone_id"):
        kwargs["timezone_id"] = cfg["timezone_id"]
    return kwargs


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.local.json")
    parser.add_argument("--profile", default="default")
    parser.add_argument("--headless", action="store_true")
    parser.add_argument("--url", default=None)
    args = parser.parse_args()

    cfg = load_config(args.config)
    kwargs = build_kwargs(cfg, args.profile, True if args.headless else None)
    if cfg.get("fail_closed"):
        require_proxy_reachable(kwargs.get("proxy"))
    start_url = args.url or cfg.get("start_url") or "about:blank"

    with sync_playwright() as p:
        context = p.chromium.launch_persistent_context(**kwargs)
        page = context.pages[0] if context.pages else context.new_page()

        proxy_desc = (kwargs.get("proxy") or {}).get("server", "direct")
        print(f"[ok] launched  profile={args.profile}")
        print(f"     user_data_dir = {kwargs['user_data_dir']}")
        print(f"     channel       = {kwargs['channel']}")
        print(f"     headless      = {kwargs['headless']}")
        print(f"     proxy         = {proxy_desc}")

        try:
            page.goto(start_url, wait_until="domcontentloaded", timeout=60000)
        except Exception as exc:  # noqa: BLE001
            # A timeout here is normal on a slow path (bot challenges can take
            # 30-90s). Never close the window on the user's behalf.
            print(f"[warn] page did not finish loading within 60s ({type(exc).__name__}); "
                  f"window stays open, refresh manually if needed")
        try:
            page.bring_to_front()
        except Exception:
            pass

        try:
            # Block until the window is closed (timeout=0 means no timeout).
            page.wait_for_event("close", timeout=0)
        except KeyboardInterrupt:
            pass
        except Exception as exc:  # closing the window trips the sync API
            print(f"[info] browser closed: {type(exc).__name__}")
        finally:
            try:
                context.close()
            except Exception:
                pass


if __name__ == "__main__":
    main()
