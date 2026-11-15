## 修复（1 条 P1 + 2 条 P2，来自发版前自查）

- **P1：保留旧配置但缺 `node.params` 时误报安装成功**
  `handle_already_installed` 的保留分支用 `verify_listening "$(read_node_param port)"`
  判断，端口为空时 `verify_listening` 把“没有可校验的端口”当成通过，于是打印
  `install state OK`——节点既没有参数也拿不到链接。现在该分支先要求 `port` 存在，
  缺失直接失败（退出码 1）并提示从快照恢复或删配置重装。
- **P2：HY2 快照复制证书/私钥/unit 失败被吞**
  这三项已参与恢复校验，复制失败必须让快照创建失败，不能记成 `none`；同时删掉
  重复的一行证书复制。
- **P2：`node.params` 先按默认 umask 写再 chmod**
  改为 umask 077 直接创建为 0600，`chmod` 失败也硬失败。

## 口径更正（权限）

- 私钥写盘瞬间是 **0600**（umask 077 + 校验 + 原子 mv），安装完成后
  `migrate_permissions` 会改成官方布局 **640 root:xray**（xray 用户需要读）。
  之前“最终 600 root:root”的说法不准确，以 **640 root:xray** 为准。

## 发布流程修正（可复现）

- **tag 打在“被构建的提交”上**：1.4.7 的 tag 打在加了 `dist/` 的发布提交上，
  而构建发生在它前面的修复提交，`SOURCE_DATE_EPOCH` 相差 405 秒——外部按 tag
  构建得到 `d921c3…`，与发布的 `85a8f8…` 不一致。从 1.4.8 起先在源码提交上构建，
  tag 也打在该提交，`dist/` 只进发布分支。
- 发布工作流新增一步：按 tag 重新构建 tarball，与 `dist/` 里的文件逐字节比对，
  不一致直接让 Release 失败。
- 复现方法：`git checkout v1.4.8 && bash tools/build-release.sh --no-sign`，
  `dist/dsh-1.4.8.tar.gz` 的 SHA256 应与 `SHA256SUMS` 一致。

## 验证

- 本机与真机（Debian 12，重置后全新安装）：86 passed / 0 failed / 1 skipped；
  发布包解包后自测同样 86/0/1。
- 真机逐项：
  - 首装退出码 0，`node.params` 存在，配置 **640 root:xray**，服务 active
  - 菜单：version/status/share/node show/logs/diag（12 PASS）/`diag --loopback`
    （13 PASS，提示正确显示 `127.0.0.1:443`）/bbr status+enable+clear/check-update/
    backup/rollback 全部正常
  - P1 复现：保留旧配置 + 缺 `node.params` → 安装器退出码 **1**，输出
    `existing config found but node.params is missing/incomplete`（修复前是 0 + OK）
  - 全新安装 → `uninstall --yes` 非交互 **5 秒返回、退出码 0**，机器清空
- 跨 umask（022/077）构建哈希一致；`SHA256SUMS` 全 OK、验签 Good。

## 安装

下载 `dsh-install-1.4.8.sh`，校验 `SHA256SUMS` 与 `SHA256SUMS.asc`
（指纹 `8E25C6FC8FA01719137FAAE6BC9AF5236E467872`）。
