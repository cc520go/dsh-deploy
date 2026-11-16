# Changelog

记录 DSH 脚本自身的版本；Xray 核心版本见 `VERSION`。

## 1.4.9 — 2026-11-16

基线：1.4.8（tag `v1.4.8`，源码提交 `0cc2459`）。按 1.4.9 修改文档修
6 高 + 4 中 + 1 个 1.4.8 回归，共 11 项。

### 高

- **H1 已装机器的版本参数被静默丢弃**：`install.sh` 收到与当前不同的版本参数
  时直接报错并指向 `DSH upgrade`（退出码非零），相同版本仍走原有的保留/修复
  路径，不再打印 “install state OK” 骗人。
- **H2 sshd 重启失败被吞**：`DSH auth` 关闭密码后必须确认 sshd 真的在运行
  （`systemctl is-active`），失败则恢复备份、明确报错，不打印“更改完成”、
  不启动回滚定时器。测试模式用 `XRAY_TEST_SSHD_RESTART=fail` 覆盖失败路径。
- **H3 回滚会删掉回滚目标**：拍 pre 快照前用 `SNAPSHOT_PROTECT` 保护点名快照，
  `snapshot_prune` 跳过它；4 个未标记快照时回滚最旧的那个不再自毁。
- **H4 drop-in 恢复路径写错**：改为恢复目录内容（先清空目标目录），不再产生
  `xray.service.d/xray.service.d/` 嵌套，也不再保留快照里没有的旧 drop-in；
  `verify_restored_state` 增加 unit 摘要校验，恢复后单元必须与快照一致。
- **H5 HY2 升级被自己占的 UDP 443 挡死**：preflight 改用进程归属判断
  （`hy2_listening`），HY2 自己监听时放行升级，其他进程占用仍拒绝；测试模式
  用 `XRAY_TEST_HY2_PORT_OWNER=self|other|none` 覆盖同一判断。
- **H6 新发布流程零校验**：`tools/release/publish-release.yml` 补齐
  `sha256sum -c`、GPG 指纹与验签、tag 必须已推送且按 tag 重建逐字节比对、
  checkout 钉 commit SHA；README 与 CHANGELOG 的说法与代码一致。

### 中

- **M1 host 从不校验**：新增 `validate_host`（IPv4 每段 0–255 或合法域名），
  在交互输入、`XRAY_NODE_HOST`、复用 params 三条来源汇合后统一校验，坏 host
  装到一半就停下，不再打印死链。
- **M2 改 SNI 后写 params 失败导致分叉**：params 先写临时文件，切换成功后再
  原子改名；改名失败调用 `abort_node_change` 把已切换的配置回滚，配置与
  params 不再一新一旧。测试用 `XRAY_TEST_PARAMS_RENAME_FAIL=1` 注入失败。
- **M3 卸载前快照失败被吞**：快照拍不成（磁盘满/不可写）直接中止卸载并明说
  没有删除任何东西，不再静默销毁唯一恢复手段。
- **M4 manage.sh 无 root 入口校验**：`main()` 入口统一 `require_root`，非 root
  在改动任何文件前就被拒绝。

### 1.4.8 回归

- **交互式安装必死**：`prompt_with_default` 的提示打到 stdout，被
  `$(...)` 捕获进变量值（`port=Port [443]: 443`）。提示改走 stderr，交互安装
  恢复正常；`maybe_install_hy2` 的 `[y/N]` 在 stdin 不是终端时改为跳过提示
  （不再无限阻塞）。

### 真机复测追加修复

- **H3 尾斜杠**：`snapshot_list` 输出带尾斜杠，而 CLI 传进来的目标路径没有，
  字符串比较不相等导致 `SNAPSHOT_PROTECT` 失效——真机上仍然删掉了回滚目标。
  现在比较前统一去掉尾部 `/`，真机复测：`retaining protected snapshot during
  prune` + `rollback complete`，目标存活。
- **H5 端口检测列号**：原来的 `ss -lun | awk '{print $5}'` 在 Debian 12 上取到的
  是对端地址，端口占用从未被检测到；改为直接匹配 `ss -ulpn` 的端口行再判进程
  归属。真机双向验证：HY2 自占时放行并升级成功，其他进程占 UDP 443 时明确拒绝。

### 测试

- 新增回归：`t_prompt_with_default`、`t_install_version_requires_upgrade`、
  `t_auth_requires_sshd_restart`、`t_manage_requires_root`、
  `t_rollback_protects_target`、`t_restore_dropin`、`t_host_validation`、
  `t_sni_params_atomic`、`t_uninstall_aborts_without_snapshot`、
  `t_hy2_preflight_own_port`。
- 全量：96 passed / 0 failed / 1 skipped（`t_archive_xray`，本机缺 `zip`）。
  与 1.4.8 的 86/0/1 对照：新增 10 项，全部有对应用例。
- 测试模式不再跳过 HY2 端口归属判断（H5）；仍无法在沙箱模拟的两条（真实
  sshd 重启、真实 HY2 升级）由真机验收覆盖。

## 1.4.8 — 2026-11-16

基线：1.4.7。按“发版前自查清单”逐项自查时发现并修复。

### 修复

- **P1 保留旧配置但缺 `node.params` 时误报安装成功**：`handle_already_installed`
  的保留分支用 `verify_listening "$(read_node_param port)"` 判断，端口为空时
  `verify_listening` 按“没有可校验的端口”返回 0，于是打印 `install state OK`
  ——节点既没有参数也拿不到链接。现在该分支先要求 `port` 存在，缺失直接失败，
  并提示从快照恢复或删配置重装。
- **P2 HY2 快照复制证书/私钥/unit 失败被吞**：这三项现在参与恢复校验，
  复制失败必须让快照创建失败，不能记成 `none`；同时删掉重复的一行证书复制。
- **P2 `node.params` 先按默认 umask 写再 chmod**：改为 umask 077 直接创建为
  0600，`chmod` 失败也硬失败（和 `render_config` 的处理一致）。

### 口径更正

- **配置权限**：写盘瞬间是 `0600`（umask 077 + 校验 + 原子 mv），安装完成后
  `migrate_permissions` 会改成官方布局 **`640 root:xray`**（xray 用户要读），
  之前“最终 600 root:root”的说法不准确，以 640 为准。

### 发布流程修正（可复现）

- **tag 打在“被构建的提交”上**：1.4.7 的 tag 打在加了 `dist/` 的发布提交上，
  而构建发生在它前面的修复提交，`SOURCE_DATE_EPOCH` 相差 405 秒——外部按 tag
  构建得到 `d921c3…`，与发布的 `85a8f8…` 不一致。从 1.4.8 起：先在源码提交上
  构建，tag 也打在该提交，`dist/` 只进发布分支。
- 发布工作流新增一步：按 tag 重新构建一次，与 `dist/` 里的 tarball 逐字节比对，
  不一致直接让 Release 失败。

### 测试

- 本机：86 passed / 0 failed / 1 skipped。
- 新增：`t_params_file_mode`（022 umask 下仍是 600）、
  `t_install_preserve_requires_params`（缺参数必须失败且不得打印 OK）。

## 1.4.7 — 2026-11-16

基线：1.4.6。按 1.4.6 闭环审查的 13 条修复 + 卸载非交互开关。

### 修复（P1）

- **Reality 私钥不再以 0644 落盘**：`render_config` 现在在目标目录里以
  umask 077 写临时文件、校验写入、`chmod 600` 后原子 `mv` 到位；写入失败
  （磁盘满/权限）直接报错，不再留下截断配置当成功。安装流程在 `mkdir` 之后
  立刻把配置目录设为 750，不再等后面的 `migrate_permissions`。
- **回滚“已验证”有了实义**：`snapshot_restore` 对 units/geodata 的复制由
  `|| true` 改为硬失败，full 模式缺 binary 直接拒绝；新增
  `verify_restored_state`，回滚后要比对“恢复的版本 == 快照记录的版本”，
  并确认节点端口在监听，才允许打印 “restored and verified”。
- **升级成功必须端口在听**：`upgrade_core` 在版本校验后调用
  `wait_for_listening`；`Type=simple` 进程启动即崩时不再报 “upgrade complete”，
  而是回滚并明确失败。

### 修复（P2）

- `daemon-reload` 失败由警告改为硬失败（旧 unit 不能继续当成功）。
- `XRAY_INSTALLER_SHA256` 改为经 `test_override` 门控：生产环境忽略并告警，
  环境变量不能再关闭安装器哈希校验。
- 权限审计真的检查 binary：`migrate_permissions` 设 755 root:root，
  `validate_permissions` 校验模式与属主（头注释与实际一致了）。
- 诊断不再硬编码 443：回环客户端与端口检查都读 `node.params` 的 port，
  非 443 端口安装不会被误判 FAIL。
- 快照 units/geodata 摘要改为各自独立校验：删掉一行不再能同时绕过两项。
- HY2 监听校验要求端口属于 `hysteria` 进程，别的进程占着 UDP 443 不会
  再被当成“已恢复并验证”。
- HY2 快照补 `cert_sha256` / `key_sha256` / `unit_sha256`，被改过的证书、
  私钥或 unit 拒绝恢复。
- 卸载失败即失败：HY2 未卸净、sysctl/logrotate 删不掉、`rm` 失败都会让
  `DSH uninstall` 返回非 0 并打印 `uninstall INCOMPLETE`，不再一律
  “uninstall complete”。
- 文档同步：`docs/ARCHITECTURE.md` 的快照 meta 字段补全。
- CI 依赖钉到 commit SHA：`actions/checkout`、`actions/upload-artifact`、
  `softprops/action-gh-release` 不再跟主版本浮标。

### 新增

- **`DSH uninstall --yes [--purge]`**：非交互 SSH 下不再挂在确认提示上；
  `--yes` 跳过确认、`--purge` 同时删状态目录。

### 测试

- 本机：84 passed / 0 failed / 1 skipped。
- 新增回归：`t_render_config_perms`、`t_installer_pin_gate`、
  `t_perm_binary_audit`、`t_diagnose_uses_node_port`、
  `t_upgrade_requires_listening`、`t_uninstall_args`，并扩展了
  `t_snapshot_units_geodata`（单行缺失绕过）与 HY2 快照用例
  （cert/key/unit 篡改）。
- 真机：见下方验证记录。

## 1.4.6 — 2026-11-15

基线：1.4.5。修 1.4.5 真机复核发现的一个测试/检测问题。

### 修复

- **smoke 的 HY2 检测新增 `HY2_UNIT_FILE` 覆盖**：`hy2_present` 之前把
  `/etc/systemd/system/hysteria-server.service` 写死，导致包内测试
  `t_smoke_reality_only` 在“真的装过 HY2”的机器上无法模拟 Reality-only
  （unit 文件还在），真机跑发布包自测会红。现在 unit 路径和其它 HY2 路径
  一样可覆盖，测试把 unit 也指到空目录，模拟才成立。
- 生产行为不变：unit 存在仍视为 HY2 已安装，装了但坏了继续 FAIL。

### 测试

- 本机：78 passed / 0 failed / 1 skipped。
- 真机（Debian 12，已装 HY2）：发布包解包后自测 78 passed / 0 failed /
  1 skipped（skip 为 `t_auth_timer_fail_closed`，机器有 `systemd-run` 时按设计跳过）。

## 1.4.5 — 2026-11-15

基线：1.4.4。按 1.4.4 闭环审查的 5 条修复，不新增功能。

### 修复

- **跨机复现构建**：`tar` 增加 `--mode='u+rwX,go+rX,go-w'` 归一化权限。
  之前只固定了排序、mtime、owner，文件权限仍跟随构建者的 umask，外部验证者
  按 tag 构建得不到发布哈希。现在不同 umask 构建出的 tarball 哈希一致。
- **Reality-only 安装不再被 smoke 误报为失败**：HY2 是可选的。以前没装 HY2
  时 8 项 HY2 检查全 FAIL、结论“未通过”，用户会以为安装坏了。现在检测到
  HY2 未安装就整体 SKIP 并说明是可选协议；装了但服务/配置坏了仍然 FAIL。
- **快照校验补 units + geodata**：`meta.txt` 记录 `units_sha256` /
  `geodata_sha256`（含文件名与目录树），恢复前一并校验；被篡改的 systemd
  unit 或 geodata 文件会像损坏的 config 一样被拒绝。1.4.5 之前的旧快照没有
  这两行时打警告并保持可恢复。
- **BBR 状态文案不再自相矛盾**：`DSH bbr status` 拆成 `runtime` 与 `persist`
  两行，分别报告“当前是否 bbr/fq”和“是否由 DSH 写进 sysctl（重启后仍在）”。
  运行时有 bbr/fq 但非 DSH 持久化时，输出“active now but NOT persisted by
  DSH”，不再在 `congestion: bbr` 下面写 “NOT effective”。退出码仍是只有
  两者都满足才为 0。
- **注释同步**：`_check_port_443` 上方注释原写 “ss missing -> warn only”，
  与实际失败关闭的代码不符，已改正。

### 测试

- 本机：78 passed / 0 failed / 1 skipped（缺 `zip` 的 `t_archive_xray`）。
- 新增回归：`t_build_reproducible_flags`、`t_smoke_reality_only`、
  `t_snapshot_units_geodata`、`t_bbr_status_semantics`。
- 真机（Debian 12）：跨 umask 构建哈希一致；Reality-only 安装 smoke 全 PASS
  + HY2 一项 SKIP；篡改 unit/geodata 的快照被拒绝恢复。

## 1.4.4 — 2026-11-15

基线：1.4.3。本版只修真机验收（清空 → 全新安装 → `smoke-remote.sh --full` →
全量测试）发现的两个问题。

### 修复

- **发布包缺 `CHANGELOG.md`**：`tools/build-release.sh` 的打包清单只带 README、
  LICENSE 等，漏了 CHANGELOG 和 CONTRIBUTING，导致**从发布包解包后自测**
  `t_release_identity` 直接失败（在 1.4.3 的 tarball 上实测复现）。现已打包，
  并加了一条看守：构建脚本必须包含 `CHANGELOG.md`。
- **HY2 恢复只验 `is-active`，不验端口**：真机上服务报 `active` 时 UDP 443
  还没绑定，恢复可能被判成“已验证”。现在恢复后轮询等待端口监听（最多 5 秒），
  绑不上就返回非 0 并输出 `未监听`，不再谎报。

### 测试

- 新增回归：`hy2_listening`（服务 active 但端口不监听时必须失败）、
  发布包自测（CHANGELOG 缺失即失败）。
- 真机验收（Debian 12，清空后全新安装）：
  - `smoke-remote.sh --full`：19 PASS / 0 FAIL / 1 SKIP（无 hysteria 客户端）
  - 发布包解包后全量测试：74 passed / 0 failed / 1 skipped
    （skip 为 `t_auth_timer_fail_closed`：机器有 `systemd-run` 时按设计跳过）
  - P0 修复实测：篡改快照 `SHA256 不符，拒绝恢复`、服务不受影响；缺 `meta.txt`
    拒绝；正常快照恢复成功且验证 active + 端口监听
- 本机：74 passed / 0 failed / 1 skipped；`shellcheck -S warning` 全树干净。

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
