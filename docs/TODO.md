# 待办 / 内部交接清单

> 这是项目内部交接笔记，不是用户文档；命令可能随版本变化，使用前先对照 README。
> 公开仓库保留仅为历史记录，不要据此直接操作生产机。

最后更新：2026-11-07

## 等一台新云服务器

到货后按这个顺序做：

1. 系统装 **Debian 12**，给我 root SSH（我把公钥给你，或你给我密码）。
2. 我这边执行：
   ```bash
   bash dsh-install-1.0.1.sh --auto --with-hy2
   bash smoke-remote.sh --full
   ```
3. 绿了之后，这台机器可以当：
   - **CI 的补充环境**：真实 systemd，跑 `tests/run_tests.sh` 全量（容器里缺 systemd，有 4 项只能跳过）；
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
- **重置会连镜像一起清掉**：686 既是测试机也是镜像站，重置后要按 `tools/mirror/nginx-dsh.conf`
  重装 nginx 并拷回 `dist/`（别忘了 `chmod 644/755`，否则 nginx 返回 403）。

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
- **测试机**：继续担任测试 + 静态镜像站（`http://<测试机>/lisa-install.sh`）。
- 主用机继续官方内核 + BBRv1；不装第三方 BBRv3 内核。

## 发布渠道（2026-11-07 定，2026-11-07 修订）

- **正式渠道：GitHub Release**，README 的推荐路径以它为准。
- 镜像（`http://<测试机>/dsh-install.sh`）只是可选加速节点，测试机重置后会离线；
  每次构建后同步 `dist/`，但不能当作唯一入口。
- `git tag` 保留，用于回溯源码；`dist/` 保留，clone 即可用。

## 待办

- [x] ~~Release 正文补镜像地址~~（2026-11-07 完成，正文已含镜像 + 验签说明）
- [x] ~~Release 附件换成签名版~~（6 个附件：安装器、源码包、SHA256SUMS、SHA256SUMS.asc、公钥、体检脚本）
- [ ] **正式机部署**：装完先跑 `smoke-remote.sh --full`，绿了再切流量。
- [ ] **可选调优**：测试机 的 UDP 缓冲（`net.core.rmem_max`）、BBR。
- [ ] **可选**：把镜像从 测试机 迁到新机器，测试机 继续当测试机。
- [ ] **清理**：手机 v2rayNG 里的 `BADPIN-test` 节点。

## 发布纪律

- 每次发布：`bash tools/build-release.sh`（自动签名）→ 传镜像 → Release 附件同步换新。
- **签名私钥只在本机 `/root/.gnupg`**（release@dsh-deploy，指纹
  `8E25C6FC8FA01719137FAAE6BC9AF5236E467872`）。丢失就无法签新版本，建议离线备份。
- 镜像与 Release 必须指向同一构建；换版本后 `sha256sum` 三处要对得上。

## 已知限制（别忘）

- CI 跑在 `debian:12` 容器里，**没有 systemd**，所以 4 个环境类测试（`t_env_check_debian12`、
  `t_install_completion`、两个 logrotate apt 用例）在 CI 里跳过；真实机器上由 `smoke-remote.sh` 覆盖。
- `pinSHA256` 只有 V2rayNG 认，官方 hysteria 客户端不认；所以服务端自检里这项永远是 SKIP，
  真正的验证在客户端侧（已实测：坏 pin → 服务端零记录）。
- 镜像只走 HTTP（无域名、无可信证书），信任锚是 GitHub 仓库或你单独保存的 SHA256。
