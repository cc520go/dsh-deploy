#!/usr/bin/env bash
#
# tools/smoke-remote.sh — acceptance checklist for a machine that is
# supposed to run xray-reality-manager with the Hysteria2 add-on.
#
# Runs ON THE SERVER, read-only: it never starts, stops, edits or removes
# anything. Every check prints PASS / FAIL / SKIP and the script exits
# non-zero if any check failed.
#
# Usage:
#   bash smoke-remote.sh            # standard checklist
#   bash smoke-remote.sh --full     # adds the reverse tests (wrong
#                                   # password / wrong pin), which need
#                                   # the hysteria client binary
#
# Exit code: 0 = every check passed (SKIP allowed), 1 = something failed.

set -uo pipefail

FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

HY2_SERVICE="${HY2_SERVICE:-hysteria-server}"
HY2_CONF_DIR="${HY2_CONF_DIR:-/etc/hysteria}"
HY2_CONF="${HY2_CONF:-${HY2_CONF_DIR}/config.yaml}"
HY2_CERT="${HY2_CERT:-${HY2_CONF_DIR}/cert.pem}"
HY2_BIN="${HY2_BIN:-/usr/local/bin/hysteria}"
HY2_USER="${HY2_USER:-hysteria}"
HY2_MARKER="${HY2_MARKER:-${HY2_CONF_DIR}/.managed-by-hy2addon}"
HY2_PORT="${HY2_PORT:-443}"
LAUNCHER="${LAUNCHER:-/usr/local/bin/lisa}"
TOOL_DIR="${TOOL_DIR:-/usr/local/share/xray-reality-manager}"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT

pass=0 fail=0 skip=0
ok()   { printf 'PASS  %s\n' "$*"; pass=$((pass + 1)); }
no()   { printf 'FAIL  %s\n' "$*"; fail=$((fail + 1)); }
skipit() { printf 'SKIP  %s\n' "$*"; skip=$((skip + 1)); }

# ---------------------------------------------------------------- basics ----
if [[ "$(id -u)" -eq 0 ]]; then ok "以 root 运行"; else no "不是 root（后面多数检查会失真）"; fi

if grep -q '^ID=debian' /etc/os-release 2>/dev/null && grep -q '^VERSION_ID="12"' /etc/os-release 2>/dev/null; then
    ok "系统是 Debian 12"
else
    no "系统不是 Debian 12（$( . /etc/os-release 2>/dev/null; printf '%s %s' "${ID:-?}" "${VERSION_ID:-?}" )）"
fi

[[ -x "${LAUNCHER}" ]] && ok "lisa 启动器存在: ${LAUNCHER}" || no "lisa 启动器缺失"
[[ -d "${TOOL_DIR}" ]] && ok "工具目录存在: ${TOOL_DIR}" || no "工具目录缺失: ${TOOL_DIR}"

# ------------------------------------------------------------- main line ----
if systemctl is-active --quiet xray; then ok "xray 服务 active"; else no "xray 服务不是 active"; fi
if ss -tln 2>/dev/null | grep -qE '[[:space:]]\*?:443[[:space:]]|:443[[:space:]]'; then
    ok "TCP 443 在监听（主线）"
else
    no "TCP 443 没有监听（主线节点不可用）"
fi

# ---------------------------------------------------------------- hy2 ----
if systemctl is-active --quiet "${HY2_SERVICE}"; then ok "hy2 服务 active"; else no "hy2 服务不是 active"; fi
if systemctl is-enabled --quiet "${HY2_SERVICE}" 2>/dev/null; then ok "hy2 开机自启 enabled"; else no "hy2 没有 enable，重启后不会自己起"; fi

if ss -uln 2>/dev/null | grep -qE "[:.]${HY2_PORT}[[:space:]]"; then
    ok "UDP ${HY2_PORT} 在监听"
else
    no "UDP ${HY2_PORT} 没有监听"
fi

[[ -f "${HY2_CONF}" ]] && ok "配置存在: ${HY2_CONF}" || no "配置缺失: ${HY2_CONF}"
[[ -f "${HY2_MARKER}" ]] && ok "标记文件存在（本项目自己装的）" || no "标记文件缺失，脚本下次会判定为“别人的安装”并拒绝操作"

if [[ -f "${HY2_CERT}" ]]; then
    end="$(openssl x509 -in "${HY2_CERT}" -noout -enddate 2>/dev/null | cut -d= -f2)"
    if [[ -n "${end}" ]] && openssl x509 -in "${HY2_CERT}" -noout -checkend 2592000 >/dev/null 2>&1; then
        ok "证书有效，30 天内不过期（到期: ${end}）"
    else
        no "证书已过期或 30 天内到期（${end:-读不到}）"
    fi
else
    no "证书缺失: ${HY2_CERT}"
fi

# The hysteria user must be able to traverse the dir and read its files.
if [[ -d "${HY2_CONF_DIR}" ]]; then
    perm="$(stat -c '%a %U:%G' "${HY2_CONF_DIR}")"
    case "${perm}" in
        "750 root:"*|"755 root:"*) ok "配置目录权限合理（${perm}）" ;;
        *) no "配置目录权限可疑（${perm}），服务可能读不到自己的证书" ;;
    esac
fi
if [[ "${HY2_USER}" != "root" ]] && id -u "${HY2_USER}" >/dev/null 2>&1; then
    ok "低权限用户 ${HY2_USER} 存在"
else
    no "低权限用户 ${HY2_USER} 不存在（没有按设计降权）"
fi

# ------------------------------------------------------------ behaviour ----
if command -v ss >/dev/null 2>&1; then :; fi

# No secrets in world-readable places.
bad_perm="$(find "${HY2_CONF_DIR}" -maxdepth 1 -type f -perm /o+r 2>/dev/null | head -5)"
[[ -z "${bad_perm}" ]] && ok "配置目录内文件不对其他用户可读" || no "有文件对其他用户可读: ${bad_perm}"

# Snapshot namespace must be separate from xray's.
if ls -d /root/hy2-backup-* >/dev/null 2>&1; then
    ok "存在 HY2 快照（hy2-backup-*）"
else
    skipit "还没有 HY2 快照（安装完成后应有）"
fi
if ls -d /root/hy2-backup-* 2>/dev/null | while read -r d; do stat -c '%a' "$d"; done | grep -qv '^700$'; then
    no "有 HY2 快照目录不是 700"
else
    ok "HY2 快照目录权限 700"
fi

# Link can be generated (never printed here).
if ( cd "${TOOL_DIR}" && bash manage.sh hy2 link >/dev/null 2>&1 ); then
    ok "能生成 V2rayNG 链接（内容不打印）"
else
    no "生成 HY2 链接失败"
fi

# Journal must not be able to fill the disk unchecked.
maxuse="$(grep -rhsE '^[[:space:]]*SystemMaxUse=' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/ 2>/dev/null | tail -1 | cut -d= -f2)"
if [[ -n "${maxuse}" ]]; then
    ok "journald 有容量上限（SystemMaxUse=${maxuse}）"
else
    skipit "journald 没设 SystemMaxUse（长期跑建议设，比如 200M）"
fi

# ------------------------------------------------------- reverse tests ----
if [[ "${FULL}" -eq 1 ]]; then
    CLIENT="${HY2_TEST_CLIENT:-}"
    if [[ -z "${CLIENT}" ]]; then
        skipit "反向测试跳过：没有 hysteria 客户端（用 HY2_TEST_CLIENT 指一个）"
    else
        pw="$(tr -d '[:space:]' < "${HY2_CONF_DIR}/.password" 2>/dev/null || true)"
        pin="$(openssl x509 -in "${HY2_CERT}" -outform der 2>/dev/null | sha256sum | cut -d' ' -f1)"
        sni="$(awk -F': *' '/^[[:space:]]*sni:/{print $2; exit}' "${HY2_CONF}" 2>/dev/null || true)"
        sni="${sni:-www.bing.com}"
        # Talk to the local listener (it binds *:PORT), not the public IP:
        # avoids NAT hairpin puzzles and tests the same server instance.
        host="${HY2_TEST_SERVER:-127.0.0.1:${HY2_PORT}}"
        sni_check="${HY2_TEST_SNI:-}"

        # probe <socksport>: 0 when an HTTPS request through the tunnel
        # actually returns an IP; 1 otherwise. This tests the whole path,
        # not just "did the process start".
        probe() {
            python3 - "$1" <<'PYEOF' 2>/dev/null
import socket, ssl, struct, sys
port = int(sys.argv[1])
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    s.sendall(b"\x05\x01\x00")
    s.recv(2)
    h = b"api.ipify.org"
    s.sendall(b"\x05\x01\x00\x03" + bytes([len(h)]) + h + struct.pack(">H", 443))
    r = s.recv(4)
    if len(r) < 2 or r[1] != 0:
        raise RuntimeError("socks")
    if r[3] == 1:
        s.recv(6)
    elif r[3] == 3:
        n = s.recv(1)[0]
        s.recv(n + 2)
    t = ssl.create_default_context().wrap_socket(s, server_hostname="api.ipify.org")
    t.sendall(b"GET / HTTP/1.1\r\nHost: api.ipify.org\r\nConnection: close\r\n\r\n")
    body = t.recv(4096).decode(errors="ignore").split("\r\n\r\n")[-1].strip()
    sys.exit(0 if body.count(".") == 3 else 1)
except Exception:
    sys.exit(1)
PYEOF
        }

        # run_case <password> <pin> <socksport>: starts the client, probes,
        # stops it. Returns probe's status.
        run_case() {
            cat > "${WORK}/c.yaml" <<EOF
server: ${host}
auth: $1
tls:
  sni: ${sni}
  ca: ${HY2_CERT}
socks5:
  listen: 127.0.0.1:$2
EOF
            "${CLIENT}" client -c "${WORK}/c.yaml" >/dev/null 2>&1 &
            local pid=$!
            sleep 5
            local rc=1
            probe "$2" && rc=0
            kill "${pid}" 2>/dev/null
            wait "${pid}" 2>/dev/null
            sleep 1
            return "${rc}"
        }

        if run_case "${pw}" 18081; then
            ok "正向对照：正确凭据能通（整条链路）"
        else
            no "正向对照失败：正确凭据都不通，服务端或端口有问题"
        fi

        if run_case "definitely-not-the-password" 18082; then
            no "反向失败：错密码竟然能通（认证没生效）"
        else
            ok "反向：错密码连不上"
        fi

        # Pin test: the official hysteria client build does not honour
        # pinSHA256 from the URI/YAML (it falls back to full chain
        # verification), so it cannot prove pinning either way. V2rayNG
        # does honour the hex pin. Honest skip beats a misleading PASS.
        skipit "反向：pin 校验（官方 hysteria 客户端不支持 pinSHA256，需在 V2rayNG 侧验证）"
    fi
else
    skipit "反向测试未启用（用 --full 跑）"
fi

# ---------------------------------------------------------------- report ----
printf '\n合计: %d PASS, %d FAIL, %d SKIP\n' "${pass}" "${fail}" "${skip}"
if [[ "${fail}" -eq 0 ]]; then
    printf '结论: 通过\n'
    exit 0
fi
printf '结论: 未通过 —— 逐条修 FAIL 项，改完再跑一遍\n'
exit 1
