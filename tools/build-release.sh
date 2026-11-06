#!/usr/bin/env bash
#
# tools/build-release.sh — build distributable artifacts for
# xray-reality-manager.
#
# Produces, under dist/:
#   lisa-<version>.tar.gz      plain source bundle (clone-and-run style)
#   lisa-install-<version>.sh  single self-contained file: payload +
#                              checksum + unpack + run install.sh
#   SHA256SUMS                 checksums of the two artifacts above
#
# Why the single file exists: the project must be installable on a
# machine with no GitHub access, by a person with no help. Upload one
# file with scp/WinSCP, run one command. Nothing is fetched to bootstrap.
#
# Usage:
#   tools/build-release.sh [--with-tests] [--no-sign] [version]
#
# The version defaults to the VERSION file's content.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${REPO_ROOT}/dist"
WITH_TESTS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-tests) WITH_TESTS=1; shift ;;
        --no-sign) NO_SIGN=1; shift ;;
        -h|--help)
            sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) break ;;
    esac
done

VERSION="${1:-$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")}"
NAME="lisa-${VERSION}"
STAGE="$(mktemp -d)"
cleanup() { rm -rf -- "${STAGE}"; }
trap cleanup EXIT

# ---------------------------------------------------------------- checks ----
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*" >&2; }

for f in "${REPO_ROOT}"/install.sh "${REPO_ROOT}"/manage.sh "${REPO_ROOT}"/diagnose.sh "${REPO_ROOT}"/lib/*.sh; do
    bash -n "${f}" || fail "syntax error: ${f}"
done
info "syntax ok"

if command -v shellcheck >/dev/null 2>&1; then
    # Warnings only: the existing tree still has a few pre-existing ones.
    shellcheck -S error "${REPO_ROOT}"/install.sh "${REPO_ROOT}"/manage.sh \
        "${REPO_ROOT}"/lib/*.sh "${REPO_ROOT}"/tools/*.sh \
        || fail "shellcheck errors"
    info "shellcheck ok"
else
    info "shellcheck not installed, skipped"
fi

if [[ "${WITH_TESTS}" -eq 1 ]]; then
    info "running test suite ..."
    bash "${REPO_ROOT}/tests/run_tests.sh" >/dev/null 2>&1 \
        || fail "test suite failed (run tests/run_tests.sh to see the failures)"
    info "tests ok"
fi

# -------------------------------------------------------------- payload ----
mkdir -p "${STAGE}/${NAME}"
copy_item() {
    local rel="$1"
    [[ -e "${REPO_ROOT}/${rel}" ]] || fail "missing: ${rel}"
    cp -a "${REPO_ROOT}/${rel}" "${STAGE}/${NAME}/${rel}"
}
for item in install.sh manage.sh diagnose.sh VERSION versions-hy2.conf \
            README.md LICENSE lib docs logrotate tests; do
    copy_item "${item}"
done

# 体检脚本随包发布，装在工具目录里，用户直接 `DSH smoke` 就能跑。
cp "${REPO_ROOT}/tools/smoke-remote.sh" "${STAGE}/${NAME}/smoke-remote.sh" \
    || fail "missing: tools/smoke-remote.sh"

rm -rf "${STAGE}/${NAME}/dist" 2>/dev/null || true

mkdir -p "${DIST}"
TARBALL="${DIST}/${NAME}.tar.gz"
tar -czf "${TARBALL}" -C "${STAGE}" "${NAME}"
info "built $(basename "${TARBALL}") ($(du -h "${TARBALL}" | cut -f1))"

# --------------------------------------------------- single-file installer ----
PAYLOAD_SHA="$(sha256sum "${TARBALL}" | cut -d' ' -f1)"
SELF="${DIST}/lisa-install-${VERSION}.sh"
HEAD="${STAGE}/self-head.sh"

cat > "${HEAD}" <<'HEADER'
#!/usr/bin/env bash
#
# lisa-install — self-contained installer for xray-reality-manager.
#
# No network access is needed to unpack this: the whole project is
# embedded below as a base64 tar.gz. Verify it, unpack it, run install.sh.
#
# Usage:
#   bash lisa-install-<version>.sh [--check|--auto|--help] [version]
#
# Offline flow:
#   1. upload this one file to the server (scp / WinSCP / panel file manager)
#   2. bash lisa-install-<version>.sh
#
set -euo pipefail

RELEASE_VERSION="__VERSION__"
PAYLOAD_SHA256="__SHA__"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    printf '[FAIL] 需要 root 运行：sudo bash %s\n' "$(basename "$0")" >&2
    exit 1
fi
for c in base64 sha256sum tar; do
    command -v "${c}" >/dev/null 2>&1 || { printf '[FAIL] 缺少 %s\n' "${c}" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT

printf '[INFO] lisa-install %s：解包中 ...\n' "${RELEASE_VERSION}" >&2
base64 -d > "${WORK}/payload.tar.gz" <<'__LISA_PAYLOAD__'
HEADER

cat > "${STAGE}/self-tail.sh" <<'TAIL'
__LISA_PAYLOAD__

printf '%s  %s\n' "${PAYLOAD_SHA256}" "${WORK}/payload.tar.gz" | sha256sum -c - >/dev/null 2>&1 \
    || { printf '[FAIL] 安装包校验失败：文件可能传坏了或被人改过，拒绝执行。\n' >&2; exit 1; }
printf '[INFO] 校验通过\n' >&2

tar -xzf "${WORK}/payload.tar.gz" -C "${WORK}" || { printf '[FAIL] 解包失败\n' >&2; exit 1; }
SRC="${WORK}/__NAME__"
[[ -f "${SRC}/install.sh" ]] || { printf '[FAIL] 解包不完整（缺 install.sh）\n' >&2; exit 1; }

cd "${SRC}"
set +e
bash ./install.sh "$@"
rc=$?
set -e
# The unpacked tree is temporary: install.sh copies what it needs into
# TOOL_INSTALL_DIR and installs the `lisa` launcher.
exit "${rc}"
TAIL

sed -e "s|__VERSION__|${VERSION}|g" -e "s|__SHA__|${PAYLOAD_SHA}|g" "${HEAD}" > "${SELF}"
base64 "${TARBALL}" >> "${SELF}"
sed -e "s|__NAME__|${NAME}|g" "${STAGE}/self-tail.sh" >> "${SELF}"
chmod 755 "${SELF}"
bash -n "${SELF}" || { printf '[FAIL] 生成的安装器语法错误\n' >&2; exit 1; }
info "built $(basename "${SELF}") ($(du -h "${SELF}" | cut -f1))"

# ------------------------------------------------------------- checksums ----
(
    cd "${DIST}"
    sha256sum "$(basename "${TARBALL}")" "$(basename "${SELF}")" > SHA256SUMS
    # 稳定别名 lisa-install.sh 与版本文件同内容，同一个哈希也写进去，
    # 这样用户下别名文件也能用 sha256sum -c 校验（否则会“no file was verified”）。
    alias_hash="$(sha256sum "$(basename "${SELF}")" | cut -d' ' -f1)"
    printf '%s  %s\n' "${alias_hash}" "lisa-install.sh" >> SHA256SUMS
)
info "wrote dist/SHA256SUMS"

# 分离签名：SHA256SUMS.asc 由仓库里的公钥可验。没有签名私钥就拒绝发布，
# 除非显式 --no-sign（仅用于本地调试）。
if [[ "${NO_SIGN:-0}" == "1" ]]; then
    info "跳过签名（--no-sign）"
else
    if ! command -v gpg >/dev/null 2>&1; then
        fail "gpg 不可用：发布必须签名。装 gnupg，或用 --no-sign 只做本地调试包。"
    fi
    if ! gpg --list-secret-keys release@dsh-deploy >/dev/null 2>&1; then
        fail "找不到签名私钥（release@dsh-deploy）。导入密钥，或用 --no-sign 只做本地调试包。"
    fi
    gpg --batch --yes --armor --detach-sign \
        -u release@dsh-deploy \
        -o "${DIST}/SHA256SUMS.asc" "${DIST}/SHA256SUMS" \
        || fail "签名失败"
    cp "${REPO_ROOT}/docs/dsh-signing-key.asc" "${DIST}/dsh-signing-key.asc"
    info "signed: dist/SHA256SUMS.asc"
fi

printf '\n发布物：\n'
printf '  %s\n' "${TARBALL}"
printf '  %s\n' "${SELF}"
printf '\n离线安装：把 %s 上传到服务器，然后\n  bash %s\n' \
    "$(basename "${SELF}")" "$(basename "${SELF}")"
