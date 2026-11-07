#!/usr/bin/env bash
#
# dsh-bootstrap.sh — one-command install for DSH on Debian 12.
#
# Usage (root, clean Debian; installs curl first if missing):
#   apt-get update && apt-get install -y curl ca-certificates && \
#     curl -fsSL https://raw.githubusercontent.com/cc520go/dsh-deploy/main/tools/dsh-bootstrap.sh | bash
#
# Or when curl is already present:
#   curl -fsSL https://raw.githubusercontent.com/cc520go/dsh-deploy/main/tools/dsh-bootstrap.sh | bash
#
# What it does:
#   1. installs curl/ca-certificates/gnupg if missing (apt, Debian)
#   2. downloads SHA256SUMS + detached signature + release key from the
#      latest GitHub Release
#   3. verifies the signature in a throw-away keyring and checks the key
#      fingerprint
#   4. finds the versioned installer in the signed manifest, downloads it,
#      and verifies its SHA256 before executing it
#   5. runs: dsh-install-<version>.sh --auto --with-hy2
#
# Environment overrides (mainly for testing):
#   DSH_INSTALL_ARGS   default: --auto --with-hy2
#   DSH_BASE_URL       default: https://github.com/cc520go/dsh-deploy/releases/latest/download
#   DSH_KEY_FPR        expected signing-key fingerprint

set -euo pipefail
LC_ALL=C
export LC_ALL

REPO="${DSH_REPO:-cc520go/dsh-deploy}"
BASE="${DSH_BASE_URL:-https://github.com/${REPO}/releases/latest/download}"
KEY_FPR="${DSH_KEY_FPR:-8E25C6FC8FA01719137FAAE6BC9AF5236E467872}"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT

log() { printf '[dsh] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "请用 root 运行（sudo bash）。"

install_pkgs() {
    command -v apt-get >/dev/null 2>&1 || die "缺少 $*，且系统没有 apt-get；请手动安装后重试。"
    log "安装依赖: $*"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || die "apt-get update 失败"
    apt-get install -y -qq --no-install-recommends "$@" >/dev/null || die "依赖安装失败: $*"
}

missing=()
for c in curl sha256sum tar; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
done
if [[ "${#missing[@]}" -gt 0 ]]; then
    install_pkgs curl ca-certificates tar
fi
command -v gpg >/dev/null 2>&1 || install_pkgs gnupg ca-certificates

log "从 ${BASE} 获取发布物"
cd "${WORK}"
for f in SHA256SUMS SHA256SUMS.asc dsh-signing-key.asc; do
    curl -fsSL --retry 3 --connect-timeout 15 -O "${BASE}/${f}" \
        || die "下载失败: ${f}"
done

export GNUPGHOME="${WORK}/gnupg"
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"
gpg --batch --import dsh-signing-key.asc >/dev/null 2>&1 || die "公钥导入失败"

got_fpr="$(gpg --with-colons --fingerprint 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
[[ "${got_fpr}" == "${KEY_FPR}" ]] || die "签名公钥指纹不符（期望 ${KEY_FPR}，实际 ${got_fpr}）"

gpg --status-fd 1 --verify SHA256SUMS.asc SHA256SUMS 2>/dev/null \
    | grep -q '^\[GNUPG:\] GOODSIG' || die "SHA256SUMS 签名校验失败"

installer="$(awk '/  dsh-install-[0-9]+\.[0-9]+\.[0-9]+\.sh$/{print $2; exit}' SHA256SUMS)"
[[ -n "${installer}" ]] || installer="$(grep -E 'dsh-install-[0-9]+\.[0-9]+\.[0-9]+\.sh$' SHA256SUMS | awk '{print $2; exit}')"
[[ -n "${installer}" ]] || die "签名清单里找不到安装器"

curl -fsSL --retry 3 --connect-timeout 15 -O "${BASE}/${installer}" \
    || die "安装器下载失败: ${installer}"
grep "  ${installer}$" SHA256SUMS | sha256sum -c - >/dev/null 2>&1 \
    || die "安装器哈希与签名清单不符"

log "签名与哈希校验通过: ${installer}"
args="${DSH_INSTALL_ARGS:---auto --with-hy2}"
log "开始安装: bash ${installer} ${args}"
# shellcheck disable=SC2086
bash "./${installer}" ${args} </dev/null
