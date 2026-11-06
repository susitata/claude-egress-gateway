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
import ipaddress
import json
import os
import socket
import sys
import time
import urllib.request
from pathlib import Path
from urllib.parse import quote, urlparse

from patchright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
REPO = HERE.parent

# Playwright appends <-loopback> to the bypass list unless this variable is set.
# That token *subtracts* Chromium's implicit loopback rules, sending localhost
# through the tunnel to the VPS. Set it unconditionally: setdefault would keep a
# pre-existing empty value (which the driver treats as false) in place.
os.environ["PLAYWRIGHT_DISABLE_FORCED_CHROMIUM_PROXIED_LOOPBACK"] = "1"

# Chrome switches that would override the fixed proxy or reintroduce a fallback.
BANNED_PROXY_ARGS = {
    "--no-proxy-server",
    "--proxy-server",
    "--proxy-pac-url",
    "--proxy-bypass-list",
    "--proxy-auto-detect",
}

# Switches that weaken the launcher's guarantees no matter how fail_closed is set.
BANNED_SECURITY_ARGS = {
    "--no-sandbox",
    "--disable-setuid-sandbox",
    "--disable-web-security",
    "--remote-debugging-port",
    "--remote-debugging-address",
    "--remote-debugging-pipe",
    "--host-resolver-rules",
    "--user-data-dir",
}

# Chromium's implicit loopback bypass, restored explicitly because an appended
# <-loopback> would otherwise cancel all of it.
LOOPBACK_BYPASS = (
    "localhost",
    "*.localhost",
    "localhost.localdomain",
    "ip6-localhost",
    "ip6-loopback",
    "127.0.0.1",
    "127.0.0.0/8",
    "::1",
    "[::1]",
)

LOOPBACK_HOSTS = {
    "localhost",
    "localhost.localdomain",
    "ip6-localhost",
    "ip6-loopback",
}
LOOPBACK_NETS = (
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("::1/128"),
)


def is_loopback_bypass(entry: str) -> bool:
    """Whether a --proxy-bypass-list entry can only match loopback targets.

    Bypass syntax is a glob language, not a host list: `*.*`, `**`, `*?*`, and
    partitioned CIDRs such as `0.0.0.0/1,128.0.0.0/1` match every host and make
    the fixed proxy a no-op. Only entries that cannot escape loopback are
    accepted; everything else is a configuration error.
    """
    key = entry.strip().lower().rstrip(".")
    if not key:
        return False
    if key == "*.localhost":
        return True
    if any(ch in key for ch in "*?<>"):
        return False
    if "/" in key:
        try:
            net = ipaddress.ip_network(key, strict=False)
        except ValueError:
            return False
        return any(
            net.version == loop.version and net.subnet_of(loop)
            for loop in LOOPBACK_NETS
        )
    host = key.strip("[]")
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        pass
    return key in LOOPBACK_HOSTS or key.endswith(".localhost")


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
        for key in ("username", "password", "bypass"):
            value = proxy.get(key)
            if value is not None and not isinstance(value, str):
                raise SystemExit(f"[fatal] proxy.{key} must be a string")

    args = cfg.get("browser_args") or []
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        raise SystemExit("[fatal] browser_args must be a list of strings")

    fc = cfg.get("fail_closed", True)
    if not isinstance(fc, bool):
        raise SystemExit("[fatal] fail_closed must be true or false")
    cfg["fail_closed"] = fc

    # A config-level false would add --no-sandbox behind the back of the
    # browser_args denylist, so it is not an accepted setting.
    sandbox = cfg.get("chromium_sandbox", True)
    if sandbox is not True:
        raise SystemExit("[fatal] chromium_sandbox must be true; --no-sandbox is not supported")
    cfg["chromium_sandbox"] = True

    ip = cfg.get("expected_ip") or ""
    if not isinstance(ip, str):
        raise SystemExit("[fatal] expected_ip must be a string")
    cfg["expected_ip"] = ip.strip()
    return cfg


def apply_env_proxy_auth(cfg: dict) -> None:
    """Let the orchestrator pass credentials without writing them to config."""
    user = os.environ.get("CLAUDE_EGRESS_PROXY_USER", "")
    password = os.environ.get("CLAUDE_EGRESS_PROXY_PASSWORD", "")
    if not user and not password:
        return
    if not (user and password):
        raise SystemExit(
            "[fatal] CLAUDE_EGRESS_PROXY_USER and CLAUDE_EGRESS_PROXY_PASSWORD "
            "must be set together"
        )
    proxy = cfg.get("proxy")
    if proxy is None:
        proxy = {}
        cfg["proxy"] = proxy
    if not isinstance(proxy, dict):
        raise SystemExit("[fatal] proxy must be an object")
    proxy["username"] = user
    proxy["password"] = password


def load_config(name: str) -> dict:
    path = find_config(name)
    try:
        with path.open(encoding="utf-8") as fh:
            cfg = json.load(fh)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"[fatal] invalid JSON in {path}: {exc}")
    print(f"[ok] config = {path}")
    cfg = validate_config(cfg)
    apply_env_proxy_auth(cfg)
    return cfg


def switch_name(arg: str) -> str | None:
    """Canonicalize switch spelling the way Chromium does on Windows.

    Chromium accepts `--switch`, `-switch` and `/switch`, ignores case, and
    trims surrounding whitespace. Comparing raw strings lets any of those
    spellings slip a banned switch past the check.
    """
    token = arg.strip()
    if not token or token[0] not in "-/":
        return None
    name = token.split("=", 1)[0].strip().lstrip("-/").lower()
    return f"--{name}" if name else None


def merge_bypass(raw: object) -> str:
    """Keep only loopback bypass entries, drop <-loopback>, add the full set.

    Playwright splits `proxy.bypass` on commas and joins the result with
    semicolons, so this function returns a comma-separated string. Non-loopback
    entries are rejected: any bypass that can match a public host routes that
    host around the fixed proxy, which defeats the launcher's only guarantee.
    """
    if raw is not None and not isinstance(raw, str):
        raise SystemExit("[fatal] proxy.bypass must be a string")
    parts: list[str] = []
    if isinstance(raw, str):
        for chunk in raw.replace(";", ",").split(","):
            chunk = chunk.strip()
            if not chunk:
                continue
            if chunk.lower() == "<-loopback>":
                continue
            if not is_loopback_bypass(chunk):
                raise SystemExit(
                    f"[fatal] proxy.bypass entry '{chunk}' is not loopback-only. "
                    "A non-loopback bypass routes that host around the fixed proxy."
                )
            parts.append(chunk)
    seen = {p.lower() for p in parts}
    for host in LOOPBACK_BYPASS:
        if host.lower() not in seen:
            parts.append(host)
            seen.add(host.lower())
    return ",".join(parts)


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
    proxy["bypass"] = merge_bypass(raw.get("bypass"))
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


def proxy_display(proxy: dict) -> str:
    """Render proxy host:port without any credentials."""
    host, port = proxy_port(proxy)
    if ":" in host:
        host = f"[{host}]"
    return f"http://{host}:{port}"


def proxy_with_auth(server: str, user: str, password: str) -> str:
    """Embed URL-encoded credentials in the proxy URL.

    urllib's ProxyHandler turns the userinfo into a Proxy-Authorization header
    and, for HTTPS, moves it into the CONNECT request. ProxyBasicAuthHandler
    cannot do this: a 407 on CONNECT raises before any 407 handler runs.
    """
    parsed = urlparse(server if "://" in server else f"http://{server}")
    if not parsed.hostname:
        raise SystemExit(f"[fatal] proxy.server has no host: {server}")
    host = parsed.hostname
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    try:
        port = parsed.port
    except ValueError as exc:
        raise SystemExit(f"[fatal] bad proxy port in {server}: {exc}")
    netloc = f"{quote(user, safe='')}:{quote(password, safe='')}@{host}"
    if port is not None:
        netloc += f":{port}"
    return f"{parsed.scheme or 'http'}://{netloc}"


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
    args = cfg.get("browser_args") or []
    names = [switch_name(a) for a in args]
    unsafe = [a for a, name in zip(args, names) if name in BANNED_SECURITY_ARGS]
    if unsafe:
        raise SystemExit(f"[fatal] browser_args weaken the sandbox/isolation: {unsafe}")
    bad = [a for a, name in zip(args, names) if name in BANNED_PROXY_ARGS]
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
        print(f"[fatal] proxy {proxy_display(proxy)} is unreachable: {exc}")
        print("[fatal] aborted: no direct fallback will be used.")
        sys.exit(2)


def fetch_egress_ip(proxy: dict, timeout: int = 15) -> str | None:
    """Ask an IP echo service *through the proxy*; None means undetermined."""
    server = proxy["server"]
    user = proxy.get("username") or ""
    password = proxy.get("password") or ""
    if user:
        if not password:
            raise SystemExit("[fatal] proxy.username is set without proxy.password")
        server = proxy_with_auth(server, user, password)
    # urllib falls back to the Windows registry ProxyOverride table when no
    # no_proxy value is present in the environment, which can silently bypass
    # the proxy for an IP echo host. A non-matching sentinel forces the
    # environment branch without exempting anything.
    saved = {k: os.environ.get(k) for k in ("NO_PROXY", "no_proxy")}
    os.environ["NO_PROXY"] = "invalid.invalid"
    os.environ["no_proxy"] = "invalid.invalid"
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
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    return None


def browser_egress_ip(context, timeout_ms: int = 30000) -> str | None:
    """Measure the egress IP *through the launched Chrome*, not through urllib.

    Chromium resolves proxy configuration as managed policy > extension >
    --proxy-server > system settings. A managed PAC or a proxy extension can
    therefore override the flag; only a request made by Chrome itself shows the
    effective path.
    """
    page = context.new_page()
    try:
        # Cache-bust: the persistent profile may already hold an echo response.
        stamp = time.time_ns()
        for url in (f"https://api.ipify.org?format=json&t={stamp}",
                    f"https://ipwho.is/?t={stamp}"):
            try:
                page.goto(url, wait_until="domcontentloaded", timeout=timeout_ms)
                text = page.locator("body").inner_text(timeout=5000).strip()
                data = json.loads(text)
                if isinstance(data, dict) and data.get("ip"):
                    return str(data["ip"])
            except Exception:
                continue
    finally:
        try:
            page.close()
        except Exception:
            pass
    return None


def verify_browser_egress(context, expected: str) -> None:
    """Abort if Chrome's own observed egress differs from the pinned address."""
    actual = browser_egress_ip(context)
    if not actual:
        print("[fatal] cannot determine Chrome's egress IP through the browser. Aborting.")
        sys.exit(2)
    if actual != expected:
        print(f"[fatal] Chrome egress IP is {actual}, expected {expected}. Aborting.")
        print("[fatal] a managed proxy policy or an extension may override --proxy-server.")
        sys.exit(2)
    print(f"[ok] Chrome egress IP = {actual}")


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
    actual = fetch_egress_ip(proxy)
    if not actual:
        print("[fatal] cannot determine the egress IP through the proxy. Aborting.")
        sys.exit(2)
    if actual != expected:
        print(f"[fatal] egress IP is {actual}, expected {expected}. Aborting.")
        sys.exit(2)
    print(f"[ok] egress IP = {actual}")


def preflight(cfg: dict) -> dict | None:
    """Run every pre-launch gate. Shared by launch.py and the probes."""
    check_browser_args(cfg)
    proxy = proxy_from_config(cfg)
    if cfg.get("fail_closed", True):
        require_proxy_reachable(proxy)
        check_expected_ip(cfg, proxy)
    return proxy


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
    ap.add_argument("--proxy-server", default=None,
                    help="overrides config proxy.server (the orchestrator passes the port it verified)")
    args = ap.parse_args()

    cfg = load_config(args.config)
    if args.expected_ip:
        cfg["expected_ip"] = args.expected_ip.strip()
    if args.proxy_server:
        proxy = cfg.get("proxy")
        if proxy is None:
            proxy = {}
            cfg["proxy"] = proxy
        if not isinstance(proxy, dict):
            raise SystemExit("[fatal] proxy must be an object")
        proxy["server"] = args.proxy_server
    proxy = preflight(cfg)
    kwargs = build_kwargs(cfg, args.profile, True if args.headless else None)
    start_url = args.url or cfg.get("start_url") or "about:blank"

    with sync_playwright() as p:
        context = p.chromium.launch_persistent_context(**kwargs)
        if cfg.get("fail_closed", True):
            # The urllib probe cannot see a policy/extension override; let
            # Chrome itself make the request before the user's page opens.
            verify_browser_egress(context, cfg["expected_ip"])
        page = context.pages[0] if context.pages else context.new_page()

        proxy_desc = proxy_display(proxy) if proxy else "system/default (no fixed proxy)"
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
