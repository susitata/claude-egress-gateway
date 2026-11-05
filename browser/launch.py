"""Launch a visible, persistent Patchright browser behind a fixed proxy.

This is the browser half of the egress gateway. Chrome is pointed at the local
end of the SSH tunnel with a *fixed* proxy (never a PAC file), and the egress IP
is verified through that proxy before the window opens, so a wrong or stale
proxy fails loudly instead of silently going direct.

Usage:
    python launch.py
    python launch.py --config config.local.json --profile work
    python launch.py --expected-ip 203.0.113.10

Config: JSON, see config.example.json. Relative paths resolve next to this file.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

from patchright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
REPO = HERE.parent

# Chrome switches that would override the fixed proxy or reintroduce a fallback.
BANNED_PROXY_ARGS = {
    "--no-proxy-server",
    "--proxy-server",
    "--proxy-pac-url",
    "--proxy-bypass-list",
}


def find_config(name: str) -> Path:
    p = Path(name)
    if p.is_absolute() and p.is_file():
        return p
    for candidate in (HERE / name, HERE / "config" / name, REPO / "config" / name):
        if candidate.is_file():
            return candidate
    raise SystemExit(f"[fatal] config not found: {name}")


def validate_config(cfg: object) -> dict:
    if not isinstance(cfg, dict):
        raise SystemExit("[fatal] config must be a JSON object")

    proxy = cfg.get("proxy")
    if proxy is not None:
        if not isinstance(proxy, dict):
            raise SystemExit("[fatal] proxy must be an object")
        server = proxy.get("server", "")
        if not isinstance(server, str):
            raise SystemExit("[fatal] proxy.server must be a string")

    args = cfg.get("browser_args") or []
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        raise SystemExit("[fatal] browser_args must be a list of strings")

    fc = cfg.get("fail_closed", True)
    if not isinstance(fc, bool):
        raise SystemExit("[fatal] fail_closed must be true or false")
    cfg["fail_closed"] = fc

    ip = cfg.get("expected_ip") or ""
    if not isinstance(ip, str):
        raise SystemExit("[fatal] expected_ip must be a string")
    cfg["expected_ip"] = ip
    return cfg


def load_config(name: str) -> dict:
    path = find_config(name)
    try:
        with path.open(encoding="utf-8") as fh:
            cfg = json.load(fh)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"[fatal] invalid JSON in {path}: {exc}")
    print(f"[ok] config = {path}")
    return validate_config(cfg)


def proxy_from_config(cfg: dict) -> dict | None:
    raw = cfg.get("proxy") or {}
    server = (raw.get("server") or "").strip()
    if not server:
        return None
    proxy: dict = {"server": server}
    if raw.get("username"):
        proxy["username"] = raw["username"]
    if raw.get("password"):
        proxy["password"] = raw["password"]
    # Patchright/Playwright otherwise passes --proxy-bypass-list=<-loopback>,
    # which sends localhost *through* the tunnel to the VPS. Keep loopback local.
    bypass = raw.get("bypass")
    proxy["bypass"] = bypass if isinstance(bypass, str) and bypass else "localhost,127.0.0.1,::1"
    return proxy


def proxy_port(proxy: dict) -> tuple[str, int]:
    parsed = urlparse(proxy["server"] if "://" in proxy["server"] else f"http://{proxy['server']}")
    host = parsed.hostname or "127.0.0.1"
    try:
        port = parsed.port
    except ValueError as exc:
        raise SystemExit(f"[fatal] bad proxy port in {proxy['server']}: {exc}")
    if port is None:
        port = 443 if parsed.scheme == "https" else 80
    return host, port


def user_data_dir(cfg: dict, profile: str) -> Path:
    base = cfg.get("user_data_dir")
    root = Path(base) if base else REPO / "profiles"
    if not root.is_absolute():
        root = (HERE / root).resolve()
    root = root.resolve()
    target = (root / profile).resolve()
    if target != root and not target.is_relative_to(root):
        raise SystemExit(f"[fatal] profile escapes the profiles directory: {profile}")
    if target == root:
        raise SystemExit("[fatal] --profile must name a subdirectory")
    return target


def check_browser_args(cfg: dict) -> None:
    bad = [a for a in cfg.get("browser_args") or [] if a.split("=", 1)[0] in BANNED_PROXY_ARGS]
    if bad and cfg.get("fail_closed", True):
        raise SystemExit(f"[fatal] browser_args would override the fixed proxy: {bad}")


def require_proxy_reachable(proxy: dict | None) -> None:
    if not proxy:
        print("[fatal] fail_closed=true but no proxy is configured. Aborting (no direct fallback).")
        sys.exit(2)
    host, port = proxy_port(proxy)
    try:
        with socket.create_connection((host, port), timeout=5):
            pass
    except OSError as exc:
        print(f"[fatal] proxy {proxy['server']} is unreachable: {exc}")
        print("[fatal] aborted: no direct fallback will be used.")
        sys.exit(2)


def fetch_egress_ip(server: str, timeout: int = 15) -> str | None:
    """Ask an IP echo service *through the proxy*; None means undetermined."""
    saved = {k: os.environ.pop(k) for k in ("NO_PROXY", "no_proxy") if k in os.environ}
    try:
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": server, "https": server})
        )
        for url in ("https://ipwho.is/", "https://api.ipify.org?format=json"):
            try:
                with opener.open(url, timeout=timeout) as resp:
                    data = json.loads(resp.read().decode("utf-8", "replace"))
                if isinstance(data, dict) and data.get("ip"):
                    return str(data["ip"])
            except Exception:
                continue
    finally:
        os.environ.update(saved)
    return None


def check_expected_ip(cfg: dict, proxy: dict | None) -> None:
    expected = (cfg.get("expected_ip") or "").strip()
    if not cfg.get("fail_closed", True):
        return
    if not expected:
        print("[fatal] fail_closed=true but expected_ip is empty.")
        print("[fatal] set expected_ip to your VPS address, or set fail_closed=false consciously.")
        sys.exit(2)
    if not proxy:
        sys.exit(2)
    actual = fetch_egress_ip(proxy["server"])
    if not actual:
        print("[fatal] cannot determine the egress IP through the proxy. Aborting.")
        sys.exit(2)
    if actual != expected:
        print(f"[fatal] egress IP is {actual}, expected {expected}. Aborting.")
        sys.exit(2)
    print(f"[ok] egress IP = {actual}")


def build_kwargs(cfg: dict, profile: str, headless_override: bool | None) -> dict:
    kwargs: dict = {
        "user_data_dir": str(user_data_dir(cfg, profile)),
        # Real installed Chrome: same binary and code paths as a normal user.
        "channel": cfg.get("channel") or "chrome",
        "headless": cfg.get("headless", False) if headless_override is None else headless_override,
        "no_viewport": bool(cfg.get("no_viewport", True)),
        "slow_mo": cfg.get("slow_mo", 0),
        "args": list(cfg.get("browser_args") or []),
        # Patchright adds --no-sandbox unless told otherwise; keep the sandbox on.
        "chromium_sandbox": bool(cfg.get("chromium_sandbox", True)),
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
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config.local.json")
    ap.add_argument("--profile", default="default")
    ap.add_argument("--headless", action="store_true")
    ap.add_argument("--url", default=None)
    ap.add_argument("--expected-ip", default=None, help="overrides config expected_ip")
    args = ap.parse_args()

    cfg = load_config(args.config)
    if args.expected_ip:
        cfg["expected_ip"] = args.expected_ip
    check_browser_args(cfg)
    kwargs = build_kwargs(cfg, args.profile, True if args.headless else None)
    if cfg.get("fail_closed", True):
        require_proxy_reachable(kwargs.get("proxy"))
        check_expected_ip(cfg, kwargs.get("proxy"))
    start_url = args.url or cfg.get("start_url") or "about:blank"

    with sync_playwright() as p:
        context = p.chromium.launch_persistent_context(**kwargs)
        page = context.pages[0] if context.pages else context.new_page()

        proxy_desc = (kwargs.get("proxy") or {}).get("server", "direct")
        print(f"[ok] launched  profile={args.profile}")
        print(f"     user_data_dir = {kwargs['user_data_dir']}")
        print(f"     channel       = {kwargs['channel']}")
        print(f"     headless      = {kwargs['headless']}")
        print(f"     sandbox       = {kwargs['chromium_sandbox']}")
        print(f"     proxy         = {proxy_desc}")

        try:
            page.goto(start_url, wait_until="domcontentloaded", timeout=60000)
        except Exception as exc:  # noqa: BLE001
            # Normal on a slow path: bot challenges can take 30-90s. Never close
            # the window on the user's behalf.
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
            print("[info] interrupted; closing.")
        except Exception as exc:  # noqa: BLE001
            if "closed" not in str(exc).lower():
                print(f"[warn] wait loop ended ({type(exc).__name__}); keeping the window open")
                try:
                    page.wait_for_timeout(24 * 60 * 60 * 1000)
                except Exception:
                    pass
        # Intentionally no context.close() here: closing the window is what ends
        # this process, and an explicit close would defeat "leave it open".


if __name__ == "__main__":
    main()
