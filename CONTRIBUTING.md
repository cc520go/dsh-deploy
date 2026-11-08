# 参与开发

## 本地检查

```bash
bash tests/run_tests.sh      # 必须全过（容器里缺 systemctl 时会有 2 项环境性失败）
bash -n install.sh manage.sh diagnose.sh lib/*.sh
shellcheck -S error install.sh manage.sh diagnose.sh lib/*.sh
```

测试全程在临时沙箱里跑，不会写真实系统路径，也不使用真实节点参数。

## 改代码的规矩

- **改名要全仓搜**：改启动器、路径、命令名后，`grep -rn "旧名" . --exclude-dir=.git`，
  注释、文档、`tools/`、`tests/` 都算。历史上漏过 `tools/smoke-remote.sh`，验收一直报启动器缺失。
- **运行路径改名必须带迁移**：`/usr/local/share/dsh`、`/root/.dsh-deploy`
  这类路径已经装在别人的机器上，不能只改常量；要么迁移旧目录，要么兼容读取一个版本周期。
- **不要提交密钥、节点链接、服务器密码**。签名私钥只留在发布机的 `~/.gnupg`，不进仓库。
- 涉及 systemd、权限、快照恢复的改动，必须在真机（或至少 Debian 12）上验证一次，不能只跑测试。

## 发布流程

1. 改 `DSH_VERSION`（必要时改 `DSH_CODENAME`），更新 `CHANGELOG.md` 与 README 里的版本号。
2. `tools/build-release.sh` 生成并签名 `dist/` 产物；**版本参数必须与 `DSH_VERSION` 一致**。
   `dist/` 已被 `.gitignore` 忽略，只上传 Release，不要提交回仓库。
3. 确认 `SHA256SUMS.asc` 可验、`SHA256SUMS` 与 `dist/` 一致。
4. 上传 GitHub Release（6 个附件）；不再维护官方国内镜像。
5. 不要发布未签名产物；`--no-sign` 只用于本地测试。

## 文档

- 设计取舍写进 `docs/ARCHITECTURE.md`，不要只留在聊天记录里。
- 版本变化写进 `CHANGELOG.md`。
- `docs/TODO.md` 是内部交接笔记，不是用户文档；其中的命令若已失效，要么修，要么删。
