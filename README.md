# Claude Egress Gateway

> Route **all** Claude traffic (Claude Code + claude.ai) through a self-hosted VPS with a fixed, verifiable egress IP — and **fail closed** when the tunnel is down, never falling back to a direct connection.
>
> 把 Claude Code 与 claude.ai 的**全部**流量经自建 VPS 出口，出口 IP 固定且每次启动可校验；链路不通时**直接失败**，绝不回退直连。

---

## Why / 为什么

**EN** — Using Claude from a network where the direct path is slow, unstable, or geolocated elsewhere causes three recurring problems: the account sees multiple countries, the web app is stuck behind a bot challenge, and a "smart" proxy silently falls back to a direct connection at the worst moment. This project addresses all three with a deliberately boring design: one SSH tunnel, one fixed egress IP, one fail-closed check before anything starts.

**中文** — 在直连不稳定、或地理归属不一致的网络里使用 Claude，会反复遇到三个问题：账号被看到从多个国家访问、网页端卡在人机验证、以及"智能"代理在关键时刻静默回退直连。本项目的设计刻意做得"笨"：一条 SSH 隧道、一个固定出口 IP、启动前一次 fail-closed 校验。

---

## Architecture / 架构

```
┌────────────────────────── local machine ─────────────────────────┐
│  Claude Code (CLI)                    Chrome (Patchright)         │
│        │                                     │                   │
│        │ HTTPS_PROXY=http://127.0.0.1:7891   │ fixed proxy.server│
│        └──────────────┬──────────────────────┘                   │
│                       ▼                                          │
│            127.0.0.1:7891  ← ssh -L local forward                │
│                       │                                          │
│  other traffic → TUN client ─┐   (bypassed by a /32 route)       │
└──────────────────────────────┼───────────────────────────────────┘
                               │ Internet
                               ▼
┌──────────────── VPS (region with a good egress) ─────────────────┐
│  public IPv4: YOUR_VPS_IP                                        │
│  sshd :22 ── port forward → sing-box mixed inbound 127.0.0.1:7890 │
│  sing-box outbound: direct                                       │
│  kernel: tcp_congestion_control=bbr, default_qdisc=fq            │
└──────────────────────────┬───────────────────────────────────────┘
                           ▼
              api.anthropic.com / claude.ai
              (egress IP = YOUR_VPS_IP)
```

**Core idea / 核心思想** — Do not expose a proxy port on the VPS at all. Borrow the SSH tunnel instead: only port 22 is needed, no proxy protocol client is installed locally, and the attack surface stays minimal.

不在 VPS 上开放任何代理端口，而是借用 SSH 隧道：只需要 22 端口，本机不需要装任何代理协议客户端，暴露面最小。

---

## Features / 特性

| | |
|---|---|
| **Fail-closed** | Preflight checks the local port, the egress IP, and API reachability. Any failure aborts — no silent direct fallback. <br> 启动前校验本地端口、出口 IP、API 可达性；任一失败即中止，**不会**静默回退直连。 |
| **Fixed exit** | A single Elastic IP, verified on every launch. <br> 固定 Elastic IP，每次启动都核对。 |
| **Fast on lossy paths** | BBR + fq on the VPS. Measured 7–15× throughput improvement over cubic. <br> VPS 开 BBR + fq，实测吞吐提升 7–15 倍。 |
| **No PAC** | PAC returns `PROXY x; DIRECT`, which falls back to direct. A fixed `proxy.server` fails instead. <br> PAC 会 `PROXY; DIRECT` 回退直连；固定代理直接失败。 |
| **Real browser** | Patchright + the locally installed Chrome, persistent profile, real GPU, no JS hooks. <br> Patchright + 本机真实 Chrome，持久化 profile，不注入 JS。 |
| **Self-diagnosing** | `probe_*.py` scripts for page state, resource loading, login flow, and environment. <br> 四个诊断脚本，分别定位页面、资源、登录、环境问题。 |

---

## Quick start / 快速开始

### 0. Prerequisites / 前置

- A Linux VPS with a public IPv4 (this project uses an Elastic IP).
- SSH key access to it.
- Windows 10/11 with OpenSSH client (or adapt the tunnel command to Linux/macOS).
- Python 3.11+ (only for the browser part).

### 1. VPS setup / VPS 配置

See [`vps/setup.md`](vps/setup.md). Short version / 简版：

```bash
# sing-box: mixed inbound on 127.0.0.1:7890, direct outbound
sudo cp vps/sing-box.example.json /etc/sing-box/config.json
sudo systemctl enable --now sing-box

# BBR: this is not optional, see docs/benchmarks.md
sudo modprobe tcp_bbr
echo 'net.ipv4.tcp_congestion_control = bbr' | sudo tee /etc/sysctl.d/99-bbr.conf
echo 'net.core.default_qdisc = fq'          | sudo tee -a /etc/sysctl.d/99-bbr.conf
echo 'tcp_bbr'                              | sudo tee /etc/modules-load.d/tcp_bbr.conf
sudo sysctl --system
```

Security group: allow **22 only**. Nothing else needs to be open.

安全组只放行 **22**，其余不需要。

### 2. SSH alias / SSH 别名

`~/.ssh/config`:

```
Host claude-vps
    HostName YOUR_VPS_IP
    User ubuntu
    IdentityFile C:/Users/<you>/.ssh/your-key.pem
    IdentitiesOnly yes
    ServerAliveInterval 15
    ServerAliveCountMax 4
```

### 3. Claude Code

```powershell
powershell -ExecutionPolicy Bypass -File scripts\start-claude-egress.ps1 `
    -SshHost claude-vps -ExpectedIp YOUR_VPS_IP -Claude
```

It verifies the tunnel, the egress IP, and `api.anthropic.com`, then sets `HTTPS_PROXY` and starts `claude`.

校验隧道 → 出口 IP → API 可达，然后设置 `HTTPS_PROXY` 并启动 `claude`。

### 4. Web (optional) / 网页端（可选）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\start-claude-egress.ps1 `
    -SshHost claude-vps -ExpectedIp YOUR_VPS_IP -Web -BrowserDir C:\path\to\browser
```

Copy `browser/config.example.json` → `browser/config.local.json`, set `proxy.server`, then run `browser/launch.py --config config.local`.

复制 `browser/config.example.json` 为 `config.local.json`，填好代理，再运行 `launch.py --config config.local`。

> **Note on the first page load / 首次加载** — claude.ai serves a Cloudflare challenge on datacenter IPs. Expect 30–90 s before the login form appears. It is not stuck; do not close the window.
> 机房 IP 上 claude.ai 会出 Cloudflare 验证页，通常 30–90 秒后才出现登录框，不是卡死，别关窗口。

---

## Project layout / 目录结构

```
.
├── scripts/
│   ├── start-claude-egress.ps1   # orchestration + fail-closed preflight
│   ├── watch-tunnel.ps1          # keep the tunnel alive
│   └── claude-menu.bat           # double-click menu
├── browser/
│   ├── launch.py                 # persistent Chrome launcher
│   ├── config.example.json
│   ├── requirements.txt
│   └── probes/                   # env / resource-timing / login diagnostics
├── vps/
│   ├── setup.md
│   ├── sing-box.example.json
│   └── sysctl-bbr.conf
└── docs/
    ├── architecture.md           # design and chain (中文)
    ├── troubleshooting.md        # symptom → cause → fix (中文)
    └── benchmarks.md             # measured numbers (中文)
```

---

## Measured results / 实测数据

| Scenario / 场景 | Before / 修复前 | After / 修复后 |
|---|---|---|
| 1 MB single stream, through tunnel | 14 KB/s (60 s timeout) | 217 KB/s (4.6 s) |
| 4 concurrent × 2 MB | 87 KB/s aggregate | 237 KB/s aggregate |
| TLS handshake through tunnel | 4–19 s | 0.8–1.9 s |
| claude.ai assets | many `ERR_ABORTED` | 25/25 HTTP 200 |

Numbers depend on the path between you and the region. See [`docs/benchmarks.md`](docs/benchmarks.md).

数据取决于你与机房之间的链路，详见 [`docs/benchmarks.md`](docs/benchmarks.md)。

---

## Documentation / 文档

| Doc | Content / 内容 |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Design, per-hop data flow, trade-offs, fail-closed gates. <br> 架构、逐跳数据流、取舍、四道闸。 |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | 12 real failure cases: symptom → root cause → verification → fix. <br> 12 个真实故障案例。 |
| [`docs/benchmarks.md`](docs/benchmarks.md) | cubic vs BBR measurements and the reproduction commands. <br> cubic/BBR 实测与复现命令。 |
| [`vps/setup.md`](vps/setup.md) | VPS build, hardening, Elastic IP change checklist. <br> VPS 搭建、加固、换 IP 清单。 |

All Chinese docs assume the reader already has a working SSH key and a VPS. / 中文文档默认你已有可用的 SSH 密钥与 VPS。

---

## Security notes / 安全说明

- **No credentials are committed.** The sing-box example has an empty password; `.gitignore` excludes `*.pem`, `profiles/`, and local config.
- **The VPS IP is a placeholder.** Replace `YOUR_VPS_IP` locally; do not commit it if you intend to keep the host private.
- **This is not a guarantee against platform risk controls.** It is a consistency and reliability tool. Datacenter IPs are still datacenter IPs.
- **WebRTC** may still reveal another exit if you run a TUN-based client for other traffic — see the limitations section in `docs/architecture.md`.

- **不含任何凭据**，示例配置里没有密码，`.gitignore` 排除了密钥与本地配置。
- **VPS IP 是占位符**，真实值不要提交。
- **本项目不承诺绕过任何风控**，它解决的是"出口一致性与可靠性"。
- 若本机同时跑 TUN 类客户端，WebRTC 仍可能暴露另一个出口，详见 `docs/architecture.md` 的限制章节。

---

## License

MIT — see [LICENSE](LICENSE).
