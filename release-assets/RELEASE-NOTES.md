## 修复（6 高 + 4 中 + 1 个 1.4.8 回归）

### 高

- **H1 已装机器的版本参数被静默丢弃**：`install.sh` 收到与当前不同的版本参数时
  直接报错并指向 `DSH upgrade`（退出码非零），相同版本仍走保留/修复路径。
- **H2 sshd 重启失败被吞**：`DSH auth` 关闭密码后确认 sshd 真的在运行，失败则
  恢复备份并明确报错，不打印“更改完成”、不启动回滚定时器。
- **H3 回滚删掉回滚目标**：拍 pre 快照前用 `SNAPSHOT_PROTECT` 保护点名快照，
  prune 跳过它；比较时归一化尾斜杠（真机复现出的第二个触发条件）。
- **H4 drop-in 恢复路径写错**：恢复目录内容而非目录本身，先清空再拷贝，不再
  产生嵌套目录或遗留旧 drop-in；恢复后校验 unit 摘要。
- **H5 HY2 升级被自己占的 UDP 443 挡死**：preflight 按进程归属判断，HY2 自己
  监听时放行；端口检测不再依赖 `ss` 的固定列号（真机发现列号随版本变化）。
- **H6 新发布流程零校验**：补齐 SHA256SUMS、GPG 指纹与验签、tag 必须已推送且
  按 tag 重建逐字节比对、checkout 钉 SHA。

### 中

- **M1 host 校验**：三条来源（交互、环境变量、复用 params）汇合后统一校验，
  非法 IPv4/域名直接失败，不再打印死链。
- **M2 改 SNI 写 params 失败导致分叉**：params 先写临时文件，切换成功后原子
  改名；失败则回滚已切换的配置。
- **M3 卸载前快照失败被吞**：拍不成快照即中止卸载，明确“未删除任何东西”。
- **M4 manage.sh 无 root 入口校验**：`main()` 统一 `require_root`。

### 1.4.8 回归

- **交互式安装必死**：`prompt_with_default` 提示改走 stderr，交互安装恢复；
  HY2 的 `[y/N]` 在 stdin 非终端时跳过提示，不再阻塞。

## 验证

- 全量测试：本机与发布包 **96 passed / 0 failed / 1 skipped**（缺 `zip`）；
  真机发布包 **95 passed / 0 failed / 2 skipped**（缺 `zip` + 有 `systemd-run`）。
- 新增 10 个回归用例，覆盖 H1/H2/H3/H4/M1/M2/M3/M4/H5 与交互安装。
- 真机（重置后的 Debian 12，全新安装）逐项：
  - 交互式安装成功（1.4.8 回归已修），config `640 root:xray`
  - HY2 运行时用菜单 13 升级成功；其他进程占 UDP 443 时被明确拒绝
  - 4 个未标记快照回滚最旧的一个：目标存活、`rollback complete`
  - drop-in 恢复：快照里的 drop-in 回到原位、旧文件被清掉、无嵌套目录
  - `26.10.21` 版本参数被拒（退出码 1，提示 upgrade）
  - 非 root 调用在入口被拒；`SNAPSHOT_PARENT` 不可写时卸载中止
  - `DSH auth` 关密码成功（`passwordauthentication no`，ssh active），随后卸载清空
- H6 发布流程演练（本机）：正常包通过；篡改一个字节被校验拦下；tag 指错提交时
  按 tag 重建比对失败；tag 未推送时直接失败。
- 跨 umask（022/077）构建哈希一致；`SHA256SUMS` 全 OK、验签 Good。

## 已知未做（按文档约定不进本版）

其余 12 个中（M5–M16）与 34 个低先放着；HY2 真实握手探活、恢复路径统一也
不在本版范围。

## 安装

下载 `dsh-install-1.4.9.sh`，校验 `SHA256SUMS` 与 `SHA256SUMS.asc`
（指纹 `8E25C6FC8FA01719137FAAE6BC9AF5236E467872`）。
