#!/usr/bin/env bash
# 天翼云电脑（Ubuntu）一键准备：Tailscale + SSH + Node + DSH
# 用法（在云电脑终端里执行）：
#   curl -fsSL https://raw.githubusercontent.com/cc520go/dsh-deploy/main/cloudpc-setup.sh | bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo -n"

echo "[1/5] 安装基础包 + SSH 服务"
$SUDO apt-get update -y -qq
$SUDO apt-get install -y -qq curl ca-certificates git tar xz-utils openssh-server >/dev/null
$SUDO mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' | $SUDO tee /etc/ssh/sshd_config.d/00-dsh.conf >/dev/null
$SUDO systemctl enable --now ssh >/dev/null 2>&1 || $SUDO service ssh start >/dev/null 2>&1 || true
$SUDO systemctl restart ssh >/dev/null 2>&1 || $SUDO service ssh restart >/dev/null 2>&1 || true

echo "[2/5] Node.js 22（官方二进制，覆盖安装）"
if ! command -v node >/dev/null 2>&1 || [ "$(node -v 2>/dev/null | sed 's/v//;s/\..*//')" -lt 20 ] 2>/dev/null; then
  V=v22.11.0
  curl -fsSL --retry 3 "https://nodejs.org/dist/$V/node-$V-linux-x64.tar.xz" -o /tmp/node.tar.xz
  $SUDO tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
fi
echo "node $(node -v) / npm $(npm -v)"

echo "[3/5] 安装 DSH"
# 用户家目录里的 .npmrc 可能带 prefix=，会干扰全局安装；统一 cd /root 并显式指定镜像源
# dsh 目前只有预发布版，* 不匹配 rc，必须显式钉版本；清空用户/项目 npmrc 避免 prefix= 干扰
DSH_VER=0.2.2-rc.1
( cd /root && $SUDO env NPM_CONFIG_USERCONFIG=/dev/null npm i -g "@deepseek-ai/dsh@$DSH_VER" --registry=https://registry.npmmirror.com ) \
  || ( cd /root && $SUDO env NPM_CONFIG_USERCONFIG=/dev/null npm i -g "@deepseek-ai/dsh@$DSH_VER" --registry=https://registry.npmjs.org )
echo "dsh $(dsh --version 2>/dev/null || echo '?')"

echo "[4/5] 安装 Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
$SUDO systemctl enable --now tailscaled >/dev/null 2>&1 || true

echo "[5/5] 防火墙放行 tailscale0 / 22（有 ufw 才做）"
if command -v ufw >/dev/null 2>&1; then
  $SUDO ufw allow in on tailscale0 >/dev/null 2>&1 || true
  $SUDO ufw allow 22/tcp >/dev/null 2>&1 || true
fi

echo
echo "==== 下一步（两条，手动执行）===="
echo "  tailscale up          # 会打印一个登录链接，用浏览器打开并用你的账号登录"
echo "  tailscale ip -4       # 记下 100.x.y.z 这个地址"
echo
echo "当前地址（还没登录会是空的）："
tailscale ip -4 2>/dev/null || true
