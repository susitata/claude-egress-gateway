# 排障手册：从白屏到出错的逐层定位

这份文档只处理一类问题：**链路看起来"不通"或"卡住"，但你不知道断在哪一层。**

项目把 Claude Code 与 claude.ai 的流量经一条 SSH 隧道送到自建 VPS 出口，本地 `127.0.0.1:7891` → VPS `127.0.0.1:7890`（sing-box mixed inbound），outbound 为 `direct`，安全组只开 22。设计是 fail-closed：任何一环不成立就失败，绝不回退直连。因此**看到报错不一定是坏事**，先判断它是"闸门正常工作"还是"链路真的坏了"。

下面 12 个案例全部来自真实排障，保留当时的数字与判据。IP、用户名、密钥一律用占位符表示。

---

## 速查表

| 症状 | 跳转 |
|---|---|
| 浏览器窗口一闪就关，或一直白屏 | [案例 1](#case-1) |
| 人机挑战页一直转圈，但 Network 没有失败请求 | [案例 2](#case-2) |
| 已开 BBR，隧道速度却完全没变 | [案例 3](#case-3) |
| 报 `ERR_PROXY_CONNECTION_FAILED`，配置没动过 | [案例 4](#case-4) |
| 换 Elastic IP 后，`ssh` 卡在 banner exchange | [案例 5](#case-5) |
| 隧道通了，却提示出口 IP 与期望不符 | [案例 6](#case-6) |
| `netstat -s -p tcp` 卡死、超时 | [案例 7](#case-7) |
| `.ps1` 输出中文乱码 | [案例 8](#case-8) |
| 怀疑"被识别成自动化了" | [案例 9](#case-9) |
| IP 信誉页显示 "Open proxy" | [案例 10](#case-10) |
| 点 "Continue with Google" 没反应 | [案例 11](#case-11) |
| 浏览器时区/语言与出口地区不一致 | [案例 12](#case-12) |

---

## 1. 浏览器白屏，窗口一闪就关 <a id="case-1"></a>

**现象**：Chrome 窗口出现、白屏，约 60 秒后自己消失；日志末尾常见 `page.goto: Timeout 60000ms exceeded`。

**根因**：三层叠加。(a) `goto` 超时抛异常后，启动器若直接退出 `with sync_playwright()` 块，persistent context 被关闭，窗口随之消失——关窗的是代码，不是网络。(b) 隧道单流只有 14 KB/s，首页资源在 60 秒内拉不完。(c) 机房 IP 触发 Cloudflare 挑战，页面 30–90 秒内本来就不出登录框。

**验证方法**：窗口是否稳定在 60 秒左右消失（是则第 a 层成立）；用 `curl -w` 测单流吞吐是否只有十几 KB/s（第 b 层）；DevTools 看主文档是否挑战页、窗口是否只是白屏（第 c 层）。

**解决**：`launch.py` 捕获异常后不关窗，阻塞等待手动关闭：

```python
try:
    page.goto(start_url, wait_until="domcontentloaded", timeout=60000)
except Exception as exc:
    print(f"[warn] page did not finish in 60s ({type(exc).__name__}); window stays open")
page.wait_for_event("close", timeout=0)   # 永不超时
```

同时开 BBR + fq 并重建隧道（案例 3）；挑战页出现后等 30–90 秒，别关窗、别连续刷新。

---

## 2. 挑战页转圈，但 Network 没有失败请求 <a id="case-2"></a>

**现象**：人机挑战页一直转圈，Network 没有 4xx/5xx、没有 `ERR_ABORTED`，看起来请求都成功，页面就是不动。

**根因**：不是资源失败，是每个资源都太慢。挑战编排脚本要拉一组资源，单流 14 KB/s 时每个约 15 秒，整套来不及在页面超时前跑完。

**验证方法**：Console 导出资源时序：

```js
performance.getEntriesByType('resource').map(r => ({
  url: r.name, status: r.responseStatus, size: r.transferSize, ms: Math.round(r.duration)
}))
```

实测 25 个资源全部 HTTP 200、无失败，但每个约 15 秒。status 全 200 而 duration 很大，即可排除 DNS/证书/代理拒绝，判定为吞吐问题。

**解决**：开 BBR + fq 并重建隧道。修复后 25/25 资源在可接受时间内完成，挑战 30–90 秒内通过。不要反复刷新，每次刷新都会重跑挑战。

---

## 3. 开了 BBR 却没生效 <a id="case-3"></a>

**现象**：VPS 上 `sysctl net.ipv4.tcp_congestion_control` 已是 `bbr`、队列是 `fq`，隧道仍只有 14 KB/s。

**根因**：拥塞控制算法在连接建立时确定。`sysctl` 只影响新连接，已有 SSH 会话仍用 cubic，不会被热切换。

**验证方法**：保留旧隧道，另开一条不同本地端口的隧道对比：

```powershell
ssh -N -L 127.0.0.1:7892:127.0.0.1:7890 claude-vps
curl.exe -o NUL -w "%{speed_download}\n" --max-time 60 -x http://127.0.0.1:7891 "https://speed.cloudflare.com/__down?bytes=1000000"
curl.exe -o NUL -w "%{speed_download}\n" --max-time 60 -x http://127.0.0.1:7892 "https://speed.cloudflare.com/__down?bytes=1000000"
```

旧 14 KB/s、新 104 KB/s；VPS 上 `ss -tin` 也能看到旧连接仍是 cubic。

**解决**：杀掉旧 `ssh`，让 `watch-tunnel.ps1` 20 秒内重拉，重建后单流 217 KB/s（1 MB 4.6 秒）。以后改参数都必须重建隧道再测。

---

## 4. `ERR_PROXY_CONNECTION_FAILED`，配置没改过 <a id="case-4"></a>

**现象**：浏览器报 `ERR_PROXY_CONNECTION_FAILED`，Claude Code 连接被拒；配置和昨天一样。

**根因**：SSH 进程静默退出（睡眠、NAT 超时、切网）。若没加 `ExitOnForwardFailure=yes`，还可能进程活着、TCP 连着，但转发没建立、端口不监听。

**验证方法**：

```powershell
Get-NetTCPConnection -LocalPort 7891 -State Listen
Get-Process ssh -ErrorAction SilentlyContinue
ssh -v -N -L 127.0.0.1:7891:127.0.0.1:7890 claude-vps   # 看到 forward 成功后 Ctrl+C
```

端口不监听就是隧道问题，不用翻浏览器配置。

**解决**：补齐 `BatchMode=yes`、`ExitOnForwardFailure=yes`、`ServerAliveInterval=15`、`ServerAliveCountMax=4`、`TCPKeepAlive=yes`；再用 `watch-tunnel.ps1` 每 20 秒查端口，不在就重拉，并放进启动项。这样掉线最多 20 秒不可用，而不是第二天才发现。

---

## 5. 换 Elastic IP 后 `ssh` 卡在 banner exchange <a id="case-5"></a>

**现象**：`ssh` 输出 `Connection established` 后停住，等不到 banner，最终超时；换 IP 前正常。

**根因**：本机 TUN 代理客户端把"到 VPS 的连接"也劫持进自己的隧道，流量绕进代理后走错出口或回不来，形成自指环路。

**验证方法**：临时退出 TUN 客户端再 `ssh`，若立刻能通即确认；`tracert YOUR_VPS_IP` 看第一跳是否进了虚拟网卡。

**解决**：给 VPS 公网 IP 加 `/32` 主机路由，强制走局域网网关直出：

```powershell
route -p add YOUR_VPS_IP mask 255.255.255.255 YOUR_LAN_GATEWAY metric 1
```

必须在管理员终端执行，普通权限报 `The requested operation requires elevation`；`-p` 持久化，删除用 `route delete YOUR_VPS_IP`。完成后用 `route print YOUR_VPS_IP` 与 `Test-NetConnection YOUR_VPS_IP -Port 22` 验证。Windows 上 `/32` 不占可用地址数，也不影响其他流量。

---

## 6. 换 IP 后忘了同步的地方 <a id="case-6"></a>

**现象**：隧道通、`7891` 在监听，启动器却中止：`egress IP is '...', expected '...'`。

**根因**：换 Elastic IP 时只改了 SSH，其他引用旧 IP 的地方没同步。漏任何一处，都是"隧道通了但出口校验失败"。

**验证方法**：逐项核对 `~/.ssh/config`（`IdentityFile` 指向 `C:\Users\<you>\.ssh\your-key.pem`，Linux/macOS 写作 `~/.ssh/your-key.pem`）的 `HostName`、启动命令的 `-ExpectedIp`、路由器/防火墙对该 IP 的放行规则、（如有）DNS。再对比：

```powershell
ssh -G claude-vps | findstr /i hostname
curl.exe -s -x http://127.0.0.1:7891 https://api.ipify.org
```

**解决**：把清单上的引用全部改成新 IP。这个报错是 fail-closed 在正常工作，不是 bug；不要为了"先跑起来"删掉 `-ExpectedIp`，那只会把"启动失败"换成"悄悄走错出口"。

---

## 7. `netstat -s -p tcp` 卡死/超时 <a id="case-7"></a>

**现象**：想统计 TCP 重传，`netstat -s -p tcp` 挂住几十秒甚至不返回。

**根因**：本机装了 TUN 虚拟网卡，`netstat` 枚举接口时卡在虚拟接口上，与 SSH 隧道无关。

**验证方法**：看 `netstat -an` 是否也慢，或临时禁用 TUN 网卡再试；确认后不再用它做统计。

**解决**：改用 `curl -w` 与 `Test-NetConnection`：

```powershell
curl.exe -o NUL -w "connect=%{time_connect} tls=%{time_appconnect} speed=%{speed_download}\n" -x http://127.0.0.1:7891 https://api.anthropic.com/
Test-NetConnection YOUR_VPS_IP -Port 22
```

`time_connect` 反映建连 RTT，`time_appconnect` 到 TLS 握手完成，`speed_download` 单位是 byte/s（÷1024 得 KB/s）。

---

## 8. PowerShell 进度条/中文乱码 <a id="case-8"></a>

**现象**：`.ps1` 的中文注释/提示变乱码；进度条刷屏把有用的日志冲掉。

**根因**：PowerShell 5.1 对无 BOM 的 UTF-8 按系统 ANSI 代码页解码，文件本身没坏；进度条是默认行为。

**验证方法**：`$PSVersionTable.PSVersion`；`Get-Content .\watch-tunnel.ps1 -Encoding Byte -TotalCount 3`，前三个字节不是 `239 187 191` 即无 BOM。

**解决**：`.ps1` 保持纯 ASCII（注释也用英文），中文提示放 `.bat`/`.md` 或改用 Python；必须在终端显示中文就用 Windows Terminal 并存为带 BOM 的 UTF-8。进度条用 `$ProgressPreference = 'SilentlyContinue'` 抑制。本仓库三个脚本都遵守纯 ASCII 约定。

---

## 9. 怀疑"被识别成自动化了"如何证伪 <a id="case-9"></a>

**现象**：claude.ai 一直卡挑战，怀疑 Patchright/自动化特征被识别。

**根因**：先别改指纹，这个假设需要对照实验证伪，否则会在错误方向上越调越乱。

**验证方法**：用不带自动化框架的普通 Chrome、独立临时 profile、同一条隧道打开同一站点：

```powershell
& "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" --user-data-dir="$env:TEMP\fresh-chrome" --proxy-server=http://127.0.0.1:7891 https://claude.ai/
```

实测：普通 Chrome 走同一台美国东部 VPS 同样卡挑战页；同一浏览器换另一个商业出口则秒过。变量是出口 IP 的路径与信誉，不是自动化特征。

**解决**：不要在这个场景里换指纹。注意别用默认 profile 做对比，否则会把用户自己的窗口和登录态带出来；务必用独立 `--user-data-dir`，用完删除。

---

## 10. IP 信誉页显示 "Open proxy" <a id="case-10"></a>

**现象**：信誉站把出口标成 "Open proxy"，担心被当成开放代理。

**根因**：这类标签多半是历史信誉，不等于当前端口开放；本项目恰恰不对外开放代理端口。

**验证方法**：先端口扫描确认事实。实测该 IP 公网只看到 22（sshd），**没有任何代理端口在监听，代理相关端口全部 closed**；sing-box 只监听 VPS 回环 `7890`，安全组只放行 22。

**解决**：换新的 Elastic IP。实测新 IP trust score 明显更高、`is_proxy=false`，挑战通过率也改善，说明标记来自历史行为，换 IP 有效。

**方法论提醒**：信誉站报的"机器流量占比"（如 94.3%）常是整段网络/整个机房的统计，不同机房可能显示同一个值，不能用来比较单个 IP。判断单 IP 要看端口扫描、黑名单命中、`is_proxy` 这类逐 IP 字段。

---

## 11. 点 "Continue with Google" 没反应 <a id="case-11"></a>

**现象**：点击后页面毫无变化，不弹窗也不报错。

**根因**：两个独立原因。(a) 跨洋慢链路下 OAuth 弹窗要约 60 秒才出现，点击其实已发出请求，只是慢到像没反应。(b) 弹窗出来后 Google 往往给图片 reCAPTCHA，自动化环境几乎过不去。

**验证方法**：点击后看 Network 是否有 `accounts.google.com` 请求，并等满 60 秒观察弹窗；不要连点，连点会叠加多个 OAuth 流程。

**解决**：优先用邮箱验证码登录；必须走 Google 就在有头浏览器里人工完成，别脚本化。等待期间不要刷新主页，否则 OAuth state 丢失。

---

## 12. 浏览器报告的时区/地区 <a id="case-12"></a>

**现象**：页面读到的时区/语言与出口 IP 的 geo 不一致，或需要浏览器"看起来在出口地区"。

**根因**：浏览器层由 CDP 覆盖 `timezone_id` 与 `locale`，应与出口自洽（出口在美国东部则 `America/New_York` + `en-US`）。示例配置即如此。

**验证方法**：页面 Console 读 `Intl.DateTimeFormat().resolvedOptions().timeZone` 与 `navigator.language`，再与出口 IP 的 `country`/`region` 对照。

**解决**：改 `config.local.json` 后重启浏览器。注意这只是浏览器上下文，**不改变系统时区**；Claude Code 默认不上报时区，唯一会带本地时间的是"定时/远程 agent"类技能拼 prompt 时的本地时间，系统时区差太多仍可能露出差异。

---

## 排障原则

### 先证明链路，再证明出口，最后才怀疑应用层

顺序不要跳：**链路**（VPS 的 22 通不通、本地 `7891` 在不在监听）→ **出口**（经 `7891` 测到的 IP 是不是 `YOUR_VPS_IP`）→ **应用层**（API 返回什么、页面资源是失败还是慢）。绝大多数"网页打不开"在前两步就能定位；跳过它们直接改浏览器参数，通常只是浪费时间。

### 一次只改一个变量

案例 3 就是对照实验：改 `sysctl`、新建隧道、杀旧隧道是三个动作，只有"旧 14 KB/s vs 新 104 KB/s"能把差异归因到连接新旧。任何一次同时改两项的测试，结果都不可解释。

### 任何"看起来卡住"，先用资源时序证伪

导出 `performance.getEntriesByType('resource')`：25 个资源全部 200、只是每个 15 秒，问题在吞吐；出现 4xx/5xx 或 `ERR_ABORTED`，才是另一类问题。先分清"慢"和"断"，再决定修哪里。

### fail-closed 的报错是功能，不是故障

`egress IP is '...', expected '...'`、`api.anthropic.com is not reachable`、浏览器退出码 2，都在告诉你"当前链路不满足约束"。正确处理是修链路或同步配置，不是删掉检查。

### 记录数字，别只记录结论

"很慢"无法比较，"14 KB/s → 217 KB/s"可以。每次排障至少留下一组可复测的数字（吞吐、握手耗时、资源状态分布），下次遇到同样症状会快得多。

### 改完底层参数，重建连接再测

拥塞控制、路由、DNS 缓存都可能绑定在"连接"或"进程"的生命周期上。改完先重建隧道/重启浏览器再测，否则测到的仍是旧状态。

---

## 附：三层最小验证

```powershell
# 1. 链路
Test-NetConnection YOUR_VPS_IP -Port 22
Get-NetTCPConnection -LocalPort 7891 -State Listen

# 2. 出口
curl.exe -s -x http://127.0.0.1:7891 https://api.ipify.org

# 3. 应用
curl.exe -s -o NUL -w "%{http_code}\n" --max-time 20 `
  -x http://127.0.0.1:7891 https://api.anthropic.com/v1/messages
```

三步都过，问题才在浏览器或页面本身；任何一步不过，先修那一步。
