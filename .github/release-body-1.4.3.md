## 修复（回滚诚实性）

- **HY2 恢复不再谎报成功**：恢复前校验 `meta.txt` 的 `binary_sha256` /
  `config_sha256`，不符、缺失、损坏一律拒绝；恢复后校验服务状态，没起来就报
  `HY2 ROLLBACK FAILED`。升级 / 轮换证书 / 改伪装域名 / 菜单恢复共 8 处调用
  都改成这个路径。
- **快照补上 `node.params`**：回滚后分享链接不再和实际配置脱节；`meta.txt`
  记录 `params_sha256`，篡改拒绝恢复，旧快照仍可恢复。
- **sshd 认证回滚失败即报**：备份缺失、复制失败、恢复后 `sshd -t` 失败都返回
  非 0，状态标记 `rolled_back_failed`，下次进菜单 1 会提示。
- **10 分钟回滚定时器**：立不起来（状态文件写失败 / `systemd-run` 不可用）就
  当失败上报，并提示手动 `DSH auth-rollback`。

## 修复（发布链与安全）

- `smoke-remote.sh` 进 `SHA256SUMS`，它是 Release 里最后一个未受校验的资产。
- 构建可复现：固定排序、owner、mtime 与 `gzip -n`，同提交两次构建哈希一致。
- 下载加 `--connect-timeout/--max-time`，不再无限期挂住安装。
- `docs/TODO.md` 删除 live 服务器 IP、SSH 端口和凭据表述（`docs/` 会进 tarball）。
- `.dgst` 只强制 `SHA256`/`SHA512`，MD5/SHA1 存在才校验。
- 端口 443 检查在没有 `ss` 时失败关闭；双栈机 IP 检测加 `-4`（686 实测 bug）。
- 测试套件不再要求宿主有 systemd；CI 新增线上 Release 全资产验签 + 哈希复验。

## 安装

下载 `dsh-install-1.4.3.sh`，校验 `SHA256SUMS` 与 `SHA256SUMS.asc`
（指纹 `8E25C6FC8FA01719137FAAE6BC9AF5236E467872`）。

## 未包含

HY2 配置测试仍是“前台跑几秒 + 日志关键字”，没有真实 QUIC 握手探活；
units/geodata 尚未纳入快照哈希。这两项留给下一版。

## 测试

本机 74 passed / 0 failed / 1 skipped（缺 `zip` 的 `t_archive_xray`），
新增 6 个回归用例；`shellcheck -S warning` 全树干净。
