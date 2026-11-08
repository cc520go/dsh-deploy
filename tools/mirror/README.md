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
curl -fsSL http://<你的地址>/dsh-install.sh -o /tmp/dsh-install.sh
sha256sum /tmp/dsh-install.sh      # 对比 SHA256SUMS
DSH_MIRROR_BASE=http://<你的地址> bash /tmp/dsh-install.sh --auto --with-hy2
```

`DSH_MIRROR_BASE` 是必须的：没有它，安装器还会去 GitHub 下载 Xray 核心、
官方 `install-release.sh` 和 HY2 二进制。本镜像已经在这些路径下提供：

```text
/xray/install-release.sh
/xray/v<VERSION>/Xray-linux-64.zip(.dgst)
/xray/v<VERSION>/Xray-linux-arm64-v8a.zip(.dgst)
/hysteria/v<HY2>/hysteria-linux-{amd64,amd64-avx,arm64}
```

也可以走 bootstrap（只设 `DSH_BASE_URL`，它会自动推导 `DSH_MIRROR_BASE`）：

```bash
curl -fsSL http://<你的地址>/dsh-bootstrap.sh -o /tmp/dsh-bootstrap.sh
DSH_BASE_URL=http://<你的地址> bash /tmp/dsh-bootstrap.sh
```

## 安全边界（说实话）

- 只用 HTTP：没有域名，装不了可信证书。**ISP 或路径上的中间人理论上能替换文件。**
- 缓解：安装器自带内嵌校验（只防传输损坏，不防篡改）；真正的信任锚是 HTTPS 的 GitHub 仓库，
  或者你把 `SHA256SUMS` 的值记在别处。
- 这个镜像只供应公开的安装包，不含任何凭据；`limit_except GET HEAD`，不提供上传。
