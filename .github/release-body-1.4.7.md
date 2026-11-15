## 修复（3 条 P1）

- **Reality 私钥不再以 0644 落盘**：`render_config` 改为在目标目录里以
  umask 077 写临时文件、校验写入、`chmod 600` 后原子 `mv`；写失败（磁盘满/
  权限）直接报错，不再把截断配置当成功。安装流程在 `mkdir` 后立刻把配置目录
  设为 750，不再等后续 `migrate_permissions`。真机实测：渲染出的配置
  `600 root:root`。
- **回滚“已验证”有了实义**：`snapshot_restore` 对 units/geodata 的复制由
  `|| true` 改为硬失败，full 模式缺 binary 直接拒绝；新增
  `verify_restored_state`，回滚后比对“实际版本 == 快照记录版本”并确认端口
  在监听，才允许打印 “restored and verified”。
- **升级成功必须端口在听**：`upgrade_core` 在版本校验后调用
  `wait_for_listening`；`Type=simple` 进程启动即崩时不再报 “upgrade complete”，
  而是回滚并明确失败。

## 修复（10 条 P2）

- `daemon-reload` 失败改为硬失败（不会再用旧 unit 当成功）。
- `XRAY_INSTALLER_SHA256` 经 `test_override` 门控：生产环境忽略并告警，
  环境变量不能再关闭安装器哈希校验。
- 权限审计真的检查 binary（755 root:root），`migrate_permissions` 同步修复。
- 诊断不再硬编码 443：回环客户端与端口检查都读 `node.params` 的 port。
- 快照 units/geodata 摘要各自独立校验：删一行不再能同时绕过两项。
- HY2 监听校验要求端口属于 `hysteria` 进程。
- HY2 快照补 `cert_sha256` / `key_sha256` / `unit_sha256`，被改的证书/私钥/
  unit 拒绝恢复。
- 卸载失败即失败：HY2 未卸净、sysctl/logrotate 删除失败、`rm` 失败都会返回
  非 0 并打印 `uninstall INCOMPLETE`。
- `docs/ARCHITECTURE.md` 快照 meta 字段同步。
- CI 依赖钉到 commit SHA（checkout / upload-artifact / action-gh-release）。

## 新增

- **`DSH uninstall --yes [--purge]`**：非交互 SSH 下不再挂在确认提示上。

## 验证

- 本机与真机（Debian 12）：**84 passed / 0 failed / 1 skipped**；发布包解包后
  自测同样 84/0/1。
- 真机 `smoke-remote.sh --full`：19 PASS / 0 FAIL / 1 SKIP。
- 真机实测：渲染配置 `600 root:root`；篡改 HY2 快照证书 → `cert.pem SHA256
  不符，拒绝恢复`，服务不受影响；正常快照恢复 → 验证 active + 端口监听；
  xray 备份/回滚 → `rollback complete` 且版本一致；`DSH uninstall --yes`
  非交互退出码 0、无挂起、环境清空。
- 跨 umask 构建（022 / 077）哈希一致；`SHA256SUMS` 全 OK、验签 Good。
- 新增 6 个回归用例，并扩展快照与 HY2 快照用例。

## 安装

下载 `dsh-install-1.4.7.sh`，校验 `SHA256SUMS` 与 `SHA256SUMS.asc`
（指纹 `8E25C6FC8FA01719137FAAE6BC9AF5236E467872`）。
