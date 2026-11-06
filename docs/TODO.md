# 待办 / 交接清单

最后更新：2026-11-07

## 等一台新云服务器（今晚）

到货后按这个顺序做：

1. 系统装 **Debian 12**，给我 root SSH（我把公钥给你，或你给我密码）。
2. 我这边执行：
   ```bash
   bash lisa-install-26.10.21.sh --auto --with-hy2
   bash smoke-remote.sh --full
   ```
3. 绿了之后，这台机器可以当：
   - **CI 的补充环境**：真实 systemd，跑 `tests/run_tests.sh` 全量（容器里缺 systemd，有 4 项只能跳过）；
   - **客户端侧验证机**：装 hysteria 客户端 / sing-box，验证 pin、协议互操作；
   - **第二台节点**：和 686 互为备份，解决"单机单点"这个先天缺陷。

## 踩过的坑（别再犯）

- **改了 `manage.sh` 只同步 `lib/` 是不够的**。重新跑一次安装器（`bash lisa-install-26.10.21.sh --auto`）
  会走“已安装”分支，把工具文件刷到 `/usr/local/share/…` 并重建 `DSH`/`lisa` 启动器——
  这是更新已部署机器 UI 的正确方式，不要手动 scp 单个文件。

## 待办

- [ ] **Release 正文补镜像地址**（1 分钟，网页手动）：在
      https://github.com/cc520go/dsh-deploy/releases/tag/v26.10.21 点 Edit，
      正文最前面插入国内镜像那三行 curl 命令。
- [ ] **主用机部署**：装完先跑 `smoke-remote.sh --full`，绿了再切流量。
- [ ] **可选调优**：686 的 UDP 缓冲（`net.core.rmem_max`）、BBR。
- [ ] **可选**：把镜像从 686 迁到新机器，686 继续当测试机。
- [ ] **清理**：手机 v2rayNG 里的 `BADPIN-test` 节点。

## 已知限制（别忘）

- CI 跑在 `debian:12` 容器里，**没有 systemd**，所以 4 个环境类测试（`t_env_check_debian12`、
  `t_install_completion`、两个 logrotate apt 用例）在 CI 里跳过；真实机器上由 `smoke-remote.sh` 覆盖。
- `pinSHA256` 只有 V2rayNG 认，官方 hysteria 客户端不认；所以服务端自检里这项永远是 SKIP，
  真正的验证在客户端侧（已实测：坏 pin → 服务端零记录）。
- 镜像只走 HTTP（无域名、无可信证书），信任锚是 GitHub 仓库或你单独保存的 SHA256。
