# Changelog

记录 DSH 脚本自身的版本；Xray 核心版本见 `VERSION`。

## 1.1.0 — 2026-11-07

### 变更

- 运行时路径收尾改名：
  - 工具目录 `/usr/local/share/xray-reality-manager` → `/usr/local/share/dsh`
  - 状态目录 `/root/.xray-reality-manager` → `/root/.dsh-deploy`
  - logrotate 配置 → `/etc/logrotate.d/dsh`
- 升级时先复制并校验 `node.params`，再切换；旧状态目录保留为软链一个版本（1.2.0 移除）。
  旧工具目录打包到 `/root/dsh-legacy-tool-*.tar.gz` 后删除，避免两份代码并存。
- HY2 生成的配置署名与 systemd `Description`、出口 IP 查询的 User-Agent、
  `DSH diag` 标题改为 DSH；不重启 HY2 只为改一行注释。
- `docs/ARCHITECTURE.md` 增加新路径说明；`docs/NAMING-MIGRATION.md` 记录迁移方案。

## 1.0.1 — 2026-11-07

### 修复

- 菜单 12 首次启用 BBR 时误报“内核没有可用的 tcp_bbr”：现在会先尝试
  `modprobe tcp_bbr` 再判断，不再需要手工加载模块。
- 构建脚本拒绝“命令行版本 ≠ `DSH_VERSION` 文件”的调用，避免打出文件名
  1.0.1、安装后却显示 1.0.0 的包。
- 测试 `t_hy2_link_and_guard` 不再在 `/tmp` 留下临时目录。

### 优化

- Xray / HY2 快照对相同 `binary_sha256` 复用旧快照的二进制（硬链接），
  后续同版本快照不再重复占 35MB / 24MB；恢复路径改为先 unlink 再写，
  快照不会被就地覆盖。
- 菜单新增 **21 卸载整机**，与菜单 14 的“卸载 HY2”区分。
- `install_lisa_launcher` 更名为 `install_launcher`，注释同步为 DSH。

### 文档

- 发布签名密钥轮换：旧私钥已删除，1.0.1 起使用新公钥（指纹
  `8E25C6FC8FA01719137FAAE6BC9AF5236E467872`）；旧公钥保留为
  `docs/dsh-signing-key-1.0.0.asc`，用于验证 1.0.0 及更早版本。
- 新增 `docs/ARCHITECTURE.md`、`CONTRIBUTING.md`、本文件。
- README 的推荐渠道改为 GitHub Release；镜像站标注为可能离线的可选加速节点。
- `docs/TODO.md` 修正失效的安装器文件名。

## 1.0.0 — 2026-11-07

- 首个正式版，核心 Xray 26.10.31。
- VLESS + Reality 主线，Hysteria2 可选附加协议。
- 官方内核 BBR+FQ（菜单 12）、HY2 伪装地址（菜单 20）、一键体检（菜单 19）。
- 快照/回滚、节点参数修改、GPG 签名发布。
