# DSH 一键部署 · Reality + Hysteria2

[![CI](https://github.com/cc520go/dsh-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/cc520go/dsh-deploy/actions/workflows/ci.yml)

Debian 12 专用的一键部署脚本。主线是 **VLESS + Reality（TCP 443）**，另可加装
**Hysteria2（UDP 443）** 作为第二个协议。两条协议、两个服务、两个端口，互不干扰：
Reality 走 TCP 适合下载和大流量，Hysteria2 走 UDP 适合语音、视频通话这类实时流量。

当前版本：**DSH 1.4.1「鲸潮」**，核心 **Xray 26.10.31**。脚本版本与核心版本分开，发布物统一为 `dsh-*` 命名；旧的 `lisa-install.sh` 只保留兼容别名。

一条命令装完，之后所有操作都在菜单里，不需要记命令、也不需要 AI 在旁边。

---

## 一分钟安装

服务器：Debian 12，root 权限。

> 最小化系统可能没装 `curl` / `gnupg`（下载和验签要用）：
> `apt-get update && apt-get install -y curl gnupg`

> **发布渠道：以 GitHub Release 为准。** 镜像站 `http://64.205.110.102/`
> 是测试机上的可选加速节点，可能随测试机重置而离线；镜像不可用时直接用
> GitHub Release，不要把它当唯一入口。

**方式零：一条命令（全新 Debian 12，root）**

```bash
apt-get -o DPkg::Lock::Timeout=600 update && apt-get -o DPkg::Lock::Timeout=600 install -y curl ca-certificates && curl -fsSL https://raw.githubusercontent.com/cc520go/dsh-deploy/main/tools/dsh-bootstrap.sh -o /tmp/dsh-bootstrap.sh && bash /tmp/dsh-bootstrap.sh
```

脚本会自动补 `gnupg`、校验 GPG 签名与安装器 SHA256，再执行 `--auto --with-hy2`。
`DPkg::Lock::Timeout` 用来等全新机器开机时的后台 apt（cloud-init / unattended-upgrades）。

**方式一：GitHub Release（推荐，稳定）**

```bash
base=https://github.com/cc520go/dsh-deploy/releases/latest/download
curl -fsSLO "$base/SHA256SUMS"
curl -fsSLO "$base/SHA256SUMS.asc"
curl -fsSLO "$base/dsh-signing-key.asc"
# 从签名清单里取当前版本，下次发版不用改这行
installer="$(awk '/  dsh-install-[0-9]+\.[0-9]+\.[0-9]+\.sh$/{print $2; exit}' SHA256SUMS)"
test -n "$installer" || { echo "SHA256SUMS 里找不到安装器"; exit 1; }
curl -fsSLO "$base/$installer"
gpg --import dsh-signing-key.asc
gpg --verify SHA256SUMS.asc SHA256SUMS && sha256sum -c SHA256SUMS --ignore-missing
bash "$installer" --auto --with-hy2
```

**方式二：国内镜像（可选加速，可能离线）**

```bash
curl -fsSL http://64.205.110.102/dsh-install.sh -o /tmp/dsh-install.sh
sha256sum /tmp/dsh-install.sh          # 对比 SHA256SUMS
DSH_MIRROR_BASE=http://64.205.110.102 bash /tmp/dsh-install.sh --auto --with-hy2
```

`DSH_MIRROR_BASE` 让 Xray 核心 zip、官方 `install-release.sh` 和 HY2 二进制也走镜像；
不设置它时，这三样仍从 GitHub 下载（国内常连不上）。

也可以走带验签的 bootstrap（只设 `DSH_BASE_URL`，它会自动把同一地址用作
`DSH_MIRROR_BASE`）：

```bash
curl -fsSL http://64.205.110.102/dsh-bootstrap.sh -o /tmp/dsh-bootstrap.sh
DSH_BASE_URL=http://64.205.110.102 bash /tmp/dsh-bootstrap.sh
```

**方式三：从源码安装（服务器能访问 GitHub）**

```bash
git clone https://github.com/cc520go/dsh-deploy.git /tmp/dsh && cd /tmp/dsh && bash install.sh --auto --with-hy2
```

**方式四：离线单文件（完全离线）**

把 `dsh-install-<DSH版本>.sh`（Release 附件）用 WinSCP / scp / 面板文件管理器上传，然后：

```bash
sha256sum dsh-install-1.4.1.sh          # 与 SHA256SUMS 对比
bash dsh-install-1.4.1.sh --auto --with-hy2
```

### 验证发布物（推荐，30 秒）

发布物用 GPG 分离签名，公钥在 `docs/dsh-signing-key.asc`（指纹
`8E25C6FC8FA01719137FAAE6BC9AF5236E467872`）。一次性导入公钥后，每次发布都能自动验。

> 2026-11-07 密钥轮换：旧私钥已删除，1.0.1 起使用新公钥。验证 1.0.0 及更早的发布物，
> 请用 `docs/dsh-signing-key-1.0.0.asc`（旧指纹 `63AEB2BD09A2458B54D7AB1E7F938C08CA8E68D6`）。

```bash
# 一次性：导入公钥
gpg --import dsh-signing-key.asc

# 每次发布：验签 + 比对哈希（任一失败就不要执行）
gpg --verify SHA256SUMS.asc SHA256SUMS && sha256sum -c SHA256SUMS --ignore-missing
```

验签通过说明发布物确实由本项目的私钥签出、且内容未被改动；篡改任何一个字节，
`gpg --verify` 会直接报 `BAD signature`。

常用的参数：

| 参数 | 作用 |
|---|---|
| `--auto` | 全自动：自动探测公网 IP、全部用默认值 |
| `--with-hy2` | 同时安装 Hysteria2 附加协议 |
| `--check` | 只做环境检查，不安装 |
| `--repair` | 允许在 `--auto` 下修复已损坏的配置（先快照） |

---

## 装完是什么样

| 项目 | 值 |
|---|---|
| 主线 | VLESS + Vision + Reality，TCP 443，Xray 26.10.31 |
| 附加协议 | Hysteria2 2.13.0（官方二进制），UDP 443，画像 A（无混淆 + masquerade） |
| 声明带宽 | 上传 50 Mbps / 下载 250 Mbps（钉死，不做菜单项） |
| 证书 | 自签 EC P-256，100 年，SAN = 公网 IP + SNI |
| 客户端 | V2rayNG，Reality 用 vless 链接，HY2 用 hysteria2 链接（十六进制指纹） |
| 服务 | `xray.service`、`hysteria-server.service`，都已 enable |
| 网络调优 | 安装 HY2 时把 UDP 缓冲调到 16MB（实测多流中位数 168→185 Mbps），写在 `/etc/sysctl.d/99-dsh-udp.conf` |
| 自动巡检 | `dsh-smoke.timer` 每天跑一次体检，结果追加到 `/var/log/dsh-smoke.log` |
| 文档 | 链接只在你主动选「查看链接」时打印，不写日志 |

---

## 菜单（输入 `DSH`）

```
  系统
   1 认证方式      2 核心版本
   3 检查更新      4 升级核心
   5 回滚快照      6 备份快照
   7 节点配置      8 通用链接
  运维
   9 状态检查     10 线路诊断
  11 查看日志     12 BBR+FQ
  21 卸载整机
  Hysteria2（附加协议）
  13 安装/升级    14 卸载
  15 查看链接     16 状态/重启
  17 日志         18 轮换证书
  19 一键体检     20 自定义伪装域名
```

- **12 BBR+FQ**：只对官方内核设置 `congestion=bbr` + `qdisc=fq`，立即生效并持久化；不安装第三方内核、不重启、不改 Xray。
- **21 卸载整机**：先卸 HY2（服务、二进制、配置、证书），再走官方安装器卸 Xray；随后清理启动器、工具目录、每日体检定时器、logrotate 规则和 BBR/UDP sysctl。
  快照（`xray-backup-*`、`hy2-backup-*`）和 `node.params` 默认保留；只有连续三次确认的 purge 才删状态目录 `/root/.dsh-deploy`，并按官方 `--purge` 语义删除 Xray 配置目录。
- **13 安装/升级**：没装就是全新安装；已装就是自定义升级（输版本号 → 快照 → 校验 → 配置测试 → 重启，失败自动回滚）。
- **14 卸载**：只删 HY2 自己的东西，主线不动；会问一次要不要删快照。
- **15 查看链接**：打印 V2rayNG 链接并写入 `/root/.hy2-client/v2rayng.txt`（600）。
- **16 状态/重启**：看状态、监听端口、journal 尾部，只重启 HY2。
- **17 日志**：读 journal，默认级别 info。
- **18 轮换证书**：换新证书 → 重启 → 出新链接。**所有客户端都要重导**。
- **19 一键体检**：直接跑 `smoke-remote.sh` 的标准清单，给出 PASS/FAIL 结论；等价于 `DSH smoke`。
- **20 自定义伪装域名**：修改 HY2 的 TLS SNI，重签证书并重新生成客户端链接；旧链接因 pin 变化失效。
  `masquerade` 探针站点已不再进菜单，只保留安装默认值。

**升级永远是手动评估，脚本不会自动升级。** 平时刻意留在钉死版本上，
只有安全修复、客户端连不上新版、或确实需要新功能时，才在菜单 13 里输版本号主动升。

直接用命令（脚本化 / 排障用）：

```bash
DSH bbr enable|status|version|clear
DSH hy2 install|uninstall|link|status|logs|rotate-cert|masquerade|restore|snapshot
DSH hy2 masquerade show|set|reset
DSH status | version | check-update | backup | diag | logs | share
```

---

## 自建镜像

GitHub 在国内经常连不上，可以在自己的机器上放一份静态镜像：

```bash
curl -fsSL http://<你的地址>/dsh-install.sh -o /tmp/dsh-install.sh
sha256sum /tmp/dsh-install.sh
bash /tmp/dsh-install.sh --auto --with-hy2
```

部署方法见 `tools/mirror/README.md`（nginx，只提供 GET/HEAD，不含任何凭据）。

## 客户端怎么连

1. 服务器上 `DSH` → `15 查看链接`，复制 `hysteria2://…`；`8 通用链接` 给出 `vless://…`。
2. 手机 V2rayNG → 右上 `+` → 从剪贴板导入。
3. 平时挂 **Reality**（快、稳、大流量）；要打语音/视频通话时切到 **HY2**（UDP，不被 TCP 队头阻塞拖死），打完再切回来。

注意：Android 同时只能开一个 VPN，两个协议**不能同时**用，切换是手动的。

---

## 验收：一条命令给出结论

`tools/smoke-remote.sh` 在服务器上跑，只读、不改任何东西：

```bash
bash smoke-remote.sh          # 标准清单
bash smoke-remote.sh --full   # 追加反向测试（需要 hysteria 客户端二进制）
```

输出是 `PASS / FAIL / SKIP` 逐条清单，最后一行给结论，退出码 0 才算通过。
这套清单就是「稳定」的定义：**任何一项 FAIL，都不算装好。**

---

## 安全边界（实测结论，不是设计承诺）

| 场景 | 期望 | 实测 |
|---|---|---|
| 正确凭据 | 通 | ✅ 端到端取到出口 IP |
| 错密码 | 连不上 | ✅ 服务端拒绝 |
| 错 `pinSHA256` | 连不上 | ✅ V2rayNG 侧验：服务端零记录，TLS 阶段就被拒 |
| 云安全组没放 UDP 443 | 服务端自检仍显示「未验证」 | ✅ 自检不会假装成功 |

已知限制：

- 官方 hysteria 客户端**不认** `pinSHA256`，所以指纹校验只能在 V2rayNG 侧验证；`smoke --full` 里这条会显示 SKIP，而不是伪造成 PASS。
- Hysteria2 的日志没有文件可轮转，安装时会写一个 journald 上限（`SystemMaxUse=200M`），除非你已经自己设过。
- 快照包含明文凭据（私钥、密码），目录 700、文件 600、只留最近 5 个，永不自动上传。
- 上游 release 没有 GPG 签名，SHA256 pin 防不了官方投毒，只能防下载损坏和镜像替换。

---

## 常见问题

**Q：安装报 `apt is locked`？**
脚本会自己等（最多 300 秒）并重试 3 次。如果最终仍失败，说明系统还有别的 apt 进程在跑，
等它结束再重跑安装即可。**不要删锁文件。**

**Q：HY2 服务是 active，但手机连不上？**
先看云厂商安全组的 **UDP 443** 有没有放行（本机防火墙脚本只提醒、不自动改）。
再用 `DSH` → `16` 看监听端口，确认服务端在听。

**Q：怎么确认脚本没动我的主线？**
HY2 的所有操作只碰自己的二进制、配置、证书、单元和快照。主线节点、`xray.service`、
logrotate、sysctl 一律不碰。`smoke-remote.sh` 里也把「xray active / TCP 443 监听」列进了必检项。

**Q：忘了链接怎么办？**
`DSH` → `15` 重新打印（会同时刷新客户端文件）。

**Q：能装在 Debian 13 或 Ubuntu 上吗？**
不能。脚本只支持 Debian 12，环境检查会直接拒绝。

---

## 仓库结构

```
install.sh              一键安装（Reality + 可选 HY2）
manage.sh               菜单与直接命令（入口 DSH）
diagnose.sh             诊断
lib/common.sh           日志、路径、服务、启动器
lib/hy2.sh              Hysteria2 附加协议（安装/卸载/链接/状态/轮换）
lib/backup.sh lib/node.sh lib/service.sh lib/download.sh lib/perm.sh lib/bbr.sh
versions-hy2.conf       钉死的 hysteria 版本与 per-arch SHA256
docs/                   交接与待办（TODO.md）、发布公钥
tools/build-release.sh  打发布物（tar.gz + 单文件安装器 + SHA256SUMS）
tools/smoke-remote.sh   验收清单
tests/run_tests.sh      测试套件（沙箱内跑，不碰真机）
```

## 待办与交接

见 [`docs/TODO.md`](docs/TODO.md)：待办事项、新机器上线的步骤、已知限制。

## 开发

```bash
bash tests/run_tests.sh          # 测试（沙箱，安全）
bash tools/build-release.sh      # 产出 dist/ + SHA256SUMS
```

测试里有几项跟 Debian 12 强绑定（内核/系统检查），在 Ubuntu 等机器上跑会出现预期失败，
这是环境差异，不是回归。
