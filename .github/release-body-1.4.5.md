## 修复

- **跨机复现构建**：`tar` 增加 `--mode='u+rwX,go+rX,go-w'` 归一化权限。
  之前只固定排序、mtime、owner，文件权限仍跟随构建者 umask，外部验证者按 tag
  构建拿不到发布哈希。现在不同 umask 构建的 tarball 哈希一致。
- **Reality-only 安装不再被 smoke 误报**：HY2 是可选的。以前没装 HY2 时
  8 项 HY2 检查全 FAIL、结论“未通过”，看起来像安装坏了。现在检测到未安装就
  整体 SKIP 并说明；装了但服务/配置坏了仍然 FAIL。
- **快照校验补 units + geodata**：`meta.txt` 记录 `units_sha256` /
  `geodata_sha256`，恢复前校验。被篡改的 systemd unit 或 geodata 文件会像
  损坏的 config 一样被拒绝；旧快照没有这两行时打警告、仍可恢复。
- **BBR 状态不再自相矛盾**：`DSH bbr status` 拆成 `runtime` 与 `persist` 两行。
  运行时有 bbr/fq 但非 DSH 持久化时输出 “active now but NOT persisted by DSH”，
  不再在 `congestion: bbr` 下面写 “NOT effective”。退出码仍要求两者都满足。
- **注释同步**：`_check_port_443` 注释原写 “ss missing -> warn only”，与实际
  失败关闭的代码不符，已改正。

## 验证

本机：78 passed / 0 failed / 1 skipped，新增 4 个回归用例。

真机（Debian 12）：

| 项 | 结果 |
|---|---|
| 跨 umask 构建 | `umask 022` 与 `umask 077` 构建的 tar/installer 哈希完全一致 |
| Reality-only 安装 | `smoke-remote.sh`：6 PASS / 0 FAIL / 1 SKIP（HY2 未安装 → 跳过），结论通过 |
| 装 HY2 后 | 19 PASS / 0 FAIL / 1 SKIP，结论通过 |
| 篡改 unit 快照 | `snapshot systemd units SHA256 mismatch; refusing to restore`，服务未受影响 |
| 篡改 geodata 快照 | `snapshot geodata SHA256 mismatch; refusing to restore` |
| BBR 状态 | `runtime: ACTIVE` / `persist: ABSENT` / `result: ... NOT persisted by DSH`，退出码 1 |

## 安装

下载 `dsh-install-1.4.5.sh`，校验 `SHA256SUMS` 与 `SHA256SUMS.asc`
（指纹 `8E25C6FC8FA01719137FAAE6BC9AF5236E467872`）。
