## 1.4.10「鲸潮」— 2026-11-16

基线 1.4.9。范围冻结：只修 H2 恢复缺口 + CHANGELOG 测试数字，其余记入
CHANGELOG“已知问题”，不夹带。

## 修复

- **H2 缺口**：`DSH auth` 关闭密码时若 sshd 重启失败，恢复备份后会再做一次
  尽力重启，避免守护进程停着、操作员一关会话就被锁在外面。失败仍按失败上报：
  退出码非零、不打印“更改完成”、不启动回滚定时器。
- **CHANGELOG**：1.4.9 的跳过用例不再写死作者环境（有 `zip` 的机器跳过的是
  另一个用例）。

## 验证

- 全量测试 **97 passed / 0 failed / 1 skipped**；新增回归
  `t_auth_restart_failure_recovers_daemon`（修复前为红）。
- 真机（重置后的 Debian 12）：安装、菜单、诊断（12 PASS，loopback 13 PASS）、
  回滚、卸载全部通过；注入 sshd 重启失败后配置逐字节恢复、确认执行了回滚后的
  尽力重启、SSH 会话未断。

## 已知问题

M7 / M8 / M9 / M10 / M11 / M12 / M13 / M14 与 33 个低优先项按约定不修，
影响范围与规避方法见 CHANGELOG“已知问题”。

## 校验

```
sha256sum -c SHA256SUMS
gpg --verify SHA256SUMS.asc SHA256SUMS   # 8E25C6FC8FA01719137FAAE6BC9AF5236E467872
```
