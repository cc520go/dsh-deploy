#!/usr/bin/env bash
#
# lib/common.sh — shared primitives for DSH.
#
# Contents: logging, fatal-error discipline, confirmation, overridable
# paths, version helpers, architecture detection, URL encoding, service
# state helpers (with a hermetic test mode), and the `lisa` launcher.
#
# Test mode: set XRAY_TEST_MODE=1 and every system-touching helper below
# switches to canned behaviour (see run_systemctl / service_state /
# service_enabled / listen_ports). Tests additionally set
# XRAY_TEST_AUTO_CONFIRM=1 to auto-answer confirmation prompts. These
# variables are honoured ONLY for tests; production runs never set them.
#
# Fatal-error discipline (learned from the previous draft's bug class):
#   die() prints an error and returns 1 — it does NOT exit and does NOT
#   stop the caller. Every call site that must stop MUST do one of:
#     die "message"; return 1
#     some_fn || return 1
#   A bare `die` with execution continuing past it is a bug. Grep for
#   `die "` in review and confirm each site stops afterwards.
#
# No secret is ever written by this library. Share links are built only
# by lib/node.sh and printed to stdout, never logged to a file.

_LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"

# 统一 PATH：SSH 的非登录会话常常没有 /usr/sbin，导致 logrotate、useradd、
# sysctl、ip 这些系统命令“看起来没装”，进而误判（真实踩过：apt 说
# 0 newly installed，脚本却报安装失败）。这里把标准目录补齐，幂等。
for _p in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    case ":${PATH}:" in
        *":${_p}:"*) ;;
        *) PATH="${PATH:+${PATH}:}${_p}" ;;
    esac
done
export PATH
unset _p

# ------------------------------------------------------------ logging ----
log_info()  { printf '[INFO] %s\n' "$*" >&2; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

# die: print an error and return 1. Callers MUST stop afterwards (see above).
die() { log_error "$*"; return 1; }

# snapshot_link_previous <sha> <dir> <parent> <name-glob> <file>: when an
# older snapshot recorded the same binary hash, hardlink its file into <dir>
# instead of copying the multi-MB core binary again. Snapshots never share
# an inode with the live path, so an in-place upgrade cannot corrupt them;
# restores must still unlink the destination first (cp --remove-destination).
# Falls back to a copy when linking is not possible.
snapshot_link_previous() {
    local sha="$1" dir="$2" parent="$3" pattern="$4" file="$5" prev
    for prev in "${parent}"/${pattern}; do
        [[ -d "${prev}" && "${prev}" != "${dir}" ]] || continue
        [[ -f "${prev}/${file}" ]] || continue
        grep -qx "binary_sha256=${sha}" "${prev}/meta.txt" 2>/dev/null || continue
        if ln "${prev}/${file}" "${dir}/${file}" 2>/dev/null; then
            return 0
        fi
        cp -a "${prev}/${file}" "${dir}/${file}" && return 0
    done
    return 1
}

# ------------------------------------------------- test-mode gating ----
# test_override <VAR>: prints the value of a XRAY_TEST_* override ONLY
# when XRAY_TEST_MODE=1. In production, a set override is ignored and a
# warning goes to stderr (never to stdout, so diagnostic output is not
# polluted). This prevents a stray test variable left in a shell from
# poisoning diagnostics, firewall status, uptime, or the loopback probe.
# All XRAY_TEST_* overrides in this tool must go through this helper;
# a direct read of a XRAY_TEST_* variable outside a XRAY_TEST_MODE=1
# branch is a bug.
test_override() {
    local var="$1" val
    val="${!var:-}"
    if [[ -z "${val}" ]]; then
        return 1
    fi
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf '%s' "${val}"
        return 0
    fi
    printf '[WARN] ignoring test override %s outside test mode\n' "${var}" >&2
    return 1
}

# --------------------------------------------------------- confirmation ----
# confirm "<impact statement>": prints the impact, then requires the user
# to type exactly "yes". Returns 0 on confirmation, 1 otherwise.
# In test mode with XRAY_TEST_AUTO_CONFIRM=1 it returns 0 immediately.
confirm() {
    if [[ "${XRAY_TEST_MODE:-0}" == "1" && "${XRAY_TEST_AUTO_CONFIRM:-0}" == "1" ]]; then
        return 0
    fi
    printf '%s\n' "$1"
    printf 'Type "yes" to confirm, anything else to cancel: '
    local ans
    read -r ans || return 1
    [[ "${ans}" == "yes" ]]
}

# -------------------------------------------------------------- paths ----
# Every path is overridable through the environment so tests can redirect
# all filesystem effects into a temp dir. Production defaults are the
# official Xray-install layout.
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONF_DIR="${XRAY_CONF_DIR:-/usr/local/etc/xray}"
XRAY_CONF="${XRAY_CONF:-${XRAY_CONF_DIR}/config.json}"
XRAY_SHARE_DIR="${XRAY_SHARE_DIR:-/usr/local/share/xray}"
XRAY_LOG_DIR="${XRAY_LOG_DIR:-/var/log/xray}"
XRAY_UNIT_DIR="${XRAY_UNIT_DIR:-/etc/systemd/system}"
# Snapshot parent: snapshots are ${SNAPSHOT_PARENT}/xray-backup-<stamp>-<ver>/
# (same naming convention the operator already uses under /root).
SNAPSHOT_PARENT="${SNAPSHOT_PARENT:-/root}"
# State dir: node.params, BBR backups, auth-rollback state.
# 1.1.0 renamed this from /root/.xray-reality-manager; migrate_legacy_state()
# copies the old dir once and leaves a symlink for one release.
DSH_STATE_DIR="${DSH_STATE_DIR:-/root/.dsh-deploy}"
LEGACY_STATE_DIR="${LEGACY_STATE_DIR:-/root/.xray-reality-manager}"
# Operator's own node parameter file (root-only, on the server, never in repo).
NODE_PARAMS_FILE="${NODE_PARAMS_FILE:-${DSH_STATE_DIR}/node.params}"
# Menu launcher directory (default /usr/local/bin, so `DSH` is on PATH).
LAUNCHER_DIR="${LAUNCHER_DIR:-/usr/local/bin}"
LAUNCHER_NAME="DSH"
# 旧命令 lisa 已废弃：安装时如果发现它指向本工具，顺手清掉。
LEGACY_LAUNCHER_NAME="lisa"
# Persistent home for the installed tool. 1.1.0 renamed it from
# /usr/local/share/xray-reality-manager; the old dir is archived and
# removed after the new launcher is in place (retire_legacy_tool_dir).
TOOL_INSTALL_DIR="${TOOL_INSTALL_DIR:-/usr/local/share/dsh}"
LEGACY_TOOL_DIR="${LEGACY_TOOL_DIR:-/usr/local/share/xray-reality-manager}"
LEGACY_TOOL_BACKUP_DIR="${LEGACY_TOOL_BACKUP_DIR:-/root}"

# Default core version: read from the VERSION file next to lib/, else pinned.
default_version() {
    local vf
    vf="$(dirname "${_LIB_DIR}")/VERSION"
    if [[ -f "${vf}" ]]; then
        tr -d '[:space:]' < "${vf}"
    else
        printf '26.10.31'
    fi
}

# DSH release identity: deliberately separate from the Xray core version.
dsh_release_version() {
    local vf
    vf="$(dirname "${_LIB_DIR}")/DSH_VERSION"
    if [[ -f "${vf}" ]]; then
        tr -d '[:space:]' < "${vf}"
    else
        printf 'unknown'
    fi
}

dsh_release_codename() {
    local vf
    vf="$(dirname "${_LIB_DIR}")/DSH_CODENAME"
    if [[ -f "${vf}" ]]; then
        tr -d '[:space:]' < "${vf}"
    else
        printf 'unknown'
    fi
}

# ----------------------------------------------------------- preconditions ----
require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "this operation must run as root (use sudo or run as root)."
        return 1
    fi
    return 0
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        die "required command not found: $1"
        return 1
    fi
    return 0
}

# -------------------------------------------------------------- version ----
# normalize_version: "v26.10.21" -> "26.10.21"; rejects anything else.
normalize_version() {
    local v="$1"
    v="${v#v}"
    v="${v#V}"
    if [[ ! "${v}" =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
        die "invalid version: $1 (expected like 26.10.21)"
        return 1
    fi
    printf '%s' "${v}"
}

# version_cmp <a> <b>: prints -1, 0 or 1 (CalVer, numeric per segment).
version_cmp() {
    local a b
    a="$(normalize_version "$1")" || return 1
    b="$(normalize_version "$2")" || return 1
    local -a ap bp
    IFS='.' read -r -a ap <<< "${a}"
    IFS='.' read -r -a bp <<< "${b}"
    local i av bv
    for i in 0 1 2; do
        av="${ap[i]}"
        bv="${bp[i]}"
        if [[ "${av}" -lt "${bv}" ]]; then printf '%s' "-1"; return 0; fi
        if [[ "${av}" -gt "${bv}" ]]; then printf '%s' "1"; return 0; fi
    done
    printf '%s' "0"
}

# ------------------------------------------------------------ architecture ----
# detect_arch_suffix: x86_64 -> linux-64, aarch64 -> linux-arm64-v8a.
detect_arch_suffix() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'linux-64' ;;
        aarch64|arm64) printf 'linux-arm64-v8a' ;;
        *)
            die "unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------- URL encoding ----
# url_encode: percent-encodes a string using bash + od only (no python/jq).
# Unreserved characters (RFC 3986) pass through; every other byte becomes
# %XX (uppercase hex). Locale-independent by design: the input is first
# expanded to its raw bytes with od -An -tx1 -v (the -v disables the '*'
# repeat compression), and encoding iterates over bytes, never over
# bash characters. The old character-indexing version broke under
# UTF-8 locales (bash counts one Chinese character as 1 character, so
# od's 3 bytes were glued into one token, e.g. %E4B8AD instead of
# %E4%B8%AD); this version gives identical output in C, POSIX,
# C.utf8 and en_US.UTF-8 locales.
url_encode() {
    local str="$1" out="" b
    # Word-splitting over od's hex output is intentional here: od
    # emits only ASCII hex tokens separated by whitespace.
    # shellcheck disable=SC2086
    for b in $(printf '%s' "${str}" | od -An -tx1 -v); do
        case "${b}" in
            30|31|32|33|34|35|36|37|38|39|41|42|43|44|45|46|47|48|49|4a|4b|4c|4d|4e|4f|50|51|52|53|54|55|56|57|58|59|5a|61|62|63|64|65|66|67|68|69|6a|6b|6c|6d|6e|6f|70|71|72|73|74|75|76|77|78|79|7a|2e|2d|5f|7e)
                out+="$(printf "\\x${b}")" ;;
            *)
                out+="%$(printf '%s' "${b}" | tr 'a-f' 'A-F')" ;;
        esac
    done
    printf '%s' "${out}"
}

# ------------------------------------------------------ service helpers ----
# All systemctl access goes through these helpers so tests can run without
# touching the real init system (XRAY_TEST_MODE=1).
run_systemctl() {
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf 'systemctl %s\n' "$*" >> "${XRAY_TEST_LOG:-/tmp/xray-test-systemctl.log}"
        local a
        for a in "$@"; do
            case ",${XRAY_TEST_SYSTEMCTL_FAIL:-}," in
                *",${a},"*) return 1 ;;
            esac
        done
        return 0
    fi
    systemctl "$@"
}

# service_state: prints active / inactive / unknown (stdout only).
service_state() {
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf '%s' "${XRAY_TEST_SERVICE_STATE:-inactive}"
        return 0
    fi
    systemctl is-active xray 2>/dev/null || printf 'inactive'
}

# service_enabled: prints enabled / disabled / unknown (stdout only).
service_enabled() {
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf '%s' "${XRAY_TEST_SERVICE_ENABLED:-disabled}"
        return 0
    fi
    systemctl is-enabled xray 2>/dev/null || printf 'disabled'
}

# listen_ports: prints space-separated local TCP listen ports (stdout only).
listen_ports() {
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf '%s' "${XRAY_TEST_LISTEN_PORTS:-}"
        return 0
    fi
    ss -tln 2>/dev/null | awk 'NR>1 {split($4, a, ":"); print a[length(a)]}' \
        | sort -u | tr '\n' ' '
}

# ------------------------------------------------------------ firewall ----
# firewall_status: read-only firewall check. Never opens anything.
# Prints one line and returns: 0 = pass, 2 = warn, 3 = skip.
# Test mode override (test-only, never used in production):
#   XRAY_TEST_FIREWALL=active-allow|active-deny|inactive|absent
#   XRAY_TEST_FIREWALL=active-allow-out|active-allow-source (test-only
#   extra states for the IN/OUT and source-IP cases below)
# Production: ufw absent -> skip; ufw inactive -> WARN (not pass: the
# tool cannot see the cloud security group, so "inactive" must not be
# read as "firewall OK"); ufw active with a 443/tcp ALLOW IN rule ->
# pass; ufw active with only an ALLOW OUT rule, or with no 443 rule ->
# warn. A rule limited to a specific source IP is a pass with a
# reminder, not a silent pass. This check does NOT cover SSH or the
# cloud security group, and it never opens either.
firewall_status() {
    local fw_override
    if fw_override="$(test_override XRAY_TEST_FIREWALL)"; then
        case "${fw_override}" in
            active-allow)
                printf 'pass: ufw active, 443/tcp ALLOW IN (test mode). 本检查不覆盖 SSH 和安全组 (this check does not cover SSH or the cloud security group).\n'; return 0 ;;
            active-deny)
                printf 'warn: ufw active but 443/tcp is NOT allowed (test mode); cloud security group must also allow 443. This tool never opens the firewall automatically. 本检查不覆盖 SSH 和安全组.\n'; return 2 ;;
            active-allow-out)
                printf 'warn: ufw active but 443/tcp is only ALLOW OUT, not ALLOW IN (test mode); inbound 443 is still blocked. 本检查不覆盖 SSH 和安全组.\n'; return 2 ;;
            active-allow-source)
                printf 'pass: ufw active, 443/tcp ALLOW IN but limited to a specific source (test mode); check that the source covers your client. 本检查不覆盖 SSH 和安全组.\n'; return 0 ;;
            inactive)
                printf 'warn: ufw inactive (本机 ufw 没开，云厂商安全组未查; cloud security group not checked). 本检查不覆盖 SSH 和安全组 (this check does not cover SSH or the cloud security group).\n'; return 2 ;;
            absent)
                printf 'skip: ufw not installed; check the cloud security group manually (this tool never opens the firewall automatically). 本检查不覆盖 SSH 和安全组.\n'; return 3 ;;
        esac
    fi
    if ! command -v ufw >/dev/null 2>&1; then
        printf 'skip: ufw not installed; check the cloud security group manually (this tool never opens the firewall automatically). 本检查不覆盖 SSH 和安全组.\n'; return 3
    fi
    local st
    st="$(ufw status 2>/dev/null || true)"
    if printf '%s' "${st}" | grep -q 'Status: inactive'; then
        printf 'warn: ufw inactive (本机 ufw 没开，云厂商安全组未查; cloud security group not checked). 本检查不覆盖 SSH 和安全组 (this check does not cover SSH or the cloud security group).\n'; return 2
    fi
    if printf '%s' "${st}" | grep -q 'Status: active'; then
        local allow_in allow_any
        allow_in="$(printf '%s' "${st}" | grep -E '443/tcp.*ALLOW IN|443.*ALLOW IN' || true)"
        if [[ -n "${allow_in}" ]]; then
            if printf '%s' "${allow_in}" | grep -q 'Anywhere'; then
                printf 'pass: ufw active, 443/tcp ALLOW IN. 本检查不覆盖 SSH 和安全组.\n'; return 0
            fi
            printf 'pass: ufw active, 443/tcp ALLOW IN but limited to a specific source; check that the source covers your client. Rule: %s. 本检查不覆盖 SSH 和安全组.\n' "$(printf '%s' "${allow_in}" | head -1)"; return 0
        fi
        allow_any="$(printf '%s' "${st}" | grep -E '443/tcp.*ALLOW|443.*ALLOW' || true)"
        if [[ -n "${allow_any}" ]]; then
            printf 'warn: ufw active but 443/tcp is only ALLOW OUT (or otherwise not ALLOW IN); inbound 443 is still blocked. Allow 443/tcp IN in ufw AND in the cloud security group. This tool never opens the firewall automatically. 本检查不覆盖 SSH 和安全组.\n'; return 2
        fi
        printf 'warn: ufw active but 443/tcp is NOT allowed; allow 443/tcp IN in ufw AND in the cloud security group. This tool never opens the firewall automatically. 本检查不覆盖 SSH 和安全组.\n'; return 2
    fi
    printf 'skip: ufw status unreadable; check the cloud security group manually. 本检查不覆盖 SSH 和安全组.\n'; return 3
}

# service_uptime: service START time (ActiveEnterTimestamp), NOT a
# duration. Callers must label it as a start time, never as "uptime"
# duration. Returns "unknown" when unavailable.
# Test override (test-only, gated by XRAY_TEST_MODE=1): XRAY_TEST_SERVICE_UPTIME.
service_uptime() {
    local up_override
    if up_override="$(test_override XRAY_TEST_SERVICE_UPTIME)"; then
        printf '%s' "${up_override}"; return 0
    fi
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf 'unknown (test mode)'; return 0
    fi
    local ts
    ts="$(systemctl show xray --property=ActiveEnterTimestamp --value 2>/dev/null || true)"
    if [[ -n "${ts}" ]]; then printf '%s' "${ts}"; else printf 'unknown'; fi
    return 0
}

# last_error_log_time: mtime of the error log only, never log content
# (log lines could contain addresses). Test override (test-only,
# gated by XRAY_TEST_MODE=1): XRAY_TEST_LAST_ERROR_TIME.
last_error_log_time() {
    local err_override
    if err_override="$(test_override XRAY_TEST_LAST_ERROR_TIME)"; then
        printf '%s' "${err_override}"; return 0
    fi
    if [[ -f "${XRAY_LOG_DIR}/error.log" ]]; then
        stat -c '%y' "${XRAY_LOG_DIR}/error.log" 2>/dev/null | cut -d'.' -f1 || printf 'unknown'
        return 0
    fi
    printf 'no error log file (see menu 11 for journalctl logs)'
    return 0
}

# migrate_legacy_state: one-time move of the old state dir to DSH_STATE_DIR.
# Copies first, verifies node.params, then deletes the old dir. Since
# 1.2.0 no compatibility symlink is kept. Aborts (without deleting the old
# dir) when the two node.params files disagree.
migrate_legacy_state() {
    local old="${LEGACY_STATE_DIR}" new="${DSH_STATE_DIR}" a b
    [[ "${old}" != "${new}" ]] || return 0
    # The suite must never touch the real /root state dir unless a test
    # explicitly points LEGACY_STATE_DIR at a sandbox path.
    if [[ "${XRAY_TEST_MODE:-0}" == "1" && "${old}" == "/root/.xray-reality-manager" ]]; then
        return 0
    fi
    if [[ -L "${old}" ]]; then
        if [[ "$(readlink "${old}")" == "${new}" ]]; then
            # 1.1.0 left this compatibility symlink; 1.2.0 removes it.
            rm -f "${old}" && log_info "removed legacy state symlink: ${old}"
            return 0
        fi
        log_warn "legacy state path ${old} is a symlink to $(readlink "${old}"); leaving it unchanged."
        return 0
    fi
    [[ -d "${old}" ]] || return 0
    if [[ ! -d "${new}" ]]; then
        cp -a "${old}" "${new}" || { log_error "cannot copy legacy state dir ${old}"; return 1; }
    else
        # Keep new files authoritative; only fill in what is missing.
        cp -an "${old}/." "${new}/" || { log_error "cannot merge legacy state into ${new}"; return 1; }
    fi
    if [[ -f "${old}/node.params" ]]; then
        [[ -f "${new}/node.params" ]] || { log_error "node.params missing after migration"; return 1; }
        a="$(sha256sum "${old}/node.params" | cut -d' ' -f1)"
        b="$(sha256sum "${new}/node.params" | cut -d' ' -f1)"
        if [[ "${a}" != "${b}" ]]; then
            log_error "legacy and new node.params differ; refusing to merge (old dir kept at ${old})."
            return 1
        fi
    fi
    chmod 700 "${new}" 2>/dev/null || true
    rm -rf "${old}" || { log_error "cannot remove legacy state dir ${old}"; return 1; }
    log_info "legacy state migrated: ${old} -> ${new} (legacy path removed)"
    return 0
}

# retire_legacy_tool_dir: after the new launcher works, archive the old
# tool directory and remove it, so two copies of the code cannot drift.
retire_legacy_tool_dir() {
    local old="${LEGACY_TOOL_DIR}" new="${TOOL_INSTALL_DIR}" stamp backup
    [[ "${old}" != "${new}" ]] || return 0
    if [[ "${XRAY_TEST_MODE:-0}" == "1" && "${old}" == "/usr/local/share/xray-reality-manager" ]]; then
        return 0
    fi
    if [[ -L "${old}" ]]; then
        rm -f "${old}" 2>/dev/null || true
        return 0
    fi
    [[ -d "${old}" ]] || return 0
    if [[ ! -f "${new}/manage.sh" ]]; then
        log_warn "new tool dir ${new} is not ready; keeping ${old} for now."
        return 0
    fi
    stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || printf 'unknown')"
    backup="${LEGACY_TOOL_BACKUP_DIR}/dsh-legacy-tool-${stamp}.tar.gz"
    if tar -czf "${backup}" -C "$(dirname "${old}")" "$(basename "${old}")" 2>/dev/null; then
        chmod 600 "${backup}" 2>/dev/null || true
        rm -rf "${old}" && log_info "legacy tool dir retired (backup: ${backup})"
    else
        log_warn "could not archive ${old}; leaving it in place."
    fi
    return 0
}

# ------------------------------------------------------------ launcher ----
# install_launcher <manage.sh path>: installs the tool's runtime files
# to ${TOOL_INSTALL_DIR} (persistent, never /tmp) and creates
# ${LAUNCHER_DIR}/${LAUNCHER_NAME} as a symlink to the persistent manage.sh. NEVER
# overwrites an existing regular file; if an existing symlink points
# elsewhere (e.g. an old /tmp download dir), warns then repoints it.
# Re-running always refreshes the persistent copy from the source, so a
# re-install with a newer download updates the installed menu.
# In test mode LAUNCHER_DIR and TOOL_INSTALL_DIR point at temp dirs.
# service_display_state [port]: listener-aware service state for display.
# "active" alone is misleading: a process can be active (running) on a
# stale empty config with no listener (failed first install). When a port
# is given and the service reports active, verify the port is actually
# listening; otherwise report "active (no listener)" so a down node never
# shows as up. With no port (no params yet), falls back to service_state
# unchanged. service_state itself is never changed (callers that need the
# raw systemd state keep using it).
service_display_state() {
    local state port ports
    state="$(service_state)"
    port="${1:-}"
    if [[ "${state}" != "active" || -z "${port}" ]]; then
        printf '%s' "${state}"
        return 0
    fi
    ports="$(listen_ports)"
    case " ${ports} " in
        *" ${port} "*) printf 'active' ;;
        *) printf 'active (no listener)' ;;
    esac
    return 0
}

# verify_listening [port]: boolean listener check for control flow (unlike
# service_display_state, which formats a state string). Returns 0 when the
# port is listening, or when no port is given (nothing to verify); returns
# 1 when a given port is not listening. Uses listen_ports (test-mode aware).
verify_listening() {
    local port="${1:-}"
    local ports
    if [[ -z "${port}" ]]; then
        return 0
    fi
    ports="$(listen_ports)"
    case " ${ports} " in
        *" ${port} "*) return 0 ;;
        *) return 1 ;;
    esac
}

# wait_for_listening [port]: like verify_listening, but after a
# (re)start it polls up to ~10 seconds before giving up, because Xray
# needs a moment to bind after systemctl restart returns. A single
# immediate check falsely fails (the wait race seen on every fresh /
# reinstall run: install exits 1, node is up ~5s later). Test mode:
# single check only (no sleeping, deterministic).
wait_for_listening() {
    local port="${1:-}"
    local i
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        verify_listening "${port}"
        return $?
    fi
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if verify_listening "${port}"; then
            return 0
        fi
        sleep 1
    done
    verify_listening "${port}"
    return $?
}

install_launcher() {
    local target="$1" link="${LAUNCHER_DIR}/${LAUNCHER_NAME}"
    local src_dir persist_dir persist_target
    src_dir="$(dirname "${target}")"
    persist_dir="${TOOL_INSTALL_DIR}"
    persist_target="${persist_dir}/manage.sh"
    if [[ -e "${link}" && ! -L "${link}" ]]; then
        die "refusing to overwrite existing non-link file: ${link} (remove it manually if you really want the '${LAUNCHER_NAME}' launcher there)."
        return 1
    fi
    # 迁移：旧版本装过 lisa 软链，这里删掉它（只删指向本工具的软链，
    # 绝不动同名的真实文件）。放在函数早段，保证“已安装”分支也会执行。
    if [[ -n "${LEGACY_LAUNCHER_NAME}" && "${LEGACY_LAUNCHER_NAME}" != "${LAUNCHER_NAME}" ]]; then
        local legacy="${LAUNCHER_DIR}/${LEGACY_LAUNCHER_NAME}"
        if [[ -L "${legacy}" && "$(readlink "${legacy}")" == "${persist_target}" ]]; then
            rm -f -- "${legacy}" && log_info "removed legacy launcher: ${legacy}"
        fi
    fi
    mkdir -p "${persist_dir}/lib" || { die "cannot create tool dir: ${persist_dir}"; return 1; }
    if [[ "${target}" != "${persist_target}" ]]; then
        compgen -G "${src_dir}/lib/*.sh" > /dev/null || { die "no lib files in source dir: ${src_dir}/lib"; return 1; }
        cp "${target}" "${persist_target}" || { die "cannot install manage.sh"; return 1; }
        cp "${src_dir}/diagnose.sh" "${persist_dir}/diagnose.sh" || { die "cannot install diagnose.sh"; return 1; }
        # 体检脚本：装完让用户能自己跑 `DSH smoke`，不需要再找文件。
        if [[ -f "${src_dir}/smoke-remote.sh" ]]; then
            cp "${src_dir}/smoke-remote.sh" "${persist_dir}/smoke-remote.sh" 2>/dev/null || true
        elif [[ -f "${src_dir}/tools/smoke-remote.sh" ]]; then
            cp "${src_dir}/tools/smoke-remote.sh" "${persist_dir}/smoke-remote.sh" 2>/dev/null || true
        fi
        cp "${src_dir}/lib/"*.sh "${persist_dir}/lib/" || { die "cannot install lib files"; return 1; }
        if [[ -f "${src_dir}/VERSION" ]]; then
            cp "${src_dir}/VERSION" "${persist_dir}/VERSION" || { die "cannot install VERSION"; return 1; }
        fi
        # DSH release identity travels with the tool; VERSION stays the core.
        if [[ -f "${src_dir}/DSH_VERSION" ]]; then
            cp "${src_dir}/DSH_VERSION" "${persist_dir}/DSH_VERSION" 2>/dev/null || true
        fi
        if [[ -f "${src_dir}/DSH_CODENAME" ]]; then
            cp "${src_dir}/DSH_CODENAME" "${persist_dir}/DSH_CODENAME" 2>/dev/null || true
        fi
        # Pinned add-on versions live in a separate file; without it the
        # HY2 module refuses to install (by design), so it must travel with
        # the tool.
        if [[ -f "${src_dir}/versions-hy2.conf" ]]; then
            cp "${src_dir}/versions-hy2.conf" "${persist_dir}/versions-hy2.conf" \
                || { die "cannot install versions-hy2.conf"; return 1; }
        fi
        # Optional, non-fatal: keep the logrotate template in the
        # persistent copy too, so a re-run of install.sh from the
        # persistent dir can still install rotation.
        if [[ -d "${src_dir}/logrotate" ]]; then
            mkdir -p "${persist_dir}/logrotate" 2>/dev/null || true
            cp "${src_dir}/logrotate/"* "${persist_dir}/logrotate/" 2>/dev/null || true
        fi
        chmod +x "${persist_target}" "${persist_dir}/diagnose.sh" "${persist_dir}/lib/"*.sh 2>/dev/null || true
    fi
    if [[ -L "${link}" ]]; then
        local cur
        cur="$(readlink "${link}")"
        if [[ "${cur}" == "${persist_target}" ]]; then
            log_info "launcher already installed: ${link} -> ${persist_target}"
            return 0
        fi
        log_warn "launcher ${link} currently points at ${cur}; repointing to ${persist_target}."
    fi
    ln -sfn "${persist_target}" "${link}" || { die "failed to create launcher link: ${link}"; return 1; }
    log_info "launcher installed: type '${LAUNCHER_NAME}' to open the menu."
    return 0
}
