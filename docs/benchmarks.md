# Claude 出口网关实测：cubic 与 BBR + fq 对比

把 Claude Code 与 claude.ai 的流量经 SSH 隧道送到自建 VPS 出口时，链路质量直接决定可用性。本文记录同一台本地机器、同一条路径、同一时段内，VPS 从默认 `cubic` 切换到 `BBR + fq` 前后的实测差异，并重点解释一个最容易误判的现象：**改完内核参数，已有连接不会变快**。

> 所有数字都来自单一路径、单一时段的测量，不代表你的链路。请只把"变化方向"当作可复现的结论。

## 1. 测试环境

| 项目 | 配置 |
|---|---|
| 本地系统 | Windows 11 |
| SSH 客户端 | OpenSSH（`ssh.exe`） |
| 本地路径 | `C:\Users\<you>` |
| VPS | 美国东部区域，Amazon Linux 2023 |
| 隧道命令 | `ssh -N -L 7891:127.0.0.1:7890 claude-vps` |
| VPS 入站 | sing-box mixed inbound `127.0.0.1:7890` |
| VPS 出站 | `direct`，无上游代理 |
| CDN / 专线 | 无，未做任何 CDN 或中转优化 |

本地所有请求都显式走隧道端口：`-x http://127.0.0.1:7891`。VPS 侧只做 `direct` 转发，因此测到的就是"本地 → VPS → 目标站"这一条裸路径的真实表现。

## 2. 测量方法

### 2.1 单流下载 1 MB

```powershell
curl.exe -o NUL -w "%{speed_download} %{time_total} %{time_appconnect}\n" -x http://127.0.0.1:7891 "https://speed.cloudflare.com/__down?bytes=1000000"
```

- Windows 上必须写 `curl.exe`；PowerShell 里的 `curl` 是 `Invoke-WebRequest` 的别名。
- `-o NUL` 丢弃响应体；Linux/macOS 改为 `-o /dev/null`。
- `%{speed_download}` 的单位是 **byte/s**，换算成 KB/s 需要 `÷1024`。
- `%{time_appconnect}` 包含 TCP 连接与 TLS 握手，用来观察握手阶段的退化。
- 1 MB 的用例若超过 60 秒仍未完成，记为超时，不参与聚合。

### 2.2 4 并发 × 2 MB 聚合

PowerShell（`Start-Job`）：

```powershell
$jobs = 1..4 | ForEach-Object {
  Start-Job {
    curl.exe -s -o NUL -w "%{speed_download}\n" -x http://127.0.0.1:7891 "https://speed.cloudflare.com/__down?bytes=2000000"
  }
}
$speeds = $jobs | Wait-Job | Receive-Job | ForEach-Object { [double]$_ }
"aggregate = {0:N1} KB/s" -f (($speeds | Measure-Object -Sum).Sum / 1024)
```

bash / xargs（`-P4`）等价写法：

```bash
seq 4 | xargs -P4 -I{} curl -s -o /dev/null -w "%{speed_download}\n" -x http://127.0.0.1:7891 "https://speed.cloudflare.com/__down?bytes=2000000" | awk '{s+=$1} END {printf "aggregate = %.1f KB/s\n", s/1024}'
```

聚合值 = 4 个 `speed_download` 之和再 ÷1024，不要把单个并发流的值当成聚合值。

### 2.3 出口 IP 与路径确认

```powershell
curl.exe -s -x http://127.0.0.1:7891 https://ipwho.is/
```

返回的 `country` / `region` 应落在 VPS 所在区域。若出口 IP 与预期不符，后面所有吞吐数字都没有比较意义。

### 2.4 为什么没用 netstat

本机 `netstat -s -p tcp` 在装有 TUN 虚拟网卡时会卡死，因此未采用。所有统计均来自 `curl -w` 的 `time_connect`、`time_appconnect`、`speed_download`，以及 `Test-NetConnection` 的连通性检查。

## 3. 结果

| 场景 | 修复前（cubic） | 修复后（BBR + fq） |
|---|---|---|
| 单流下载 1 MB | 14 KB/s，60 秒超时未完 | 217 KB/s，4.6 秒 |
| 4 并发 × 2 MB 聚合 | 87 KB/s | 237 KB/s |
| TLS 握手耗时 | 4–19 秒 | 0.8–1.9 秒 |
| 页面资源 | 大量 `ERR_ABORTED`，挑战页不完成 | 25/25 资源 HTTP 200，挑战 30–90 秒内通过 |

逐项解释差异来源：

| 指标 | 变化 | 主要原因 |
|---|---|---|
| 单流下载 | 14 → 217 KB/s（约 15 倍） | cubic 以丢包为拥塞信号，一丢包就大幅减窗且恢复慢；BBR 用带宽时延积自适应，不把丢包直接等同于拥塞 |
| 4 并发聚合 | 87 → 237 KB/s | 每条连接都不再被丢包反复压窗，聚合吞吐随之抬升；但仅比单流高约 9% |
| TLS 握手 | 4–19 秒 → 0.8–1.9 秒 | 握手需要多个往返；单流吞吐崩塌时握手包排队与重传，握手时间被成倍放大 |
| 页面资源 | 25/25 全部 200 | 浏览器并发拉取资源，依赖每条连接都能在有限时间内完成；`ERR_ABORTED` 大量出现说明连接被超时或重置 |

BBR 的核心收益在高 RTT 且有丢包的链路上：它估计瓶颈带宽与最小 RTT，按带宽时延积主动发送，而不是等丢包后再退让。`fq` 则提供每流 pacing，把突发流量摊平，减少因突发造成的丢包和 bufferbloat。

## 4. 一次"看起来没生效"的实验

这是整个过程中最容易误判的地方：改完 `sysctl` 立刻测速，数字纹丝不动，很容易得出"BBR 没用"的结论。实际做了一次三阶段对照。

| 阶段 | 操作 | 单流 1 MB 结果 | 观察 |
|---|---|---|---|
| A | VPS 上设置 `net.ipv4.tcp_congestion_control=bbr`、`net.core.default_qdisc=fq`，不重启隧道 | 14 KB/s | 与改前完全一致 |
| B | 保留旧隧道，在另一个本地端口新建一条 SSH 隧道 | 104 KB/s | 新连接已生效，但旧隧道仍在运行 |
| C | 杀掉旧隧道，由看护脚本重新拉起 | 217 KB/s | 同一路径稳定复现 |

结论：

- Linux 的拥塞控制算法在**连接建立时**确定，`sysctl` 只影响之后新建的连接；已有 SSH 隧道不会被"热切换"。
- 因此"改完 sysctl 测速没变"不是 BBR 无效，而是**测的仍是旧连接**。
- 正确的验证动作是重建隧道：A → B 证明新连接已经变快；C 说明必须彻底替换旧连接，才能得到稳定结果。
- B 的 104 KB/s 与 C 的 217 KB/s 之间的差异未做隔离实验，本文不据此推断成因，只作为过程记录。

## 5. 反向结论：瓶颈在单流，不在隧道数量

| 观察 | 推论 |
|---|---|
| 4 并发 237 KB/s，单流 217 KB/s，仅高约 9% | 增加并发几乎不增加总吞吐 |
| 若瓶颈是 VPS 总带宽 | 4 并发应接近单流的 4 倍 |
| 若瓶颈是单条 TCP 的窗口与丢包 | 多条流只能各分到相近份额，聚合提升很小 |

所以优化顺序应当是：

1. 先把单流做对：`BBR + fq`，并**重建连接**。
2. 再考虑多路复用、多隧道、多入口。
3. 如果单流只有 200 KB/s 量级，多开几条隧道通常只是把同一个瓶颈复制几份，不会线性叠加。

## 6. 可复现性与诚实声明

| 声明 | 说明 |
|---|---|
| 绝对值会变 | 地区、时段、ISP、VPS 邻居负载都会影响结果 |
| 只保证方向 | 同一链路上 BBR 相对 cubic 的提升方向可复现，具体倍数不保证 |
| 单路径单时段 | 未做多日重复采样与统计显著性检验 |
| 无 CDN | 结果是裸链路表现；接入 CDN 后结论可能不同 |
| 工具限制 | `netstat -s -p tcp` 在 TUN 环境下卡死，统一改用 `curl -w` |

## 7. 在自己的链路上复测（约 10 分钟）

| 步骤 | 耗时 | 操作 | 判据 |
|---|---|---|---|
| 1. 确认路径 | 2 分钟 | 查出口 IP、当前拥塞控制算法、RTT | IP 落在预期区域；算法名符合预期 |
| 2. 测基线 | 3 分钟 | 单流 1 MB 跑 3 次取中位数；4 并发 × 2 MB 记聚合 | 得到 cubic 下的两组数 |
| 3. 切换并复测 | 5 分钟 | 设 BBR + fq，**杀掉并重建隧道**，重复步骤 2 | 单流明显上升、4 并发提升有限，即与本文一致 |

VPS 侧切换命令：

```bash
sysctl net.ipv4.tcp_congestion_control
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr
sudo sysctl -w net.core.default_qdisc=fq
```

若接口上的 qdisc 没有随之变化，执行 `tc qdisc replace dev <iface> root fq` 使其立即生效。需要持久化时，把上述两个键写入 `/etc/sysctl.d/99-bbr.conf`。

切换完成后必须重建隧道：

```bash
ssh -N -L 7891:127.0.0.1:7890 claude-vps
```

只要第 3 步里单流吞吐相对第 2 步明显上升，就说明改动生效；如果没变，先检查隧道是否真的重建，再怀疑参数。
