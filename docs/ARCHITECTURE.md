# 架构说明

本文只讲“为什么这样设计”。安装与命令用法见 [README](../README.md)。

## 组件

| 文件 | 职责 |
|---|---|
| `install.sh` | 环境检查、装核心（调用 XTLS 官方安装器）、渲染配置、装启动器 |
| `manage.sh` | 菜单与 CLI 入口，参数解析后调用 `lib/` |
| `lib/download.sh` | 下载核心 zip、`.dgst` 校验、官方安装器 pin |
| `lib/backup.sh` | Xray 快照：创建、列表、known-good、剪枝、恢复 |
| `lib/hy2.sh` | Hysteria2 附加协议：安装、证书、链接、伪装地址、快照 |
| `lib/node.sh` | 节点参数渲染与变更（SNI、Vision、链接） |
| `lib/bbr.sh` | 官方内核 BBR+FQ（只写 sysctl，不装内核） |
| `lib/perm.sh` | 配置/日志权限迁移 |
| `lib/service.sh` | systemd 服务封装 |
| `diagnose.sh` | 只读体检（菜单 19 / `DSH diag`） |
| `tools/smoke-remote.sh` | 装后自检清单（`DSH smoke`） |

## 双协议

- **主线**：VLESS + Reality，Xray 监听 TCP 443。
- **附加**：Hysteria2，独立进程监听 UDP 443，证书自签。
- 两者互不改配置：HY2 的安装/卸载不会碰 Xray 的 `config.json`、systemd unit 或分享链接。
- 因此云安全组必须同时放行 **TCP 443 和 UDP 443**；只开 TCP 时主线可用，HY2 不可用。

## 版本策略

三个根目录文件各管一件事，运行时都会读：

| 文件 | 示例 | 含义 | 发版时 |
|---|---|---|---|
| `VERSION` | `26.10.31` | Xray 核心版本（钉死） | 升级核心时才改 |
| `DSH_VERSION` | `1.0.1` | DSH 脚本自身版本 | 每次发版必改 |
| `DSH_CODENAME` | `鲸潮` | 版本代号 | 换代号时改 |

核心版本不自动跟随上游：`DSH check-update` 只报告，升级要显式执行 `DSH upgrade`，升级前自动快照。
`tools/build-release.sh` 会拒绝“命令行版本参数 ≠ `DSH_VERSION` 文件”的构建，避免文件名与安装后版本不一致。

## 快照与回滚

- Xray 快照在 `/root/xray-backup-<时间>-<核心版本>/`，HY2 在 `/root/hy2-backup-…`。
- 每个快照写 `meta.txt`，记录 `version`、`binary_sha256`、`config_sha256`。
- 同一 `binary_sha256` 的后续快照**硬链接旧快照的二进制**，不再复制 35MB/24MB；运行中的文件永远不参与链接。
- 恢复时先 unlink 目标再拷贝（`cp --remove-destination` / `install`），保证不会写穿共享 inode。
- Xray 默认保留 3 个快照 + 1 个 known-good；HY2 保留 5 个。

## 伪装地址

HY2 的 `masquerade` 只影响未通过认证的 HTTP/3 探针，不影响隧道与客户端链接。只接受
`https://` 公网地址；私网、本机、带凭据的 URL 会被拒绝。

## 权限与路径

- 配置目录 `/usr/local/etc/xray`：`750 root:xray`，`config.json` `640 root:xray`。
- 日志 `/var/log/xray`：`700 xray:xray`。
- 工具安装目录 `/usr/local/share/xray-reality-manager`：历史名字，保留是为了已装机器平滑升级；
  改名需要带迁移，不能直接换常量。
- 状态目录 `/root/.xray-reality-manager`：同样是历史名字，存 BBR 备份与节点参数。

## 发布

源码在 GitHub；构建产物由 `tools/build-release.sh` 生成到 `dist/`，用离线私钥签名后发布。
镜像站只是可选加速节点，正式渠道是 GitHub Release。详见 [CONTRIBUTING](../CONTRIBUTING.md)。
