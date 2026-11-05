# browser

Patchright launcher + diagnostics. Python 3.11+.

```bash
python -m venv .venv
.venv\Scripts\activate          # Windows
pip install -r requirements.txt

copy config.example.json config.local.json
# edit config.local.json -> proxy.server = http://127.0.0.1:7891

python launch.py --config config.local.json --profile work
```

`config.local.json` is git-ignored — keep real endpoints there.

## Why these settings

| Setting | Reason |
|---|---|
| `channel: "chrome"` | Uses the locally installed Chrome instead of bundled chromium. |
| `proxy.server` (fixed) | A PAC file ending in `; DIRECT` falls back to a direct connection. A fixed server cannot. |
| `fail_closed: true` | TCP-probes the proxy before launch and exits non-zero if it is unreachable. |
| `no_viewport: true` | Lets the window size come from the real window, not a fixed emulated viewport. |
| `timezone_id` / `locale` | CDP-level overrides so the browser is consistent with the exit region. **This does not change the system timezone.** |
| anti-throttling args | Keeps a background window's timers running, so a slow page doesn't stall when it loses focus. |

## Probes

| Script | Question it answers |
|---|---|
| `probes/probe_env.py` | What timezone / locale / UA / `webdriver` does the page actually see? |
| `probes/probe_assets.py` | Is the page failing to load, or just slow? (per-resource timings) |
| `probes/probe_login.py` | Why does "Continue with Google" appear to do nothing? |

All three accept `--config config.local.json`. `probe_env` and `probe_assets` run
headless; `probe_login` runs headed because some identity-provider popups require
a visible window.

> Run probes with their own `--profile`. Sharing a profile with your real session
> while running a probe can land you in a half-authenticated state.
