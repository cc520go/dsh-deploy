# Changelog

记录 DSH 脚本自身的版本；Xray 核心版本见 `VERSION`。

## 1.4.3 — 2026-11-15

基线：1.4.2（`f997a92`）。本版只修 1.4.2 全量复审发现的问题，不新增功能。

### 修复（P0/P1）

- **HY2 恢复不再谎报成功**：`hy2_snapshot_restore` 恢复前校验 `meta.txt` 的
  `binary_sha256` / `config_sha256`，缺失、损坏、不符一律拒绝恢复；恢复后
  校验服务状态，服务没起来就返回非 0。升级、轮换证书、改伪装域名、菜单恢复
  的 8 处调用改用 `hy2_rollback_after_failure`，失败时明确输出
  `HY2 ROLLBACK FAILED` / “HY2 节点可能仍是坏的”，不再打“已从快照恢复”。
- **快照包含 node.params**：`snapshot_create` 一起备份 `node.params`，
  `meta.txt` 记录 `params_sha256`，`snapshot_restore full` 一起还原并校验。
  1.4.2 的菜单回滚只还原配置不还原参数，会导致分享链接和实际配置脱节。
  1.4.3 之前的旧快照仍可恢复（meta 无 params 行时打警告）。
- **sshd 认证回滚不再吞错**：`cmd_auth_rollback` 与菜单 1 的恢复分支改用
  `_sshd_restore_all`，备份缺失或复制失败返回非 0 并输出错误；恢复后重跑
  `sshd -t`，失败同样上报，状态记为 `rolled_back_failed`，下次进菜单 1 会提示。
- **10 分钟回滚定时器失败即报错**：`auth_timer_start` 在状态文件写失败、
  `systemd-run` 缺失或失败时返回非 0，并提示“自动回滚不可用，需手动
  `DSH auth-rollback`”，调用点按失败处理，不再静默降级。
- **公开仓库/发布包不再泄露 live 服务器信息**：`docs/TODO.md` 删掉 IP、
  SSH 端口和“给我密码”一类表述（`docs/` 会进 tarball）。
- **smoke-remote.sh 进签名清单**：`SHA256SUMS` 现在覆盖体检脚本，之前它是
  Release 里唯一不受校验的资产。

### 改进

- **构建可复现**：`tools/build-release.sh` 用
  `tar --sort=name --mtime=@SOURCE_DATE_EPOCH --owner=0 --group=0 --numeric-owner`
  加 `gzip -n`，同一提交两次构建哈希一致。
- **下载不再无限期挂住**：`download_file` 的 curl 加
  `--connect-timeout/--max-time`，wget 加超时重试；GitHub API 查询同样加超时。
- **版本号不再硬编码**：查询 Xray 最新版的 User-Agent 改用
  `dsh_release_version`（原来写死 `DSH/1.1`）；`t_release_identity` 现在也查
  代号、横幅插值和残留的 `DSH/1.x` User-Agent。
- **摘要要求放宽到安全相关项**：`.dgst` 只强制 `SHA256`/`SHA512`；MD5/SHA1
  存在就校验，缺失不再让安装硬失败。
- **测试套件不再依赖宿主 systemd**：测试模式下 `env_check` 不再要求真实
  `systemctl`，`t_env_check_debian12` / `t_install_completion` 在任何环境都能跑
  （CI 不用再 `SKIP_ENV_TESTS=1` 遮蔽它们）。
- **端口 443 检查失败关闭**：没有 `ss` 时不再静默放行，而是报错让用户装
  iproute2。
- **双栈机 IP 检测**：`fetch_one_ip` 加 `-4`，第三路源改用
  `ipv4.icanhazip.com`，修掉 686 双栈机只拿到一个有效源、被标“未验证”的 bug。
- **诊断环回不再误判**：本机没有出网时，环回 Reality 测试报 SKIP 而不是 FAIL。
- **硬链接复用复核哈希**：`snapshot_link_previous` 链接后校验文件哈希，避免把
  旧快照里的损坏文件带进新快照。
- **HY2 增加 known-good**：`hy2_snapshot_prune` 跳过标记为 known-good 的快照，
  安装/恢复验证通过后标记，避免最后一张好快照被新快照顶掉。
- **菜单文案**：菜单 7 明确写“新 Reality SNI（会同时改 dest）”，菜单 20 注释
  的编号改对。
- **CI**：权限按作业分配（测试作业 `contents/statuses: write`，复验作业只读）；
  shellcheck 提升到 warning 级；新增 `verify-release` 作业，每次 push 都从
  Release 下载全部资产、验签并逐个对哈希。
- 删除死配置 `XRAY_INSTALLER_URL`（总是被镜像/钉死提交覆盖，改了也没用）。

### 不在本版范围（如实说明）

- HY2 配置测试仍是“前台跑 6 秒 + 日志关键字”，没有真实 QUIC 握手探活
  （需要 hysteria 客户端二进制，测试要联网下载，会破坏沙盒封闭性）。
- `snapshot_verify_meta` 仍只校验 binary/config/params，units 与 geodata
  没有纳入哈希。
- 云电脑脚本（`cloudpc-setup.sh`）仍未重写，按原计划另开分支。

### 测试

- 本机：74 passed, 0 failed, 1 skipped（缺 `zip` 的 `t_archive_xray`）。
- 新增回归：`t_hy2_snapshot_restore_verified`、`t_hy2_rollback_honest_failure`、
  `t_snapshot_params_roundtrip`、`t_snapshot_legacy_meta`、
  `t_auth_rollback_honest_failure`、`t_auth_timer_fail_closed`。
- `shellcheck -S warning` 全树干净；`bash -n` 全部通过。

## 1.4.2 — 2026-11-15

### 修复

- **回滚/恢复可验证**：`snapshot_restore` 恢复前对照 `meta.txt` 校验
  `binary_sha256` / `config_sha256`，缺失、损坏或不符一律拒绝恢复并返回非 0。
- **回滚诚实上报**：`rollback_node_config`、`repair_rollback`、`upgrade_core`
  及 `rollback_core` 的恢复路径现在校验权限迁移、配置测试和服务重启；
  恢复失败时明确输出 `ROLLBACK FAILED` / “node may still be faulty”，
  不再断言“previous state restored”。新增损坏快照、恢复失败和成功路径回归测试。
- **撤下 `cloudpc-setup.sh`**：该脚本开 root 密码登录、自动放行 22、
  使用 `curl | sh`、不校验 Node 包并安装预发布 DSH，与仓库安全原则冲突；
  需要云电脑脚本时另开分支按密钥登录、手动防火墙、哈希校验和正式版重写。
- **HY2 配置测试临时文件降权**：临时目录 750 root:hysteria、配置 640
  root:hysteria、日志 600 root，避免测试窗口内明文密码被本机其他用户读取。
- **镜像协议强制**：`DSH_MIRROR_BASE` / `DSH_BASE_URL` 只接受 `https://`
  或 `file://`；`http://` 默认拒绝， trusted LAN 必须显式设置
  `DSH_ALLOW_INSECURE_MIRROR=1` 并会打印警告。
- **版本号单一来源**：移除 `default_version` 的硬编码核心版本兜底；
  `VERSION` 缺失时直接报错，不再静默使用旧值。
- **认证回滚单元改名**：`lisa-auth-rollback` → `dsh-auth-rollback`，
  取消时顺带停掉旧单元，避免升级后旧定时器回滚过期 sshd 备份。
- 文档同步：README 版本、CHANGELOG、TODO；`cloudpc-setup.sh` 不再出现在仓库。

### 变更

- 取消官方国内镜像：删除 `tools/mirror/`、README 的镜像安装方式，
  构建产物不再生成 `index.html`；686 不再提供 nginx / `/srv/dsh/dist`。
  GitHub Release 成为唯一发布渠道；国内连不上 GitHub 时用离线单文件安装。
- 安装器的 `DSH_MIRROR_BASE` 代码能力保留，仅供自建镜像使用，不再承诺维护。

## 1.4.1 — 2026-11-08

### 修复

- 菜单 21 卸载顺序与清理范围：先卸载 HY2（服务、二进制、配置、证书），
  再通过官方安装器卸载 Xray；随后清理 `DSH`/`lisa` 启动器、工具目录
  `/usr/local/share/dsh`、每日体检定时器、`/etc/logrotate.d/dsh`，以及
  BBR、UDP 的 sysctl 文件（运行时尽量回到 `cubic`/`fq_codel`）。
- 快照（`xray-backup-*`、`hy2-backup-*`）与 `node.params` 默认一律保留；
  purge 额外删除状态目录 `/root/.dsh-deploy`（node.params、BBR 备份），
  官方安装器的 `remove --purge` 仍按原语义删除 Xray 配置目录，快照不删。
- HY2 卸载新增 `--yes`（菜单 21 已确认）与 `--keep-snapshots`（快照保留、
  不再二次询问），部分安装或非本项目创建的 `/etc/hysteria` 不会阻塞 Xray 卸载。
- 新增回归测试 `t_uninstall_menu21`，覆盖保留与 purge 两条路径。

## 1.4.0 — 2026-11-08

### 新增

- 菜单 20 改为“自定义伪装域名（SNI）”：持久化域名、重签 HY2 证书、
  重启服务并重新生成客户端链接；旧链接因 pin 变化失效。
- 删除旧的菜单 20 masquerade 交互（探针伪装网站仍在安装时写默认值）。

## 1.3.0 — 2026-11-08

### 新增

- 国内镜像支持：设置 `DSH_MIRROR_BASE` 后，Xray 核心 zip/.dgst、官方
  `install-release.sh`、Hysteria2 二进制全部从镜像获取，原有 SHA256 校验不变。
- `env_check` 在镜像模式下检查镜像可达性，不再要求能连 GitHub。
- 新增 `tools/dsh-bootstrap.sh` 一键入口：自动装依赖、验签、校验安装器哈希。

## 1.2.0 — 2026-11-07

### 变更

- 移除 1.1.0 的旧状态目录兼容软链：`migrate_legacy_state` 迁移校验后直接删除
  `/root/.xray-reality-manager`，不再创建软链；1.1.0 留下的软链在升级时被清理。
- 认证回滚状态与 `smoke-remote.sh` 不再回退旧路径。
- 停止跟踪 `dist/` 构建产物（`.gitignore`），发布只走 GitHub Release 与镜像；
  仓库里不再出现版本落后的安装包。

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
