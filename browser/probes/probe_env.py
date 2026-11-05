"""Print what the browser actually reports for timezone / locale / fingerprints.

Run it with the same config you use for real, so the overrides are in play:

    python probes/probe_env.py --config config.local.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from patchright.sync_api import sync_playwright  # noqa: E402

from launch import build_kwargs, load_config  # noqa: E402

JS = """() => ({
  timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  utcOffsetMinutes: new Date().getTimezoneOffset(),
  language: navigator.language,
  languages: navigator.languages,
  platform: navigator.platform,
  userAgent: navigator.userAgent,
  webdriver: navigator.webdriver,
  screen: [screen.width, screen.height, window.devicePixelRatio],
  hardwareConcurrency: navigator.hardwareConcurrency,
  deviceMemory: navigator.deviceMemory ?? null,
})"""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config.local.json")
    ap.add_argument("--profile", default="probe")
    ap.add_argument("--url", default="https://claude.ai/")
    args = ap.parse_args()

    cfg = load_config(args.config)
    kwargs = build_kwargs(cfg, args.profile, True)  # always headless for a probe
    with sync_playwright() as p:
        context = p.chromium.launch_persistent_context(**kwargs)
        page = context.pages[0] if context.pages else context.new_page()
        try:
            page.goto(args.url, wait_until="domcontentloaded", timeout=60000)
        except Exception as exc:  # noqa: BLE001
            print(f"[warn] goto: {type(exc).__name__}: {exc}")
        print(json.dumps(page.evaluate(JS), indent=2, ensure_ascii=False))
        context.close()


if __name__ == "__main__":
    main()
