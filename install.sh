#!/usr/bin/env bash
#
# install.sh — one-click install and initialization for xray-reality-manager.
#
# Fresh install: environment checks -> download verified core -> official
# installer (local mode, xray user) -> permission migration -> `DSH`
# launcher first -> node setup / config test (+ auto-repair if invalid)
# -> enable + restart + listener check -> share link.
#
# Re-running install on an already-installed machine NEVER destroys a
# valid (non-empty) config: it migrates permissions, installs the `DSH`
# launcher first, and if the config is still the installer's empty
# placeholder ({}), it completes node setup; otherwise it tests the
# config (auto-repairing an invalid one: snapshot first, dest only;
# restarting a valid one only when it is not listening), then reports
# status.
#
# Usage:
#   install.sh [--check] [--auto] [version]
#     --check   run environment checks only, do not install
#     --auto    non-interactive install: auto-detect public IP, defaults
#               for port/SNI/dest/Vision, no prompts, no confirmation
#     version   core version to install (default: VERSION file, 26.10.21)

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/download.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/backup.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/perm.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/node.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/service.sh"

# Non-interactive mode, set by --auto (or pre-set in the environment).
# In auto mode node_setup asks nothing: host comes from XRAY_NODE_HOST
# or public-IP auto-detection, everything else uses the standard
# defaults, and the node-creation confirmation is implied by --auto.
AUTO_INSTALL="${AUTO_INSTALL:-0}"
# Optional Hysteria2 add-on, installed in the same run (--with-hy2).
# Never fatal for the main line: a HY2 failure only warns.
WITH_HY2="${WITH_HY2:-0}"
# Explicit repair flag, set by --repair (or pre-set in the environment).
# --auto alone NEVER implies a repair: a valid, listening node exits
# untouched under --auto; an invalid / incomplete node is only repaired
# when --repair is also given, after a snapshot, dest/port only.
REPAIR_INSTALL="${REPAIR_INSTALL:-0}"

usage() {
    printf 'Usage: %s [--check] [--auto] [--repair] [version]\n' "$(basename "$0")"
    printf '  --check   run environment checks only, do not install\n'
    printf '  --auto    non-interactive install (auto-detect public IP, defaults, no prompts)\n'
    printf '  --with-hy2  also install the Hysteria2 add-on (UDP 443, optional second protocol)\n'
    printf '  --repair  explicit repair only: with --auto, allow repairing an invalid/incomplete node (snapshot first, dest/port only); without --repair, --auto never repairs\n'
    printf '  version   core version to install (default: %s)\n' "$(default_version)"
}

# Debian 12 pre-install environment check (added 2026-11-02, main-chat
# confirmed scope): detect first, auto-install only small tools, fail
# early instead of failing halfway through install (the fresh-Debian
# curl-then-unzip-then-apt-lock sequence seen on 2026-11-02).
# Scope, exactly as confirmed:
#   - Debian 12 ONLY. Other systems are rejected here, never auto-fixed.
#   - Detects: OS, architecture, systemd, 443 occupancy, GitHub
#     Releases network, and small tools curl/wget/tar/unzip/gzip/
#     iproute2(ss)/ca-certificates. Missing small tools are installed
#     with apt; an apt lock is NEVER deleted — it means another apt
#     process is running, so the check fails with "wait and rerun".
#   - BBR is REPORT ONLY: kernel/congestion/qdisc/tcp_bbr version are
#     printed, never installed, never sysctl -w, never tc changed.
#     BBRv3+FQ stays a manual `lisa bbr bbr3` step by the operator.
#   - Firewall / cloud security group: WARNING only, never auto-opened.
#   - No Docker, no Nginx, no other extra software is ever installed.
# Testability: ENV_OS_RELEASE, ENV_GITHUB_URL and
# BBR_MODULE_VERSION_FILE are overridable paths/URLs; in test mode
# (XRAY_TEST_MODE=1) apt is never run — the check only logs what it
# would install, and XRAY_TEST_APT_FAIL=1 simulates an apt failure.
# The GitHub network check is also skipped in test mode (the suite is
# hermetic and must not depend on real network) unless
# XRAY_TEST_NETWORK_CHECK=1 forces it, in which case curl/wget from
# PATH (a fakebin in tests) is used.
ENV_OS_RELEASE="${ENV_OS_RELEASE:-/etc/os-release}"
ENV_GITHUB_URL="${ENV_GITHUB_URL:-https://github.com/XTLS/Xray-core/releases}"
BBR_MODULE_VERSION_FILE="${BBR_MODULE_VERSION_FILE:-/sys/module/tcp_bbr/version}"

# _env_tool_present <tool>: 1 if the tool (or, for ca-certificates, its
# update command / bundle) is available. ca-certificates has no binary
# of its own, so update-ca-certificates (or the bundle file) is the
# proxy check; iproute2 is checked via ss.
_env_tool_present() {
    case "$1" in
        ca-certificates)
            command -v update-ca-certificates >/dev/null 2>&1 || [[ -f /etc/ssl/certs/ca-certificates.crt ]] ;;
        *) command -v "$1" >/dev/null 2>&1 ;;
    esac
}

# _ensure_env_tools: install missing small tools with apt, or fail.
# Never deletes an apt lock, never installs anything outside the small
# tool list below.
_ensure_env_tools() {
    local tools="curl wget tar unzip gzip ss ca-certificates"
    local missing_tools="" missing_pkgs="" t pkg
    for t in ${tools}; do
        if ! _env_tool_present "${t}"; then
            missing_tools+="${t} "
            case "${t}" in
                ss) pkg="iproute2" ;;
                ca-certificates) pkg="ca-certificates" ;;
                *) pkg="${t}" ;;
            esac
            missing_pkgs+="${pkg} "
        fi
    done
    if [[ -z "${missing_tools}" ]]; then
        log_info "environment tools present: curl, wget, tar, unzip, gzip, ss, ca-certificates."
        return 0
    fi
    log_info "missing environment tools: ${missing_tools}-> installing with apt: ${missing_pkgs}"
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        if [[ "${XRAY_TEST_APT_FAIL:-0}" == "1" ]]; then
            die "apt install failed (test mode simulation); missing tools remain: ${missing_tools}"
            return 1
        fi
        log_info "test mode: would run apt-get install -y ${missing_pkgs}(apt not actually run)."
        return 0
    fi
    require_command apt-get || return 1
    # A freshly reinstalled Debian often has cloud-init / unattended-upgrades
    # holding the dpkg lock for a couple of minutes. Wait for it instead of
    # failing the whole install on a transient condition.
    wait_for_apt_lock() {
        local waited=0 limit="${APT_LOCK_WAIT:-300}"
        while [[ "${waited}" -lt "${limit}" ]]; do
            if ! command -v fuser >/dev/null 2>&1 || ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
                return 0
            fi
            [[ "${waited}" -eq 0 ]] && log_info "dpkg 锁被占用（可能是云初始化），最多等 ${limit} 秒 ..."
            sleep 10
            waited=$((waited + 10))
        done
        return 1
    }
    # cloud-init keeps dpkg busy for a minute or two after a fresh
    # reinstall; wait for it instead of racing it (bounded).
    if command -v cloud-init >/dev/null 2>&1; then
        if ! timeout "${CLOUDINIT_WAIT:-180}" cloud-init status --wait >/dev/null 2>&1; then
            log_warn "cloud-init 未在 ${CLOUDINIT_WAIT:-180} 秒内结束（继续，后面会等 dpkg 锁）"
        else
            log_info "cloud-init 已结束"
        fi
    fi
    if ! wait_for_apt_lock; then
        die "apt 锁等待 ${APT_LOCK_WAIT:-300} 秒仍未释放；等系统初始化完再重跑安装，切勿删除锁文件。"
        return 1
    fi
    apt-get update >/dev/null 2>&1 || log_warn "apt-get update failed; trying install from the local package cache."
    local apt_out apt_rc try
    for try in 1 2 3; do
        # shellcheck disable=SC2086
        apt_out="$(apt-get install -y ${missing_pkgs} 2>&1)"; apt_rc=$?
        [[ "${apt_rc}" -eq 0 ]] && break
        printf '%s' "${apt_out}" | grep -qi 'lock' || break
        log_warn "apt 又被锁住了，等 15 秒重试（第 ${try}/3 次）..."
        sleep 15
    done
    if [[ "${apt_rc}" -ne 0 ]]; then
        if printf '%s' "${apt_out}" | grep -qi 'lock'; then
            die "apt is locked by another apt/dpkg process; do NOT delete the lock file — wait for that process to finish, then rerun install."
            return 1
        fi
        die "apt-get install failed for: ${missing_pkgs} (first line: $(printf '%s' "${apt_out}" | head -1))"
        return 1
    fi
    for t in ${tools}; do
        if ! _env_tool_present "${t}"; then
            # A tool that was not in the missing list cannot fail here;
            # only re-check what we tried to install.
            case " ${missing_tools} " in
                *" ${t} "*) die "still missing after apt install: ${t}"; return 1 ;;
            esac
        fi
    done
    log_info "environment tools installed: ${missing_pkgs}"
    return 0
}

# _check_port_443: fail when 443 is already taken by something other
# than the running xray service (fresh node defaults to 443 and could
# not bind). An active xray service on 443 is the reinstall/upgrade
# path and passes. ss missing -> warn only, never a silent pass.
_check_port_443() {
    if ! command -v ss >/dev/null 2>&1; then
        log_warn "ss not found; 443 occupancy check skipped (port check will be limited)."
        return 0
    fi
    local ports
    ports="$(listen_ports)"
    case " ${ports} " in
        *" 443 "*)
            if [[ "$(service_state)" == "active" ]]; then
                log_info "port 443 already listening (xray service active; reinstall/upgrade path)."
                return 0
            fi
            die "port 443 is already in use by another process; free 443 (or stop that service) before install, otherwise the new node cannot bind 443."
            return 1
            ;;
    esac
    log_info "port 443 free."
    return 0
}

# _check_github_network: the core and the official installer both come
# from GitHub, so a failed reachability check here fails early with a
# readable reason instead of a mid-download failure later.
_check_github_network() {
    if [[ "${XRAY_TEST_MODE:-0}" == "1" && "${XRAY_TEST_NETWORK_CHECK:-0}" != "1" ]]; then
        log_info "test mode: GitHub network check skipped (set XRAY_TEST_NETWORK_CHECK=1 to force it)."
        return 0
    fi
    local url="${ENV_GITHUB_URL}"
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSI --max-time 15 "${url}" >/dev/null 2>&1; then
            log_info "GitHub Releases reachable: ${url}"
            return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget --spider -q --timeout=15 "${url}" >/dev/null 2>&1; then
            log_info "GitHub Releases reachable: ${url}"
            return 0
        fi
    else
        die "neither curl nor wget is available for the GitHub network check (tools should have been installed above)."
        return 1
    fi
    die "cannot reach GitHub Releases (${url}); check network, DNS and proxy, then rerun install."
    return 1
}

# _report_bbr_status: READ ONLY. Prints kernel, congestion, qdisc and
# tcp_bbr version and whether BBRv3+FQ is effective. It never installs
# a kernel, never writes sysctl, never runs tc, never creates a unit.
# BBRv3+FQ remains a manual operator step (`lisa bbr bbr3`).
_report_bbr_status() {
    local kernel cong qdisc modver effective="not effective"
    kernel="$(uname -r 2>/dev/null || printf 'unknown')"
    cong="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '')"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf '')"
    if [[ -f "${BBR_MODULE_VERSION_FILE}" ]]; then
        modver="$(tr -d '[:space:]' < "${BBR_MODULE_VERSION_FILE}" 2>/dev/null || printf '')"
    else
        modver="$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2; exit}' || printf '')"
    fi
    if [[ "${cong}" == "bbr" && "${qdisc}" == "fq" && "${modver}" == "3" ]]; then
        effective="effective"
    fi
    log_info "BBR status (report only, never auto-installed): kernel=${kernel}, congestion=${cong:-unknown}, qdisc=${qdisc:-unknown}, tcp_bbr=${modver:-unknown}, BBRv3+FQ ${effective}. To install/enable BBRv3+FQ, run it manually via 'lisa bbr bbr3'; this check will not do it for you."
    return 0
}

# env_check: Debian 12 pre-install check (see header above).
env_check() {
    local os_id="" os_ver="" os_major=""
    if [[ ! -f "${ENV_OS_RELEASE}" ]]; then
        die "cannot read OS release file: ${ENV_OS_RELEASE}"
        return 1
    fi
    os_id="$(grep '^ID=' "${ENV_OS_RELEASE}" | cut -d'=' -f2 | tr -d '"')"
    os_ver="$(grep '^VERSION_ID=' "${ENV_OS_RELEASE}" | cut -d'=' -f2 | tr -d '"')"
    os_major="$(printf '%s' "${os_ver}" | cut -d. -f1)"
    if [[ "${os_id}" != "debian" || "${os_major}" != "12" ]]; then
        die "this pre-check targets Debian 12 only (found: ${os_id} ${os_ver}); it does not auto-install on other systems."
        return 1
    fi
    log_info "OS supported: Debian ${os_ver}"
    detect_arch_suffix >/dev/null || return 1
    require_command systemctl || return 1
    if [[ ! -d /run/systemd/system ]] && [[ "${XRAY_TEST_MODE:-0}" != "1" ]]; then
        die "systemd does not appear to be running (no /run/systemd/system)."
        return 1
    fi
    _ensure_env_tools || return 1
    _check_port_443 || return 1
    _check_github_network || return 1
    # Firewall is a WARNING only, never a failure and never auto-opened:
    # ufw absent/inactive still needs a manual cloud security-group check.
    local fw_out fw_rc
    fw_out="$(firewall_status 2>&1)"; fw_rc=$?
    case "${fw_rc}" in
        0) log_info "firewall: ${fw_out}" ;;
        2) log_warn "firewall: ${fw_out}" ;;
        *) log_info "firewall: ${fw_out}" ;;
    esac
    _report_bbr_status
    log_info "environment checks passed."
    return 0
}

# prompt_with_default <prompt> <default>: reads a line; empty means default.
prompt_with_default() {
    local prompt="$1" default="$2" ans
    printf '%s [%s]: ' "${prompt}" "${default}"
    read -r ans || ans=""
    if [[ -z "${ans}" ]]; then
        printf '%s' "${default}"
    else
        printf '%s' "${ans}"
    fi
}

# _install_logrotate_rule <src> <dest>: copy the template into place
# and verify it. Never fails the caller: a missing/unwritable dest or
# a failed syntax check only produces a warning, and a failed syntax
# check is reported as such, never as a successful install. The
# template itself is unchanged (daily, rotate 7, compress,
# delaycompress, copytruncate), so xray keeps writing to the same
# file and diagnose.sh / `lisa logs` keep working after rotation,
# with no service restart.
_install_logrotate_rule() {
    local src="$1" dest="$2" destdir
    destdir="$(dirname "${dest}")"
    mkdir -p "${destdir}" 2>/dev/null || { log_warn "cannot create ${destdir}; skipping log rotation install."; return 0; }
    cp "${src}" "${dest}" 2>/dev/null || { log_warn "cannot install logrotate config to ${dest}; skipping."; return 0; }
    chmod 644 "${dest}" 2>/dev/null || true
    if [[ ! -f "${dest}" ]]; then
        log_warn "logrotate config not found after copy (${dest}); skipping."
        return 0
    fi
    if command -v logrotate >/dev/null 2>&1; then
        local dbg_ok=0
        if command -v timeout >/dev/null 2>&1; then
            timeout 30 logrotate --debug "${dest}" >/dev/null 2>&1 && dbg_ok=1 || true
        else
            logrotate --debug "${dest}" >/dev/null 2>&1 && dbg_ok=1 || true
        fi
        if [[ "${dbg_ok}" -eq 1 ]]; then
            log_info "logrotate config installed: ${dest} (copytruncate, daily, 7 rotations; no service restart for rotation)."
        else
            log_warn "logrotate config installed at ${dest} but syntax check (logrotate --debug) failed; rotation may not work, check the config manually."
        fi
    else
        # Test-mode legacy path (see install_logrotate_config): the
        # suite installs the rule without a real logrotate binary.
        log_info "logrotate config installed: ${dest} (copytruncate, daily, 7 rotations; no service restart for rotation)."
    fi
    return 0
}

# install_logrotate_config: smart install for log rotation.
#   - logrotate present: install the rule directly, skip package install.
#   - logrotate missing, production: print an explicit notice, then
#     try apt-get (Debian 12 only, matching the Debian 12-only
#     pre-check) with a timeout; apt failure only warns and never
#     fails the Xray install, and no rule is installed until
#     logrotate is actually present afterwards.
#   - logrotate missing, other systems (no apt-get / not Debian 12):
#     warn and skip, never hard-install.
#   - test mode (XRAY_TEST_MODE=1): never run the real apt-get. If
#     LOGROTATE_TEST_APT_CMD is set, that explicit test injection is
#     run instead (a sandbox fake apt script); otherwise the rule is
#     installed directly, preserving the pre-existing test-suite
#     behaviour where the rule lands in the sandbox without a real
#     logrotate binary. Missing template or an unwritable dir only
#     warns, never fails the install.
install_logrotate_config() {
    local src="${SCRIPT_DIR}/logrotate/xray-reality-manager"
    local destdir="${LOGROTATE_DIR:-/etc/logrotate.d}"
    local dest="${destdir}/xray-reality-manager"
    if [[ ! -f "${src}" ]]; then
        log_warn "logrotate config source not found (${src}); skipping log rotation install."
        return 0
    fi
    if command -v logrotate >/dev/null 2>&1; then
        _install_logrotate_rule "${src}" "${dest}"
        return 0
    fi
    # logrotate missing from here on.
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        if [[ -n "${LOGROTATE_TEST_APT_CMD:-}" ]]; then
            log_info "机器上没有 logrotate，现在帮你装一个"
            if "${LOGROTATE_TEST_APT_CMD}" >/dev/null 2>&1; then
                if command -v logrotate >/dev/null 2>&1; then
                    _install_logrotate_rule "${src}" "${dest}"
                    return 0
                fi
                log_warn "logrotate package install reported success but logrotate is still not available; skipping log rotation install."
                return 0
            fi
            log_warn "logrotate install failed; skipping log rotation install (Xray install continues)."
            return 0
        fi
        _install_logrotate_rule "${src}" "${dest}"
        return 0
    fi
    # Production smart install: Debian 12 + apt-get only (Debian 12
    # exclusive; Ubuntu is no longer an accepted system here).
    if ! command -v apt-get >/dev/null 2>&1; then
        log_warn "logrotate not installed and no apt-get found; skipping log rotation install (Xray install continues)."
        return 0
    fi
    local os_id="" os_ver="" os_major="" os_file="${ENV_OS_RELEASE:-/etc/os-release}"
    if [[ -f "${os_file}" ]]; then
        os_id="$(grep '^ID=' "${os_file}" | cut -d'=' -f2 | tr -d '"')"
        os_ver="$(grep '^VERSION_ID=' "${os_file}" | cut -d'=' -f2 | tr -d '"')"
        os_major="$(printf '%s' "${os_ver}" | cut -d. -f1)"
    fi
    if [[ "${os_id}" != "debian" || "${os_major}" != "12" ]]; then
        log_warn "logrotate not installed and this system (${os_id:-unknown} ${os_ver:-unknown}) is not Debian 12; skipping apt install of logrotate."
        return 0
    fi
    log_info "机器上没有 logrotate，现在帮你装一个"
    local apt_ok=0
    if command -v timeout >/dev/null 2>&1; then
        timeout 300 apt-get update -qq >/dev/null 2>&1 || log_warn "apt-get update failed; trying logrotate install from existing apt cache."
        timeout 300 apt-get install -y logrotate >/dev/null 2>&1 && apt_ok=1 || true
    else
        apt-get update -qq >/dev/null 2>&1 || log_warn "apt-get update failed; trying logrotate install from existing apt cache."
        apt-get install -y logrotate >/dev/null 2>&1 && apt_ok=1 || true
    fi
    if [[ "${apt_ok}" -ne 1 ]] || ! command -v logrotate >/dev/null 2>&1; then
        log_warn "logrotate install failed; skipping log rotation install (Xray install continues)."
        return 0
    fi
    _install_logrotate_rule "${src}" "${dest}"
    return 0
}

# detect_public_ip: public IPv4 detection for --auto installs.
# One-click scheme (2026-11-04, C's requirement: --auto never asks
# yes/no and never aborts on IP disagreement):
#   1. Query all three plain-text IP echo services (IPv4 only; IPv6
#      and private addresses are discarded, never counted).
#   2. Each service gets one retry on an empty/invalid answer.
#   3. Preferred: at least 2 sources agree -> that IP, verified.
#   4. Otherwise: first valid source, with a warning only, and the
#      caller must treat the host as unverified (see
#      DETECT_IP_VERIFIED / HOST_IP_UNVERIFIED).
#   5. Only when NO source returns a valid IPv4 does it return 1:
#      there is genuinely nothing to use, so the caller fails.
# Sets DETECT_IP_VERIFIED to 1 (agreed) or 0 (fallback) on success.
# Call it directly (not in $(...)): a command substitution runs in a
# subshell, so the verified flag would be lost to the caller.
# Usage: detect_public_ip <result-var-name>; on success the variable
# holds the IP, on failure it returns 1 and the variable is untouched.
# A mismatch against the local NIC / default-route exit address is
# only a warning, never a hard failure: cloud machines commonly sit
# behind NAT with a private local IP.
DETECT_IP_VERIFIED="0"
fetch_one_ip() {
    local svc="$1" ip attempt
    for attempt in 1 2; do
        ip="$(curl -fsSL --max-time 10 "${svc}" 2>/dev/null | tr -d '[:space:]')"
        if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s' "${ip}"
            return 0
        fi
        [[ "${attempt}" == "1" ]] && sleep 1
    done
    return 1
}
detect_public_ip() {
    # Note: no local named like the caller's result variable — printf -v
    # must reach the caller's variable (dynamic scope), so the fetched
    # value lives in "fetched", never in a local called "ip"/"host".
    local out_var="$1" svc fetched first second third chosen
    first=""; second=""; third=""
    DETECT_IP_VERIFIED="0"
    for svc in "https://ifconfig.me/ip" "https://api.ipify.org" "https://icanhazip.com"; do
        if fetched="$(fetch_one_ip "${svc}")"; then
            if [[ -z "${first}" ]]; then first="${fetched}";
            elif [[ -z "${second}" ]]; then second="${fetched}";
            else third="${fetched}"; fi
        fi
    done
    if [[ -n "${first}" && "${first}" == "${second}" ]]; then chosen="${first}"; DETECT_IP_VERIFIED="1";
    elif [[ -n "${first}" && "${first}" == "${third}" ]]; then chosen="${first}"; DETECT_IP_VERIFIED="1";
    elif [[ -n "${second}" && "${second}" == "${third}" ]]; then chosen="${second}"; DETECT_IP_VERIFIED="1";
    elif [[ -n "${first}" ]]; then
        chosen="${first}"
        log_warn "no two IP sources agreed; using first source IP ${first} (unverified host; connect with the client after install to confirm; if it is wrong, set XRAY_NODE_HOST and re-run)."
    else
        printf -v "${out_var}" '%s' ""
        return 1
    fi
    printf -v "${out_var}" '%s' "${chosen}"
    return 0
}

# warn_local_ip_mismatch <public-ip>: warning only, never a hard failure.
# If the local NIC / route exit address is a private IP that differs
# from the detected public IP, that is normal NAT, not an error.
warn_local_ip_mismatch() {
    local host="$1" local_ip=""
    if command -v ip >/dev/null 2>&1; then
        local_ip="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
    fi
    if [[ -n "${local_ip}" && "${local_ip}" != "${host}" ]]; then
        case "${local_ip}" in
            10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*)
                log_warn "local IP ${local_ip} is private and differs from detected public IP ${host}; this is normal behind NAT, continuing (warning only)."
                ;;
            *)
                log_warn "local IP ${local_ip} differs from detected public IP ${host}; continuing (warning only)."
                ;;
        esac
    fi
    return 0
}

# node_setup: interactive first-node setup. Prompts for host/port/sni/dest,
# generates uuid/keypair/shortid, renders the Vision config, writes the
# root-only params file, tests the config. Prints nothing secret except
# through the caller's share-link step (stdout only, by design).
# With AUTO_INSTALL=1 (--auto) it asks nothing: host comes from
# XRAY_NODE_HOST or auto-detection, port 443, SNI = www.apple.com
# (never the host IP — an IP SNI breaks the Reality handshake, because
# the certificate carries no IP SANs), dest www.apple.com:443, Vision on,
# and no confirmation prompt.
node_setup() {
    local host port sni dest flow ans uuid keys priv pub shortid
    if [[ "${AUTO_INSTALL}" == "1" ]]; then
        # 1 = host came from an explicit override, a preserved existing
        # node, or an agreed detection; 0 = fallback detection only.
        HOST_IP_UNVERIFIED="0"
        host="${XRAY_NODE_HOST:-}"
        if [[ -n "${host}" ]]; then
            log_info "using XRAY_NODE_HOST: ${host} (verify this is correct before continuing)."
        elif [[ -n "$(read_node_param host)" ]]; then
            # An existing node keeps its host: auto-detection must never
            # silently rewrite a working node's link address.
            host="$(read_node_param host)"
            log_info "reusing existing node host from params (auto-detection skipped; existing host is preserved)."
        else
            detect_public_ip host || { die "cannot auto-detect public IP: no IP source returned a valid IPv4; set XRAY_NODE_HOST and re-run."; return 1; }
            if [[ "${DETECT_IP_VERIFIED}" == "1" ]]; then
                log_info "auto-detected public IP: ${host} (at least 2 sources agreed)."
            else
                HOST_IP_UNVERIFIED="1"
                log_warn "auto-detected public IP: ${host} (no two sources agreed; unverified host; connect with the client after install to confirm)."
            fi
            warn_local_ip_mismatch "${host}"
        fi
        port="443"
        sni="www.apple.com"
        dest="www.apple.com:443"
        flow="vision"
    else
        printf 'First-time node setup (VLESS + TCP + REALITY + Vision).\n'
        printf 'Server address for the client link (IP or domain): '
        read -r host || host=""
        if [[ -z "${host}" ]]; then
            die "server address is required."
            return 1
        fi
        port="$(prompt_with_default "Port" "443")"
        if [[ ! "${port}" =~ ^[0-9]+$ ]] || [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
            die "invalid port: ${port}"
            return 1
        fi
        sni="$(prompt_with_default "Reality SNI (serverNames, custom domain)" "www.apple.com")"
        validate_sni "${sni}" || return 1
        dest="$(prompt_with_default "Reality dest (target site)" "www.apple.com:443")"
        printf 'Enable Vision flow? [Y/n]: '
        read -r ans || ans=""
        case "${ans}" in
            n|N|no|NO) flow="none" ;;
            *) flow="vision" ;;
        esac
    fi
    # Reality dest must include a port (Xray rejects a bare domain as
    # "target"); normalize a bare domain to :443 so a typed domain
    # without a port can never produce an invalid config.
    if [[ -n "${dest}" && "${dest}" != *":"* ]]; then dest="${dest}:443"; fi
    uuid="$(gen_uuid)" || return 1
    keys="$(gen_keypair)" || return 1
    priv="${keys%% *}"
    pub="${keys##* }"
    shortid="$(gen_shortid)" || return 1
    masked_summary "${host}" "${port}" "${flow}" "${sni}" "${dest}"
    if [[ "${AUTO_INSTALL}" != "1" ]]; then
        confirm "Impact: a new node config will be written to ${XRAY_CONF} and the service will start." || { log_info "node setup cancelled."; return 1; }
    fi
    mkdir -p "${XRAY_CONF_DIR}" || { die "cannot create config dir"; return 1; }
    render_config "${uuid}" "${shortid}" "${priv}" "${sni}" "${port}" "${flow}" "${dest}" "${XRAY_CONF}" || return 1
    write_node_params "${uuid}" "${priv}" "${pub}" "${shortid}" "${host}" "${port}" "${sni}" "${dest}" "${flow}" || return 1
    config_test "${XRAY_CONF}" || return 1
    log_info "node config written and tested."
    return 0
}

# print_share_link: prints the DSH-Reality share link (stdout only) when
# node params exist; prints nothing otherwise. Never logged to a file.
print_share_link() {
    local uuid host port flow sni pub sid
    uuid="$(read_node_param uuid)"
    host="$(read_node_param host)"
    port="$(read_node_param port)"
    flow="$(read_node_param flow)"
    sni="$(read_node_param sni)"
    pub="$(read_node_param public_key)"
    sid="$(read_node_param shortid)"
    if [[ -n "${uuid}" && -n "${host}" && -n "${port}" && -n "${sni}" && -n "${pub}" && -n "${sid}" ]]; then
        printf 'DSH-Reality 链接（复制到 V2rayNG 导入；不要公开发送）：\n'
        build_share_link "${uuid}" "${host}" "${port}" "${flow}" "${sni}" "${pub}" "${sid}" "DSH-Reality"
        printf '\n'
    fi
    return 0
}

# verify_fresh_install <port>: post-install self-check for a fresh
# node. All four must pass before a link is printed or "complete" is
# claimed: the six share params are non-empty, the config passes its
# test, the service is active, and the port is listening. A listening
# service does NOT prove the host IP is reachable from outside, so
# this check can never certify an unverified host — it only stops a
# half-installed node from looking complete. Returns 1 naming the
# failed item; callers must not print a link afterwards.
verify_fresh_install() {
    local port="$1" k v
    for k in uuid host port sni public_key shortid; do
        v="$(read_node_param "${k}")"
        [[ -n "${v}" ]] || { log_error "self-check failed: node param ${k} is empty; link will not be printed."; return 1; }
    done
    config_test "${XRAY_CONF}" || { log_error "self-check failed: config test did not pass; link will not be printed."; return 1; }
    [[ "$(service_state)" == "active" ]] || { log_error "self-check failed: service is not active; link will not be printed."; return 1; }
    verify_listening "${port}" || { log_error "self-check failed: port ${port} is not listening; link will not be printed."; return 1; }
    return 0
}

# print_unverified_host_note: completion note for a fallback host.
# A note only, never a prompt: one-click installs must not stop and
# ask, but a fallback host must not look identical to a verified one.
print_unverified_host_note() {
    if [[ "${HOST_IP_UNVERIFIED:-0}" == "1" ]]; then
        printf '注意：本次 host 未经多源交叉验证，请先用客户端连一次确认；若连不上，用 XRAY_NODE_HOST=正确地址 重新一键安装。\n'
    fi
    return 0
}

# handle_already_installed: the already-installed path of main(),
# extracted so tests can call it directly. Launcher first (so a broken
# config never leaves the operator without `DSH`), then either
# complete a partial install, preserve a valid config, or auto-repair
# an invalid config (snapshot first, dest only).
# repair_rollback <snapshot-dir>: best-effort rollback for repair_invalid_config.
# Restores binary+config+units+geodata from the snapshot AND the params file
# (snapshot_restore does not restore params, so repair backs it up explicitly).
# Never fails (callers report the original error after rollback).
repair_rollback() {
    local snap="$1"
    snapshot_restore "${snap}" full || true
    if [[ -f "${snap}/node.params" ]]; then
        cp -a "${snap}/node.params" "${NODE_PARAMS_FILE}" || true
    fi
    migrate_permissions || true
    service_restart || true
    return 0
}

# repair_invalid_config: repairs an existing INVALID node config in place.
# Only ever runs when the live config FAILS config_test (callers must check
# first); a valid config is never touched. Steps (fail-closed):
#   1. Read all params; if any required param is missing, fail (cannot
#      safely re-render without the full node identity).
#   2. Validate SNI (an IP SNI would pass Xray's test but fail handshakes).
#   3. Normalize dest in memory (bare domain -> :443).
#   4. Confirm in interactive mode (auto mode implies it); declined repair
#      changes nothing.
#   5. Re-render to a TEMP file and test the TEMP file BEFORE touching the
#      live config or service (same test-before-stop pattern as node_set_sni).
#      If the temp test fails, live files + service are untouched.
#   6. If the temp test passes: snapshot (config + params) first, then stop,
#      install the temp file as live, migrate, test live, write normalized
#      params, enable + restart, verify the port is listening. On ANY
#      failure after the live install, roll back to the snapshot + params.
# Returns 0 only when the live config now passes test AND the service
# restarted with the port listening.
repair_invalid_config() {
    local host port sni dest flow uuid priv pub sid snap tmpconf ports
    # --auto never implies repair: in auto mode without --repair, do not
    # touch an invalid config at all; the caller reports the failure and
    # the operator re-runs with --repair. Interactive mode still asks.
    if [[ "${AUTO_INSTALL}" == "1" && "${REPAIR_INSTALL}" != "1" ]]; then
        die "invalid config under --auto, and --repair was not given; --auto never repairs by itself. Re-run with --repair to allow a snapshot-first repair (dest/port only), or fix the config manually."
        return 1
    fi
    host="$(read_node_param host)"; port="$(read_node_param port)"
    sni="$(read_node_param sni)"; dest="$(read_node_param dest)"
    flow="$(read_node_param flow)"; uuid="$(read_node_param uuid)"
    priv="$(read_node_param private_key)"; pub="$(read_node_param public_key)"
    sid="$(read_node_param shortid)"
    if [[ -z "${host}" || -z "${port}" || -z "${sni}" || -z "${dest}" || -z "${flow}" || -z "${uuid}" || -z "${priv}" || -z "${pub}" || -z "${sid}" ]]; then
        die "cannot auto-repair: node params are incomplete (missing at least one of host/port/sni/dest/flow/uuid/keys/shortid); delete the broken config + params and re-run the one-liner for a fresh node."
        return 1
    fi
    validate_sni "${sni}" || return 1
    if [[ "${dest}" != *":"* ]]; then dest="${dest}:443"; fi
    if [[ "${AUTO_INSTALL}" != "1" ]]; then
        confirm "Impact: existing config failed the test; auto-repair will snapshot the current config + params, normalize dest to include :443, re-test, and restart the service if the repair passes." || { log_info "auto-repair declined."; return 1; }
    fi
    # Snapshot BEFORE the temp test (so a temp-test failure still
    # leaves a snapshot), and temp config MUST end in .json: real
    # Xray rejects a bare mktemp file on format detection.
    snap="$(snapshot_create)" || return 1
    if [[ -f "${NODE_PARAMS_FILE}" ]]; then
        cp -a "${NODE_PARAMS_FILE}" "${snap}/node.params" || { die "repair: failed to back up params"; return 1; }
    fi
    local tmpdir tmpconf
    tmpdir="$(mktemp -d)" || { die "repair: cannot create temp dir"; return 1; }
    tmpconf="${tmpdir}/config.json"
    # shellcheck disable=SC2064
    trap "rm -rf -- '${tmpdir}'; trap - RETURN" RETURN
    render_config "${uuid}" "${sid}" "${priv}" "${sni}" "${port}" "${flow}" "${dest}" "${tmpconf}" || return 1
    if ! config_test "${tmpconf}"; then
        log_error "auto-repair: re-rendered config still fails the test; live config left untouched."
        return 1
    fi
    service_stop || log_warn "repair: stop reported an error; continuing (service may already be stopped)."
    cp -a "${tmpconf}" "${XRAY_CONF}" || {
        log_error "repair: failed to install repaired config; restoring snapshot."
        repair_rollback "${snap}"
        die "repair aborted: could not install repaired config; previous state restored."
        return 1
    }
    migrate_permissions || {
        log_error "repair: permission migration failed; restoring snapshot."
        repair_rollback "${snap}"
        die "repair aborted: permission migration failed; previous state restored."
        return 1
    }
    if ! config_test "${XRAY_CONF}"; then
        log_error "repair: live config test failed after install; restoring snapshot."
        repair_rollback "${snap}"
        die "repair aborted: live config test failed; previous state restored."
        return 1
    fi
    # Root-run live test may have created root-owned log files;
    # re-migrate before restart, or the xray-user service fails (23).
    migrate_permissions || {
        log_error "repair: permission migration failed after live test; restoring snapshot."
        repair_rollback "${snap}"
        die "repair aborted: permission migration failed; previous state restored."
        return 1
    }
    write_node_params "${uuid}" "${priv}" "${pub}" "${sid}" "${host}" "${port}" "${sni}" "${dest}" "${flow}" || {
        log_error "repair: failed to write normalized params; restoring snapshot."
        repair_rollback "${snap}"
        die "repair aborted: could not write params; previous state restored."
        return 1
    }
    service_enable || true
    service_restart || {
        log_error "repair: service failed to restart; restoring snapshot."
        repair_rollback "${snap}"
        die "repair aborted: service restart failed; previous state restored."
        return 1
    }
    if ! wait_for_listening "${port}"; then
        log_error "repair: service restarted but port ${port} is not listening; restoring snapshot."
        service_stop || true
        repair_rollback "${snap}"
        die "repair aborted: repaired config did not produce a listening service; previous state restored."
        return 1
    fi
    # Post-change verified marking (main-chat decision 2026-11-03):
    # the repaired, verified config becomes the known-good snapshot.
    # Marking failure is a warning only, never a repair failure.
    snapshot_mark_verified_current || log_warn "repair: known-good marking skipped (config or listening check did not pass for marking)."
    log_info "auto-repair complete: dest normalized, config test passed, service restarted and listening on ${port} (snapshot kept: ${snap})."
    return 0
}


handle_already_installed() {
        # Already installed: migrate permissions, then either preserve a
        # real config or COMPLETE a partial install. The official
        # installer writes an empty placeholder config ({}) when none
        # exists; if that placeholder is still there, no node was ever
        # set up, so run node_setup now (same as a fresh install).
        # A non-empty VALID config is always preserved, never overwritten;
        # an INVALID config (fails the test) is auto-repaired (snapshot
        # first, dest normalization only) — see repair_invalid_config.
        log_info "xray already installed (version $(current_version))."
        migrate_permissions || return 1
        install_logrotate_config || true
        # Launcher first: even if the node config is broken, the operator
        # must end up with `DSH` available to diagnose/repair. Previously
        # a failed config test aborted before the launcher step, leaving
        # no menu at all (and the error's "backup menu (option 6)" unreachable).
        install_lisa_launcher "${SCRIPT_DIR}/manage.sh" || return 1
        if [[ ! -f "${XRAY_CONF}" ]] || [[ "$(tr -d '[:space:]' < "${XRAY_CONF}")" == "{}" ]]; then
            log_info "no node config yet (installer placeholder); completing node setup."
            node_setup || return 1
            # Same root-log issue as fresh install: re-migrate after
            # the root-run config test, before restart.
            migrate_permissions || return 1
            service_enable || true
            service_restart || { die "service failed to start after install."; return 1; }
            if ! wait_for_listening "$(read_node_param port)"; then
                die "service restarted but port $(read_node_param port) is still not listening; node is down, not complete."
                return 1
            fi
            verify_fresh_install "$(read_node_param port)" || return 1
            log_info "install complete: version $(current_version), service $(service_display_state "$(read_node_param port)")."
            print_share_link
            print_unverified_host_note
            printf '\n安装已完成！输入 DSH 打开菜单查看配置。\n'
        else
            log_info "preserving existing config."
            if config_test "${XRAY_CONF}"; then
                # Listener-aware: a valid config with a stale service (active
                # but not listening, or inactive) must be restarted to load
                # the disk config; a healthy listening service is left alone
                # (no downtime on re-runs).
                if ! verify_listening "$(read_node_param port)"; then
                    log_warn "valid config but service is not listening on $(read_node_param port); restarting to load the disk config."
                    # The root-run config_test above may have created
                    # root-owned log files; re-migrate before restart.
                    migrate_permissions || return 1
                    service_enable || true
                    service_restart || { die "service failed to restart."; return 1; }
                    if ! wait_for_listening "$(read_node_param port)"; then
                        log_error "service restarted but port $(read_node_param port) is still not listening; node is still down."
                        return 1
                    fi
                fi
                log_info "install state OK: version $(current_version), service $(service_display_state "$(read_node_param port)"), autostart $(service_enabled)."
            else
                log_warn "existing config failed the test; attempting repair (snapshot first, dest normalization only; under --auto this requires --repair)."
                if repair_invalid_config; then
                    log_info "install state OK after auto-repair: version $(current_version), service $(service_display_state "$(read_node_param port)"), autostart $(service_enabled)."
                    print_share_link
            printf '\n安装已完成（已自动修复配置）！输入 DSH 打开菜单查看配置。\n'
                else
                    log_error "auto-repair did not fix the config. The launcher is installed (run: DSH), the broken config + params are preserved (plus a snapshot backup), and the node is still down."
                    log_error "Next steps: use 'DSH' menu option 6 to restore a valid snapshot, or delete the broken config + params and re-run the one-liner for a fresh node."
                    return 1
                fi
            fi
        fi
        maybe_install_hy2 || true
        return 0
}

# maybe_install_hy2: install the optional Hysteria2 add-on in the same run.
# Called only after the main line is verified and listening, so a HY2
# problem can never take Reality down with it.
maybe_install_hy2() {
    local want="${WITH_HY2}" ans
    if [[ "${want}" != "1" ]]; then
        if [[ "${AUTO_INSTALL}" == "1" ]]; then
            return 0
        fi
        printf '是否同时安装 Hysteria2 附加协议（UDP 443，通话备用）？[y/N]: '
        read -r ans || ans=""
        case "${ans}" in
            y|Y|yes|YES) want=1 ;;
            *) return 0 ;;
        esac
    fi
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/hy2.sh"
    printf 'yes\n' | hy2_cmd_install || {
        log_warn "HY2 附加协议没装成功；主线 Reality 不受影响。稍后可用 lisa 菜单 13 重试。"
        return 0
    }
    log_info "HY2 附加协议已就绪（UDP 端口见 lisa 菜单 16）。"
    return 0
}

main() {
    local check_only=0 version=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) usage; return 0 ;;
            --check) check_only=1; shift ;;
            --auto) AUTO_INSTALL=1; shift ;;
            --repair) REPAIR_INSTALL=1; shift ;;
            --with-hy2) WITH_HY2=1; shift ;;
            *) version="$1"; shift ;;
        esac
    done
    require_root || return 1
    env_check || return 1
    if [[ "${check_only}" -eq 1 ]]; then
        return 0
    fi
    if [[ -z "${version}" ]]; then
        version="$(default_version)"
    fi
    version="$(normalize_version "${version}")" || return 1
    if [[ -x "${XRAY_BIN}" ]]; then
        handle_already_installed
        return $?
    fi
    local arch tmpdir zip installer
    arch="$(detect_arch_suffix)" || return 1
    tmpdir="$(mktemp -d)" || { die "cannot create temp dir"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -rf -- '${tmpdir}'; trap - RETURN" RETURN
    zip="$(download_core "${version}" "${arch}" "${tmpdir}")" || return 1
    installer="$(fetch_installer "${tmpdir}/install-release.sh")" || return 1
    install_with_official "${installer}" "${zip}" || return 1
    service_reload_units || true
    migrate_permissions || return 1
    install_logrotate_config || true
    # Launcher first (see handle_already_installed): a failed node
    # setup must still leave `DSH` available for diagnosis.
    install_lisa_launcher "${SCRIPT_DIR}/manage.sh" || return 1
    if [[ -f "${XRAY_CONF}" ]] && [[ "$(tr -d '[:space:]' < "${XRAY_CONF}")" != "{}" ]]; then
        log_info "existing non-empty config found; preserving it (not overwritten)."
        if ! config_test "${XRAY_CONF}"; then
            log_warn "existing config failed the test; attempting repair (snapshot first, dest normalization only; under --auto this requires --repair)."
            repair_invalid_config || {
                log_error "auto-repair did not fix the config. The launcher is installed (run: DSH), the broken config + params are preserved (plus a snapshot backup), and the node is still down."
                log_error "Next steps: use 'DSH' menu option 6 to restore a valid snapshot, or delete the broken config + params and re-run the one-liner for a fresh node."
                return 1
            }
            log_info "auto-repair succeeded; continuing with service restart."
        fi
    else
        node_setup || return 1
    fi
    # Root-run config_test (inside node_setup / repair) creates
    # /var/log/xray/*.log as root when the service has never created
    # them; the xray-user service then fails with exit 23 (permission
    # denied on access.log). Re-migrate AFTER the test, BEFORE restart.
    migrate_permissions || return 1
    service_enable || true
    # Restart (not start): the official installer already started the
    # service with an empty placeholder config, so a plain start is a
    # no-op and the service never loads the real config just written.
    service_restart || { die "service failed to start after install."; return 1; }
    if ! wait_for_listening "$(read_node_param port)"; then
        die "install failed: service restarted but port $(read_node_param port) is not listening; node is down, not complete."
        return 1
    fi
    snapshot_mark_verified_current || log_warn "install: known-good marking skipped."
    verify_fresh_install "$(read_node_param port)" || return 1
    log_info "install complete: version $(current_version), service $(service_display_state "$(read_node_param port)")."
    print_share_link
    print_unverified_host_note
    maybe_install_hy2 || true
    printf '\n安装已完成！输入 DSH 打开菜单查看配置。\n'
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
    exit $?
fi
