# 旧名迁移方案（xray-reality-manager → DSH）

> 状态：2026-11-07 已在 1.1.0 实现、1.2.0 移除兼容软链；686 上做了旧路径升级验证。

目标版本：**1.1.0**。1.0.x 不动运行时路径；1.1.0 一次迁完，1.2.0 收掉兼容层。

## 为什么要单独做

仓库里 `xray-reality-manager` 共 39 处，分三类，风险完全不同：

| 类别 | 数量（约） | 例子 | 处理方式 |
|---|---|---|---|
| 注释/文档 | 15 | `lib/*.sh` 文件头、`.gitignore`、README 说明 | 直接改 |
| 对外文案/标识 | 5 | `diagnose.sh` 标题、HY2 systemd `Description`、User-Agent、生成配置的署名 | 直接改，随下次写入生效 |
| 运行时路径/文件名 | 19 | 工具目录、状态目录、node.params、BBR 备份、auth 回滚状态、logrotate 文件名 | **必须带迁移**，不能只改常量 |

只改注释会把数量从 39 降到 24，但会让“同一个东西两种叫法”更难排查；只改路径又会让已装机器丢状态。所以一次做完。

## 目标名字

| 现在 | 迁移后 | 说明 |
|---|---|---|
| `/usr/local/share/xray-reality-manager` | `/usr/local/share/dsh` | 工具运行目录，launcher 指向这里 |
| `/root/.xray-reality-manager` | `/root/.dsh-deploy` | 状态目录：`node.params`、`bbr-backups/`、`auth-rollback.state` |
| `/etc/logrotate.d/xray-reality-manager` | `/etc/logrotate.d/dsh` | logrotate 配置 |
| `User-Agent: xray-reality-manager` | `User-Agent: DSH/1.1` | 出口 IP 查询用 |
| HY2 `Description=...managed by xray-reality-manager...` | `...managed by DSH...` | 仅 systemd 描述，不影响运行 |
| `diagnose.sh` 标题 | `DSH diagnostics` | 用户可见输出 |

**不改**：`xray.service`、`hysteria-server.service` 的 unit 名，`/usr/local/bin/DSH` 启动器名，
Xray 配置路径 `/usr/local/etc/xray`，HY2 配置路径 `/etc/hysteria`。这些不是旧名，改了只会增加风险。

## 迁移算法（install.sh 启动时，早于写配置）

要求：幂等；失败不损坏旧数据；任何一步失败都能回退到旧路径继续用。

### 1. 预检

- 计算 `OLD_TOOL_DIR` / `NEW_TOOL_DIR`、`OLD_STATE_DIR` / `NEW_STATE_DIR`。
- 记录 `legacy_present=0/1`，写进安装日志。
- 如果新旧都不存在：正常全新安装，跳过迁移。

### 2. 状态目录（最要紧，含私密参数）

顺序必须是“先复制、后切换、最后才删旧”：

1. `NEW_STATE_DIR` 不存在、`OLD_STATE_DIR` 存在：
   `cp -a OLD NEW` → 校验 `node.params`（若存在）SHA256 一致 → `rm -rf OLD` → `ln -s NEW OLD`。
   旧内容已在 `NEW` 里，不再留第二份私密参数。
2. 两者都存在（之前手工拷过/迁移中断）：
   以 `NEW` 为准；只把 `OLD` 里缺失的文件补进 `NEW`（不覆盖新文件），
   校验通过后 `rm -rf OLD` 再建软链。
3. 迁移后 `chmod 700 NEW_STATE_DIR`；`node.params` 保持 600。
4. 任何复制/校验失败：删除半成品 `NEW`，保留 `OLD` 原样，安装继续用旧路径（降级兼容），并打印警告。

### 3. 工具目录

1. `NEW_TOOL_DIR` 不存在：`cp -a OLD NEW`，`bash -n NEW/manage.sh` 与 `lib/*.sh` 全部通过再继续。
2. 校验通过后，把旧目录打包备份到 `/root/dsh-legacy-tool-<日期>.tar.gz`（仅这一次），
   然后 `rm -rf OLD`（旧目录里的文件已全部在新目录，且有 tar 备份）。
3. 两者都存在：保留 `NEW`，把 `OLD` 打包备份后删除，避免出现两份可执行代码。
4. 新目录权限与旧目录一致（目录 755、脚本 755）。

> 不采用“旧目录留软链”的方案：软链会让 `grep`/备份/人工排查继续看到旧名，也会让旧版
> `manage.sh` 被误运行。工具目录直接切换，状态目录才需要软链。

### 4. 启动器

- `install_launcher` 已存在：先装新工具目录，再把 `/usr/local/bin/DSH` 重指到
  `${NEW_TOOL_DIR}/manage.sh`；旧 `lisa` 软链按现有逻辑删除。
- 启动器重指之前，旧启动器仍可用；重指是 `ln -sfn` 原子替换。

### 5. logrotate

- 安装 `/etc/logrotate.d/dsh`。
- 如果 `/etc/logrotate.d/xray-reality-manager` 存在且内容含本工具的标记
  （`/var/log/xray/*.log` + `copytruncate`），删除旧文件；不是我们的文件则不动并警告。
- `logrotate -d` 语法检查失败则保留旧文件并报警，不阻断安装。

### 6. HY2 文案

- 不为了改一行注释去重写正在运行的 `config.yaml`。
- 下次 `hy2 install/upgrade` 时自然写成 `# Written by DSH HY2 add-on`；
  systemd `Description` 在下次安装 unit 时更新。
- 这样迁移不会触发 HY2 重启。

### 7. 收尾校验

- `DSH version` 能跑；`DSH smoke --full`（若已装 HY2）21 PASS。
- `node.params` 前后 SHA256 一致；BBR 备份目录文件数一致。
- 打印一行：`legacy paths migrated: <old> -> <new>`，方便日志排查。

## 代码改动点

| 文件 | 改动 |
|---|---|
| `lib/common.sh` | `TOOL_INSTALL_DIR`、`NODE_PARAMS_FILE` 默认值改新路径；新增 `migrate_legacy_paths()`（可测试、路径可用环境变量覆盖） |
| `lib/bbr.sh` | `BBR_BACKUP_DIR` 改 `/root/.dsh-deploy/bbr-backups`；若旧路径存在且新路径没有，迁移时复制 |
| `manage.sh` | `auth-rollback.state` 路径改新；读取时回退旧路径一个版本 |
| `install.sh` | 调用迁移；logrotate 新文件名 + 旧文件清理；注释改 DSH |
| `lib/hy2.sh` | 配置署名、`Description`、User-Agent 文案 |
| `lib/service.sh` | User-Agent 改 `DSH/1.1` |
| `diagnose.sh` | 标题改 DSH |
| `tools/smoke-remote.sh` | `TOOL_DIR` 默认新路径，兼容读旧路径 |
| `tests/run_tests.sh` | 路径常量、logrotate 文件名全部改新；新增迁移用例 |
| `README.md` / `docs/*` | 文档改新名，保留一段“旧名迁移说明” |

## 兼容窗口

- **1.1.0**：新路径为主，旧状态目录留软链，auth 状态可回退旧路径。
- **1.1.x**：只修 bug，保留软链。
- **1.2.0**：删除软链与回退代码；迁移后直接移除旧目录。1.1.0 的软链在升级时被清理。

## 测试计划

1. **单元（沙箱）**：
   - 旧路径 + 旧 `node.params` → 迁移后新路径存在、哈希一致、旧路径变软链、重复执行不报错；
   - 新旧同时存在 → 不覆盖新文件、旧目录被备份后清理；
   - 复制失败（只读目录模拟）→ 旧路径保持可用，返回非零但不破坏状态；
   - 卸载 → 新旧目录、软链、logrotate 文件全部清掉。
2. **686 真机**：现在的 686 正是旧路径安装。装 1.1.0 测试包后检查：
   - `node.params` 哈希不变，`DSH smoke --full` 21 PASS；
   - `readlink /root/.xray-reality-manager` 指向新目录；
   - `/usr/local/bin/DSH` 指向新工具目录；
   - BBR 备份、auth 状态还在。
3. **全新机器**：旧路径不存在时直接装新路径，不产生任何 legacy 软链。
4. **回滚演练**：保留旧工具 tar 包与状态副本，重装 1.0.1 能回到旧路径（仅验收用，不长期支持双向迁移）。

## 发布顺序

1. **先发 1.0.1**（当前内容，不含改名）并签名；这是最后一个使用旧路径的正式版。
2. 从 `main` 拉 `release/1.1` 做迁移；`DSH_VERSION=1.1.0`，CHANGELOG 写清兼容窗口。
3. 686 上用 1.0.1 → 1.1.0 做实机升级验证；再找一台全新 Debian 12 做全新安装验证。
4. 签名发布 1.1.0；1.1.x 保持软链；1.2.0 再清理。

## 明确不做

- 不为了“搜不到旧名”去改 systemd unit 名、Xray 配置目录、HY2 配置目录——这些不是旧名，
  改了只会让回滚和排障更复杂。
- 不在 1.0.1 里夹带迁移代码；发布内容与已验证的 1.0.1 测试包保持一致。
