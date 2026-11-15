## 修复

- `snapshot_restore` 恢复前校验 `meta.txt` 的 binary/config SHA256，损坏快照拒绝恢复。
- `rollback_node_config` / `repair_rollback` / `upgrade_core` / `rollback_core` 验证恢复结果并诚实上报；失败输出 `ROLLBACK FAILED`。
- 撤下 `cloudpc-setup.sh`（root 密码登录 / 自动放行 22 / curl|sh / 未校验 Node / 预发布 DSH）。
- HY2 配置测试临时文件改为 750/640/600（root:hysteria）。
- `DSH_MIRROR_BASE` / `DSH_BASE_URL` 强制 https 或 file；http 需显式 `DSH_ALLOW_INSECURE_MIRROR=1`。
- 移除核心版本硬编码兜底；`lisa-auth-rollback` 改名 `dsh-auth-rollback`。

## 安装

下载 `dsh-install-1.4.2.sh`，校验 `SHA256SUMS` 与 `SHA256SUMS.asc`（指纹 `8E25C6FC8FA01719137FAAE6BC9AF5236E467872`）。
