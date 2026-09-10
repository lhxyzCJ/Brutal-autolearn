# Brutal-autolearn

给 `tcp-brutal`（HyNetworks/tcp-brutal v2）代理服务器用的自动运维脚本：一边自动发现真实客户端 IP 并下发拥塞控制规则，一边把扫描器挡在门外、把僵尸规则定期清理掉。

实测环境：Debian 13，`sing-box`（naive h2 / anytls）+ `xray`（VLESS），生产跑了 19h+ 零 `FAIL`。

## 目录

- [背景：为什么需要它](#背景为什么需要它)
- [功能](#功能)
- [仓库结构](#仓库结构)
- [依赖](#依赖)
- [安装](#安装)
- [配置](#配置)
- [工作原理](#工作原理)
- [验证](#验证)
- [调参指南](#调参指南)
- [卸载](#卸载)
- [License](#license)

## 背景：为什么需要它

tcp-brutal 是**按目的前缀生效**的发送端拥塞控制。`brutalctl add <IP/掩码> <rate> gain=<x>`
实质是下一条 `ip route replace <IP> ... congctl lock brutal`，只有**加规则之后新建的 TCP**
才走 brutal。几个关键约束（来自官方 README）：

| 约束 | 说明 |
|---|---|
| `rate` = 接收端带宽 | 填客户端链路**真实能吃到**的带宽。设高了不会更快，只会制造丢包（实测 rate 超过 policing 上限时重传率 50%）。 |
| `gain` 1.5x–2x | 即 `gain=15` 到 `gain=20`，官方上限 2x，不要再往上加。 |
| 只对新连接生效 | 老连接保持原 CC（一般是 bbr/cubic），必须重连/新开 TCP 才进 brutal。 |
| 调参热生效 | 同一前缀重复 `add` 会原地更新 rate/gain（同 ID），不断连。 |
| 别设成系统默认 CC | 只给代理客户端 IP 下发，不要全局替换。 |

痛点：代理服务器的客户端 IP 天天变，手动 `brutalctl add` 维护不过来；
而把全量 CN 网段（上万 CIDR，大部分永不连你）预填进内核表，全是僵尸条目。
这个脚本就是干这件事的：**动态学、落盘存、定期清**。

## 功能

1. **自学习（行为门）**：每 5s 扫一次 `ss`，只有**同一个 socket（IP:port）在前后两次轮询都存活**
   （约 10s 长连接）才加规则。正常 naive h2 / VLESS 长连接一根 TCP 跑几分钟，轻松过；
   毫秒级握手失败的扫描器靠换源端口高频重连，同一个 IP:port 永远对不上，直接挡掉。
2. **预置 + 落盘**：`KNOWN_CLIENTS` 每次必保（重连首 SYN 即 brutal）；所有加过的 IP 记
   `known.list`（`IP 首次时间戳`），重启丢表后下个周期自动补回。
3. **季度僵尸清理**：超 90 天、且 `MEMBERS=0`、`SENT=0` 的纯僵尸删掉并移出 `known.list`，
   `KNOWN_CLIENTS` / `PROTECTED` 永不删。
4. **防护细节**：私网地址过滤、双栈 `::ffff:` 归一化（流量走 IPv4 表，必须归一成纯 IPv4）、
   端口号误加防护、IPv6 提端口兼容。

## 仓库结构

```text
Brutal-autolearn/
├── brutal-autolearn.sh   # 主脚本：预置 + 落盘恢复 + 行为门自学习（5s 一次）
├── brutal-cleanup.sh     # 僵尸清理脚本（季度 timer 调用）
├── systemd/
│   ├── brutal-autolearn.service
│   ├── brutal-autolearn.timer    # 开机 10s 后启动，之后每 5s 跑一次
│   ├── brutal-cleanup.service
│   └── brutal-cleanup.timer      # 每年 01/04/07/10 月 1 日 03:00 跑一次
├── LICENSE               # MIT
└── README.md
```

运行时文件（不在仓库里，脚本自动维护）：

| 路径 | 说明 |
|---|---|
| `/var/lib/brutal-autolearn/known.list` | 已加规则 IP + 首次时间戳，`IP epoch` 一行一条 |
| `/var/lib/brutal-autolearn/last_candidates` | 上一轮 `ss` 抓到的 `IP:port` 快照（行为门用） |
| `/var/log/brutal-autolearn.log` | `ADD / FAIL` 记录 |
| `/var/log/brutal-cleanup.log` | `DEL / FAIL-DEL` 记录 |

## 依赖

- Linux 内核已加载 tcp-brutal 模块，`brutalctl` 可用（`brutalctl list` 有表头输出）。
  可用 CC 里应能看到 `brutal`：`cat /proc/sys/net/ipv4/tcp_available_congestion_control`
- `ss`（iproute2）、`systemd`、bash 4+。

## 安装

```bash
install -m 0755 brutal-autolearn.sh /usr/local/bin/brutal-autolearn.sh
install -m 0755 brutal-cleanup.sh  /usr/local/bin/brutal-cleanup.sh
cp systemd/brutal-*.service systemd/brutal-*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now brutal-autolearn.timer
systemctl enable --now brutal-cleanup.timer
```

先按[配置](#配置)改好 `PORTS` / `KNOWN_CLIENTS` 再启用 timer。

## 配置

都在脚本头部的变量里改：

**brutal-autolearn.sh**

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORTS` | `"auto"` | `auto` = 自动跟随本机所有监听中的 TCP 端口（新代理端口零配置生效；出站连接本地是随机端口，永远学不到）。也可写死，如 `PORTS="3306 443 8443 8964"`。UDP/QUIC 类协议（hysteria2/TUIC，自带应用层控制）不用填。 |
| `LEARN_IGNORE_PORTS` | `"22"` | 这些本地端口不参与学习：SSH/管理口流量小不需要 brutal，且慢速扫描最爱按住它们混过行为门。空格分隔。 |
| `DEFAULT_RATE_MBPS` | `"100"` | 下发 rate，单位 Mbps，含义见[调参指南](#调参指南)。按自家链路实测改（100M 宽带填 100）。 |
| `GAIN` | `"20"` | 即 2.0x，官方上限，别再高。 |
| `KNOWN_CLIENTS` | `""` | 常客 IP，空格分隔，每次必保。填你自己的固定 IP，重连首包即 brutal。 |
| `KICK_PORTS` | `"3306 443 8443 8964"` | 新规则下发后立即踢掉该 IP 在这些端口上的老 TCP，逼客户端重连、首包即 brutal。只保留代理端口，别加 SSH/管理端口；只对新加的 known/learned 生效，`restore` 不踢。 |
| `LOG` / `STATE_DIR` | 见脚本 | 日志和状态目录，一般不用动。 |

**brutal-cleanup.sh**

| 变量 | 默认 | 说明 |
|---|---|---|
| `PROTECTED` | `""` | 永不清理的 IP（建议跟 `KNOWN_CLIENTS` 保持一致）。 |
| `RETENTION_DAYS` | `90` | azdui多大年龄算僵尸，默认 90 天一清（配合季度 timer）。 |
| 清理条件（三者同时满足才删） | — | ① 年龄 ≥ `RETENTION_DAYS`；② `brutalctl list` 里 `MEMBERS=0`；③ `SENT=0` / `0.0`。删完同步踢出 `known.list` 防复活。 |

## 工作原理

一次轮询（5s）干三件事：

1. **保预置**：`KNOWN_CLIENTS` 逐个 `ensure_rule`（内核没规则就 `brutalctl add IP/32 rate gain=xx`）。
2. **恢复落盘**：`known.list` 里所有 IP 同样 `ensure_rule`，重启后自动补表。
3. **行为门学习**：
   - 抓 `ss -tn established` 里本地端口命中监听集合的对端，存 **`本地端口 + IP:port`**
     （如 `443 [1.2.3.4]:5678`）到本轮快照；
   - 跟上一轮快照取交集——**同一个 socket 连活两轮（约 10s）**才提 IP 加规则，日志记为
     `ADD x.x.x.x/32 100Mbps (learned:443)`，端口号即审计依据。正常 naive h2 / VLESS
     长连接轻松过；毫秒级握手失败的扫描器换端口重连，对不上号。
   - 本轮快照覆盖旧的，供下一轮比对。
4. **下发即踢**：新规则（known/learned，非 restore）落表后，`ss -K` 踢掉该 IP 在
   `KICK_PORTS` 上的老 TCP（记 `KICK x.x.x.x closed=N`），客户端自动重连，
   新 TCP 首包即 brutal。代价是一次秒级抖动，只对该 IP 生效一次。

为什么是 `IP:port` 而不是 `IP`：旧版按 IP 比对时，实测某扫描器（`TLS handshake: EOF`，
单连接存活几十毫秒）靠高频换源端口重连、每轮 IP 都在场，混进了表。改成四元组后这类扫描
再也对不上——而代价是：能把一个 socket 按住 10 秒以上的慢速扫描偶尔会漏进一条，
它零流量躺着，90 天后清理掉即可，全表常年几十条，内核查找零压力。

`ensure_rule` 的归一化：`::ffff:a.b.c.d` → `a.b.c.d`（内核路由走 IPv4 表）；
纯 IP 才加 `/32`（v6 `/128`），端口号、域名、私网一律丢弃并记 `FAIL` 备查。

## 验证

```bash
brutalctl list                          # 看 RATE/GAIN/LOCK/MEMBERS/SENT
ss -tin state established               # brutal 连接显示 brutal + pacing_rate=rate；其余是 bbr
ip route get <客户端IP>                 # 应含 congctl lock brutal
tail -f /var/log/brutal-autolearn.log   # ADD ... (learned/known/restore)，无 FAIL 即正常
systemctl list-timers brutal-autolearn.timer brutal-cleanup.timer
```

典型正常输出：`ADD 1.2.3.4/32 100Mbps (learned)`，之后该 IP 的新连接 `ss -ti` 显示
`brutal ... pacing_rate 100000000bps`。注意：**加规则前已建连的老 TCP 不会切换**，
要等客户端重连（naive h2 单长连接复用，影响最明显，重连一次即生效）。

## 调参指南

- 先看下行：客户端下行多少就填多少（如 100M 下行填 `100`），宁小勿大。
- `gain` 从 `20` 起，官方上限 2x；丢包/重传高先降 `rate`，别加 `gain`。
- 同前缀重复 `add` 即热更新：`brutalctl add <IP/32> 100 gain=20`，不断连。
- 对照指标跑 speedtest：goodput 持平 + 重传率减半 = 净赚；掉速就把数据贴出来往 `110/120` 试。

## 卸载

```bash
systemctl disable --now brutal-autolearn.timer brutal-cleanup.timer
rm /etc/systemd/system/brutal-autolearn.* /etc/systemd/system/brutal-cleanup.*
systemctl daemon-reload
brutalctl flush   # 清空内核规则（含路由），慎用：会把所有 brutal 下发连带删掉
rm -rf /var/lib/brutal-autolearn /var/log/brutal-autolearn.log /var/log/brutal-cleanup.log
```

## License

MIT，见 [LICENSE](LICENSE)。
