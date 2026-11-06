# 自建静态镜像

用途：GitHub 在国内常常打不开，把发布物放到自己的机器上，一条 `curl` 就能装。

## 一次性部署（Debian 12）

```bash
apt-get update && apt-get install -y nginx
mkdir -p /srv/dsh/dist
# 把 dist/ 里的发布物 + index.html 拷进去
cp dist/* /srv/dsh/dist/
cp tools/mirror/index.html /srv/dsh/dist/index.html
cp tools/mirror/nginx-dsh.conf /etc/nginx/sites-available/dsh
ln -sfn /etc/nginx/sites-available/dsh /etc/nginx/sites-enabled/dsh
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
```

## 发布新版本

```bash
bash tools/build-release.sh
cp dist/* /srv/dsh/dist/
cp dist/lisa-install-<版本>.sh /srv/dsh/dist/lisa-install.sh   # 稳定别名
```

## 用法

```bash
curl -fsSL http://<你的地址>/lisa-install.sh -o /tmp/lisa-install.sh
sha256sum /tmp/lisa-install.sh      # 对比 SHA256SUMS
bash /tmp/lisa-install.sh --auto --with-hy2
```

## 安全边界（说实话）

- 只用 HTTP：没有域名，装不了可信证书。**ISP 或路径上的中间人理论上能替换文件。**
- 缓解：安装器自带内嵌校验（只防传输损坏，不防篡改）；真正的信任锚是 HTTPS 的 GitHub 仓库，
  或者你把 `SHA256SUMS` 的值记在别处。
- 这个镜像只供应公开的安装包，不含任何凭据；`limit_except GET HEAD`，不提供上传。
