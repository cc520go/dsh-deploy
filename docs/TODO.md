# 待办 / 内部交接清单

> 这是项目内部交接笔记，不是用户文档；命令可能随版本变化，使用前先对照 README。
> 公开仓库保留仅为历史记录，不要据此直接操作生产机。

最后更新：2026-11-15（1.4.6）

## 1.4.6（2026-11-15，基线 1.4.5）

- smoke 的 `hy2_present` 新增 `HY2_UNIT_FILE` 覆盖，修掉“真机装过 HY2 时
  包内 reality-only 测试必红”的问题；生产检测语义不变。

## 1.4.5 闭环审查修复（2026-11-15，基线 1.4.4）

- 构建可复现补上权限归一化（`tar --mode`），跨 umask 哈希一致。
- smoke 区分“HY2 未装（跳过）”和“HY2 装了但坏了（失败）”。
- 快照校验纳入 systemd units 与 geodata（`units_sha256` / `geodata_sha256`）。
- `bbr status` 拆运行时态 / 持久化态两行，退出码仍要求两者都满足。
- `_check_port_443` 注释与实际失败关闭行为对齐。

## 1.4.4 真机验收修复（2026-11-15，基线 1.4.3）

真机验收流程：清空（卸载 + purge + 删快照）→ 全新安装 → `smoke-remote.sh --full`
→ 发布包解包跑全量测试。发现并修复：

- 发布包漏 `CHANGELOG.md` / `CONTRIBUTING.md`，导致包内自测 `t_release_identity`
  失败；已补打包并加看守。
- HY2 恢复只验服务 `active`，真机上 `active` 早于 UDP 443 绑定；已改为轮询验端口，
  绑不上判失败。

真机结果：smoke 19 PASS / 0 FAIL / 1 SKIP；包内全量 74 passed / 0 failed /
1 skipped。验收机为 Debian 12（地址与凭据不进仓库）。

## 1.4.3 复审修复（2026-11-15，基线 1.4.2 = `f997a92`）

复审结论：1 个 P0、6 个 P1、13 个 P2，外加 686 实测 1 个 bug。本版处理 P0 全部、
P1 全部、P2 中成本低收益高的 9 项，其余如实留在下面。

- P0：`hy2_snapshot_restore` 验 meta/hash + 验服务状态，失败返回非 0；
  8 处调用统一走 `hy2_rollback_after_failure`，不再 `|| true` 后谎报回滚成功。
- P1：快照补 `node.params`（含 `params_sha256`）并随 full 恢复一起还原；
  `cmd_auth_rollback` 与菜单 1 恢复分支改失败即报；`auth_timer_start` 立不起来
  当失败报；公开 TODO 删掉 live 服务器 IP/端口/密码表述；
  `smoke-remote.sh` 进 `SHA256SUMS`；CHANGELOG 写明 HY2 修复后仍不含握手探活。
- 已修 P2：构建可复现、curl 超时、摘要只强制 SHA256/512、测试模式不依赖
  宿主 systemctl、443 检查失败关闭、硬链接复用复核哈希、HY2 known-good、
  诊断环回无网报 SKIP、双栈机 IPv4 检测、菜单 7/20 文案、CI 权限与 shellcheck 级别、
  `XRAY_INSTALLER_URL` 死配置。
- 未做（留给 1.4.4）：HY2 真实握手探活（需 hysteria 客户端，测试要联网）、
  units/geodata 纳入快照哈希、云电脑脚本重写。

## 1.4.2 审计修复（2026-11-15）

- 撤下 `cloudpc-setup.sh`（root 密码登录 / 自动放行 22 / curl|sh / 未校验 Node / 预发布 DSH），需要时另开分支重写。
- `snapshot_restore` 恢复前校验 `meta.txt` 的 binary/config SHA256，损坏快照拒绝恢复。
- `rollback_node_config` / `repair_rollback` / `upgrade_core` / `rollback_core` 改为验证恢复结果并诚实上报，失败输出 `ROLLBACK FAILED`。
- HY2 配置测试临时文件改为 750/640/600（root:hysteria），不再全局可读。
- `DSH_MIRROR_BASE` / `DSH_BASE_URL` 强制 https 或 file；http 需显式 `DSH_ALLOW_INSECURE_MIRROR=1`。
- 移除核心版本硬编码兜底；`lisa-auth-rollback` 改名 `dsh-auth-rollback`。
- 新增 `t_snapshot_restore_sha_mismatch`、`t_rollback_honest_failure`、`t_upgrade_rollback_honest_failure`。

## 命名与签名

- 启动器保持大写 `DSH`；**不提供**小写 `dsh` 别名，避免与 `@deepseek-ai/dsh`、DSH Go 混淆。R-05 关闭。
- 现役发布密钥：`8E25C6FC8FA01719137FAAE6BC9AF5236E467872`（`DSH Release <release@dsh-deploy>`）。
- 旧密钥：`63AEB2BD09A2458B54D7AB1E7F938C08CA8E68D6`，仅保留公钥，标记 retired；不再用于新签名。
- 私钥只存在维护者本机 keyring，发布前必须确认离线备份与试签；备份由维护者执行，不写入仓库。

## 新云服务器（验收机，2026-11-15 起）

一台 **Debian 12** 机器待接 CI 补充环境并跑 `smoke-remote.sh --full`，
通过后再勾下面各项。主机地址、SSH 端口与凭据只保存在维护者的私有记录里，
不写进仓库、不写进发布包（`tools/build-release.sh` 会把 `docs/` 打进 tarball）。

1. 机器装 **Debian 12**，用密钥登录接入（不在这里记录 IP / 端口 / 密码）。
2. 接入后由维护者执行：
   ```bash
   bash dsh-install-<version>.sh --auto --with-hy2
   bash smoke-remote.sh --full
   ```
3. 绿了之后，这台机器可以当：
   - **CI 的补充环境**：真实 systemd，跑 `tests/run_tests.sh` 全量与 `smoke-remote.sh --full`；
   - **客户端侧验证机**：装 hysteria 客户端 / sing-box，验证 pin、协议互操作；
   - **第二台节点**：和 测试机 互为备份，解决"单机单点"这个先天缺陷。

## 性能实测（2026-11-07，手机→686→Cloudflare）

| 项 | 默认 UDP 缓冲(208KB) | 调到 16MB |
|---|---|---|
| 4 并发中位数 | 168 Mbps | **185 Mbps** |
| 单流 | 103 Mbps | ~91–103 Mbps（波动） |

结论：多流 +10%，接近运营商对 UDP 的 200 Mbps 上限；调优已固化进 HY2 安装。

## 踩过的坑（别再犯）

- **改名要全局搜**：把启动器 `lisa` 改成 `DSH` 时，`tools/smoke-remote.sh` 里还留着
  `LAUNCHER=/usr/local/bin/lisa`，导致验收一直报「启动器缺失」。改名后务必全仓 grep 旧名。

- **改了 `manage.sh` 只同步 `lib/` 是不够的**。重新跑一次安装器（`bash dsh-install-1.0.1.sh --auto`）
  会走“已安装”分支，把工具文件刷到 `/usr/local/share/…` 并重建 `DSH` 启动器（旧 `lisa` 会自动清理）——
  这是更新已部署机器 UI 的正确方式，不要手动 scp 单个文件。

## 菜单实测记录（2026-11-07）

| # | 功能 | 状态 | 备注 |
|---|---|---|---|
| 1 | 认证方式 | ✅ 实测 | 已关闭密码登录、只留密钥；10 分钟自动回滚验证有效，`auth-confirm` 确认成功 |
| 2 | 核心版本 | ✅ | 26.10.31 |
| 3 | 检查更新 | ✅ | 检测到 26.10.21 → 26.10.31 |
| 4 | 升级核心 | ✅ 实测 | 26.10.21 → 26.10.31，配置测试通过，快照保留 |
| 5 | 回滚快照 | ✅ 实测 | 回滚到 26.10.31 快照，服务保持 active |
| 6 | 备份快照 | ✅ | — |
| 7 | 节点配置 | ✅ | — |
| 8 | 通用链接 | ✅ | — |
| 9 | 状态检查 | ✅ | — |
| 10 | 线路诊断 | ✅ | 12 PASS / 0 FAIL |
| 11 | 查看日志 | ✅ | — |
| 12 | BBR+FQ | ✅ 实测 | 官方内核 `6.1.0-54`；菜单 12 一键设置 `bbr + fq`，clear 恢复 `cubic/fq_codel`；不安装第三方内核 |
| 13–18 | HY2 六项 | ✅ | 安装/卸载/链接/状态/日志/轮换全跑过 |
| 19 | 一键体检 | ✅ | 21 PASS |
| 20 | HY2 伪装地址 | ✅ 实测 | show/set/reset；非法/私网 URL 拒绝；改完服务 active、链接不变 |

### BBR 路线（2026-11-07 调整）

- 现在只走 **Debian 官方内核 + BBRv1 + fq**，不安装 byJoey BBRv3 内核。
- `DSH bbr enable|status|clear` 与菜单 12 均只操作 `/etc/sysctl.d/99-dsh-bbr.conf`，不重启、不改 Xray。
- 旧 `99-lisa-bbr.conf` 会在第一次 enable 时迁移到 `99-dsh-bbr.conf`。
- BBRv3 的第三方内核路径已从代码中移除；旧机器若还有 `lisa-bbr3-oneshot`，clear 会顺手清掉。

## 部署状态（2026-11-07）

- **主用机**：已上线。一条命令装完，`DSH smoke --full` 21 PASS，客户端实测
  Reality 与 Hysteria2 **双通**。
- **测试机**：继续担任测试，不再兼作镜像站。
- 主用机继续官方内核 + BBRv1；不装第三方 BBRv3 内核。

## 发布渠道（2026-11-08 更新）

- **唯一正式渠道：GitHub Release**，README 的推荐路径以它为准。
- **官方国内镜像已取消**：686 不再提供 nginx / `/srv/dsh/dist`，相关工具与文档已删除。
  国内连不上 GitHub 时，用 Release 附件走“离线单文件”方式。
- 安装器的 `DSH_MIRROR_BASE` 代码能力保留，仅供自建镜像使用，不承诺、不维护。
- `git tag` 保留，用于回溯源码。`dist/` **不进 main**：发布物由 `tools/build-release.sh` 生成，只随 Release 附件发布（历史遗留的 1.4.2 资产已从 main 摘除）。

## 待办

- [x] ~~Release 附件换成签名版~~（6 个附件：安装器、源码包、SHA256SUMS、SHA256SUMS.asc、公钥、体检脚本）
- [ ] **正式机部署**：装完先跑 `smoke-remote.sh --full`，绿了再切流量。
- [ ] **可选调优**：测试机 的 UDP 缓冲（`net.core.rmem_max`）、BBR。
- [ ] **清理**：手机 v2rayNG 里的 `BADPIN-test` 节点。

## 发布纪律

- 每次发布：`bash tools/build-release.sh`（自动签名）→ 上传 GitHub Release 附件。
- **签名私钥只在本机 `/root/.gnupg`**（release@dsh-deploy，指纹
  `8E25C6FC8FA01719137FAAE6BC9AF5236E467872`）。丢失就无法签新版本，建议离线备份。
- Release 附件必须与 `dist/` 指向同一构建；换版本后 `sha256sum` 要对得上。

## 已知限制（别忘）

- 1.4.3 起环境类测试在测试模式下不再要求真实 `systemctl`，CI 里也照跑；真实 systemd 的
  验收（服务重启、监听、防火墙）仍由 `tools/smoke-remote.sh` 在真机上覆盖。
- `pinSHA256` 只有 V2rayNG 认，官方 hysteria 客户端不认；所以服务端自检里这项永远是 SKIP，
  真正的验证在客户端侧（已实测：坏 pin → 服务端零记录）。
