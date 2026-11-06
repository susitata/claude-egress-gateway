# Claude 专用出口网关：架构与设计

本文描述这条链路的组成、逐跳数据流、关键取舍，以及 fail-closed 是如何落到每一道检查上的。参数以 `scripts/` 与 `browser/launch.py` 中的实际实现为准。

## 1. 目标与约束

### 1.1 目标

1. **出口固定**：Claude Code（CLI）与 claude.ai（浏览器）经代理的 TCP 流量，最终都从同一台 VPS 的同一个公网 IPv4 出去。UDP/ICMP 与 IPv6 不在覆盖范围内。
2. **可校验**：每次启动都实际测量出口 IP，并与期望值比对，而不是"相信配置是对的"。
3. **fail-closed（默认）**：链路任何一环不成立，启动直接失败。CLI 不存在"代理不通就直连"的回退路径；浏览器侧只有显式设置 `fail_closed: false` 才会关闭代理检查。
4. **暴露面最小**：VPS 上不开放任何代理端口，本机不安装额外的代理协议客户端。

### 1.2 硬约束

| 约束 | 取值 | 影响 |
|---|---|---|
| 本地代理入口 | `127.0.0.1:7891` | 只监听回环，局域网不可达 |
| VPS 入口 | 仅 TCP `22` | 安全组不放行任何代理端口 |
| VPS 代理 | sing-box（示例按 `1.14.x` 语法编写，规则使用 `action: "reject"` / `"resolve"`），`mixed` inbound 监听 `127.0.0.1:7890` | 只被 sshd 的本地转发访问 |
| VPS 出口 | `direct` outbound | 不做二次代理、不做分流 |
| 客户端 | Windows + OpenSSH | 隧道命令按 Windows 写法给出，Linux/macOS 可平移 |
| 浏览器 | Patchright + 本机 Chrome | 需要本地已安装 Chrome |

### 1.3 非目标

- 不承诺绕过平台风控。本项目解决的是"出口一致性与可靠性"，不是"隐身"。
- 不做多出口、负载均衡或自动选路。
- 不代理系统全局流量；只有显式指向 `7891` 的进程才走这条链路。

## 2. 拓扑

```
+------------------------------- 本机 (Windows) -------------------------------+
|                                                                              |
|   Claude Code (CLI)                        Chrome (Patchright)                |
|   HTTPS_PROXY=http://127.0.0.1:7891        proxy.server=http://127.0.0.1:7891 |
|          |                                          |                        |
|          +------------------+----------------------- +                       |
|                             v                                                |
|                 127.0.0.1:7891  (ssh -L 的本地转发端口)                       |
|                             |                                                |
|   ssh.exe -N -L 127.0.0.1:7891:127.0.0.1:7890 claude-vps                     |
|                             |                                                |
|   其他流量 --> TUN 客户端 --+  (VPS IP 的 /32 路由指向 LAN 网关，绕开 TUN)     |
+-----------------------------|------------------------------------------------+
                              | 公网，仅 TCP 22
                              v
+----------------------------------- VPS --------------------------------------+
|   sshd :22                                                                   |
|      |  端口转发：127.0.0.1:7890 (VPS 侧回环)                                 |
|      v                                                                       |
|   sing-box (1.14.x syntax)  mixed inbound 127.0.0.1:7890                       |
|                     outbound: direct                                         |
|   kernel: tcp_congestion_control=bbr, default_qdisc=fq                       |
+-----------------------------|------------------------------------------------+
                              v
                api.anthropic.com / claude.ai
                出口源 IP = YOUR_VPS_IP
```
要点：

- 本机到 VPS 只有一条 SSH 连接，隧道内承载 TCP 流；`7891` 与 `7890` 都只在各自机器的回环地址上。
- VPS 侧没有对公网监听的代理端口，扫描 `YOUR_VPS_IP` 只会看到 `22`。
- 若本机同时运行 TUN 类客户端（如 FlClash），默认它会把"到 VPS 的 SSH 连接"也劫持进隧道，导致 SSH 在新公网 IP 上握手超时或出口漂移；需要用第 8 节的 `/32` 路由让 SSH 直出。

## 3. 组件职责

| 组件 | 位置 | 职责 | 失败时 |
|---|---|---|---|
| `claude` | 本机 | Claude Code CLI，读取 `HTTPS_PROXY` | 代理不可用则请求失败 |
| `browser/launch.py` | 本机 | 用 Patchright 启动真实 Chrome，使用编排脚本传入的 `proxy.server`，持久化 profile | 代理探测失败 `sys.exit(2)` |
| `scripts/start-claude-egress.ps1` | 本机 | 编排：起隧道、校验端口/出口 IP/API、注入环境变量、拉起 CLI 或浏览器 | 任一校验不过即 `throw`，不降级 |
| `scripts/watch-tunnel.ps1` | 本机 | 每 20 秒检查端口与属主（绝对路径 `ssh.exe`、完整 `-L` 值、末尾主机别名），掉了就重建隧道 | 重建失败则下一轮重试；非期望的监听者只告警、不触碰 |
| `ssh.exe` | 本机 | `-N -L` 本地转发，把 `127.0.0.1:7891` 映射到 VPS 的 `127.0.0.1:7890` | `ExitOnForwardFailure=yes` 让它直接退出而不是半可用 |
| `sshd` | VPS | 接受 SSH、执行本地转发 | 隧道断开，端口消失 |
| `sing-box` | VPS | `mixed` inbound 接收 HTTP/SOCKS，`direct` 出站 | 端口不监听，转发连接被拒 |
| 内核 BBR + fq | VPS | 高丢包链路上的拥塞控制与队列 | 退回 cubic，吞吐骤降 |
| 安全组 | 云厂商 | 只放行 22 | 多开端口会扩大攻击面 |

## 4. 逐跳数据流

### 4.1 CLI 路径

以 `scripts/start-claude-egress.ps1 -SshHost claude-vps -ExpectedIp YOUR_VPS_IP -Claude` 为例。

1. **检查本地端口**。`Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 7891 -State Listen` 判断 `7891` 是否只在本机回环监听。
2. **必要时起隧道**。未监听则后台启动：
   ```powershell
   ssh -N -L 127.0.0.1:7891:127.0.0.1:7890 `
       -o BatchMode=yes -o ExitOnForwardFailure=yes `
       -o ConnectTimeout=10 `
       -o ServerAliveInterval=15 -o ServerAliveCountMax=4 `
       -o TCPKeepAlive=yes claude-vps
   ```
   随后以 500 ms 间隔复查 20 次（最长 10 秒）。仍不监听则中止。
3. **校验出口 IP**。经代理请求 `https://ipwho.is/`，失败再退回 `https://api.ipify.org`，两次都设 15 秒超时。取到的 IP 必须等于 `-ExpectedIp`，否则中止。`-ExpectedIp` 未通过参数给出时读取 `$env:CLAUDE_EGRESS_EXPECTED_IP`；两者都没有时最终拒绝启动（`-CheckOnly` 需显式 `-AllowUnpinned` 才放行）。四个 `curl` 调用都写成 `--noproxy=` 和 `--max-time=N`：Windows PowerShell 5.1 会丢掉空字符串参数，`--noproxy ""` 实际会变成 `--noproxy --max-time 15`，超时被吞掉、`15` 被当成 URL；等号形式没有这个问题，同时仍能阻止环境里的 `NO_PROXY` 让 curl 跳过 `-x` 去测直连路径。
4. **校验 API 可达**。经代理请求 `https://api.anthropic.com/v1/messages`，20 秒超时。判据是"拿到任意 HTTP 状态码"——401/403/404 都算通，只有 `000` 或 curl 非零退出才中止。`-Web` 模式额外检查 `https://claude.ai/`（25 秒超时）。
5. **注入环境变量**。设置 `HTTPS_PROXY`/`HTTP_PROXY` 为 `http://127.0.0.1:7891`，`NO_PROXY` 为回环地址，然后前台启动 `claude`。
6. **实际转发**。Claude Code 发出 `CONNECT api.anthropic.com:443` 到 `127.0.0.1:7891` → ssh 客户端经加密连接送到 VPS → sshd 在本机回环连 `127.0.0.1:7890` → sing-box `mixed` inbound 接受 → `direct` outbound 发起真正的 TLS 连接。回包沿原路返回。

整条链上，Anthropic 看到的源地址只有 `YOUR_VPS_IP`；本机 ISP 分配的公网 IP 不参与。

### 4.2 浏览器路径

1. 同一个编排脚本先跑完上述第 1–4 步（`-Web` 时含 claude.ai 检查）。
2. 调用 `launch.py --config config.local.json --profile claude --expected-ip <IP> --proxy-server http://127.0.0.1:<LocalPort>`。
3. `launch.py` 读取配置，组装 `launch_persistent_context` 参数：`channel="chrome"`、`user_data_dir=<repo>/profiles/claude`（默认）、`proxy.server` 由 `--proxy-server` 覆盖（示例配置为 `http://127.0.0.1:7891`）。
4. **启动前探测**。解析 `proxy.server` 的 host/port，做一次 5 秒超时的 `socket.create_connection`；再**经该代理**请求 IP 回显服务，比对 `expected_ip`。任一失败打印 `[fatal]` 并 `sys.exit(2)`。这两步都发生在 Chrome 进程创建之前，配置错误不会拖到浏览器起来之后才暴露。
5. **启动后用 Chrome 再测一次**。企业策略（managed `ProxySettings`）或代理扩展的优先级高于 `--proxy-server`，仅用 urllib 预检看不到这种覆盖。`launch.py` 在 `launch_persistent_context` 之后新建一个页面，让 **Chrome 自己**访问 IP 回显服务；结果不等于 `expected_ip` 就关闭并 `sys.exit(2)`。这一步同时能兜住 `proxy.bypass` 配置错误。
6. **启动浏览器**。持久化上下文复用已有 profile 的 cookie 与登录态；扩展默认被 Playwright 的 `--disable-extensions` 禁用，需要额外处理默认参数才会加载。`locale` 与 `timezone_id` 由配置覆盖。
7. **导航**。默认打开 `https://claude.ai/`，`domcontentloaded` 超时 60 秒。超时只告警、不关窗——机房 IP 上的 Cloudflare 挑战通常要 30–90 秒。

浏览器不使用 PAC，也没有系统代理作为后备。代理路径上的 HTTPS 请求只会连到 `proxy.server`；该端口不通时页面直接报错。回环直连、DoH 与 WebRTC UDP 是例外，见 [`security.md`](security.md) 第 3、4、5 节。

## 5. 关键取舍

### 5.1 SSH 隧道，而不是在 VPS 上开公开代理端口

- **选择**：只保留 22 端口，用 `ssh -L` 借用隧道。
- **理由**：VPS 不需要对公网暴露任何代理协议端口，扫描面只有一个 sshd；鉴权复用 SSH 密钥；流量在传输段被加密；本机不需要安装 sing-box/clash 之类的客户端。
- **代价**：TCP over TCP 的队头阻塞、单条 SSH 连接的并发上限，以及 `-L` 不承载 UDP。需要大量并发或 UDP 时，这套结构不是最优解，但本项目的目标流量（HTTPS API 与网页）以 TCP 为主。

### 5.2 专用 7891，而不是复用机器上已有的代理端口

- **选择**：单独一条隧道、单独一个本地端口。
- **理由**：让 Claude 流量与其他流量在**进程级**隔离。校验出口 IP 时，测的就是 Claude 实际会走的那条路，不会被"另一个客户端的规则"污染；其他代理改配置、挂掉或切节点，都不会静默改变 Claude 的出口。
- **代价**：多一个隧道进程、多一个端口要维护；机器上同时存在多套代理配置时，需要明确谁指向谁。

### 5.3 真实 Chrome + 持久化 profile，而不是捆绑 chromium + 全新上下文

- **选择**：`channel="chrome"`，使用本机安装的 Chrome 与固定 `user_data_dir`。
- **理由**：走的是普通用户同样的二进制与代码路径（GPU、媒体栈、扩展、企业策略），持久化 profile 也保留了真实登录态，避免每次从零开始重建会话。
- **代价**：本地环境差异成为变量——Chrome 版本、扩展、策略、残留代理设置都会影响结果，复现性不如捆绑 chromium。

### 5.4 用 CDP 覆盖 `timezone_id` / `locale`，而不是跟随系统

- **选择**：在启动参数里显式指定，使其与出口地区自洽。
- **理由**：时区、语言、出口 IP 三者不一致本身就是异常信号；显式覆盖至少保证浏览器层自洽。
- **边界**：这属于 CDP/浏览器层覆盖，会改变页面可见的 `Intl`/`Date`、`navigator.language(s)` 和 `Accept-Language`，**不改变操作系统时区**，也不影响浏览器之外的任何进程。

### 5.5 隧道保活 + 20 秒看护进程

- **选择**：`ServerAliveInterval=15`、`ServerAliveCountMax=4`、`TCPKeepAlive=yes`，外加 `watch-tunnel.ps1` 每 20 秒轮询端口。
- **理由**：sshd 会静默掉线——笔记本睡眠、NAT 表项超时、切换网络，都会让隧道消失而本地无明显报错。fail-closed 会把"掉线"翻译成"启动被拒"，看护进程把这个失败模式收敛成一次自动重建，而不是让用户去猜。
- **代价**：多一个常驻进程；它只负责端口层面的重建，不修复路由或 DNS 层面的问题。

### 5.6 BBR 必须开，而且改完要重建隧道

- **选择**：VPS 内核启用 `bbr` + `fq`。
- **理由**：跨洋高丢包链路上，cubic 的单流实测只有 14 KB/s，开 BBR 后为 217 KB/s，差距是数量级的。
- **关键细节**：拥塞控制算法在连接建立时确定。只改 `sysctl` 不会影响已经存在的 SSH 连接——老连接仍然是 cubic。改完必须断开并重建隧道，新连接才会用上 BBR。

## 6. 失败模式与 fail-closed 设计

### 6.1 五道检查

| # | 检查 | 判据 | 失败动作 |
|---|---|---|---|
| 1 | 本地端口 | 尝试拉起后 `127.0.0.1:7891` 处于 Listen | `throw`，不启动任何东西 |
| 1b | **端口属主** | 监听进程是绝对路径的系统 `ssh.exe`，`-L` 值与期望转发完全一致，且主机别名是最后一个参数 | `throw`；识别不到属主也 `throw`，除非显式 `-AllowUnknownOwner` |
| 2 | 出口 IP | 经代理测得的 IP 等于 `-ExpectedIp`；未钉扎则拒绝启动 | `throw`（`-CheckOnly` + `-AllowUnpinned` 除外） |
| 3 | API 可达 | `api.anthropic.com/v1/messages` 返回任意 HTTP 状态 | `000` 或 curl 失败则 `throw` |
| 4 | 浏览器侧（`fail_closed: true`） | 端口可达 **且** 经代理测得的出口 IP 等于 `expected_ip`；Chrome 启动后再由 Chrome 自己实测一次 | `sys.exit(2)` |

这五道检查的共同点是：默认**没有"继续但降级"的分支**。任何一道不过，进程就结束；两个 `-Allow*` 开关和浏览器的 `fail_closed: false` 是显式、可审计的例外，不是默认行为。

闸 1b 存在的理由：只判断"端口有人监听"会把任何本地代理误当成隧道——例如把另一个客户端的混合端口设成 7891，脚本就会跳过建隧道直接使用它。出口 IP 校验能兜住多数情况，但它无法识破一个会对 IP 回显服务特判的本地代理。

### 6.2 典型失败模式

| 现象 | 根因 | 系统行为 |
|---|---|---|
| 启动即报端口未监听 | VPS 不可达、sshd 拒绝、转发失败 | 闸 1 中止 |
| 出口 IP 与期望不符 | 隧道没起作用、流量走了别的代理 | 闸 2 中止 |
| API 检查返回 `000` | 代理链路断、DNS 失败、TLS 被拦 | 闸 3 中止 |
| 浏览器窗口没出现，退出码 2 | 先看 `[fatal]` 行：代理不可达、`expected_ip` 为空或不匹配都会退出 2；`browser_args`/配置错误通常是退出 1 | 闸 4 中止 |
| 用着用着端口消失 | sshd 静默掉线、睡眠、NAT 超时 | ssh 进程已退出时：最多 20 秒发现 + 10 秒重建等待；TCP 半开但进程还活着时，要先等 `ServerAliveInterval=15 × CountMax=4`（约 60 秒）让 ssh 退出，最坏约 90 秒。期间新启动会被拒 |
| SSH 握手超时且出口 IP 变成家宽 | TUN 客户端劫持了到 VPS 的连接 | 需要 `/32` 路由，见第 8 节 |
| 改完 BBR 仍然很慢 | 老连接仍用 cubic | 重建隧道 |

### 6.3 为什么不用 PAC

PAC 的常见写法是 `return "PROXY 127.0.0.1:7891; DIRECT"`。分号后面的 `DIRECT` 是**回退路径**：代理不可达时，浏览器会直接连接目标站点。这恰好破坏了本项目最重要的性质——你无法从结果判断"这次到底走没走 VPS"。

固定的 `proxy.server` 没有分号、没有候选列表。代理不通就是不通，页面报错，退出码非零。可观测性比"尽量能用"更重要。

## 7. 已知限制

- **WebRTC 绕过 HTTP 代理**。`--proxy-server` 只代理 TCP，`RTCPeerConnection` 会直接向 STUN 服务器发 UDP，暴露本机真实出口。浏览器层的 `--force-webrtc-ip-handling-policy` 在新版 Chrome 上实测无效，只有网络层（TUN / 防火墙阻断 UDP）能解决。给 VPS IP 加 `/32` 路由同样**不能**解决这个问题——它只固定"到 VPS 的 SSH 外层连接"。
- **机房 IP 的信誉不会因为这条隧道而改变**。能保证的是一致性与可靠性，不承诺绕过任何风控。claude.ai 的 Cloudflare 挑战在机房 IP 上通常需要 30–90 秒才放行，这是预期行为，不是故障。
- **单点**。VPS 挂了就没有出口，CLI 与网页一起不可用。这是有意的设计，不是待修的 bug——引入备用出口就会引入"当前到底走哪条"的不确定性。
- **并发与 UDP 受限**。单条 SSH 隧道 + `-L` 转发不承载 UDP，高并发场景下吞吐会受队头阻塞影响。
- **地址计费**。VPS 公网 IPv4 自 2024-02-01 起按 `$0.005/IP/小时` 计费（约 `$3.65/月`）；Elastic IP 即使未绑定实例也会计费，销毁实例前记得释放。

## 8. 参数速查

### 8.1 端口与地址

| 项 | 值 | 说明 |
|---|---|---|
| 本地代理端口 | `7891` | 只监听 `127.0.0.1` |
| VPS 代理端口 | `7890` | sing-box `mixed`，只监听 VPS 回环 |
| VPS 公网 IP | `YOUR_VPS_IP` | 同时是期望出口 IP |
| SSH 别名 | `claude-vps` | 定义在 `~/.ssh/config` |
| 密钥 | `~/.ssh/your-key.pem` | 不要提交到仓库 |
| 安全组 | 仅 `22/tcp` | 其余全部拒绝 |

### 8.2 SSH 配置

```
Host claude-vps
    HostName YOUR_VPS_IP
    User ec2-user
    IdentityFile C:/Users/<you>/.ssh/your-key.pem
    IdentitiesOnly yes
    ServerAliveInterval 15
    ServerAliveCountMax 4
    TCPKeepAlive yes
```

### 8.3 隧道与看护

| 参数 | 值 | 位置 |
|---|---|---|
| `LocalPort` | `7891` | `start-claude-egress.ps1` |
| `RemotePort` | `7890` | 同上 |
| 隧道拉起等待 | 20 × 500 ms = 10 s | 同上 |
| `ServerAliveInterval` | 15 s | ssh 选项 |
| `ServerAliveCountMax` | 4（约 60 s 判定断线） | ssh 选项 |
| 看护轮询 | 20 s | `watch-tunnel.ps1 -IntervalSec` |
| 校验超时 | IP 15 s / API 20 s / Web 25 s | 编排脚本 |

### 8.4 浏览器配置字段

| 字段 | 示例 | 作用 |
|---|---|---|
| `proxy.server` | `http://127.0.0.1:7891` | 单一代理，无回退；`-Web` 时由 `--proxy-server` 覆盖为实际校验的端口 |
| `fail_closed` | `true` | 代理不可达或 `expected_ip` 为空时退出 2 |
| `channel` | `chrome` | 使用本机 Chrome |
| `user_data_dir` | `null` → `<repo>/profiles/<profile>` | 持久化 profile；相对路径按 `browser/` 解析 |
| `timezone_id` | 按出口地区填写 | CDP 层覆盖 |
| `locale` | 按出口地区填写 | CDP 层覆盖 |
| `start_url` | `https://claude.ai/` | 首次导航 |
| 代理探测超时 | 5 s | `launch.py` |
| 首屏导航超时 | 60 s | 超时只告警，不关窗 |

### 8.5 VPS 侧

sing-box 配置节选（示意；示例按 1.14.x 语法编写，部署前请先跑一次 `sing-box check`）：

```json
{
  "dns": {
    "servers": [
      { "type": "tls", "tag": "public", "server": "1.1.1.1", "server_port": 853,
        "tls": { "server_name": "cloudflare-dns.com" }, "detour": "direct" }
    ]
  },
  "inbounds": [
    { "type": "mixed", "listen": "127.0.0.1", "listen_port": 7890 }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "action": "resolve", "server": "public", "strategy": "prefer_ipv4" },
      { "ip_is_private": true, "action": "reject" },
      { "ip_cidr": ["0.0.0.0/8", "127.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16",
                    "192.0.0.0/24", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4",
                    "::1/128", "fe80::/10", "fc00::/7", "::ffff:0:0/96"], "action": "reject" },
      { "domain_suffix": ["localhost", "local", "localdomain", "localtest.me", "nip.io",
                          "sslip.io", "xip.io", "internal", "instance-data", "svc"], "action": "reject" }
    ]
  }
}
```

`action: "resolve"` 必须排在 IP 规则之前：没有它，域名形式的目标不会产生 `DestinationAddresses`，`ip_is_private` / `ip_cidr` 只对 IP 字面量生效。解析后仍建议在 VPS 防火墙上按 sing-box 用户的出站目标兜底，见 [`security.md`](security.md) 第 7 节；防火墙不依赖 sing-box 的解析路径，是第二道独立防线。

BBR 与队列：

```
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
```

应用后必须重建已有 SSH 隧道，否则老连接仍是 cubic：

```powershell
# 只杀掉带这条完整 -L 转发的 ssh，不要误伤其他 SSH 会话
$forward = '127.0.0.1:7891:127.0.0.1:7890'
$pattern = '(?<![0-9.])' + [regex]::Escape($forward) + '(?![0-9])'
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern } |
    ForEach-Object { Stop-Process -Id $_.ProcessId }

ssh -N -L 127.0.0.1:7891:127.0.0.1:7890 claude-vps
```

### 8.6 绕开本机 TUN 的 /32 路由

需要管理员权限；`metric 1` 保证优先于 TUN 的默认路由：

```powershell
route -p add YOUR_VPS_IP mask 255.255.255.255 YOUR_LAN_GATEWAY metric 1
```
`-p` 使其持久化。删除用 `route delete YOUR_VPS_IP`。这条路由只影响去往 VPS 的包，其他流量仍由 TUN 处理；它解决的是"SSH 被自己的代理劫持"这个自指问题。
