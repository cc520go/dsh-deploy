## 修复

- **smoke 的 HY2 检测新增 `HY2_UNIT_FILE` 覆盖**：`hy2_present` 之前把
  `/etc/systemd/system/hysteria-server.service` 写死。结果在**真的装过 HY2**
  的机器上，发布包里的 `t_smoke_reality_only` 无法模拟 Reality-only
  （unit 文件还在），包内自测会红。现在 unit 路径和其它 HY2 路径一样可覆盖，
  测试把 unit 也指到空目录，模拟才成立。
- 生产行为不变：unit 存在仍视为 HY2 已安装；装了但服务/配置坏了仍然 FAIL。

## 验证

- 本机：78 passed / 0 failed / 1 skipped。
- 真机（Debian 12，已装 HY2）：`dsh-1.4.6.tar.gz` 解包后自测
  **78 passed / 0 failed / 1 skipped**（skip 为 `t_auth_timer_fail_closed`，
  机器有 `systemd-run` 时按设计跳过）。
- 跨 umask 构建：`umask 022` 与 `umask 077` 产物哈希一致。
- `SHA256SUMS` 全 OK、`SHA256SUMS.asc` 验签 Good（指纹 `8E25…7872`）。

## 安装

下载 `dsh-install-1.4.6.sh`，校验 `SHA256SUMS` 与 `SHA256SUMS.asc`。
