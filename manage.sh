#!/usr/bin/env bash
#
# manage.sh — menu + direct commands for xray-reality-manager.
#
# Menu display name: DSH 一键部署. Launch command: `DSH` (install.sh
# copies this tool to a persistent dir and creates a /usr/local/bin/DSH
# symlink to the persistent copy; never overwrites an existing regular
# file, and never points the launcher at a /tmp download dir).
#
# Menu:
#   1  system security: change auth method (password off, key login on)  7  node config management
#   2  view current core version               8  DSH-Reality share link
#   3  check official updates                  9  config + service status
#   4  manual core upgrade                    10  line diagnostics
#   5  rollback to latest snapshot            11  logs
#   6  backup (create snapshot)               12  official BBR+FQ
#   0  exit
# Direct `install` command is kept as a fallback (menu 1 no longer shows it).
# Uninstall is NOT in the menu; it stays as a direct command only
# (triple-confirmed for purge). No third-party kernel install exists: menu 12
# only persists/applies the in-tree BBR algorithm plus fq.
# Rollback is menu 5 only (menu 6 is backup only).
#
# Direct commands (same functions, scriptable):
#   manage.sh status|version|check-update|install [ver]|upgrade [ver]|
#             downgrade [ver]|rollback [snapshot]|backup|restore [snapshot]|
#             node <sub>|share|diag [--loopback]|logs|uninstall|bbr <sub>|
#             auth|menu|help
# auth = menu 1, 更改认证方式（关闭密码、开启密钥登录）.
#
# Every destructive/overwriting operation states its impact and requires
# confirmation. No silent auto-upgrade exists anywhere in this tool.

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
# lib/bbr.sh 按需加载：只有菜单 12 或 `DSH bbr` 才会 source，
# 打开菜单/日常操作不再为它付解析成本。
_bbr_lib() {
    # shellcheck disable=SC1091
    [[ -n "${_BBR_LOADED:-}" ]] || { source "${SCRIPT_DIR}/lib/bbr.sh"; _BBR_LOADED=1; }
}
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hy2.sh"

MENU_NAME="DSH 一键部署"

usage() {
    printf 'Usage: %s [command] [args]\n' "$(basename "$0")"
    printf 'Commands: status, version, check-update, install [ver], upgrade [ver], downgrade [ver],\n'
    printf '          rollback [snapshot], backup, restore [snapshot], node <sub>,\n'
    printf '          share, diag [--loopback], logs, uninstall, bbr <sub>, auth,\n'
    printf '          hy2 <install|uninstall|link|status|logs|rotate-cert|masquerade|restore|snapshot>, smoke, menu, help\n'
    printf 'auth = menu 1, 更改认证方式（关闭密码、开启密钥登录）\n'
    printf 'hy2 = Hysteria2 附加协议（菜单 13-18，20 = 伪装地址）。\n'
    printf 'BBR = 官方内核 BBR+FQ（菜单 12）；subs: enable, version, status, clear\n'
    printf 'Node subs: show, init, share, sni, restore-main\n'
    printf 'With no command, the interactive menu opens. Type `DSH` to open it.\n'
}

banner() {
    local ver rel codename xr hy2
    ver="$(current_version)"
    rel="$(dsh_release_version)"
    codename="$(dsh_release_codename)"
    xr="$(service_display_state "$(read_node_param port)")"
    xr="${xr%%$'\n'*}"
    hy2="$(hy2_service_state)"

    printf '\n'
    printf '  \033[90m══════════════════════════════════════\033[0m\n'
    printf '\033[36m'
    cat <<'EOF'
   ▄▄▄▄▄▄▄▄▄▄▄
  █  D S H  █▄▄▄▄
  █         █    ▀▄
   ▀▀▀▀▀▀▀▀▀▀▀      ▀
EOF
    printf '\033[0m'
    printf '  \033[36mReality\033[0m · \033[36mHysteria2\033[0m'
    if [[ "${rel}" != "unknown" ]]; then
        if [[ "${codename}" != "unknown" ]]; then
            printf '       \033[90mDSH %s「%s」\033[0m\n' "${rel}" "${codename}"
        else
            printf '       \033[90mDSH %s\033[0m\n' "${rel}"
        fi
    else
        printf '                    \033[90mv%s\033[0m\n' "${ver}"
    fi
    printf '  \033[90m══════════════════════════════════════\033[0m\n'
    if [[ "${xr}" == "active" ]]; then
        printf '   Reality \033[32m●\033[0m \033[32m运行中\033[0m'
    else
        printf '   Reality \033[31m○\033[0m \033[31m已停止\033[0m'
    fi
    if [[ "${hy2}" == "active" ]]; then
        printf '     HY2 \033[32m●\033[0m \033[32m运行中\033[0m\n'
    else
        printf '     HY2 \033[31m○\033[0m \033[31m已停止\033[0m\n'
    fi
    printf '\n'
}


# ------------------------------------------------------------ commands ----
cmd_status() {
    printf 'core version : %s (default %s)\n' "$(current_version)" "$(default_version)"
    printf 'service      : %s\n' "$(service_display_state "$(read_node_param port)")"
    printf 'autostart    : %s\n' "$(service_enabled)"
    printf 'listen ports : %s\n' "$(listen_ports)"
    printf 'config       : %s\n' "${XRAY_CONF}"
    if [[ -f "${XRAY_CONF}" ]]; then
        config_test "${XRAY_CONF}" >/dev/null 2>&1 && printf 'config test  : OK\n' || printf 'config test  : FAILED (run option 9/10 for details)\n'
    else
        printf 'config test  : config file missing\n'
    fi
    printf 'snapshots    : %s\n' "$(snapshot_list | wc -l)"
    printf 'service start: %s\n' "$(service_uptime)"
    printf 'log last mod : %s\n' "$(last_error_log_time)"
    return 0
}

# cmd_install [ver]: option 1, ONLY when no core is installed.
# Previously options 1 and 4 both called cmd_upgrade, which was confusing
# and could hide the "already installed" case. Now option 1 refuses when
# a core is already present and points at option 4 instead; option 4
# (cmd_upgrade) refuses nothing new, it is the already-installed path.
cmd_install() {
    if [[ -x "${XRAY_BIN}" ]]; then
        die "core is already installed (version $(current_version)); use option 4 to upgrade, not option 1. 如果配置还没建好，请重跑一键安装补建，而不是用菜单 4 升级 (if the node config is not built yet, re-run the one-click install to build it instead of using option 4 to upgrade)."
        return 1
    fi
    cmd_upgrade "$@"
}

cmd_version() {
    printf 'dsh: %s「%s」\n' "$(dsh_release_version)" "$(dsh_release_codename)"
    printf 'current: %s\n' "$(current_version)"
    printf 'default: %s\n' "$(default_version)"
    return 0
}

cmd_check_update() {
    local cur latest cmp
    cur="$(current_version)"
    latest="$(official_latest_version)" || return 1
    cmp="$(version_cmp "${latest}" "${cur}")"
    printf 'current: %s\n' "${cur}"
    printf 'latest : %s\n' "${latest}"
    if [[ "${cmp}" == "1" ]]; then
        printf 'update available: %s -> %s (run option 4 to upgrade manually; never automatic.)\n' "${cur}" "${latest}"
    elif [[ "${cmp}" == "0" ]]; then
        printf 'up to date.\n'
    else
        printf 'current version is newer than the latest release tag (or a pre-release).\n'
    fi
    return 0
}

cmd_upgrade() {
    local target="${1:-}"
    if [[ -z "${target}" ]]; then
        printf 'Target version (e.g. 26.10.21): '
        read -r target || target=""
    fi
    if [[ -z "${target}" ]]; then
        die "target version is required."
        return 1
    fi
    upgrade_core "${target}"
}

cmd_downgrade() {
    local target="${1:-}" cur cmp
    if [[ -z "${target}" ]]; then
        printf 'Target version to downgrade to (e.g. 26.3.27): '
        read -r target || target=""
    fi
    if [[ -z "${target}" ]]; then
        die "target version is required."
        return 1
    fi
    cur="$(current_version)"
    cmp="$(version_cmp "${target}" "${cur}")"
    if [[ "${cmp}" != "-1" ]]; then
        die "downgrade target ${target} is not older than current ${cur}; use upgrade instead."
        return 1
    fi
    upgrade_core "${target}"
}

cmd_rollback() {
    rollback_core "${1:-}"
}

cmd_backup() {
    local snap
    snap="$(snapshot_create)" || return 1
    printf 'backup created: %s\n' "${snap}"
    printf 'snapshots:\n'
    snapshot_list
    return 0
}

# ------------------------------------------------------------ node cmds ----
# rollback_node_config <snapshot>: best-effort restore of a node change.
# Restores binary+config+units+geodata from the snapshot, re-migrates
# permissions, and restarts the service. Never fails the caller twice:
# it always returns 0 (the caller reports the original error).
rollback_node_config() {
    local snap="$1"
    snapshot_restore "${snap}" full || true
    migrate_permissions || true
    service_restart || true
    return 0
}

# apply_node_config <tmpconf> <label>: test-then-switch + auto-rollback
# for node parameter changes (SNI, Vision on/off). The caller must
# already have: a temp config rendered and tested OK, and confirmation
# done. This helper then: takes a snapshot, stops the service, installs
# the temp config atomically (cp -a), migrates permissions, tests the
# LIVE config, migrates again (root-run tests can create root-owned
# log files), and restarts. On ANY failure after the install, it
# restores the snapshot (original config preserved) and returns 1.
# On success it returns 0; the caller then writes the new params file
# (params are only updated after a successful switch, so params and
# live config can never diverge on failure).
apply_node_config() {
    local tmpconf="$1" label="${2:-node config}" snap
    snap="$(snapshot_create)" || return 1
    service_stop || true
    cp -a "${tmpconf}" "${XRAY_CONF}" || {
        log_error "failed to install ${label}; restoring snapshot."
        rollback_node_config "${snap}"
        die "node change aborted: install failed; previous config restored."
        return 1
    }
    migrate_permissions || {
        log_error "permission migration failed for ${label}; restoring snapshot."
        rollback_node_config "${snap}"
        die "node change aborted: permission migration failed; previous config restored."
        return 1
    }
    if ! config_test "${XRAY_CONF}"; then
        log_error "live config test failed for ${label}; restoring snapshot."
        rollback_node_config "${snap}"
        die "node change aborted: live config test failed; previous config restored."
        return 1
    fi
    migrate_permissions || {
        log_error "permission migration failed after ${label} test; restoring snapshot."
        rollback_node_config "${snap}"
        die "node change aborted: permission migration failed; previous config restored."
        return 1
    }
    if ! service_restart; then
        log_error "service failed to restart with ${label}; restoring snapshot."
        rollback_node_config "${snap}"
        die "node change aborted: service restart failed; previous config restored."
        return 1
    fi
    log_info "${label} applied (snapshot kept: ${snap})."
    return 0
}

node_show() {
    local host port flow sni dest
    host="$(read_node_param host)"
    if [[ -z "${host}" ]]; then
        die "no node params file found (${NODE_PARAMS_FILE}). Run 'node init' first to record the existing node, or install a fresh node with install.sh."
        return 1
    fi
    port="$(read_node_param port)"
    flow="$(read_node_param flow)"
    sni="$(read_node_param sni)"
    dest="$(read_node_param dest)"
    masked_summary "${host}" "${port}" "${flow}" "${sni}" "${dest}"
    return 0
}

node_init() {
    local host port sni dest flow uuid priv pub sid
    printf 'Record an existing node (values go to the root-only params file, never to the repo).\n'
    printf 'Server address (IP or domain): '
    read -r host || host=""
    [[ -n "${host}" ]] || { die "server address is required."; return 1; }
    printf 'Port [443]: '
    read -r port || port=""
    port="${port:-443}"
    printf 'SNI: '
    read -r sni || sni=""
    printf 'Reality dest: '
    read -r dest || dest=""
    if [[ -n "${dest}" && "${dest}" != *":"* ]]; then dest="${dest}:443"; fi
    printf 'Flow (vision/none) [vision]: '
    read -r flow || flow=""
    flow="${flow:-vision}"
    printf 'UUID: '
    read -r uuid || uuid=""
    printf 'Reality private key: '
    read -r priv || priv=""
    printf 'Reality public key: '
    read -r pub || pub=""
    printf 'shortId: '
    read -r sid || sid=""
    if [[ -z "${uuid}" || -z "${priv}" || -z "${pub}" || -z "${sid}" || -z "${sni}" || -z "${dest}" ]]; then
        die "all node parameters are required."
        return 1
    fi
    validate_sni "${sni}" || return 1
    confirm "Impact: node parameters will be written to the root-only file ${NODE_PARAMS_FILE} (never to the repo)." || { log_info "node init cancelled."; return 1; }
    write_node_params "${uuid}" "${priv}" "${pub}" "${sid}" "${host}" "${port}" "${sni}" "${dest}" "${flow}" || return 1
    log_info "node params recorded."
    return 0
}

node_share() {
    local uuid host port flow sni pub sid
    uuid="$(read_node_param uuid)"
    host="$(read_node_param host)"
    port="$(read_node_param port)"
    flow="$(read_node_param flow)"
    sni="$(read_node_param sni)"
    pub="$(read_node_param public_key)"
    sid="$(read_node_param shortid)"
    if [[ -z "${uuid}" || -z "${host}" || -z "${port}" || -z "${sni}" || -z "${pub}" || -z "${sid}" ]]; then
        die "node params incomplete; run 'node init' or install a fresh node first."
        return 1
    fi
    printf 'DSH-Reality 链接（仅本终端显示；不要公开发送）：\n'
    build_share_link "${uuid}" "${host}" "${port}" "${flow}" "${sni}" "${pub}" "${sid}" "DSH-Reality"
    printf '\n'
    return 0
}

# node_set_sni [domain]: changes only the Reality SNI (serverNames) to a
# custom domain (default www.apple.com when no domain is given). The node
# identity (uuid/keys/port/dest/flow) is preserved; the service restarts
# and the old share link stops working (clients must re-import the new
# link). An IP SNI is rejected (it breaks the Reality handshake).
node_set_sni() {
    local new_sni="${1:-}" uuid sid priv pub host port dest flow
    uuid="$(read_node_param uuid)"
    sid="$(read_node_param shortid)"
    priv="$(read_node_param private_key)"
    pub="$(read_node_param public_key)"
    host="$(read_node_param host)"
    port="$(read_node_param port)"
    dest="$(read_node_param dest)"
    flow="$(read_node_param flow)"
    if [[ -z "${uuid}" || -z "${sid}" || -z "${priv}" || -z "${pub}" || -z "${host}" || -z "${port}" || -z "${dest}" || -z "${flow}" ]]; then
        die "node params incomplete; run 'node init' first."
        return 1
    fi
    if [[ -z "${new_sni}" ]]; then
        printf 'Custom SNI domain [www.apple.com]: '
        read -r new_sni || new_sni=""
        new_sni="${new_sni:-www.apple.com}"
    fi
    validate_sni "${new_sni}" || return 1
    # Lightweight, warn-only precheck (camouflage case): DNS/TLS warnings
    # never block the change; the confirm below is the user's decision.
    # The local IP is passed only when the node host itself is an IP,
    # and only the "own domain" precheck mode would use it.
    local sni_local_ip=""
    case "${host}" in
        *.*.*.*) sni_local_ip="${host}" ;;
    esac
    sni_precheck "${new_sni}" "${dest}" "camouflage" "${sni_local_ip}" || true
    confirm "Impact: SNI will change to ${new_sni}, the config will be rewritten (other node values preserved), the service will restart, and the old share link will stop working (clients must re-import the new link). A snapshot is taken first." || { log_info "SNI change cancelled."; return 1; }
    # Temp config MUST end in .json: real Xray rejects a bare mktemp
    # file on format detection before content ("Failed to get format").
    local tmpdir tmpconf
    tmpdir="$(mktemp -d)" || { die "cannot create temp dir"; return 1; }
    tmpconf="${tmpdir}/config.json"
    # shellcheck disable=SC2064
    trap "rm -rf -- '${tmpdir}'; trap - RETURN" RETURN
    render_config "${uuid}" "${sid}" "${priv}" "${new_sni}" "${port}" "${flow}" "${dest}" "${tmpconf}" || { rm -rf -- "${tmpdir}"; return 1; }
    config_test "${tmpconf}" || { rm -rf -- "${tmpdir}"; return 1; }
    # Test-then-switch: the temp config is already tested; apply_node_config
    # snapshots, installs, live-tests, and restarts, restoring the snapshot
    # automatically on any failure after the install. Params are written
    # only after a successful switch.
    apply_node_config "${tmpconf}" "SNI change" || { rm -rf -- "${tmpdir}"; return 1; }
    rm -rf -- "${tmpdir}"
    write_node_params "${uuid}" "${priv}" "${pub}" "${sid}" "${host}" "${port}" "${new_sni}" "${dest}" "${flow}" || return 1
    log_info "SNI changed to ${new_sni}."
    masked_summary "${host}" "${port}" "${flow}" "${new_sni}" "${dest}"
    node_share
    return 0
}

# node_restore_main: re-render the Vision main config from params
# (snapshot + confirm + test + restart via apply_node_config).
# The old no-Vision variant file (generate/activate) was removed in
# the slim version; restoring the main node does not need it, and a
# broken config is also recoverable via menu 5 rollback.
node_restore_main() {
    local uuid sid priv sni port dest
    uuid="$(read_node_param uuid)"
    sid="$(read_node_param shortid)"
    priv="$(read_node_param private_key)"
    sni="$(read_node_param sni)"
    port="$(read_node_param port)"
    dest="$(read_node_param dest)"
    if [[ -z "${uuid}" || -z "${sid}" || -z "${priv}" || -z "${sni}" || -z "${port}" || -z "${dest}" ]]; then
        die "node params incomplete; run 'node init' first."
        return 1
    fi
    confirm "Impact: the running node config will be replaced by the Vision main config rendered from params (service will restart). A snapshot is taken first." || { log_info "restore cancelled."; return 1; }
    local tmpdir tmpconf
    tmpdir="$(mktemp -d)" || { die "cannot create temp dir"; return 1; }
    tmpconf="${tmpdir}/config.json"
    # shellcheck disable=SC2064
    trap "rm -rf -- '${tmpdir}'; trap - RETURN" RETURN
    render_config "${uuid}" "${sid}" "${priv}" "${sni}" "${port}" "vision" "${dest}" "${tmpconf}" || { rm -rf -- "${tmpdir}"; return 1; }
    config_test "${tmpconf}" || { rm -rf -- "${tmpdir}"; return 1; }
    apply_node_config "${tmpconf}" "Vision main config" || { rm -rf -- "${tmpdir}"; return 1; }
    rm -rf -- "${tmpdir}"
    log_info "Vision main node restored."
    return 0
}

cmd_node() {
    local sub="${1:-}"
    shift || true
    case "${sub}" in
        ""|show) node_show ;;
        init) node_init ;;
        share) node_share ;;
        sni) node_set_sni "$@" ;;
        restore-main) node_restore_main ;;
        *) die "node: unknown subcommand '${sub}' (show|init|share|sni|restore-main)."; return 1 ;;
    esac
}

cmd_share() {
    node_share
}

# Menu 1 rollback timer (minimal, supplement only — never a substitute
# for testing key login in a new session):
#   Unit name: lisa-auth-rollback (systemd-run transient, 10 minutes).
#   State file: /root/.xray-reality-manager/auth-rollback.state
#     (test override: XRAY_TEST_AUTH_STATE, test mode only).
#     Contents: "pending" + bak_main= + bak_list= lines, or "rolled_back".
#   Cancel command: `manage.sh auth-confirm` (also offered when menu 1
#     is re-entered with a pending timer).
#   Timer-fire command: `manage.sh auth-rollback` (restores the backups
#     recorded in the state file, restarts ssh, writes rolled_back).
#   Log file: auth-rollback.log next to the state file.
# The timer is started only AFTER sshd backups are made; if it is never
# confirmed, it restores the backups at 10 minutes and the next menu 1
# entry prints "上次未确认，已自动回滚" once, then clears the state.
auth_state_file() {
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        test_override XRAY_TEST_AUTH_STATE || printf '/tmp/lisa-auth-rollback-test.state'
    else
        printf '/root/.xray-reality-manager/auth-rollback.state'
    fi
}
auth_log_file() {
    local state
    state="$(auth_state_file)"
    printf '%s/auth-rollback.log' "$(dirname "${state}")"
}
auth_timer_start() {
    local bak_main="$1" bak_list="$2" state log
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf '测试模式：回滚定时器已模拟启动（10 分钟，单元 lisa-auth-rollback），不调用 systemd-run，不写真实状态文件。\n'
        return 0
    fi
    state="$(auth_state_file)"; log="$(auth_log_file)"
    mkdir -p "$(dirname "${state}")" 2>/dev/null || true
    {
        printf 'pending\n'
        printf 'bak_main=%s\n' "${bak_main}"
        printf 'bak_list=%s\n' "${bak_list}"
    } > "${state}" 2>/dev/null || { log_warn "auth rollback timer: cannot write state file ${state}."; return 0; }
    printf '%s auth rollback timer started: 10 minutes, unit lisa-auth-rollback, state %s, log %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '')" "${state}" "${log}" >> "${log}" 2>/dev/null || true
    if command -v systemd-run >/dev/null 2>&1; then
        systemd-run --on-active=10min --unit=lisa-auth-rollback --timer-property=AccuracySec=1s "${SCRIPT_DIR}/manage.sh" auth-rollback >/dev/null 2>&1 \
            || log_warn "auth rollback timer: systemd-run failed; timer is a supplement only, the auth change itself is unchanged."
    else
        log_warn "auth rollback timer: systemd-run not available; no timer started (supplement only)."
    fi
    printf '回滚定时器已启动：10 分钟内回菜单确认测通，否则自动恢复备份的 sshd 配置。确认命令：DSH auth-confirm（或再次进菜单 1）。\n'
    return 0
}
auth_timer_cancel() {
    local state
    state="$(auth_state_file)"
    if [[ "${XRAY_TEST_MODE:-0}" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl stop lisa-auth-rollback.timer 2>/dev/null || true
        systemctl stop lisa-auth-rollback.service 2>/dev/null || true
    fi
    rm -f "${state}" 2>/dev/null || true
    return 0
}
cmd_auth_confirm() {
    local state
    state="$(auth_state_file)"
    if [[ ! -f "${state}" ]] || ! grep -q '^pending' "${state}" 2>/dev/null; then
        printf '没有待确认的认证更改。\n'
        return 0
    fi
    auth_timer_cancel
    printf '已确认新会话密钥登录测通，回滚定时器已取消。\n'
    return 0
}
cmd_auth_rollback() {
    local state bak_main bak_list orig f
    state="$(auth_state_file)"
    if [[ ! -f "${state}" ]] || ! grep -q '^pending' "${state}" 2>/dev/null; then
        log_info "auth rollback: no pending timer state, nothing to restore."
        return 0
    fi
    bak_main="$(grep '^bak_main=' "${state}" 2>/dev/null | cut -d= -f2-)"
    bak_list="$(grep '^bak_list=' "${state}" 2>/dev/null | cut -d= -f2-)"
    if [[ -n "${bak_main}" && -f "${bak_main}" ]]; then
        cp -a "${bak_main}" "${bak_main%.bak-*}" 2>/dev/null || true
        # bak_main suffix is .bak-YYYYMMDD-HHMMSS; strip it for the original path.
        orig="$(printf '%s' "${bak_main}" | sed -E 's/\.bak-[0-9]+-[0-9]+$//')"
        cp -a "${bak_main}" "${orig}" 2>/dev/null || true
    fi
    for f in ${bak_list}; do
        orig="$(printf '%s' "${f}" | sed -E 's/\.bak-[0-9]+-[0-9]+$//')"
        cp -a "${f}" "${orig}" 2>/dev/null || true
    done
    if [[ "${XRAY_TEST_MODE:-0}" != "1" ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    fi
    printf 'rolled_back\n' > "${state}" 2>/dev/null || true
    printf '%s auth rollback fired: sshd backups restored (timer not confirmed in 10 minutes).\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '')" >> "$(auth_log_file)" 2>/dev/null || true
    printf '回滚定时器到点未确认，已自动恢复备份的 sshd 配置。\n'
    return 0
}

# cmd_auth [pubkey]: menu 1, 更改认证方式（关闭密码、开启密钥登录）.
# Foolproof flow: user pastes ONE public key line. The script validates
# the format, rejects private keys (-----BEGIN, multiline, empty), never
# prints key material (only comments), backs up authorized_keys before
# appending, sets .ssh 700 / authorized_keys 600, shows key count and
# comments, then asks a second confirmation before closing password.
# Closing password: backups sshd_config + sshd_config.d/*.conf, changes
# BOTH main file and drop-ins (first-match trap, 2026-10-31 main-machine
# lesson), sets PasswordAuthentication no, KbdInteractiveAuthentication
# no, ChallengeResponseAuthentication no, PubkeyAuthentication yes,
# PermitRootLogin prohibit-password. sshd -t failure restores backups
# and does NOT restart; success restarts ssh and rechecks sshd -T.
# No key (no input, validation fail, authorized_keys empty) = refuse.
# Test mode (XRAY_TEST_MODE=1): never touches real sshd, real
# authorized_keys, or real systemctl. Test files come from
# XRAY_TEST_AUTH_KEYS, XRAY_TEST_SSHD_CONFIG, XRAY_TEST_SSHD_DIR
# (via test_override), sshd -T / restart are simulated, and the same
# validation, backup, append, and count logic runs on those test files.
cmd_auth() {
    local pubkey="${1:-}"
    local sshd_config sshd_dir auth_keys ssh_dir
    sshd_config="$(test_override XRAY_TEST_SSHD_CONFIG || printf '/etc/ssh/sshd_config')"
    sshd_dir="$(test_override XRAY_TEST_SSHD_DIR || printf '/etc/ssh/sshd_config.d')"
    auth_keys="$(test_override XRAY_TEST_AUTH_KEYS || printf '%s/.ssh/authorized_keys' "${HOME}")"
    ssh_dir="$(dirname "${auth_keys}")"
    # Rollback-timer state, shown once on next menu 1 entry:
    local _auth_state
    _auth_state="$(auth_state_file)"
    if [[ -f "${_auth_state}" ]] && grep -q '^rolled_back' "${_auth_state}" 2>/dev/null; then
        printf '上次未确认，已自动回滚。\n'
        rm -f "${_auth_state}" 2>/dev/null || true
    elif [[ -f "${_auth_state}" ]] && grep -q '^pending' "${_auth_state}" 2>/dev/null; then
        printf '已有待确认的认证更改（回滚定时器运行中）。\n'
        if confirm "Impact: 确认你已在新会话里测通密钥登录，取消回滚定时器？" ; then
            auth_timer_cancel
            printf '已确认，回滚定时器已取消。\n'
            return 0
        else
            log_info "回滚定时器仍在运行，本次不开始新的认证更改。"
            return 1
        fi
    fi
    printf '更改认证方式（关闭密码、开启密钥登录）\n'
    printf '========================================\n'
    printf '当前 sshd 生效状态（sshd -T）：\n'
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf '  passwordauthentication no (测试模式模拟)\n'
        printf '  pubkeyauthentication yes (测试模式模拟)\n'
        printf '  permitrootlogin prohibit-password (测试模式模拟)\n'
        printf '  kbdinteractiveauthentication no (测试模式模拟)\n'
    elif command -v sshd >/dev/null 2>&1; then
        sshd -T 2>/dev/null | grep -iE '^(passwordauthentication|pubkeyauthentication|permitrootlogin|kbdinteractiveauthentication) ' || printf '  （sshd -T 无输出，请检查 sshd 是否可用）\n'
    else
        printf '  （sshd 未安装，无法显示当前状态）\n'
    fi
    if [[ -z "${pubkey}" ]]; then
        printf '请粘贴一行公钥（不要粘贴私钥，只粘贴公钥那一行）：\n'
        read -r pubkey || pubkey=""
    fi
    if [[ -z "${pubkey}" ]]; then
        die "公钥不能为空，拒绝关闭密码。"
        return 1
    fi
    if printf '%s' "${pubkey}" | grep -q 'BEGIN.*PRIVATE KEY'; then
        die "这是私钥，不是公钥，拒绝保存、拒绝关闭密码。请只粘贴公钥那一行。"
        return 1
    fi
    if [[ "${pubkey}" == *$'\n'* ]]; then
        die "公钥必须是单行，拒绝保存、拒绝关闭密码。"
        return 1
    fi
    if ! [[ "${pubkey}" =~ ^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
        die "公钥格式不对，拒绝保存、拒绝关闭密码。必须是 ssh-ed25519 / ssh-rsa / ecdsa-* / sk-* 开头的公钥单行。"
        return 1
    fi
    local key_material key_comment
    key_material="$(printf '%s' "${pubkey}" | awk '{print $2}')"
    key_comment="$(printf '%s' "${pubkey}" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')"
    [[ -n "${key_comment}" ]] || key_comment="(无注释)"
    printf '你输入的公钥注释：%s（密钥值不打印）\n' "${key_comment}"
    local count=0 line comment
    if [[ -f "${auth_keys}" ]]; then
        while IFS= read -r line || [[ -n "${line}" ]]; do
            [[ -z "${line}" ]] && continue
            case "${line}" in \#*) continue ;; esac
            count=$((count+1))
            comment="$(printf '%s' "${line}" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')"
            [[ -n "${comment}" ]] || comment="(无注释)"
            printf '  已有密钥 %s：%s\n' "${count}" "${comment}"
        done < "${auth_keys}"
    fi
    printf '已有密钥数量：%s\n' "${count}"
    local already=0
    if [[ -f "${auth_keys}" ]] && grep -qF "${key_material}" "${auth_keys}" 2>/dev/null; then
        already=1
        printf '该公钥已在 authorized_keys 里，跳过追加。\n'
    else
        local stamp bak_keys
        stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || printf 'bak')"
        mkdir -p "${ssh_dir}" || { die "无法创建 ${ssh_dir}"; return 1; }
        if [[ -f "${auth_keys}" ]]; then
            bak_keys="${auth_keys}.bak-${stamp}"
            cp -a "${auth_keys}" "${bak_keys}" || { die "备份 authorized_keys 失败，拒绝继续。"; return 1; }
            printf '已备份 authorized_keys 到：%s（只显示路径，不打印密钥）\n' "${bak_keys}"
        fi
        printf '%s\n' "${pubkey}" >> "${auth_keys}" || { die "追加公钥失败，拒绝关闭密码。"; return 1; }
        chmod 700 "${ssh_dir}" 2>/dev/null || true
        chmod 600 "${auth_keys}" 2>/dev/null || true
        printf '已追加公钥（注释：%s）。\n' "${key_comment}"
        count=$((count+1))
        printf '追加后密钥数量：%s\n' "${count}"
    fi
    if [[ "${count}" -eq 0 ]]; then
        die "authorized_keys 为空，拒绝关闭密码。请先加一把公钥。"
        return 1
    fi
    if [[ "${count}" -eq 1 ]]; then
        printf '警告：只有 1 把密钥。关闭密码后如果这把密钥丢了，会被锁在外面。\n'
        printf '请先在新会话里测通密钥登录，不要关掉当前会话。\n'
    fi
    confirm "Impact: 关闭密码登录，只留密钥登录。sshd_config 和 sshd_config.d/*.conf 都会备份并一起改，sshd -t 失败会恢复备份不重启，通过才重启 ssh 并用 sshd -T 复核。请确认你已在新会话里测通密钥登录。" || { log_info "更改认证方式已取消，密码未关闭。"; return 1; }
    local stamp bak_main bak_file f
    stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || printf 'bak')"
    if [[ -f "${sshd_config}" ]]; then
        bak_main="${sshd_config}.bak-${stamp}"
        cp -a "${sshd_config}" "${bak_main}" || { die "备份 sshd_config 失败，拒绝继续。"; return 1; }
        printf '已备份：%s\n' "${bak_main}"
    else
        die "找不到 sshd_config：${sshd_config}，拒绝继续。"
        return 1
    fi
    local bak_list=""
    if [[ -d "${sshd_dir}" ]]; then
        for f in "${sshd_dir}"/*.conf; do
            [[ -f "${f}" ]] || continue
            bak_file="${f}.bak-${stamp}"
            cp -a "${f}" "${bak_file}" || { die "备份 ${f} 失败，拒绝继续。"; return 1; }
            bak_list="${bak_list} ${bak_file}"
            printf '已备份：%s\n' "${bak_file}"
        done
    fi
    # set_sshd_value <file> <key> <value>: replace existing (uncommented)
    # directive, else append. Must run on main + every drop-in.
    set_sshd_value() {
        local file="$1" key="$2" val="$3"
        if grep -qiE "^[[:space:]]*${key}[[:space:]]" "${file}"; then
            sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${val}|I" "${file}"
        else
            printf '%s %s\n' "${key}" "${val}" >> "${file}"
        fi
    }
    local target_files="${sshd_config}"
    if [[ -d "${sshd_dir}" ]]; then
        for f in "${sshd_dir}"/*.conf; do
            [[ -f "${f}" ]] || continue
            target_files="${target_files} ${f}"
        done
    fi
    local tf key val
    for tf in ${target_files}; do
        set_sshd_value "${tf}" "PasswordAuthentication" "no"
        set_sshd_value "${tf}" "KbdInteractiveAuthentication" "no"
        set_sshd_value "${tf}" "ChallengeResponseAuthentication" "no"
        set_sshd_value "${tf}" "PubkeyAuthentication" "yes"
        set_sshd_value "${tf}" "PermitRootLogin" "prohibit-password"
    done
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf '测试模式：不碰真实 sshd，不重启。已模拟 sshd -t 通过、sshd -T 复核 password no。\n'
        printf '更改完成（测试模式）：密码已关闭（模拟），只留密钥登录。\n'
        printf '请先在新会话里测通密钥登录，不要关掉当前会话。\n'
        auth_timer_start "${bak_main}" "${bak_list}"
        return 0
    fi
    if ! command -v sshd >/dev/null 2>&1; then
        die "sshd 未安装，无法校验，正在恢复备份。"
        cp -a "${bak_main}" "${sshd_config}" 2>/dev/null || true
        for bak_file in ${bak_list}; do
            local orig="${bak_file%.bak-*}"
            cp -a "${bak_file}" "${orig}" 2>/dev/null || true
        done
        return 1
    fi
    if ! sshd -t 2>&1; then
        log_error "sshd -t 校验失败，正在恢复备份，不重启。"
        cp -a "${bak_main}" "${sshd_config}" 2>/dev/null || true
        for bak_file in ${bak_list}; do
            local orig="${bak_file%.bak-*}"
            # bak suffix is .bak-YYYYMMDD-HHMMSS, orig is file without that suffix
            orig="$(printf '%s' "${bak_file}" | sed -E 's/\.bak-[0-9]+-[0-9]+$//')"
            cp -a "${bak_file}" "${orig}" 2>/dev/null || true
        done
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    else
        service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
    fi
    printf '重启后 sshd -T 复核：\n'
    sshd -T 2>/dev/null | grep -iE '^(passwordauthentication|pubkeyauthentication|permitrootlogin|kbdinteractiveauthentication) ' || true
    if sshd -T 2>/dev/null | grep -qiE '^passwordauthentication[[:space:]]+no'; then
        printf '更改完成：密码已关闭，只留密钥登录。\n'
        printf '请先在新会话里测通密钥登录，不要关掉当前会话。\n'
        auth_timer_start "${bak_main}" "${bak_list}"
        return 0
    else
        log_error "复核未见 password no，正在恢复备份并重启。"
        cp -a "${bak_main}" "${sshd_config}" 2>/dev/null || true
        for bak_file in ${bak_list}; do
            local orig2
            orig2="$(printf '%s' "${bak_file}" | sed -E 's/\.bak-[0-9]+-[0-9]+$//')"
            cp -a "${bak_file}" "${orig2}" 2>/dev/null || true
        done
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        fi
        return 1
    fi
}

cmd_diag() {
    bash "${SCRIPT_DIR}/diagnose.sh" "$@"
}

cmd_logs() {
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u xray -n 100 --no-pager 2>&1 | tail -100
    elif [[ -f "${XRAY_LOG_DIR}/error.log" ]]; then
        tail -100 "${XRAY_LOG_DIR}/error.log"
    else
        # Log rotation may have moved the current file away; a rotated
        # file is still readable and is better than nothing.
        local rotated
        rotated="$(ls -t "${XRAY_LOG_DIR}"/error.log.1* 2>/dev/null | head -1 || true)"
        if [[ -n "${rotated}" ]]; then
            printf '(current error.log is rotated away; showing latest rotated file: %s)\n' "${rotated}"
            case "${rotated}" in
                *.gz) zcat "${rotated}" 2>/dev/null | tail -100 ;;
                *) tail -100 "${rotated}" ;;
            esac
        else
            die "no journalctl and no error log file found."
            return 1
        fi
    fi
    return 0
}

cmd_uninstall() {
    local purge=0 ans ans2
    confirm "Impact: this removes the xray binary, systemd units, geodata, and the 'DSH' launcher. Your node config is KEPT by default. A snapshot backup is taken first." || { log_info "uninstall cancelled."; return 1; }
    printf 'Also delete the node config directory (purge)? [y/N]: '
    read -r ans || ans=""
    case "${ans}" in
        y|Y|yes|YES)
            # Purge needs three affirmatives: this prompt, the confirm
            # below, and the re-typed "yes". Any decline keeps the config.
            if confirm "Impact: PURGE will delete the entire config directory ${XRAY_CONF_DIR} including your node config. This cannot be undone except from a snapshot."; then
                printf 'Type "yes" again to confirm PURGE (delete config dir): '
                read -r ans2 || ans2=""
                if [[ "${ans2}" == "yes" ]]; then
                    purge=1
                else
                    log_info "purge not confirmed; continuing with config kept."
                fi
            else
                log_info "purge declined; continuing with config kept."
            fi
            ;;
    esac
    snapshot_create >/dev/null || true
    service_stop || true
    run_systemctl disable xray || true
    local tmpdir installer
    tmpdir="$(mktemp -d)" || { die "cannot create temp dir"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -rf -- '${tmpdir}'; trap - RETURN" RETURN
    installer="$(fetch_installer "${tmpdir}/install-release.sh")" || return 1
    if [[ "${purge}" -eq 1 ]]; then
        bash "${installer}" remove --purge || { die "official uninstall (purge) failed."; return 1; }
    else
        bash "${installer}" remove || { die "official uninstall failed."; return 1; }
    fi
    local link="${LAUNCHER_DIR}/${LAUNCHER_NAME}"
    if [[ -L "${link}" && "$(readlink "${link}")" == "${SCRIPT_DIR}/manage.sh" ]]; then
        rm -f -- "${link}" || true
        log_info "launcher removed: ${link}"
    fi
    # 顺手清掉每日体检定时器（它只属于本工具）。
    if [[ "${XRAY_TEST_MODE:-0}" != "1" ]]; then
        run_systemctl disable --now dsh-smoke.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/dsh-smoke.timer /etc/systemd/system/dsh-smoke.service 2>/dev/null || true
        run_systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    log_info "uninstall complete (snapshot kept for recovery)."
    return 0
}

# ------------------------------------------------------------ BBR cmds ----
# cmd_smoke: 一条命令体检（调用随工具一起安装的 smoke-remote.sh）。
cmd_smoke() {
    local f="${SCRIPT_DIR}/smoke-remote.sh"
    if [[ ! -f "${f}" ]]; then
        die "体检脚本缺失：${f}（重跑一次安装器即可补上）"
        return 1
    fi
    bash "${f}" "$@"
}

cmd_bbr() {
    _bbr_lib
    local sub="${1:-}"
    shift || true
    case "${sub}" in
        ""|menu) bbr_menu ;;
        enable) bbr_enable ;;
        version) bbr_version ;;
        status) bbr_status ;;
        clear) bbr_clear ;;
        bbr3) die "BBRv3 安装已移除；请用 'DSH bbr enable'（官方内核 BBR+FQ）。"; return 1 ;;
        *) die "bbr: unknown subcommand '${sub}' (enable|version|status|clear)."; return 1 ;;
    esac
}

bbr_menu() {
    local choice
    while true; do
        printf '  ── BBR+FQ（官方内核）──\n'
        printf '  只设置 congestion=bbr + qdisc=fq；不安装内核、不重启、不改 Xray。\n'
        printf '   1.  一键启用 BBR+FQ\n'
        printf '   2.  检查版本与状态\n'
        printf '   3.  清除 BBR 配置\n'
        printf '   0.  返回\n'
        printf '请选择 [0-3]: '
        read -r choice || return 0
        case "${choice}" in
            1) bbr_enable ;;
            2) bbr_version; bbr_status || true ;;
            3) bbr_clear ;;
            0) return 0 ;;
            *) printf '无效选择：%s\n' "${choice}" ;;
        esac
        printf '按回车返回 BBR 菜单 ... '
        read -r _dummy || true
    done
}

menu() {
    local choice ns
    local rule='\033[90m┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄\033[0m'
    local y='\033[33m' r='\033[0m'
    while true; do
        banner
        printf "  ${rule}\n"
        printf '  \033[1;36m系统\033[0m\n'
        printf "   ${y}%2s${r} 认证方式     ${y}%2s${r} 核心版本\n" 1 2
        printf "   ${y}%2s${r} 检查更新     ${y}%2s${r} 升级核心\n" 3 4
        printf "   ${y}%2s${r} 回滚快照     ${y}%2s${r} 备份快照\n" 5 6
        printf "   ${y}%2s${r} 节点配置     ${y}%2s${r} 通用链接\n" 7 8
        printf "  ${rule}\n"
        printf '  \033[1;36m运维\033[0m\n'
        printf "   ${y}%2s${r} 状态检查     ${y}%2s${r} 线路诊断\n" 9 10
        printf "   ${y}%2s${r} 查看日志     ${y}%2s${r} BBR+FQ\n" 11 12
        printf "  ${rule}\n"
        printf '  \033[1;36mHysteria2\033[0m \033[90m附加协议\033[0m\n'
        printf "   ${y}%2s${r} 安装/升级    ${y}%2s${r} 卸载\n" 13 14
        printf "   ${y}%2s${r} 查看链接     ${y}%2s${r} 状态/重启\n" 15 16
        printf "   ${y}%2s${r} 日志         ${y}%2s${r} 轮换证书\n" 17 18
        printf "   ${y}%2s${r} 一键体检     ${y}%2s${r} 伪装地址\n" 19 20
        printf "  ${rule}\n"
        printf "   ${y}%2s${r} \033[90m退出\033[0m\n" 0
        printf '  \033[36m请选择\033[0m [0-20]: '
        read -r choice || return 0
        case "${choice}" in
            1) cmd_auth ;;
            2) cmd_version ;;
            3) cmd_check_update ;;
            4) cmd_upgrade ;;
            5) cmd_rollback ;;
            6) cmd_backup ;;
            7)
                printf '节点操作：show/init/share/sni/restore-main: '
                read -r ns || ns=""
                cmd_node "${ns:-show}"
                ;;
            8) cmd_share ;;
            9)
                cmd_status
                printf '权限审计：\n'
                validate_permissions || true
                ;;
            10) cmd_diag ;;
            11) cmd_logs ;;
            12) cmd_bbr enable ;;
            13) hy2_cmd_install ;;
            14) hy2_cmd_uninstall ;;
            15) hy2_cmd_link ;;
            16) hy2_cmd_status ;;
            17) hy2_cmd_logs ;;
            18) hy2_cmd_rotate_cert ;;
            19) cmd_smoke ;;
            20) hy2_cmd_masquerade ;;
            0) printf '再见。\n'; return 0 ;;
            *) printf '无效选择：%s\n' "${choice}" ;;
        esac
        printf '按回车返回菜单 ... '
        read -r _dummy || true
    done
}
main() {
    local cmd="${1:-menu}"
    shift || true
    case "${cmd}" in
        menu) menu ;;
        status) cmd_status ;;
        version) cmd_version ;;
        check-update) cmd_check_update ;;
        install) cmd_install "$@" ;;
        upgrade) cmd_upgrade "$@" ;;
        downgrade) cmd_downgrade "$@" ;;
        rollback) cmd_rollback "$@" ;;
        backup) cmd_backup ;;
        restore) cmd_rollback "$@" ;;
        node) cmd_node "$@" ;;
        share) cmd_share ;;
        diag) cmd_diag "$@" ;;
        auth) cmd_auth "$@" ;;
        auth-confirm) cmd_auth_confirm ;;
        auth-rollback) cmd_auth_rollback ;;
        logs) cmd_logs ;;
        uninstall) cmd_uninstall ;;
        bbr) cmd_bbr "$@" ;;
        hy2) hy2_cmd "$@" ;;
        smoke) cmd_smoke "$@" ;;
        help|--help|-h) usage ;;
        *) die "unknown command: ${cmd} (run with 'help' for usage)."; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
    exit $?
fi
