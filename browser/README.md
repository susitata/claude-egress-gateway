# browser

Patchright launcher + diagnostics. Python 3.11+.

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1       # Windows PowerShell
pip install -r requirements.txt

Copy-Item config.example.json config.local.json
# edit config.local.json -> proxy.server = http://127.0.0.1:7891
#                         -> expected_ip  = YOUR_VPS_IP

python launch.py --config config.local.json --profile work
```

如果 PowerShell 阻止执行激活脚本，用 `Set-ExecutionPolicy -Scope Process Bypass` 只对当前窗口放行。

`config.local.json` is git-ignored — keep real endpoints there.

## Why these settings

| Setting | Reason |
|---|---|
| `channel: "chrome"` | Uses the locally installed Chrome instead of bundled chromium. |
| `proxy.server` (fixed) | A PAC file ending in `; DIRECT` falls back to a direct connection. A fixed server cannot. |
| `proxy.bypass` | Playwright appends `--proxy-bypass-list=<-loopback>` unless told otherwise, which sends `localhost` *through* the tunnel to the VPS. `launch.py` sets `PLAYWRIGHT_DISABLE_FORCED_CHROMIUM_PROXIED_LOOPBACK=1` unconditionally, drops any explicit `<-loopback>`, accepts only loopback-range entries (hostnames, `*.localhost`, subnets of `127.0.0.0/8` or `::1/128`), and always merges `localhost,*.localhost,localhost.localdomain,ip6-localhost,ip6-loopback,127.0.0.1,127.0.0.0/8,::1,[::1]`. Wildcards/CIDRs that can match a public host (`*.*`, `**`, `0.0.0.0/1,128.0.0.0/1`) are fatal, not silently ignored. The result is comma-separated because Playwright splits on commas. |
| `fail_closed: true` | TCP-probes the proxy **and** verifies the egress IP before launch; after Chrome starts it also lets Chrome itself fetch the echo service and aborts on a mismatch (managed proxy policy and proxy extensions outrank `--proxy-server`). `false` skips all of these checks and also permits proxy-overriding `browser_args`; it does **not** retry direct when the configured proxy fails — if `proxy.server` is empty or overridden, Chrome uses the system proxy or direct, and the launcher logs `system/default`. Not recommended. |
| `expected_ip` | Pinned egress address. Empty value + `fail_closed: true` means "refuse to start" — for `launch.py` and for all three probes. |
| `chromium_sandbox: true` | Required. `launch.py` defaults to `true` and **rejects** an explicit `false`, because that would add `--no-sandbox` behind the `browser_args` denylist. Patchright otherwise adds `--no-sandbox`; a compromised renderer would run as you. `browser_args` containing `--no-sandbox`, `--disable-setuid-sandbox`, `--disable-web-security`, `--remote-debugging-port`, `--remote-debugging-address`, `--remote-debugging-pipe`, `--host-resolver-rules` or `--user-data-dir` is rejected outright. Switch names are normalized (`-x`, `/x`, case, leading whitespace all count as `--x`). |
| `no_viewport: true` | Lets the window size come from the real window, not a fixed emulated viewport. |
| `timezone_id` / `locale` | CDP-level overrides so the browser is consistent with the exit region. **This does not change the system timezone.** |
| anti-throttling args | Keeps a background window's timers running, so a slow page doesn't stall when it loses focus. These are themselves detectable; see `docs/security.md`. |

## Probes

| Script | Question it answers |
|---|---|
| `probes/probe_env.py` | What timezone / locale / UA / `webdriver` does the page actually see? |
| `probes/probe_assets.py` | Is the page failing to load, or just slow? (per-resource timings) |
| `probes/probe_login.py` | Why does "Continue with Google" appear to do nothing? |

All three accept `--config config.local.json`. They run the same fail-closed
preflight as `launch.py` (proxy reachable + egress IP pinned) and, with
`fail_closed: true`, the same post-launch check in which Chrome itself fetches
the echo service; a probe cannot open a browser while the real launcher would
refuse. `probe_env` and
`probe_assets` run headless; `probe_login` uses the config's `headless` value
(the example config is headed) because some identity-provider popups require a
visible window.

> Run probes with their own `--profile`. Sharing a profile with your real session
> while running a probe can land you in a half-authenticated state.
