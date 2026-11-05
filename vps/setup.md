# VPS 配置

目标：一台只做出口的 Linux 机器 —— 对本机而言，它只是一个 SSH 端口 + 一个绑定在回环上的代理端口。

> 本文以 Amazon Linux 2023 为例（`ec2-user`、`dnf`）。Debian/Ubuntu 把 `dnf` 换成 `apt` 即可；systemd 逻辑一致，但重启 SSH 的单元名不同（Debian/Ubuntu 是 `ssh`，AL2023 是 `sshd`）。
>
> **以下命令除特别说明外，都在仓库根目录执行**（即 `vps/setup.md` 的上一级）。

---

## 0. 前置

- 一台有公网 IPv4 的 VPS，建议绑定 **Elastic IP**（出口 IP 固定，才能做启动校验）。
- 本地生成过 SSH 密钥，能免密登录。
- 一个"到此为止"的认知：**这台机器不需要对外提供任何服务**，唯一要开放的端口是 22。

---

## 1. 网络：只开 22

云厂商安全组 / 防火墙里：

| 端口 | 来源 | 用途 |
|---|---|---|
| 22/tcp | 你的固定出口 IP（或临时放开后收紧） | SSH + 端口转发 |
| 其他 | — | **全部拒绝** |

两条容易被忽略的规则：

- **不要**把代理端口（如 7890）监听在 `0.0.0.0`，更不要放行到安全组。本文的配置一律 `127.0.0.1`。
- 不要为了"方便"临时全开 `0.0.0.0/0` 再忘记改回来；扫段机器人几分钟内就会找到它。

---

## 2. 安装 sing-box

从 [sing-box releases](https://github.com/SagerNet/sing-box/releases) 下载与架构对应的 `linux-amd64` 压缩包，解压后把二进制放到 `/usr/local/bin`：

```bash
tar -xzf sing-box-*-linux-amd64.tar.gz
sudo install -m 0755 sing-box-*-linux-amd64/sing-box /usr/local/bin/sing-box
sing-box version
```

创建运行用户与目录：

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin sing-box
sudo mkdir -p /etc/sing-box
sudo chown root:sing-box /etc/sing-box
sudo chmod 0750 /etc/sing-box
```

Debian/Ubuntu 也可以直接用官方 APT 仓库（见官方安装文档）；Amazon Linux 一般走上面的二进制方式。

---

## 3. 配置：一个 mixed inbound + direct outbound

复制仓库里的样例：

```bash
sudo cp vps/sing-box.example.json /etc/sing-box/config.json
sudo chown root:sing-box /etc/sing-box /etc/sing-box/config.json
sudo chmod 0750 /etc/sing-box
sudo chmod 0640 /etc/sing-box/config.json
# 以服务用户校验，权限问题会在这里暴露，而不是等 systemd 启动失败
sudo -u sing-box /usr/local/bin/sing-box check -c /etc/sing-box/config.json
```

关键点只有两条：

- `listen: "127.0.0.1"` —— 绑定回环，外网无法直连；
- `outbound: direct` —— 这台机器的公网 IP 就是最终出口。

如果以后需要给其他流量做分流，再加 inbound/outbound 与 `route.rules`；**但不要让 Claude 专用的那条路径经过任何规则**，否则出口 IP 就不再是这台机器。

### systemd 单元

`/etc/systemd/system/sing-box.service`：

```ini
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target

[Service]
User=sing-box
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now sing-box
sudo systemctl status sing-box --no-pager
ss -lntp | grep 7890        # 期望：127.0.0.1:7890，而不是 0.0.0.0:7890
```

最后一行是**验收标准**。看到 `0.0.0.0:7890` 就停下来改配置。

---

## 4. 开 BBR（不是可选项）

不开 BBR，跨洋长肥管道上的单流可能只有十几 KB/s，表现为"网页永远加载不完"。详见 [`../docs/benchmarks.md`](../docs/benchmarks.md)。

```bash
sudo modprobe tcp_bbr
sudo cp vps/sysctl-bbr.conf /etc/sysctl.d/99-bbr.conf
echo 'tcp_bbr' | sudo tee /etc/modules-load.d/tcp_bbr.conf
sudo sysctl --system
```

验证：

```bash
sysctl net.ipv4.tcp_congestion_control   # net.ipv4.tcp_congestion_control = bbr
sysctl net.core.default_qdisc            # net.core.default_qdisc = fq
lsmod | grep bbr
```

> **改完必须重建 SSH 隧道。** 拥塞控制算法在连接建立时固定，已经连着的会话仍用旧算法。这一点在第 8 节验收时会直接体现出来——旧隧道没变快，新隧道变快了。

---

## 5. 本机侧：SSH 别名与端口转发

`~/.ssh/config`：

```
Host claude-vps
    HostName YOUR_VPS_IP
    User ec2-user
    IdentityFile C:/Users/<you>/.ssh/your-key.pem
    IdentitiesOnly yes
    ServerAliveInterval 15
    ServerAliveCountMax 4
    TCPKeepAlive yes
    ExitOnForwardFailure yes
```

测试转发是否真的工作（这一步比 `ssh` 是否登录成功更有意义）：

```bash
ssh -f -N -L 127.0.0.1:7891:127.0.0.1:7890 claude-vps   # -f: 认证后转后台，不阻塞
curl.exe -s --noproxy "" -x http://127.0.0.1:7891 https://ipwho.is/
```

返回的 `ip` 必须等于 `YOUR_VPS_IP`。不等就说明流量没走隧道（常见原因：本机还有 TUN 类客户端劫持了到 VPS 的连接，见 [`../docs/troubleshooting.md`](../docs/troubleshooting.md) 第 5 条）。

---

## 6. 换 Elastic IP 时要同步的四件事

换 IP 是排障手段之一（历史信誉由 IP 承载），但它是一个**跨四处**的操作，漏一处就会以"隧道通了但出口校验失败"的形式暴露：

1. 云端把 EIP 重新关联到实例（关联后旧的公网 IPv4 会被释放）。
2. 本机 `~/.ssh/config` 的 `HostName`。
3. 启动脚本里的 `-ExpectedIp`（这是 fail-closed 的锚点）。
4. 如果给 VPS 加了 `/32` 主机路由绕开本机 TUN，那条路由也要改成新 IP。
5. `known_hosts`：旧 IP 可能被分配给别的 AWS 客户，换 IP 后先 `ssh-keygen -R <旧IP>`，再通过控制台核对新主机指纹。

另外：

- 换 IP 后**旧的 EIP 如果没释放，仍然计费**（公网 IPv4 自 2024-02-01 起按 $0.005/IP/小时计，约 $3.65/月；未绑定实例的 EIP 同样计费）。
- 换 IP **不会**改变这台机器在任何平台上的信誉历史之外的东西——它只是给你一段干净的起点，不是隐身衣。

---

## 7. 加固

最低限度用 **drop-in** 写，而不是改主配置——cloud-init 的 `50-cloud-init.conf` 可能覆盖主文件里的同名项：

```bash
sudo tee /etc/ssh/sshd_config.d/99-egress.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
AuthenticationMethods publickey
AllowTcpForwarding local
PermitOpen 127.0.0.1:7890
MaxAuthTries 3
LoginGraceTime 20
EOF
```

`PermitOpen` 很关键：即使密钥泄露，拿到它的人也只能把转发指向 VPS 的 7890，不能拿这台机器当通用跳板。

验证**生效值**（不是文件内容）：

```bash
sudo sshd -t
sudo sshd -T | grep -Ei 'passwordauthentication|permitrootlogin|permitopen|allowtcpforwarding'
sudo systemctl restart ssh    # Debian/Ubuntu
sudo systemctl restart sshd   # Amazon Linux 2023
```

- 安全组只留 22，且来源尽量收窄。
- 不用这台机器跑任何对外服务；不装面板。
- 定期 `dnf update -y`，重启后确认 `systemctl is-active sing-box`。

---

## 8. 验收清单

- [ ] `ss -lntp` 里 7890 只监听 `127.0.0.1`
- [ ] `sysctl net.ipv4.tcp_congestion_control` 为 `bbr`
- [ ] 本地 `curl -x http://127.0.0.1:7891 https://ipwho.is/` 返回 `YOUR_VPS_IP`
- [ ] 隧道**重建之后**再测一次速度（旧连接不会自动变快）
- [ ] 安全组只放行 22
