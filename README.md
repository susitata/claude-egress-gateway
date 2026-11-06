# Claude Egress Gateway

把 Claude Code 和 claude.ai 的 TCP 流量经一条 SSH 隧道送到你自己的 VPS，让 Anthropic 看到的源 IP 是同一个（仅限经这条代理的 TCP）。默认配置下，隧道不通时启动直接失败，不会悄悄退回直连。

> English summary at the end.

---

## 它解决什么问题

直连不稳定，或者你希望 Claude 的出口 IP 长期固定（账号不要今天从 A 国、明天从 B 国登录），通常会挂一个代理。问题在于多数代理是"尽力而为"的：PAC 末尾带 `DIRECT`、客户端切节点、代理挂了自动直连。出了问题时，你无法从结果判断这次到底走了哪条路。

这个项目只做一件事：一条固定的 SSH 隧道，加启动前后对出口 IP 的实测。默认配置下，任何一项检查不满足就报错退出。

---

## 适用条件

先确认这些条件都成立，再往下看：

- **一台 Linux VPS，有固定的公网 IPv4。** 本项目按 AWS EC2 + Elastic IP 写，其他云厂商同理，只需要一个不会变的地址。
- **愿意自己维护这台机器。** 系统更新、SSH、sing-box 都由你负责；仓库里没有托管服务。
- **客户端是 Windows 10/11。** 脚本用 PowerShell，依赖 `Get-NetTCPConnection`、`Get-CimInstance`。Linux/macOS 可以手工敲隧道命令，但脚本需要自己移植。
- **只需要 TCP。** 浏览器和 CLI 的 HTTP/HTTPS 在这个范围内；UDP（WebRTC、QUIC）和 IPv6 不在。
- **能接受固定成本。** EC2 实例费用另计；公网 IPv4 自 2024-02-01 起约 `$0.005/小时`（约 `$3.65/月`），Elastic IP 未绑定实例时同样计费。

以下情况不适合用它：

- 想要"隐藏身份"或绕过平台风控。机房 IP 的信誉不会因为换了一条隧道而改变；claude.ai 的 Cloudflare 挑战在机房 IP 上通常要 30–90 秒。
- 想要整机全局代理。这里覆盖的是**本次启动的进程**，不是整台机器。
- 不想维护服务器。

---

## 保证与不保证

| 保证 | 不保证 |
|---|---|
| 启动前经代理实测出口 IP，并与 `-ExpectedIp` / `expected_ip` 比对 | 整机所有流量。IDE 插件、其它终端里已开的 `claude`、你自己平时用的浏览器都不在范围内 |
| 监听 `7891` 的进程必须是绝对路径的系统 `ssh.exe`，`-L` 值与期望转发完全一致，且主机别名是最后一个参数 | 上述进程的 HTTP/HTTPS 仍有例外：git-over-SSH、部分 MCP server，以及自带网络栈或显式绕过代理的工具；git HTTPS 远端与 npm/npx/uvx 通常继承 `HTTPS_PROXY` |
| 任一检查失败即中止；CLI 没有直连回退，浏览器不使用 PAC | UDP、ICMP、IPv6。WebRTC 直接发 UDP，HTTP 代理管不到 |
| 浏览器使用单一 `proxy.server`（无 PAC、无候选），loopback 始终绕过代理；Chrome 启动后再由 Chrome 自己复核出口 IP | 企业代理策略/扩展仍可能覆盖 `--proxy-server`；启动后复核会中止，但无法阻止策略本身存在。也不保证绕过平台风控，或让机房 IP 变得"像住宅" |
| VPS 只开放 TCP 22，代理端口不对外监听 | 本机已有权限的攻击者。`7891` 默认无认证 |

这些边界在 [`docs/security.md`](docs/security.md) 里有逐条说明。

浏览器的 `fail_closed: false` 不是一个"失败后自动直连"的开关：它只是跳过代理可达性、出口 IP 检查和启动后的 Chrome 复核，并允许覆盖代理的 `browser_args`。如果 `proxy.server` 指向一个不可达的代理，浏览器仍然启动失败；只有 `proxy.server` 为空或被参数覆盖掉时，Chrome 才会退回系统代理或直连（启动器日志写 `system/default`）。上表描述的是默认值 `true` 下的行为。

---

## 架构

```
本机 (Windows)
  Claude Code ── HTTPS_PROXY=127.0.0.1:7891 ──┐
  Chrome (Patchright) ── proxy.server=... ────┴──> ssh -L 127.0.0.1:7891
                                                        │  (仅 TCP 22)
VPS                                                     v
  sshd :22 ──本地转发──> sing-box mixed 127.0.0.1:7890 ──direct──> api.anthropic.com
  tcp_congestion_control=bbr, default_qdisc=fq
```

VPS 上不开放任何代理端口。本机不需要安装 sing-box 或其它代理协议客户端，SSH 客户端就够了。

---

## 快速开始

### 0. 前置

- Linux VPS + 固定公网 IPv4（本项目用 Elastic IP）。
- 能免密 SSH 登录这台机器。
- Windows 10/11，自带 OpenSSH 客户端。
- 浏览器部分另需：本机已安装 Chrome、Python 3.11+。

### 1. VPS

完整步骤见 [`vps/setup.md`](vps/setup.md)：安装 sing-box、配置 mixed inbound、启用 BBR + fq、加固 sshd。注意其中的命令要在 **VPS 上**执行，且需要先把仓库放到 VPS。

要点：

- sing-box 只监听 `127.0.0.1:7890`。示例配置先用 `action: "resolve"` 解析目标域名，再按解析结果拒绝私网/回环/云元数据地址；仍建议叠加 VPS 防火墙兜底（见 `docs/security.md` 第 7 节）。
- 安全组只放行 `22/tcp`。
- BBR 不是可选项；改完必须重建 SSH 隧道，老连接不会热切换。

### 2. SSH 别名

`~/.ssh/config`：

```
Host claude-vps
    HostName YOUR_VPS_IP
    User ec2-user
    IdentityFile C:/Users/<you>/.ssh/your-key.pem
    IdentitiesOnly yes
    AddressFamily inet
    ServerAliveInterval 15
    ServerAliveCountMax 4
```

首次连接时，先在云控制台核对主机指纹，再接受：

```powershell
ssh -o StrictHostKeyChecking=accept-new claude-vps
```

核对无误后，把 `StrictHostKeyChecking yes` 加进上面的配置。隧道使用 `BatchMode=yes`，不会替你回答任何提示。

### 3. Claude Code

```powershell
powershell -ExecutionPolicy Bypass -File scripts\start-claude-egress.ps1 `
    -SshHost claude-vps -ExpectedIp YOUR_VPS_IP -Claude
```

脚本会依次检查：本地端口、端口属主、经隧道测到的出口 IP、`api.anthropic.com` 可达性。全部通过后设置 `HTTPS_PROXY` 并启动 `claude`。

`-ExpectedIp` 也可以通过环境变量 `CLAUDE_EGRESS_EXPECTED_IP` 提供。两者都没有时会拒绝启动——这是有意为之。

### 4. 浏览器（可选）

浏览器部分依赖 [Patchright](https://github.com/Kaliiiiiiiiii-Vinyzu/patchright)，它不是标准库，需要先建虚拟环境：

```powershell
python -m venv browser\.venv
browser\.venv\Scripts\Activate.ps1
pip install -r browser\requirements.txt

copy browser\config.example.json browser\config.local.json
# 编辑 config.local.json：proxy.server 与 expected_ip
python browser\launch.py --config config.local.json --profile claude
```

细节见 [`browser/README.md`](browser/README.md)。`config.local.json` 已被 `.gitignore` 排除。`fail_closed: true` 且 `expected_ip` 为空时会拒绝启动，同样是故意的；把它设成 `false` 会关闭代理可达性、出口 IP 和启动后 Chrome 复核这三道检查，并允许覆盖代理的启动参数——这是显式的降级，不建议。

也可以用编排脚本一次完成隧道检查与浏览器启动：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\start-claude-egress.ps1 `
    -SshHost claude-vps -ExpectedIp YOUR_VPS_IP -Web -BrowserDir .\browser
```

`-BrowserDir` 相对于你的当前目录解析，请在仓库根目录执行，或直接传绝对路径。编排脚本会把本次实际校验的 `-LocalPort` 通过 `--proxy-server` 传给 `launch.py`，所以浏览器不会用到 `config.local.json` 里另一个端口。

首次打开 claude.ai 时，机房 IP 会触发 Cloudflare 挑战，通常等 30–90 秒才出现登录框。不是卡死，别关窗口。

---

## 实测数据

同一条链路、同一时段，VPS 从默认 `cubic` 切到 `bbr + fq`：

| 场景 | cubic | bbr + fq |
|---|---|---|
| 单流 1 MB | 14 KB/s，60 秒超时 | 217 KB/s，4.6 秒 |
| 4 并发 × 2 MB 聚合 | 87 KB/s | 237 KB/s |
| TLS 握手 | 4–19 秒 | 0.8–1.9 秒 |
| claude.ai 资源 | 大量 `ERR_ABORTED` | 25/25 HTTP 200 |

绝对值取决于你和 VPS 之间的路径。可复现的是变化方向，复测方法见 [`docs/benchmarks.md`](docs/benchmarks.md)。

---

## 已知限制

- **WebRTC 绕过 HTTP 代理。** `--proxy-server` 只代理 TCP；`RTCPeerConnection` 会直接向 STUN 服务器发 UDP，暴露本机真实出口。Chrome 156 上 `--force-webrtc-ip-handling-policy` 实测无效，只能靠网络层（TUN 或防火墙阻断 UDP）解决。
- **覆盖范围是进程级。** 只有本次启动的 `claude` 或 Chrome 实例被覆盖。
- **`7891` 默认没有认证。** 本机任何进程都能借用你的出口，行为会归因到你。可用 sing-box `users` 加 `-ProxyUser`/`-ProxyPassword` 启用认证。
- **单点。** VPS 挂了就没有出口。
- **TCP over TCP。** 单条 SSH 隧道有队头阻塞和并发上限，不适合高并发或 UDP 场景。

---

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | 逐跳数据流、关键取舍、五道检查 |
| [`docs/security.md`](docs/security.md) | 覆盖边界、加固清单、自查命令 |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | 12 个真实故障：现象 → 根因 → 验证 → 修复 |
| [`docs/benchmarks.md`](docs/benchmarks.md) | cubic / BBR 实测与复测命令 |
| [`docs/lessons.md`](docs/lessons.md) | BBR、Cloudflare、IP 信誉、WebRTC、审计方法 |
| [`browser/README.md`](browser/README.md) | 浏览器依赖、配置字段、三个探测脚本 |
| [`vps/setup.md`](vps/setup.md) | VPS 搭建、加固、换 Elastic IP 清单 |

`scripts/start-claude-egress.ps1` 另有两个明确的逃生口：`-AllowUnknownOwner`（无法识别端口属主时继续）和 `-AllowUnpinned`（`-CheckOnly` 时不比对 IP）。默认都关闭。

---

## License

MIT，见 [LICENSE](LICENSE)。

---

## English

This is a small, fail-closed egress gateway for Claude Code and claude.ai.

A single SSH local forward (`127.0.0.1:7891` → VPS `127.0.0.1:7890` → sing-box `direct`) sends the TCP traffic of the processes this launcher starts through one fixed public IPv4. Before anything is launched, the launcher measures the egress IP through that proxy and compares it with the pinned value; with the default `fail_closed: true`, any failure aborts instead of falling back to a direct connection. The browser half uses a fixed `proxy.server` (never a PAC file), verifies the same egress IP before opening Chrome, and then lets Chrome itself fetch the echo service once more, because a managed policy or proxy extension can outrank `--proxy-server`.

Requirements: a Linux VPS with a fixed public IPv4 (written for AWS EC2 + Elastic IP), SSH key access, Windows 10/11 with PowerShell for the scripts, and Chrome + Python 3.11+ with `pip install -r browser/requirements.txt` for the browser part. Public IPv4 addresses cost about `$0.005/hour` on AWS even when the Elastic IP is unattached.

It covers the launched processes only, over TCP. It does not proxy UDP (WebRTC bypasses HTTP proxies), IPv6, or the whole machine, and it does not claim to defeat platform risk controls or make a datacenter IP look residential.

See [`docs/architecture.md`](docs/architecture.md), [`docs/security.md`](docs/security.md), and [`docs/troubleshooting.md`](docs/troubleshooting.md) for details (Chinese).
