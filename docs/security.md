# 安全边界与加固清单

本文回答一个问题：**这套东西到底保证了什么，没保证什么。**

如果你只记住一句：默认配置下，它保证的是"**从本脚本启动的那个进程**，其 TCP 流量从固定 VPS 出口出去，且失败时不回退直连"。它不保证整机、不代表反检测、也不能挡住本机已有权限的攻击者。浏览器的 `fail_closed: false` 是显式的降级模式，不在这个保证范围内。

---

## 1. 覆盖边界

| 覆盖 | 不覆盖 |
|---|---|
| `start-claude-egress.ps1` 启动的 `claude` 进程 | IDE 插件、桌面端、其它终端里已开的 `claude` |
| `-Web` 启动的那个 Chrome 实例 | 你自己平时用的浏览器 |
| 上述进程的 HTTP/HTTPS（读 `HTTPS_PROXY` 或 `proxy.server`） | git-over-SSH、部分 MCP server，以及自带网络栈或显式绕过代理的工具；git HTTPS 远端与 npm/npx/uvx 通常继承 `HTTPS_PROXY` |
| 代理链路上的 TCP | UDP（WebRTC/TURN）、ICMP |

验证方法（PowerShell）：

```powershell
# 看某个 claude 进程到底连了谁（npm 安装时实际进程可能是 node.exe）
$p = Get-CimInstance Win32_Process |
     Where-Object { $_.CommandLine -match 'claude' } |
     Select-Object -First 1
if ($p) {
    Get-NetTCPConnection -OwningProcess $p.ProcessId -State Established |
        Select-Object RemoteAddress, RemotePort
}
```

如果 `RemoteAddress` 不是 `127.0.0.1`，它就没走隧道。

**要真正做到"整机只有一条出口"**，应用层代理做不到，需要操作系统级规则（Windows 防火墙按可执行文件限制出站，只允许 `127.0.0.1:7891`），或干脆把 Claude 放在独立用户/虚拟机里。

---

## 2. 五道检查与它们的补充

| 检查 | 判据 | 备注 |
|---|---|---|
| 本地端口 | `127.0.0.1:7891` 处于 Listen | |
| **端口属主** | 监听进程必须是绝对路径的系统 `ssh.exe`，`-L` 值与期望转发完全一致，且主机别名是最后一个参数；识别不到属主同样中止 | 只判断"有人在听"是不够的；`-AllowUnknownOwner` 是显式例外 |
| 出口 IP | 经代理测到的 IP **必须等于** `expected_ip` | 未配置时拒绝启动（`-CheckOnly` + `-AllowUnpinned` 除外） |
| API 可达 | `api.anthropic.com` 返回任意 HTTP 状态 | `000` 视为失败 |
| 浏览器侧 | 代理端口可达，且经代理测到的出口 IP 等于 `expected_ip`；Chrome 启动后再由 **Chrome 自己**访问 IP 回显服务复核一次 | 启动前检查在 Chrome 创建之前执行；启动后复核能发现企业策略/扩展对 `--proxy-server` 的覆盖；`fail_closed: false` 时都跳过 |

为什么"端口属主"这一条必须有：如果 `7891` 上恰好是别的代理（例如你把 Clash 的混合端口设成了 7891），只看端口会让脚本**跳过建隧道**，直接把它当隧道用。出口 IP 校验能兜住大部分情况，但它依赖"那个代理确实能连出去"，而一个回环上的 MITM 代理完全可以对 `ipwho.is` 特判、返回你期望的 IP。

同样地，所有 `curl` 预检都显式加了 `--noproxy=`：环境里若存在 `NO_PROXY=*`，curl 会**忽略 `-x`** 直连目标，于是你测的是家宽而不是隧道。

这里必须用等号形式。Windows PowerShell 5.1 会把空字符串参数丢掉，`--noproxy ""` 实际传给 curl 的是 `--noproxy` 加上下一个参数（通常是 `--max-time`），于是超时设置被吞掉、`15` 被当成 URL；文档里若写成 `--noproxy ""`，那条自查命令甚至会退化成直连测试。`--noproxy=` 没有这个问题。

---

## 3. WebRTC：HTTP 代理管不到

`--proxy-server` 只代理 TCP。浏览器里的 `RTCPeerConnection` 会直接向 STUN 服务器发 UDP，拿到本机真实公网 IP（`srflx` 候选）。**这与是否运行 TUN 客户端无关**，也不是"容易被忽略的小问题"——任何页面无需用户交互就能做这件事。

缓解：**只有网络层可靠**——让 UDP 也进隧道（TUN 模式），或在操作系统层阻断除回环外的 UDP 出站。

`--force-webrtc-ip-handling-policy=disable_non_proxied_udp` 在实测的 Chrome 156 上**不生效**（Chromium issue 41180783），即使参数出现在命令行里。本仓库因此不再默认添加它：留着只会制造"已经处理过"的错觉。

验证：`chrome://webrtc-internals` 或 CreepJS，确认候选里**没有**你的家宽地址；只出现 `.local`（mDNS）或出口 IP 才算干净。**不要**用 JS 覆盖 `RTCPeerConnection`——原型链的不一致反而更容易被识别。

> **更正**：早先文档把"给 VPS IP 加 `/32` 路由"写成 WebRTC/UDP 泄漏的缓解手段，这是错的。`/32` 只固定"到 VPS 的那条 SSH 外层连接"走物理网卡，对发往任意 STUN 服务器的 UDP 完全无效。

---

## 4. 本地回环：不要被送进隧道

Patchright/Playwright 默认会给 Chrome 加 `--proxy-bypass-list=<-loopback>`。这个写法的含义是"**取消** loopback 的隐式直连"，结果 `localhost`、`127.0.0.1`、`[::1]` 的请求会被送进代理，最终连到 **VPS 自己的回环**。

后果有两个：本地 OAuth 回调、开发服务器打不开；在没有示例 `route.rules` 的情况下，页面还能把 VPS 的 `127.0.0.1:22`、`127.0.0.1:7890` 当目标，借 sing-box 的 `direct` 出站形成 SSRF。示例配置先用 `action: "resolve"` 解析域名，再用 `ip_is_private`、扩展 CIDR 与 `domain_suffix` 拒绝私网/回环目标；防火墙兜底仍是第二道防线（第 7 节）。

本仓库的 `launch.py` 有四层处理。第一，**无条件**设置 `PLAYWRIGHT_DISABLE_FORCED_CHROMIUM_PROXIED_LOOPBACK=1`（不用 `setdefault`：预先存在的空值会被驱动当成 false），让 Playwright 不再追加 `<-loopback>`。第二，不原样使用配置里的 `bypass`：剔除显式的 `<-loopback>`，并且只接受**回环范围**的条目——主机名、`*.localhost`、`127.0.0.0/8` 或 `::1/128` 的子网；`*.*`、`**`、`*?*`、`0.0.0.0/1,128.0.0.0/1` 这类通配符/分区 CIDR，以及任何公网主机，都会让启动直接失败。第三，**强制合并**完整的 loopback 集合（含 `localhost.localdomain`、`ip6-localhost`、`ip6-loopback`）。第四，输出用逗号分隔，因为 Playwright 只按逗号拆分，再用分号拼接。最终生效的 bypass 只可能包含回环项，例如：

```text
bypass = localhost,*.localhost,localhost.localdomain,ip6-localhost,ip6-loopback,127.0.0.1,127.0.0.0/8,::1,[::1]
```

验证：`chrome://net-export` 抓包，确认 `http://127.0.0.1/` 走 `DIRECT`。

---

## 5. DNS 与 DoH

- 走 HTTP 代理的 HTTPS 请求，Chrome 发的是 `CONNECT host:443`，**目标域名由 VPS 解析**，本机 ISP 看不到。
- 例外是浏览器自己的解析路径：Secure DNS（DoH）、预取、WebRTC 的 TURN 主机名。新 profile 可能默认启用 Secure DNS，届时查询会直接发给 DoH 提供方。
- 还有一个本地陷阱：如果 `proxy.server` 写成主机名而不是字面 IP，在 fake-ip 的 TUN 环境下会解析成 `198.18.x.x`，Chrome 会连进 TUN 客户端，而不是 SSH 隧道。

建议：`proxy.server` 保持 `http://127.0.0.1:7891` 字面量；需要更严格时用企业策略 `DnsOverHttpsMode=off`。

---

## 6. IPv6

当前多数家用网络没有 IPv6 默认路由，所以这条暂时不触发；**一旦有**，IPv6 流量会绕过 IPv4 的 `/32` 路由和隧道。

- SSH：`AddressFamily inet`
- 浏览器：`--disable-ipv6`，或在防火墙阻断除回环外的 IPv6 出站
- 自查：`Get-NetRoute -AddressFamily IPv6`

---

## 7. 本地端口 `7891` 没有认证

隧道本地端默认是一个**无认证**的 HTTP 代理：本机任何用户/进程都能连上，用你的固定 VPS IP 作为出口——行为会归因到你。启用 sing-box `users` 后则需要认证。

同理，VPS 上的 `direct` 出站本身不限制目标。示例 `route.rules` 先用 `action: "resolve"` 解析域名，再拒绝解析结果中的回环、私网、链路本地和云元数据地址（含 `169.254.169.254`）；如果删掉 `resolve` 规则，IP 规则就只对 IP 字面量生效。无论是否保留这些规则，都建议叠加第 7 节第 4 条的防火墙兜底。

可行加固（按需，会增加配置复杂度）：

1. sing-box inbound 配 `users`（随机用户名/密码），`config.local.json` 填 `proxy.username/password`。CLI 侧用 `-ProxyUser` / `-ProxyPassword`（或环境变量 `CLAUDE_EGRESS_PROXY_USER` / `CLAUDE_EGRESS_PROXY_PASSWORD`）传入。编排脚本把凭据 URL 编码后放进 `$ProxyUrl`，用于预检和 `HTTPS_PROXY`；只有在 `-Web` 分支才把**原始值**临时放进子进程环境变量，`launch.py` 再自行编码，浏览器退出后恢复原值。CLI 分支不会把这两个变量传给 `claude`。浏览器侧 `launch.py` 把凭据嵌入代理 URL 交给 `ProxyHandler`：urllib 会据此生成 `Proxy-Authorization`，HTTPS 时放进 `CONNECT` 请求。不要改用 `ProxyBasicAuthHandler`——Python 3.12 在 `CONNECT` 收到 407 时会直接抛 `OSError`，407 处理器根本不会被调用。注意 `curl -x` 的代理 URL 会出现在进程命令行里，同一用户下的其他进程可以读到；不需要认证时就不要开 `users`。
2. sshd 限制转发目标：
   ```
   AllowTcpForwarding local
   PermitOpen 127.0.0.1:7890
   ```
3. sing-box `route.rules` 先 `resolve` 再拒绝私网/链路本地目标（`vps/sing-box.example.json` 已包含）。
4. VPS 防火墙按 sing-box 用户兜底，阻断其出站到回环、私网和链路本地地址。示例（nftables，需按发行版调整）：

   ```bash
   sudo nft add table inet egress
   sudo nft add chain inet egress out '{ type filter hook output priority 0; }'
   sudo nft add rule inet egress out meta skuid sing-box ip daddr '{ 0.0.0.0/8, 127.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 192.0.0.0/24, 198.18.0.0/15, 224.0.0.0/4, 240.0.0.0/4 }' reject
   sudo nft add rule inet egress out meta skuid sing-box ip6 daddr '{ ::1/128, fc00::/7, fe80::/10, ::ffff:0:0/96 }' reject
   ```

   这条规则比 `route.rules` 更靠底层：它不依赖 sing-box 的解析路径，即使 `resolve` 被删掉或解析失败，任意域名解析到私网地址也都会被拦下。两者叠加，而不是二选一。
5. VPS 强制 **IMDSv2**，关闭 IMDSv1。

---

## 8. 浏览器沙箱与 profile 权限

- 不传 `chromium_sandbox` 时，Playwright 会加 `--no-sandbox`：渲染器失陷即用户级代码执行。示例配置显式设置 `chromium_sandbox: true`；`launch.py` 默认也是 `true`，并且**拒绝** `config.local.json` 里的 `false`——否则一个配置值就能绕过 `browser_args` 的 `--no-sandbox` 黑名单。需要关闭沙箱只能改代码，属于明确的维护者决定，不是运行时可选项。`browser_args` 里出现 `--no-sandbox`、`--disable-web-security`、`--remote-debugging-port`、`--remote-debugging-address`、`--remote-debugging-pipe`、`--host-resolver-rules`、`--user-data-dir` 等开关时直接拒绝启动。比较前会按 Chromium 的规则归一化：去掉前导 `-`/`--`/`/`、忽略大小写、去掉首尾空白，所以 `/proxy-server=...` 或 ` -Proxy-Server=...` 同样会被拦下。可在启动后用
  `Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Select-Object CommandLine`
  确认参数里没有 `--no-sandbox`。
- 持久化 profile 里有登录 cookie。如果仓库放在 `E:\...` 这类继承 `Authenticated Users:(M)` 的目录，**本机其他已认证用户可以直接改写 `launch.py`**，等你下次运行时以你的身份执行。最省事的做法是把**整个仓库**放到只有你可写的目录，并收紧 ACL：

  ```powershell
  $dir = "$env:LOCALAPPDATA\claude-egress-gateway"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  icacls $dir /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F"
  ```

  如果只想移动其中一部分，注意两条限制：`user_data_dir: null` 时 profile 默认在 `<repo>/profiles/<profile>`，相对路径按 `browser/` 解析，改位置必须同步修改 `user_data_dir`；`config.local.json` 的查找顺序是 `browser/<name>`、`browser/config/<name>`、`<repo>/config/<name>`，仓库外的配置需要给 `launch.py --config` 传绝对路径。`-Web` 固定使用文件名 `config.local.json`，没有独立的配置路径参数。

  注意 `"${env:USERNAME}:(OI)(CI)F"` 的花括号不能省：写成 `"$env:USERNAME:(OI)(CI)F"` 时，PowerShell 会把 `:...` 当成变量名的一部分，展开结果里没有用户名。

---

## 9. VPS 加固

```ini
# /etc/systemd/system/sing-box.service 片段
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6
LimitNOFILE=65535
```

sshd 用 drop-in 写死策略，并用 `sshd -T` 验证**生效值**。文件名请用 `00-egress.conf` 以保证优先级，不要用 `99-`：sshd 对同一项取"首次出现的值"，并按文件名字典序读取 drop-in，`50-cloud-init.conf` 会先于 `99-egress.conf` 生效。

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AuthenticationMethods publickey
AllowTcpForwarding local
PermitOpen 127.0.0.1:7890
MaxAuthTries 3
```

主机密钥：最终配置用 `StrictHostKeyChecking=yes`。首次连接不要指望交互提示——`yes` 会直接拒绝未知主机；先用 `ssh -o StrictHostKeyChecking=accept-new` 连一次，同时在云控制台核对指纹。换 Elastic IP 后同步更新 `known_hosts`——旧 IP 可能被分配给别的 AWS 客户。

---

## 10. 供应链

- `pip install -r browser/requirements.txt` 只锁版本，不锁 hash。更严格的做法是 `pip-compile --generate-hashes` + `pip install --require-hashes`，并把 `greenlet`、`pyee` 一并锁住。
- 从 GitHub Releases 下载 sing-box 二进制后，应对照官方 `*_checksums.txt` 做 `sha256sum -c`，不要直接 `install`。

---

## 11. 可检测性（不是泄漏，但相关）

`--disable-backgrounding-occluded-windows`、`--disable-renderer-backgrounding` 会让页面在被遮挡时仍保持 visible、计时器全速运行。普通用户不会这样，反自动化脚本可以据此识别环境。这些参数是为了让慢链路下的挑战页不至于停滞，属于取舍，不是"更真实"。

同理，`timezone_id` / `locale` 是 CDP 层覆盖，系统语言（例如 `--lang=zh-CN`）仍会在覆盖不到的表面露出。需要彻底一致，就对齐系统语言/时区，或用独立用户/虚拟机。

---

## 12. 附：一次自查

```powershell
# 1. 隧道属主
$c = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 7891 -State Listen
(Get-CimInstance Win32_Process -Filter "ProcessId=$($c.OwningProcess)").CommandLine

# 2. 出口
curl.exe -s --noproxy= -x http://127.0.0.1:7891 https://ipwho.is/

# 3. 浏览器参数里没有危险开关
Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" |
    Select-Object -First 1 -ExpandProperty CommandLine

# 4. IPv6 是否有默认路由（有就说明可能绕过）
Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue
```
