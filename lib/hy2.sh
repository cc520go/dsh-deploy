#!/usr/bin/env bash
#
# lib/hy2.sh — Hysteria2 add-on protocol for xray-reality-manager (v5 design).
#
# This module adds Hysteria2 as an OPTIONAL second protocol next to the
# existing VLESS + Reality node. It never touches the main line:
#   - no write to ${XRAY_CONF}, ${XRAY_BIN}, xray.service, logrotate, sysctl
#   - HY2 owns its own binary, config, cert, unit, snapshot set and marker
#
# Server core: official Hysteria2 binary (pinned in versions-hy2.conf),
# never the Xray core — Xray has no Hysteria2 inbound.
# Client: V2rayNG only, hysteria2:// link with a hex pinSHA256.
#
# Paths are overridable so the test harness can redirect every filesystem
# effect into a temp dir.

_HY2LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
[[ -n "${_HY2LIB_DIR}" ]] && source "${_HY2LIB_DIR}/common.sh"

# -------------------------------------------------------------- paths ----
HY2_BIN="${HY2_BIN:-/usr/local/bin/hysteria}"
HY2_CONF_DIR="${HY2_CONF_DIR:-/etc/hysteria}"
HY2_CONF="${HY2_CONF:-${HY2_CONF_DIR}/config.yaml}"
HY2_CERT="${HY2_CERT:-${HY2_CONF_DIR}/cert.pem}"
HY2_KEY="${HY2_KEY:-${HY2_CONF_DIR}/key.pem}"
HY2_CLIENT_DIR="${HY2_CLIENT_DIR:-/root/.hy2-client}"
HY2_CLIENT_LINK="${HY2_CLIENT_LINK:-${HY2_CLIENT_DIR}/v2rayng.txt}"
HY2_MARKER="${HY2_MARKER:-${HY2_CONF_DIR}/.managed-by-hy2addon}"
HY2_UNIT_DIR="${HY2_UNIT_DIR:-${XRAY_UNIT_DIR:-/etc/systemd/system}}"
HY2_SERVICE="${HY2_SERVICE:-hysteria-server}"
HY2_UNIT="${HY2_UNIT:-${HY2_UNIT_DIR}/${HY2_SERVICE}.service}"
HY2_USER="${HY2_USER:-hysteria}"
HY2_SNAPSHOT_PARENT="${HY2_SNAPSHOT_PARENT:-${SNAPSHOT_PARENT:-/root}}"
HY2_SNAPSHOT_PREFIX="hy2-backup-"
HY2_SNAPSHOT_KEEP="${HY2_SNAPSHOT_KEEP:-5}"
HY2_VERSIONS_FILE="${HY2_VERSIONS_FILE:-$(dirname "${_HY2LIB_DIR}")/versions-hy2.conf}"

# Fixed design values (v5 §1/§4). Not menu options on purpose.
HY2_PORT="${HY2_PORT:-443}"
HY2_SNI="${HY2_SNI:-www.bing.com}"
HY2_BW_UP="${HY2_BW_UP:-50}"
HY2_BW_DOWN="${HY2_BW_DOWN:-250}"
HY2_CERT_DAYS="${HY2_CERT_DAYS:-36500}"

# ------------------------------------------------------------- pins ----
hy2_pin_value() {
    local key="$1" f="${HY2_VERSIONS_FILE}"
    [[ -f "${f}" ]] || return 1
    awk -F= -v k="${key}" '$1==k {sub(/^[^=]*=/,"",$0); print $0; exit}' "${f}"
}

hy2_default_version() {
    local v
    v="$(hy2_pin_value HYSTERIA_VERSION 2>/dev/null || true)"
    v="${v#app/}"
    v="${v#v}"
    printf '%s' "${v:-2.13.0}"
}

# hy2_sha_for_arch <amd64|amd64-avx|arm64>: prints the pinned SHA256.
hy2_sha_for_arch() {
    hy2_pin_value "SHA256_linux_$1" 2>/dev/null || true
}

# ------------------------------------------------------------ state ----
hy2_installed() {
    [[ -x "${HY2_BIN}" && -f "${HY2_CONF}" && -f "${HY2_UNIT}" ]]
}

hy2_marker_present() { [[ -f "${HY2_MARKER}" ]]; }

hy2_version_installed() {
    local out ver
    [[ -x "${HY2_BIN}" ]] || { printf 'unknown'; return 0; }
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf '%s' "${XRAY_TEST_HY2_VERSION:-$(hy2_default_version)}"
        return 0
    fi
    out="$("${HY2_BIN}" version 2>/dev/null | head -30)"
    ver="$(printf '%s' "${out}" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    ver="${ver#v}"
    printf '%s' "${ver:-unknown}"
}

hy2_service_state() {
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf '%s' "${XRAY_TEST_HY2_SERVICE_STATE:-inactive}"
        return 0
    fi
    systemctl is-active "${HY2_SERVICE}" 2>/dev/null || printf 'inactive'
}

hy2_service_enabled() {
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf '%s' "${XRAY_TEST_HY2_SERVICE_ENABLED:-disabled}"
        return 0
    fi
    systemctl is-enabled "${HY2_SERVICE}" 2>/dev/null || printf 'disabled'
}

# --------------------------------------------------------- preflight ----
# hy2_preflight: hard checks before any write. Never modifies anything.
hy2_preflight() {
    require_root || return 1
    if [[ "${XRAY_TEST_MODE:-0}" != "1" ]]; then
        command -v systemctl >/dev/null 2>&1 || { die "systemd not found: HY2 add-on requires systemd."; return 1; }
        command -v openssl >/dev/null 2>&1 || { die "openssl not found: HY2 add-on needs it for the self-signed cert."; return 1; }
    fi

    if [[ -d "${HY2_CONF_DIR}" ]] && ! hy2_marker_present; then
        die "${HY2_CONF_DIR} 已存在，但没有本项目标记文件 ${HY2_MARKER}。这看起来是别人手动装的 Hysteria2，拒绝覆盖。请先人工确认后清理或改名该目录。"
        return 1
    fi

    if [[ "${XRAY_TEST_MODE:-0}" != "1" ]]; then
        if ss -lun 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${HY2_PORT}\$"; then
            die "UDP ${HY2_PORT} 已被占用（不是 HY2 自己的服务时就别继续）。先查: ss -ulpn | grep :${HY2_PORT}"; return 1
        fi
        if id -u "${HY2_USER}" >/dev/null 2>&1 && ! hy2_marker_present; then
            die "系统里已有用户 ${HY2_USER}，但本项目没有标记文件。为免踩到别人的安装，拒绝继续。"; return 1
        fi
    fi
    return 0
}

# ------------------------------------------------------------ arch ----
# hy2_detect_arch: prints amd64 | amd64-avx | arm64 (v1 supports these only).
hy2_detect_arch() {
    local m
    m="$(uname -m)"
    case "${m}" in
        x86_64|amd64)
            if grep -qE '(^| )avx( |$)' /proc/cpuinfo 2>/dev/null; then
                printf 'amd64-avx'
            else
                printf 'amd64'
            fi
            ;;
        aarch64|arm64) printf 'arm64' ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------- snapshot ----
# HY2 snapshots live in their own namespace and never mix with xray ones.
hy2_snapshot_create() {
    local stamp ver dir suffix=1 sha_bin sha_conf
    stamp="$(date +%Y%m%d-%H%M%S)"
    ver="$(hy2_version_installed)"
    dir="${HY2_SNAPSHOT_PARENT}/${HY2_SNAPSHOT_PREFIX}${stamp}-${ver}"
    while [[ -e "${dir}" ]]; do
        suffix=$((suffix + 1))
        dir="${HY2_SNAPSHOT_PARENT}/${HY2_SNAPSHOT_PREFIX}${stamp}-${ver}-${suffix}"
    done
    mkdir -p "${dir}" || { die "cannot create HY2 snapshot dir: ${dir}"; return 1; }
    [[ -f "${HY2_BIN}" ]]   && cp -a "${HY2_BIN}"   "${dir}/hysteria.bin" 2>/dev/null || true
    [[ -f "${HY2_CONF}" ]]  && cp -a "${HY2_CONF}"  "${dir}/config.yaml"  2>/dev/null || true
    [[ -f "${HY2_CERT}" ]]  && cp -a "${HY2_CERT}"  "${dir}/cert.pem"     2>/dev/null || true
    [[ -f "${HY2_KEY}" ]]   && cp -a "${HY2_KEY}"   "${dir}/key.pem"      2>/dev/null || true
    [[ -f "${HY2_UNIT}" ]]  && cp -a "${HY2_UNIT}"  "${dir}/${HY2_SERVICE}.service" 2>/dev/null || true
    [[ -f "${HY2_MARKER}" ]] && cp -a "${HY2_MARKER}" "${dir}/marker"     2>/dev/null || true
    sha_bin="none"; sha_conf="none"
    [[ -f "${dir}/hysteria.bin" ]] && sha_bin="$(sha256sum "${dir}/hysteria.bin" | cut -d' ' -f1)"
    [[ -f "${dir}/config.yaml" ]] && sha_conf="$(sha256sum "${dir}/config.yaml" | cut -d' ' -f1)"
    {
        printf 'version=%s\n' "${ver}"
        printf 'created=%s\n' "${stamp}"
        printf 'binary_sha256=%s\n' "${sha_bin}"
        printf 'config_sha256=%s\n' "${sha_conf}"
    } > "${dir}/meta.txt"
    chmod 700 "${dir}" 2>/dev/null || true
    chmod 600 "${dir}"/* 2>/dev/null || true
    log_info "HY2 快照已创建: ${dir} (version ${ver})"
    hy2_snapshot_prune || true
    printf '%s' "${dir}"
    return 0
}

# hy2_snapshot_list: newest first (stdout, one per line, no trailing slash).
hy2_snapshot_list() {
    local -a dirs
    local d t
    mapfile -t dirs < <(ls -d "${HY2_SNAPSHOT_PARENT}/${HY2_SNAPSHOT_PREFIX}"*/ 2>/dev/null || true)
    [[ "${#dirs[@]}" -eq 0 ]] && return 0
    for d in "${dirs[@]}"; do
        d="${d%/}"
        t="$(stat -c %Y "${d}" 2>/dev/null || echo 0)"
        printf '%s %s\n' "${t}" "${d}"
    done | sort -k1,1nr -k2,2r | awk '{print $2}'
}

hy2_snapshot_prune() {
    local -a all
    local i
    mapfile -t all < <(hy2_snapshot_list)
    [[ "${#all[@]}" -le "${HY2_SNAPSHOT_KEEP}" ]] && return 0
    for ((i = HY2_SNAPSHOT_KEEP; i < ${#all[@]}; i++)); do
        rm -rf -- "${all[$i]}" 2>/dev/null || true
    done
    return 0
}

hy2_snapshot_latest() { hy2_snapshot_list | head -1; }

# hy2_snapshot_restore <dir>: restore binary/config/cert/unit from a snapshot.
hy2_snapshot_restore() {
    local dir="$1"
    [[ -d "${dir}" ]] || { die "快照不存在: ${dir}"; return 1; }
    run_systemctl stop "${HY2_SERVICE}" >/dev/null 2>&1 || true
    [[ -f "${dir}/hysteria.bin" ]] && { install -m 755 -o root -g root "${dir}/hysteria.bin" "${HY2_BIN}" || return 1; }
    [[ -f "${dir}/config.yaml" ]]  && { install -m 600 -o "${HY2_USER}" -g "${HY2_USER}" "${dir}/config.yaml" "${HY2_CONF}" || return 1; }
    [[ -f "${dir}/cert.pem" ]]     && { install -m 600 -o "${HY2_USER}" -g "${HY2_USER}" "${dir}/cert.pem" "${HY2_CERT}" || return 1; }
    [[ -f "${dir}/key.pem" ]]      && { install -m 600 -o "${HY2_USER}" -g "${HY2_USER}" "${dir}/key.pem" "${HY2_KEY}" || return 1; }
    [[ -f "${dir}/${HY2_SERVICE}.service" ]] && { install -m 644 "${dir}/${HY2_SERVICE}.service" "${HY2_UNIT}" || return 1; }
    run_systemctl daemon-reload >/dev/null 2>&1 || true
    run_systemctl start "${HY2_SERVICE}" >/dev/null 2>&1 || true
    log_info "已从快照恢复: ${dir}"
    return 0
}

# -------------------------------------------------------- install bits ----
hy2_ensure_user() {
    if ! id -u "${HY2_USER}" >/dev/null 2>&1; then
        [[ "${XRAY_TEST_MODE:-0}" == "1" ]] && return 0
        useradd --system --no-create-home --shell /usr/sbin/nologin "${HY2_USER}" \
            || { die "创建用户 ${HY2_USER} 失败"; return 1; }
        log_info "已创建系统用户 ${HY2_USER}"
    fi
    return 0
}

# hy2_download_binary <version> <arch>: download + SHA256 verify, install to HY2_BIN.
hy2_download_binary() {
    local ver="$1" arch="$2" url tmp want got
    url="https://github.com/HyNetworks/hysteria/releases/download/app/v${ver#v}/hysteria-linux-${arch}"
    want="$(hy2_sha_for_arch "${arch}")"
    if [[ -z "${want}" ]]; then
        die "versions-hy2.conf 里没有 SHA256_linux_${arch}，拒绝安装未知架构/未钉死版本。"
        return 1
    fi
    tmp="$(mktemp /tmp/hysteria.XXXXXX)" || return 1
    # shellcheck disable=SC2064
    trap "rm -f -- '${tmp}'" RETURN
    log_info "下载 hysteria ${ver} (${arch}) ..."
    if ! curl -fsSL --retry 3 --connect-timeout 20 -o "${tmp}" "${url}"; then
        die "下载失败: ${url}"; return 1
    fi
    got="$(sha256sum "${tmp}" | cut -d' ' -f1)"
    if [[ "${got}" != "${want}" ]]; then
        die "SHA256 校验失败，拒绝安装。期望 ${want}，实际 ${got}"
        return 1
    fi
    log_info "SHA256 校验通过: ${got}"
    install -m 755 -o root -g root "${tmp}" "${HY2_BIN}" || { die "安装二进制失败"; return 1; }
    return 0
}

# hy2_gen_cert: self-signed EC P-256 leaf, SAN = SNI + public IPv4.
hy2_gen_cert() {
    local ip days tmpkey tmpcrt
    ip="$(hy2_public_ip 2>/dev/null || true)"
    days="${HY2_CERT_DAYS}"
    tmpkey="$(mktemp)"; tmpcrt="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f -- '${tmpkey}' '${tmpcrt}'" RETURN
    openssl ecparam -name prime256v1 -genkey -noout -out "${tmpkey}" 2>/dev/null \
        || { die "生成 EC 私钥失败"; return 1; }
    local san="DNS:${HY2_SNI}"
    [[ -n "${ip}" ]] && san="IP:${ip},DNS:${HY2_SNI}"
    openssl req -new -x509 -key "${tmpkey}" -out "${tmpcrt}" -days "${days}" \
        -subj "/CN=${HY2_SNI}" -addext "subjectAltName=${san}" 2>/dev/null \
        || { die "生成自签证书失败"; return 1; }
    install -m 600 -o "${HY2_USER}" -g "${HY2_USER}" "${tmpkey}" "${HY2_KEY}" || return 1
    install -m 600 -o "${HY2_USER}" -g "${HY2_USER}" "${tmpcrt}" "${HY2_CERT}" || return 1
    log_info "已生成自签叶证书 (EC P-256, ${days} 天, SAN=${san})"
    return 0
}

# hy2_public_ip: multi-source check, >=2 identical wins, else first + warn.
hy2_public_ip() {
    local -a urls=( "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipv4.icanhazip.com" )
    local -a got=()
    local u ip
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf '%s' "${XRAY_TEST_HY2_PUBLIC_IP:-203.0.113.10}"
        return 0
    fi
    for u in "${urls[@]}"; do
        ip="$(curl -fsS --connect-timeout 6 --max-time 10 "${u}" 2>/dev/null | tr -d '[:space:]' || true)"
        [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && got+=("${ip}")
    done
    if [[ "${#got[@]}" -eq 0 ]]; then
        return 1
    fi
    ip="$(printf '%s\n' "${got[@]}" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
    local same
    same="$(printf '%s\n' "${got[@]}" | grep -c "^${ip}$")"
    if [[ "${same}" -lt 2 ]]; then
        log_warn "公网 IP 未获多源一致确认（${ip}），链接 host 标记为未验证。"
    fi
    printf '%s' "${ip}"
}

# hy2_cert_pin: hex SHA256 of the DER certificate (what V2rayNG pins).
hy2_cert_pin() {
    local f="${HY2_CERT}"
    [[ -f "${f}" ]] || return 1
    openssl x509 -in "${f}" -outform der 2>/dev/null | sha256sum | cut -d' ' -f1
}

hy2_read_password() {
    local f="${HY2_CONF_DIR}/.password"
    [[ -f "${f}" ]] || return 1
    tr -d '[:space:]' < "${f}"
}

hy2_write_password() {
    local pw="$1" f="${HY2_CONF_DIR}/.password"
    printf '%s' "${pw}" > "${f}" || return 1
    chmod 600 "${f}" 2>/dev/null || true
    return 0
}

# hy2_write_config <password> <public-ip>
hy2_write_config() {
    local pw="$1" ip="$2" tmp
    tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f -- '${tmp}'" RETURN
    {
        printf 'listen: :%s\n\n' "${HY2_PORT}"
        printf 'tls:\n'
        printf '  cert: %s\n' "${HY2_CERT}"
        printf '  key: %s\n\n' "${HY2_KEY}"
        printf 'auth:\n'
        printf '  type: password\n'
        printf '  password: %s\n\n' "${pw}"
        printf '# Fixed by design (v5 §1.6): declared bandwidth turns on Brutal.\n'
        printf 'bandwidth:\n'
        printf '  up: %s mbps\n' "${HY2_BW_UP}"
        printf '  down: %s mbps\n\n' "${HY2_BW_DOWN}"
        printf '# Profile A: no obfuscation, masquerade on.\n'
        printf 'masquerade:\n'
        printf '  type: proxy\n'
        printf '  proxy:\n'
        printf '    url: https://www.bing.com\n'
        printf '    rewriteHost: true\n'
    } > "${tmp}"
    install -m 600 -o "${HY2_USER}" -g "${HY2_USER}" "${tmp}" "${HY2_CONF}" || { die "写配置失败"; return 1; }
    [[ -n "${ip}" ]] || true
    return 0
}

# hy2_set_journal_cap: HY2 logs to journald with no file to rotate, so the
# journal must have a ceiling or it will eventually fill the disk (and take
# the main line down with it). Only writes a drop-in when no SystemMaxUse is
# already configured anywhere — never overrides an operator's own policy.
hy2_set_journal_cap() {
    local dropin="/etc/systemd/journald.conf.d/60-hy2addon.conf"
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        return 0
    fi
    if grep -rqsE '^[[:space:]]*SystemMaxUse=' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/ 2>/dev/null; then
        log_info "journald 已有 SystemMaxUse，沿用（不覆盖）"
        return 0
    fi
    mkdir -p "$(dirname "${dropin}")" || return 0
    {
        printf '# Written by xray-reality-manager HY2 add-on (%s)\n' "$(date +%F)"
        printf '# HY2 writes to the journal (no log file to rotate); without a\n'
        printf '# ceiling the journal can fill the disk and hurt the main line.\n'
        printf '[Journal]\nSystemMaxUse=200M\n'
    } > "${dropin}" || return 0
    run_systemctl restart systemd-journald >/dev/null 2>&1 || true
    log_info "已给 journald 设 200M 上限（${dropin}）"
    return 0
}

hy2_write_unit() {
    local tmp
    tmp="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f -- '${tmp}'" RETURN
    cat > "${tmp}" <<EOF
[Unit]
Description=Hysteria2 Server (managed by xray-reality-manager HY2 add-on)
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${HY2_USER}
Group=${HY2_USER}
ExecStart=${HY2_BIN} server -c ${HY2_CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
    install -m 644 "${tmp}" "${HY2_UNIT}" || { die "写 systemd 单元失败"; return 1; }
    return 0
}

# hy2_config_test: run the server in the foreground on a temp UDP port as
# the hysteria user; a clean start (still alive after a few seconds) passes.
# hy2_fix_perms: the hysteria user must be able to traverse the config dir
# and read its own files. Dir is root:hysteria 750 (not 700 — that would
# lock the service out of its own cert, a real failure seen on a live Debian box).
hy2_fix_perms() {
    [[ -d "${HY2_CONF_DIR}" ]] || return 0
    chown root:"${HY2_USER}" "${HY2_CONF_DIR}" 2>/dev/null || true
    chmod 750 "${HY2_CONF_DIR}" 2>/dev/null || true
    local f
    for f in "${HY2_CONF}" "${HY2_CERT}" "${HY2_KEY}" "${HY2_CONF_DIR}/.password"; do
        [[ -f "${f}" ]] || continue
        chown "${HY2_USER}:${HY2_USER}" "${f}" 2>/dev/null || true
        chmod 600 "${f}" 2>/dev/null || true
    done
    [[ -f "${HY2_MARKER}" ]] && chmod 600 "${HY2_MARKER}" 2>/dev/null || true
    return 0
}

hy2_config_test() {
    local work tmp logf out rc
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        log_info "config test passed (test mode): ${HY2_CONF}"
        return 0
    fi
    command -v timeout >/dev/null 2>&1 || { log_warn "timeout 不可用，跳过前台配置测试"; return 0; }
    # A dedicated work dir: hysteria infers the config type from the file
    # extension (.yaml), so a bare mktemp file would be rejected, and the
    # hysteria user must be able to read both the config and the dir.
    work="$(mktemp -d)" || return 1
    tmp="${work}/config.yaml"
    logf="${work}/server.log"
    chmod 755 "${work}"
    if ! sed "s/^listen: .*/listen: 127.0.0.1:39871/" "${HY2_CONF}" > "${tmp}"; then
        rm -rf -- "${work}"; die "配置测试：无法生成临时配置"; return 1
    fi
    chmod 644 "${tmp}"
    : > "${logf}"; chmod 666 "${logf}"
    timeout 6 runuser -u "${HY2_USER}" -- "${HY2_BIN}" server -c "${tmp}" >"${logf}" 2>&1
    rc=$?
    out="$(cat "${logf}" 2>/dev/null || true)"
    rm -rf -- "${work}"
    if [[ "${rc}" -eq 124 ]] || printf '%s' "${out}" | grep -qiE 'server up|listening'; then
        log_info "配置测试通过（前台临时端口启动正常）"
        return 0
    fi
    log_error "配置测试失败（exit ${rc}）"
    printf '%s\n' "${out}" | tail -20 >&2
    return 1
}

hy2_selfcheck() {
    local state ok=1
    state="$(hy2_service_state)"
    if [[ "${state}" != "active" ]]; then
        log_warn "自检第一层：服务状态 ${state}（不是 active）"
        ok=1
    else
        log_info "自检第一层：服务 active"
        ok=0
    fi
    log_warn "自检第二层：外部可达性 —— 未验证（本机看不到云安全组，也看不到你客户端那条路）"
    return "${ok}"
}

# hy2_build_link <password> <host> <pin>: hysteria2:// for V2rayNG.
hy2_build_link() {
    local pw="$1" host="$2" pin="$3" name="DSH-HY2"
    printf 'hysteria2://%s@%s:%s/?sni=%s&pinSHA256=%s#%s' \
        "$(url_encode "${pw}")" "${host}" "${HY2_PORT}" \
        "$(url_encode "${HY2_SNI}")" "${pin}" "${name}"
}

# hy2_save_link <link>: client file per v5 §6.6 — dir 700, file 600.
hy2_save_link() {
    local link="$1"
    mkdir -p "${HY2_CLIENT_DIR}" || return 1
    chmod 700 "${HY2_CLIENT_DIR}" 2>/dev/null || true
    printf '%s\n' "${link}" > "${HY2_CLIENT_LINK}" || return 1
    chmod 600 "${HY2_CLIENT_LINK}" 2>/dev/null || true
    return 0
}

hy2_warn_firewall() {
    printf '\n[提醒] 需要放行 UDP %s（服务器本机防火墙 + 云厂商安全组都要）。\n' "${HY2_PORT}"
    printf '       本工具只提醒，不会替你改防火墙状态。\n'
}

# ----------------------------------------------------------- commands ----
hy2_cmd_install() {
    local target_ver arch ip pw pin snap
    hy2_preflight || return 1

    arch="$(hy2_detect_arch)" || { die "不支持的架构 $(uname -m)：v1 只支持 amd64 / amd64-avx / arm64。"; return 1; }

    if hy2_installed; then
        # Installed -> this menu entry means a manual upgrade.
        target_ver="${1:-}"
        if [[ -z "${target_ver}" ]]; then
            printf 'HY2 已安装（当前 %s）。这一项是自定义升级，不是重装。\n' "$(hy2_version_installed)"
            printf '目标版本 [%s]: ' "$(hy2_default_version)"
            read -r target_ver || return 0
            target_ver="${target_ver:-$(hy2_default_version)}"
        fi
        if ! confirm "将把 HY2 从 $(hy2_version_installed) 升级到 ${target_ver}：先快照，再按架构校验 SHA256，换完做前台配置测试，过了才重启；失败自动回滚。主线 Reality 不动。"; then
            log_info "已取消。"; return 0
        fi
        snap="$(hy2_snapshot_create)" || return 1
        hy2_download_binary "${target_ver}" "${arch}" || { log_warn "升级失败，开始回滚"; hy2_snapshot_restore "${snap}" || true; return 1; }
        hy2_fix_perms
        if ! hy2_config_test; then
            log_error "新二进制配置测试未过，回滚到 ${snap}"
            hy2_snapshot_restore "${snap}" || true
            return 1
        fi
        run_systemctl enable "${HY2_SERVICE}" >/dev/null 2>&1 || true
        run_systemctl restart "${HY2_SERVICE}" || { log_error "重启失败，回滚"; hy2_snapshot_restore "${snap}" || true; return 1; }
        hy2_selfcheck || log_warn "升级后自检未全过，请人工确认。链接、密码、端口都没变。"
        pw="$(hy2_read_password)" || true
        if [[ -n "${pw}" ]]; then
            pin="$(hy2_cert_pin)" || true
            ip="$(hy2_public_ip || true)"; [[ -z "${ip}" ]] && ip="<你的服务器IP>"
            hy2_save_link "$(hy2_build_link "${pw}" "${ip}" "${pin}")" || true
        fi
        log_info "HY2 升级完成: $(hy2_version_installed)"
        return 0
    fi

    target_ver="${1:-$(hy2_default_version)}"
    if ! confirm "将安装 Hysteria2 ${target_ver}（官方二进制 ${arch}）：写 ${HY2_CONF_DIR}、建 ${HY2_USER} 用户、写 systemd 单元、自签证书。不动主线 VLESS/Reality。"; then
        log_info "已取消。"; return 0
    fi

    hy2_ensure_user || return 1
    mkdir -p "${HY2_CONF_DIR}" || { die "创建 ${HY2_CONF_DIR} 失败"; return 1; }
    hy2_fix_perms
    : > "${HY2_MARKER}" || { die "写标记文件失败"; return 1; }

    hy2_download_binary "${target_ver}" "${arch}" || return 1
    hy2_gen_cert || return 1

    # Reuse the existing password on repair/reinstall; generate only if absent.
    if pw="$(hy2_read_password)"; then
        log_info "沿用已有密码（不重新生成）"
    else
        pw="$(openssl rand -base64 32 | tr -d '/+=\n' | cut -c1-40)"
        hy2_write_password "${pw}" || return 1
    fi

    ip="$(hy2_public_ip || true)"
    if [[ -z "${ip}" ]]; then
        log_warn "取不到公网 IP，链接里先留占位符，稍后用菜单 15 重新生成。"
        ip="<你的服务器IP>"
    fi

    hy2_write_config "${pw}" "${ip}" || return 1
    hy2_write_unit || return 1
    hy2_set_journal_cap || true
    hy2_fix_perms
    run_systemctl daemon-reload || true

    if ! hy2_config_test; then
        log_error "配置测试没过，不启动服务。修好后重新点菜单 13（会走修复流程，不重新生成密码）。"
        return 1
    fi

    run_systemctl enable "${HY2_SERVICE}" || log_warn "enable 失败"
    run_systemctl restart "${HY2_SERVICE}" || { log_error "启动失败，查: journalctl -u ${HY2_SERVICE} -n 50"; return 1; }

    hy2_selfcheck || true
    hy2_snapshot_create >/dev/null || true

    pin="$(hy2_cert_pin)"
    local link
    link="$(hy2_build_link "${pw}" "${ip}" "${pin}")"
    hy2_save_link "${link}" || log_warn "客户端链接文件写入失败（不影响服务）"
    printf '\n安装完成。V2rayNG 链接（已存 %s，权限 600）：\n%s\n' "${HY2_CLIENT_LINK}" "${link}"
    hy2_warn_firewall
    printf '\n客户端机器上先跑这条看服务端可达性：\n  curl -v --http3-only https://%s/ 2>&1 | head\n' "${ip}"
    return 0
}

hy2_cmd_uninstall() {
    local keep
    hy2_installed || { [[ -d "${HY2_CONF_DIR}" ]] || { log_info "HY2 没装，什么都不用做。"; return 0; }; }
    if ! hy2_marker_present; then
        die "${HY2_CONF_DIR} 没有本项目标记文件，判断不是本项目装的，拒绝删。"; return 1
    fi
    if ! confirm "将停止并删除 HY2：服务、二进制、配置、证书、客户端链接、标记文件。主线 VLESS/Reality 完全不动。"; then
        log_info "已取消。"; return 0
    fi
    run_systemctl stop "${HY2_SERVICE}" >/dev/null 2>&1 || true
    run_systemctl disable "${HY2_SERVICE}" >/dev/null 2>&1 || true
    rm -f -- "${HY2_UNIT}" 2>/dev/null || true
    run_systemctl daemon-reload >/dev/null 2>&1 || true
    rm -f -- "${HY2_BIN}" 2>/dev/null || true
    rm -rf -- "${HY2_CONF_DIR}" 2>/dev/null || true
    rm -rf -- "${HY2_CLIENT_DIR}" 2>/dev/null || true
    id -u "${HY2_USER}" >/dev/null 2>&1 && userdel "${HY2_USER}" 2>/dev/null || true

    printf '要不要顺手删掉 HY2 快照（含明文凭据）？输入 yes 删除，其他保留： '
    read -r keep || keep=""
    if [[ "${keep}" == "yes" ]]; then
        local d
        while IFS= read -r d; do
            [[ -n "${d}" ]] && rm -rf -- "${d}"
        done < <(hy2_snapshot_list)
        log_info "HY2 快照已删除。"
    else
        log_info "HY2 快照保留在 ${HY2_SNAPSHOT_PARENT}（hy2-backup-*）。"
    fi
    log_info "HY2 已卸载，主线节点未受影响。"
    return 0
}

hy2_cmd_link() {
    local pw pin ip
    hy2_installed || { die "HY2 还没装。先走菜单 13。"; return 1; }
    pw="$(hy2_read_password)" || { die "找不到密码文件 ${HY2_CONF_DIR}/.password"; return 1; }
    pin="$(hy2_cert_pin)" || { die "读证书指纹失败: ${HY2_CERT}"; return 1; }
    ip="$(hy2_public_ip || true)"
    [[ -z "${ip}" ]] && ip="<你的服务器IP>"
    local link
    link="$(hy2_build_link "${pw}" "${ip}" "${pin}")"
    hy2_save_link "${link}" || true
    printf '%s\n' "${link}"
    # Never written to a log file: terminal + the 600 client file only.
    return 0
}

hy2_cmd_status() {
    local state
    printf 'HY2 服务: %s (%s)\n' "$(hy2_service_state)" "$(hy2_service_enabled)"
    printf '版本: %s\n' "$(hy2_version_installed)"
    if [[ "${XRAY_TEST_MODE:-0}" != "1" ]]; then
        printf '监听(UDP %s):\n' "${HY2_PORT}"
        ss -ulpn 2>/dev/null | grep -E "[:.]${HY2_PORT}[[:space:]]" | head -3
        printf 'journal 尾部:\n'
        journalctl -u "${HY2_SERVICE}" -n 10 --no-pager 2>/dev/null | tail -10
    fi
    printf '\n重启 HY2 服务？(每次重启只会重启 HY2，不碰主线) [y/N]: '
    local a; read -r a || a=""
    case "${a}" in
        y|Y|yes) run_systemctl restart "${HY2_SERVICE}" && log_info "已重启 ${HY2_SERVICE}" ;;
        *) : ;;
    esac
    return 0
}

hy2_cmd_logs() {
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        log_info "journal (test mode): empty"
        return 0
    fi
    journalctl -u "${HY2_SERVICE}" -n "${1:-80}" --no-pager 2>/dev/null || die "读 journal 失败"
    return 0
}

hy2_cmd_rotate_cert() {
    local snap pin ip pw
    hy2_installed || { die "HY2 还没装。"; return 1; }
    if ! confirm "将生成一张新的自签证书并换掉旧的，然后重启 HY2。⚠ 每个客户端都要用新链接重导（指纹会变），旧链接会连不上。主线 Reality 不受影响。"; then
        log_info "已取消。"; return 0
    fi
    snap="$(hy2_snapshot_create)" || return 1
    hy2_gen_cert || { hy2_snapshot_restore "${snap}" || true; return 1; }
    if ! hy2_config_test; then
        log_error "新证书配置测试失败，回滚。"
        hy2_snapshot_restore "${snap}" || true
        return 1
    fi
    run_systemctl restart "${HY2_SERVICE}" || { hy2_snapshot_restore "${snap}" || true; return 1; }
    pw="$(hy2_read_password)" || return 1
    pin="$(hy2_cert_pin)"
    ip="$(hy2_public_ip || true)"; [[ -z "${ip}" ]] && ip="<你的服务器IP>"
    local link
    link="$(hy2_build_link "${pw}" "${ip}" "${pin}")"
    hy2_save_link "${link}" || log_warn "客户端链接文件写入失败（不影响服务）"
    printf '\n证书已轮换。V2rayNG 新链接（旧链接作废，已存 %s）：\n%s\n' "${HY2_CLIENT_LINK}" "${link}"
    return 0
}

hy2_cmd_restore() {
    local d
    d="${1:-$(hy2_snapshot_latest)}"
    [[ -n "${d}" ]] || { die "没有 HY2 快照"; return 1; }
    if ! confirm "将把 HY2 恢复到快照 ${d}（只动 HY2，主线不动）。"; then
        log_info "已取消。"; return 0
    fi
    hy2_snapshot_restore "${d}"
}

# -------------------------------------------------------------- menu ----
hy2_menu() {
    local c
    printf '%s\n' '┄┄┄┄┄┄┄┄┄┄┄┄┄┄ Hysteria2 附加协议 ┄┄┄┄┄┄┄┄┄┄┄┄┄┄'
    printf ' 13. 安装 HY2（已装时=自定义升级）\n'
    printf ' 14. 卸载 HY2\n'
    printf ' 15. 查看 HY2 链接（V2rayNG）\n'
    printf ' 16. HY2 状态 / 重启服务\n'
    printf ' 17. 查看 HY2 日志\n'
    printf ' 18. 轮换 HY2 证书\n'
    printf '请选择 [13-18]: '
    read -r c || return 0
    case "${c}" in
        13) hy2_cmd_install ;;
        14) hy2_cmd_uninstall ;;
        15) hy2_cmd_link ;;
        16) hy2_cmd_status ;;
        17) hy2_cmd_logs ;;
        18) hy2_cmd_rotate_cert ;;
        *) printf '无效选择：%s\n' "${c}"; return 0 ;;
    esac
    return 0
}

hy2_cmd() {
    local sub="${1:-}"
    shift || true
    case "${sub}" in
        install) hy2_cmd_install "$@" ;;
        uninstall) hy2_cmd_uninstall ;;
        link) hy2_cmd_link ;;
        status) hy2_cmd_status ;;
        logs) hy2_cmd_logs "$@" ;;
        rotate-cert) hy2_cmd_rotate_cert ;;
        restore) hy2_cmd_restore "$@" ;;
        snapshot) hy2_snapshot_create ;;
        menu|"") hy2_menu ;;
        *) die "hy2: 未知子命令 '${sub}' (install|uninstall|link|status|logs|rotate-cert|restore|snapshot)"; return 1 ;;
    esac
}
