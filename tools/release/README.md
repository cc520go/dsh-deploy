# 用一次性分支发布 GitHub Release

本机（手机）没有 GitHub API token，但仓库的 Actions 自带 `GITHUB_TOKEN`。
做法：把已签名的附件放到一个临时 `release/**` 分支，让
`publish-release.yml` 在 Actions 里执行 `gh release create`，发布完成后删分支。

> 本文档在公开仓库里，只写流程，不写任何私钥、token、节点链接。
> 需要 SSH 推送时用你自己的 deploy key 环境变量（示例：`GIT_DEPLOY_KEY`）。

## 步骤（在仓库根目录）

```bash
# 关键：tag 要打在“被构建的源码提交”上。构建用的是 HEAD 的提交时间
# （SOURCE_DATE_EPOCH），tag 若打在后面加了 dist/ 的发布提交上，外部按 tag
# 构建会得到不同的哈希（1.4.7 踩过）。
ver=1.4.9
git checkout -b "release/v${ver}"
mkdir -p release-assets
cp dist/dsh-install-${ver}.sh dist/dsh-${ver}.tar.gz \
   dist/SHA256SUMS dist/SHA256SUMS.asc dist/dsh-signing-key.asc \
   dist/smoke-remote.sh release-assets/
printf 'v%s\n' "${ver}" > release-assets/RELEASE-TAG
# 写 release-assets/RELEASE-NOTES.md（发版说明，支持 Markdown）
cp tools/release/publish-release.yml .github/workflows/publish-release.yml
git add -f release-assets .github/workflows/publish-release.yml
git -c user.name='DSH Bot' -c user.email='bot@dsh.local' commit -m "ci: publish v${ver}"
GIT_SSH_COMMAND="ssh -i ${GIT_DEPLOY_KEY:?请设置 deploy key 路径} -o IdentitiesOnly=yes" \
  git push origin "release/v${ver}"
```

## 等待与核对

```bash
curl -fsSL 'https://api.github.com/repos/cc520go/dsh-deploy/actions/runs?per_page=5' \
  | python3 -c 'import json,sys; [print(r["name"], r["status"], r["conclusion"]) for r in json.load(sys.stdin)["workflow_runs"]]'
curl -fsSL 'https://api.github.com/repos/cc520go/dsh-deploy/releases/tags/v1.4.9' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["name"], d["draft"], [a["name"] for a in d["assets"]])'
```

`Publish release` 成功后，删分支：

```bash
git checkout main
GIT_SSH_COMMAND="ssh -i ${GIT_DEPLOY_KEY:?请设置 deploy key 路径} -o IdentitiesOnly=yes" \
  git push origin --delete "release/v${ver}"
git branch -D "release/v${ver}"
```

注意：`tag` 必须先推送；附件必须是已经签好名的 `dist/` 产物，不要在 CI 里重新构建
（CI 没有签名私钥，`build-release.sh --with-tests` 在手机上也会因缺少 systemd 失败）。

## 复现校验

在任意机器上：

```bash
git checkout "v${ver}"            # 必须是构建时的源码提交
bash tools/build-release.sh --no-sign
sha256sum dist/dsh-${ver}.tar.gz  # 应与 Release 的 SHA256SUMS 一致
```

发布工作流也会做这一步：按 tag 重建 tarball 并与 `dist/` 比对，不一致即失败。
