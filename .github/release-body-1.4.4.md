## 修复（真机验收发现）

1.4.3 发布后在 Debian 12 真机上做了一次完整验收：清空环境 → 全新安装 →
`smoke-remote.sh --full` → 解包跑全量测试。发现两个问题，本版修掉。

- **发布包缺 `CHANGELOG.md`**：`dsh-1.4.3.tar.gz` 里没有 CHANGELOG，
  导致从发布包解包后自测 `t_release_identity` 直接失败（本地仓库里看不出来）。
  现已把 CHANGELOG / CONTRIBUTING 打进包，并加了一条看守：构建脚本必须包含
  `CHANGELOG.md`。
- **HY2 恢复只验 `is-active`，不验端口**：真机上服务报 `active` 时 UDP 443
  还没绑定，恢复可能被判成“已验证”。现在恢复后轮询等待端口监听（最多 5 秒），
  绑不上就返回非 0 并输出“未监听”。

## 真机验收结果（Debian 12）

- 清空后全新安装：Xray 26.10.31 + HY2 2.13.0，两个服务 active
- `smoke-remote.sh --full`：**19 PASS / 0 FAIL / 1 SKIP**（无 hysteria 客户端，
  反向探测按设计跳过）
- 发布包解包后全量测试：**74 passed / 0 failed / 1 skipped**
  （skip 为 `t_auth_timer_fail_closed`，机器有 `systemd-run` 时按设计跳过）
- P0 修复实测：篡改快照 → `SHA256 不符，拒绝恢复`，线上服务不受影响；
  缺 `meta.txt` → 拒绝；正常快照 → 恢复成功并验证 active + 端口监听

## 升级说明

1.4.3 用户建议直接升到 1.4.4：同样的代码路径，多了打包完整性和恢复后的端口校验。
安装方式不变：

下载 `dsh-install-1.4.4.sh`，校验 `SHA256SUMS` 与 `SHA256SUMS.asc`
（指纹 `8E25C6FC8FA01719137FAAE6BC9AF5236E467872`）。
