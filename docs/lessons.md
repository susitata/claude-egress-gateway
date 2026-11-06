# 结论与踩坑记录

这里记的是"结论"而不是步骤：每一条都来自实测，且都曾经让我在错误方向上浪费过时间。

---

## 1. BBR：不开就没法用，改完必须重建隧道

跨境长肥管道上，VPS 默认的 `cubic` 在丢包时把窗口砍半并缓慢恢复。实测单流 14 KB/s（1 MB 传 60 秒都没完），TLS 握手 4–19 秒，任何页面都会超时。换成 `bbr` + `fq` 后单流 217 KB/s、4 并发 237 KB/s。

**关键细节**：拥塞控制算法在**连接建立时**确定。`sysctl` 只影响之后新建的连接，已经连着的 SSH 会话仍是旧算法。

所以"改完 sysctl 测速没变化"不是 BBR 无效，而是**你测的还是旧连接**。正确做法是重建隧道再测。详见 [`benchmarks.md`](benchmarks.md) 第 4 节的三阶段对照实验。

---

## 2. 数据中心的 IP 过 Cloudflare：是慢，不是被拒

`claude.ai` 的 Turnstile 在机房 IP 上通常需要 **30–90 秒**才放行，期间页面看起来完全静止。40 秒就关窗口 = 白屏。

判断"是不是被识别成自动化"的正确方式是对照实验：用**不带任何自动化框架**的普通 Chrome、独立临时 profile、同一条代理打开同一站点。实测结果是普通 Chrome 同样卡住——变量是出口 IP 的路径与信誉，不是自动化特征。

---

## 3. IP 信誉：机房层面的统计不能用来比较单台 IP

信誉站报的"机器流量占比"（例如 94.3%）通常是**整段网络**的统计，不同机房可能显示同一个数值。它不能说明这台 IP 比那台更好。

判断单台 IP 要看逐 IP 的字段：端口扫描结果、`is_proxy`、`trust_score`、滥用评分、黑名单命中。一个曾被标成 "Open proxy" 的 IP，端口扫描可能显示所有代理端口都关闭——那只是**历史信誉**。换一个 Elastic IP **可能**拿到更干净的起点，但不保证：新地址也可能是别的 AWS 客户刚释放的，信誉需要重新测。

---

## 4. WebRTC：浏览器参数修不掉，只能靠网络层

`--proxy-server` 只代理 HTTP/HTTPS。WebRTC 的 STUN 走 UDP，会直连并暴露真实公网 IP（`srflx` 候选）。

**`--force-webrtc-ip-handling-policy=disable_non_proxied_udp` 在新版 Chrome（实测 156）上不生效**（Chromium issue 41180783），即使 `chrome://version` 里能看到这个参数。本仓库因此**不再默认添加**它——加了只会给人"已处理"的错觉。

唯一可靠的解法是让 UDP 也进隧道：TUN 模式的代理客户端，或在操作系统层阻断除回环外的 UDP 出站。

两条附带结论：

- **不要用 JS 覆盖 `RTCPeerConnection`**。原型链会留下不一致，CreepJS 这类工具反而更容易抓。
- 判断标准：如果存在 WebRTC `srflx` 候选，它必须等于 HTTP 出口 IP；没有 `srflx`、只有 `.local`（mDNS），或只有出口 IP，都算干净。关键是候选里不能出现家宽公网 IP。

TUN 客户端本身也有坑：部分版本在 Windows 11 25H2 上 helper 服务无法启动（Event 7023），表现为"开了 TUN 但路由没生效"，升级版本即可。

---

## 5. 指纹：它修的是"字段一致性"，不是"不可检测"

检测大致分三层：

1. **字段自洽**：时区 = IP 地理时区、语言 = `Accept-Language`、UA 与 `Sec-CH-UA-*` 一致。
2. **JS hook 痕迹**：`Function.prototype.toString`、属性描述符位置、iframe/Worker 逃逸、被替换的 `Math.random`。
3. **网络侧**：TLS 指纹（JA3/JA4）、HTTP/2 指纹、WebRTC 泄漏、IP 质量（机房/住宅）。

Patchright 只修**协议层**（`Runtime.enable`、`Target.setAutoAttach` 的调用序列），不伪造硬件指纹。硬件级伪装需要专门的浏览器。

另外，"用完即删 profile"并不降低暴露：一旦访问过目标站点，那一次请求里的指纹与 IP 就已经被记录，事后无法撤回。风险管理靠"不用真实身份访问"，不靠删除。

本仓库的 `timezone_id` / `locale` 属于第 1 层，只覆盖页面可见的 `Intl` 与 `Date`；系统语言（`--lang`）等表面仍会露出。

---

## 6. 审计这类项目的方法：按攻击面分组，别按文件分组

这次对仓库做红队式审计，最有效的拆法是**四个互不重叠的攻击面**，而不是"逐个文件看一遍"：

| 面 | 要找的东西 |
|---|---|
| 泄密与元数据 | 真实 IP/路径/密钥、git 悬空对象、`.gitignore` 是否真生效 |
| 脚本逻辑 | "看起来 fail-closed，实际有降级分支"；参数绑定；退出码 |
| 网络与浏览器 | 出口泄漏（DNS/WebRTC/IPv6）、本地端口暴露、沙箱 |
| 文档一致性 | 照文档操作会不会失败；数字与代码常量是否一致 |

三个最值得记住的发现类型：

1. **参数绑定**：PowerShell 的 `-Xxx` 唯一前缀会静默绑定到另一个参数；完全不匹配的名字才会在绑定阶段报"找不到参数"。两者都不是 fail-closed，文档里的开关必须和脚本定义逐字一致。
2. **只验证"端口有人听"不等于验证了隧道**。任何本地代理占住同一个端口都能冒充隧道；必须校验监听进程的身份与命令行。
3. **`NO_PROXY` 会让 `curl -x` 静默失效**。预检必须加 `--noproxy=`，否则测的是直连路径。
4. **空字符串参数在 Windows PowerShell 5.1 里会消失**。`--noproxy ""` 传给原生程序的实参里没有空串，下一项（如 `--max-time`）会被 `--noproxy` 吃掉，`15` 变成 URL——超时失效、返回值变形。写成 `--noproxy=` 和 `--max-time=15` 才能保持原意。这类问题不会报错，只会让"检查通过"和"检查失效"看起来一样。

---

## 7. 浏览器启动器的两个隐蔽坑

- Patchright 在没有显式传 `chromium_sandbox` 时会给 Chrome 加 `--no-sandbox`。
- `proxy.bypass` 为空时，它会加 `--proxy-bypass-list=<-loopback>`——这个写法的含义是"**取消** loopback 直连"，于是 `localhost` 被送进代理，最终连到代理另一端自己的回环。本地 OAuth 回调会失效；如果代理侧没有拒绝私网/回环目标，还构成 SSRF。本仓库的 sing-box 示例先用 `action: "resolve"` 解析域名，再拒绝私网目标；防火墙兜底仍是第二道防线。

两者都只能通过查看实际 Chrome 命令行发现：

```powershell
Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
    Select-Object -First 1 -ExpandProperty CommandLine
```
