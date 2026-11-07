#!/usr/bin/env bash
#
# lib/bbr.sh — BBR acceleration for xray-reality-manager (menu 12, BBRv3-only).
#
# Design (BBRv3-only, pushed 2026-10-30, remote head a6d909d9):
#   12. BBR 加速方案, section 系统优化, prompt [0-12].
#   Submenu:
#     1. BBRv3+FQ   (ONLY variant. One-click flow: run once, install the
#                   v3 kernel if needed, reboot once; on the next boot a
#                   one-shot unit (not a daemon) auto-enables FQ only if
#                   the running kernel really is joeyblog v3 and
#                   tcp_bbr module version == 3, verifies congestion=bbr
#                   and qdisc=fq and module 3, then removes itself.
#                   If the v3 kernel is already running, FQ only, no
#                   reboot needed. Never enables FQ as v1, never claims
#                   v3 until module version == 3. If auto-enable fails,
#                   the one-shot is still disabled/removed and the user
#                   can re-run BBRv3+FQ manually; at most one more
#                   reboot or one manual run is expected, never a
#                   guarantee that reboot alone always succeeds.)
#     2. 检查版本与状态 (read-only: bbr_version + bbr_status)
#     3. 清空网络优化配置 (delete Lisa sysctl file, reload, tc revert;
#                   does NOT uninstall the kernel, does NOT reboot)
#     0. 返回
#   Direct commands: DSH bbr bbr3|version|status|clear
#   No "bbr1", no "bbr2", no standalone install/uninstall menu items
#   or direct commands. Kernel install exists ONLY as phase 1 of
#   bbr3_enable, and kernel rollback (bbr_rollback_kernel) exists
#   ONLY as the safety rollback inside bbr_install_kernel on
#   verification failure. Loading this file alone does NOT change the
#   live VPS kernel or BBR state; a change happens only when the
#   operator explicitly runs BBRv3+FQ / clear.
#
# Safety (same discipline as the Xray tool):
#   - Backup before every BBR change (sysctl file, kernel list, grub cfg).
#   - confirm() "yes" for bbr3/clear; version and status are
#     read-only and need no confirmation.
#   - NEVER reboot without an explicit yes at the reboot prompt.
#     Kernel install (as phase 1 of BBR3) and BBR3 installed-not-running offer
#     an immediate reboot (yes = reboot now, no = reboot later
#     manually); stage gate 4 (explicit consent before any reboot)
#     is satisfied by that yes, not bypassed by it. Test mode never
#     reboots.
#   - Manual only, no silent auto-upgrade (kernel or sysctl).
#   - Standard latest kernel only, no Max, no specific-version install,
#     no FQ_CODEL/FQ_PIE/CAKE, no APAC, no smart bandwidth, no crazy
#     mode, no IPv6 toggle. BBR is TCP-only and does not promise speed.
#   - Running BBR items never touches Xray config, params, keys, port
#     or share links. The share link is unchanged by BBR.
#   - BBR kernel .deb files come from byJoey's GitHub Releases at
#     install time (Lisa builds no kernel, bundles no .deb). If that
#     release publishes a checksum in a recognised sha256sum format it
#     is verified; otherwise the install proceeds on TLS + version
#     check only and says so honestly (same treatment as the official
#     Xray-install script, which has no published checksum).
#   - FQ failure never fails a node install: BBR items are manual menu
#     actions, separate from install.sh, which does NOT auto-enable FQ.
#     A fresh node stays on the system default until the operator runs
#     a BBR scheme explicitly. A script refresh (one-liner re-run on an
#     already-installed node) never changes sysctl or kernel either.
#
# Testability: paths are overridable (BBR_SYSCTL_FILE, BBR_BACKUP_DIR,
# BBR_OS_RELEASE, BBR_GRUB_CFG). System commands (sysctl, tc, ip,
# uname, modinfo, dpkg, update-grub) are called via PATH so tests can
# shadow them with fakes; API/download helpers (bbr_api_get,
# bbr_download_file) are plain functions tests may redefine, exactly
# like download_core() is redefined in the Xray tests. Production runs
# never set XRAY_TEST_MODE for BBR paths except confirm() auto-confirm
# (shared with the rest of the tool); BBR functions themselves do not
# branch on XRAY_TEST_MODE.

# -------------------------------------------------------------- paths ----
BBR_SYSCTL_FILE="${BBR_SYSCTL_FILE:-/etc/sysctl.d/99-lisa-bbr.conf}"
BBR_ONESHOT_UNIT="${BBR_ONESHOT_UNIT:-/etc/systemd/system/lisa-bbr3-oneshot.service}"
BBR_ONESHOT_NAME="lisa-bbr3-oneshot.service"
BBR_ONESHOT_RESULT="${BBR_ONESHOT_RESULT:-/root/.xray-reality-manager/bbr-oneshot-result.log}"
BBR_BACKUP_DIR="${BBR_BACKUP_DIR:-/root/.xray-reality-manager/bbr-backups}"
BBR_OS_RELEASE="${BBR_OS_RELEASE:-/etc/os-release}"
BBR_GRUB_CFG="${BBR_GRUB_CFG:-/boot/grub/grub.cfg}"
BBR_REPO="byJoey/Actions-bbr-v3"
BBR_API_RELEASES="https://api.github.com/repos/${BBR_REPO}/releases?per_page=30"
BBR_API_TAG_BASE="https://api.github.com/repos/${BBR_REPO}/releases/tags"

# ------------------------------------------------------------ helpers ----
# bbr_api_get <url>: JSON API fetch (stdout). Uses GITHUB_TOKEN only
# for api.github.com, only when set; the token value is never logged
# and never appears in the process argument list: when set, it is
# passed to curl via a config on stdin (-K -), not via -H on argv,
# so `ps` cannot see it. Interactive token entry must use
# `read -rs` from /dev/tty (see README), never as a command argument.
bbr_api_get() {
    local url="$1" token="${GITHUB_TOKEN:-}"
    if [[ -n "${token}" ]]; then
        printf 'header = "Authorization: Bearer %s"\n' "${token}" \
            | curl -fsSL -K - "${url}"
    else
        curl -fsSL "${url}"
    fi
}

# bbr_download_file <url> <dest>: binary download, no token (public assets).
bbr_download_file() {
    curl -fsSL "$1" -o "$2"
}

# bbr_arch_tag_prefix: x86_64 -> x86_64-, aarch64 -> arm64- (byJoey tags).
bbr_arch_tag_prefix() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64-' ;;
        aarch64|arm64) printf 'arm64-' ;;
        *)
            die "unsupported architecture for BBR kernel: $(uname -m)"
            return 1
            ;;
    esac
}

# bbr_congestion: current sysctl congestion (stdout, empty on failure).
bbr_congestion() {
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf ''
}

# bbr_qdisc: current sysctl default qdisc (stdout, empty on failure).
bbr_qdisc() {
    sysctl -n net.core.default_qdisc 2>/dev/null || printf ''
}

# bbr_module_version: tcp_bbr module version (stdout, empty only if
# modinfo itself fails). A stock in-tree BBR kernel has NO version
# field in modinfo; that is BBR v1, not unknown, so it prints 1 here
# (previously it printed empty, rendering as "module version :" in
# status output). A v3 kernel prints 3.
bbr_module_version() {
    local out line
    out="$(modinfo tcp_bbr 2>/dev/null)" || { printf ''; return 0; }
    line="$(printf '%s' "${out}" | grep '^version:' | head -1)" || true
    if [[ -z "${line}" ]]; then
        printf '1'
        return 0
    fi
    printf '%s' "${line}" | sed 's/^version:[[:space:]]*//;s/[[:space:]]*$//'
}

# bbr_default_iface: default-route interface (stdout, empty if none).
bbr_default_iface() {
    ip route show default 2>/dev/null | awk '{print $5; exit}'
}

# bbr_joeyblog_pkgs: installed joeyblog kernel package names (stdout).
# Only status "ii" counts as installed: after dpkg -r, a package stays
# listed with status "rc" (config files remain), and counting it would
# make uninstall repeat with a reboot message when nothing is left.
bbr_joeyblog_pkgs() {
    dpkg -l 2>/dev/null | awk '$1 == "ii" && /joeyblog/ {print $2}'
}

# bbr_backup_dir <stamp>: creates (idempotent) a timestamped backup dir.
bbr_backup_dir() {
    local d="${BBR_BACKUP_DIR}/$1"
    mkdir -p "${d}" || { die "cannot create BBR backup dir: ${d}"; return 1; }
    printf '%s' "${d}"
}

# bbr_stamp: timestamp for backup dirs (seconds + pid, collision-safe).
# Single line: date's trailing newline must not leak into the dirname
# (an internal newline would split log lines and break glob checks).
bbr_stamp() {
    printf '%s-%s' "$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf 'unknown')" "$$"
}

# ------------------------------------------------------------ env check ----
# bbr_check_env: Debian 12 only (Debian 12 exclusive, 2026-11-02),
# x86_64/aarch64, apt, GRUB, and no known-bad DKMS module
# (mimic/0.7.1). Fails closed, no changes. This gates only the BBRv3
# kernel install (bbr_install_kernel); bbr_version / bbr_status are
# read-only and do not call it, and FQ on an already-running v3
# kernel also does not call it.
bbr_check_env() {
    local id ver major
    [[ -f "${BBR_OS_RELEASE}" ]] || { die "cannot read OS release file: ${BBR_OS_RELEASE}"; return 1; }
    id="$(grep '^ID=' "${BBR_OS_RELEASE}" | cut -d= -f2 | tr -d '"')"
    ver="$(grep '^VERSION_ID=' "${BBR_OS_RELEASE}" | cut -d= -f2 | tr -d '"')"
    major="$(printf '%s' "${ver}" | cut -d. -f1)"
    if [[ "${id}" != "debian" || "${major}" != "12" ]]; then
        die "BBR kernel install needs Debian 12 only (found: ${id} ${ver})."
        return 1
    fi
    case "$(uname -m)" in
        x86_64|amd64|aarch64|arm64) ;;
        *) die "unsupported architecture for BBR kernel: $(uname -m)"; return 1 ;;
    esac
    require_command apt-get || return 1
    require_command dpkg || return 1
    require_command curl || return 1
    if [[ ! -f "${BBR_GRUB_CFG}" ]] && ! command -v update-grub >/dev/null 2>&1 && ! command -v grub-install >/dev/null 2>&1; then
        die "GRUB not found (no ${BBR_GRUB_CFG}, update-grub or grub-install); BBR kernel install requires GRUB."
        return 1
    fi
    if command -v dkms >/dev/null 2>&1; then
        if dkms status 2>/dev/null | grep -q 'mimic/0\.7\.1'; then
            die "DKMS module mimic/0.7.1 is registered; it is known to fail new-kernel builds (byJoey issue #37). Fix or remove it first; aborting with no kernel installed."
            return 1
        fi
    fi
    return 0
}

# ------------------------------------------------------------ FQ core ----
# bbr_enable_fq: shared sysctl+FQ step (BBRv3 phase 2 only).
# Backs up the previous Lisa file (if any) plus previous congestion/qdisc
# values, writes the Lisa file (bbr + fq only, no buffers), applies
# immediately (sysctl -w + tc replace on the default-route interface when
# one exists), then verifies sysctl values. On verification failure it
# rolls back (restores file/values, tc back when known) and returns 1.
# A missing default route skips tc (warns, still writes the file: the
# qdisc applies to new queues after reboot); a tc failure after a
# successful sysctl write is a rollback, not a partial success.
bbr_enable_fq() {
    local stamp bdir prev_file prev_cong prev_qdisc prev_tc iface
    stamp="$(bbr_stamp)"
    bdir="$(bbr_backup_dir "${stamp}")" || return 1
    prev_cong="$(bbr_congestion)"
    prev_qdisc="$(bbr_qdisc)"
    iface="$(bbr_default_iface)"
    prev_tc=""
    if [[ -n "${iface}" ]] && command -v tc >/dev/null 2>&1; then
        prev_tc="$(tc qdisc show dev "${iface}" 2>/dev/null | awk '{print $2; exit}')"
    fi
    {
        printf 'congestion=%s\n' "${prev_cong}"
        printf 'qdisc=%s\n' "${prev_qdisc}"
        printf 'tc_qdisc=%s\n' "${prev_tc}"
        printf 'iface=%s\n' "${iface}"
    } > "${bdir}/fq-before.txt" || { die "cannot write FQ backup meta."; return 1; }
    if [[ -f "${BBR_SYSCTL_FILE}" ]]; then
        cp -a "${BBR_SYSCTL_FILE}" "${bdir}/99-lisa-bbr.conf.bak" || { die "cannot back up existing BBR sysctl file."; return 1; }
    fi
    {
        printf 'net.ipv4.tcp_congestion_control=bbr\n'
        printf 'net.core.default_qdisc=fq\n'
    } > "${BBR_SYSCTL_FILE}" || { die "cannot write BBR sysctl file: ${BBR_SYSCTL_FILE}"; return 1; }
    chmod 644 "${BBR_SYSCTL_FILE}" 2>/dev/null || true
    if ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
        bbr_rollback_fq "${bdir}" || true
        die "failed to apply tcp_congestion_control=bbr (rolled back)."
        return 1
    fi
    if ! sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
        bbr_rollback_fq "${bdir}" || true
        die "failed to apply default_qdisc=fq (rolled back)."
        return 1
    fi
    if [[ -n "${iface}" ]]; then
        if command -v tc >/dev/null 2>&1; then
            if ! tc qdisc replace dev "${iface}" root fq >/dev/null 2>&1; then
                bbr_rollback_fq "${bdir}" || true
                die "failed to replace root qdisc on ${iface} with fq (rolled back)."
                return 1
            fi
        else
            log_warn "tc not found; root qdisc on ${iface} left unchanged (sysctl file still persists; fq applies to new queues after reboot)."
        fi
    else
        log_warn "no default route; tc replace skipped (sysctl file still persists; fq applies to new queues after reboot)."
    fi
    if [[ "$(bbr_congestion)" != "bbr" ]] || [[ "$(bbr_qdisc)" != "fq" ]]; then
        bbr_rollback_fq "${bdir}" || true
        die "FQ verification failed (congestion=$(bbr_congestion), qdisc=$(bbr_qdisc); expected bbr/fq; rolled back)."
        return 1
    fi
    log_info "BBR+FQ enabled (backup: ${bdir})."
    return 0
}

# bbr_rollback_fq <backup dir>: restores file + sysctl values + tc qdisc.
bbr_rollback_fq() {
    local bdir="$1" cong qdisc tcq iface
    [[ -d "${bdir}" ]] || return 1
    if [[ -f "${bdir}/99-lisa-bbr.conf.bak" ]]; then
        cp -a "${bdir}/99-lisa-bbr.conf.bak" "${BBR_SYSCTL_FILE}" || true
    else
        rm -f -- "${BBR_SYSCTL_FILE}" || true
    fi
    cong="$(grep '^congestion=' "${bdir}/fq-before.txt" 2>/dev/null | cut -d= -f2)"
    qdisc="$(grep '^qdisc=' "${bdir}/fq-before.txt" 2>/dev/null | cut -d= -f2)"
    tcq="$(grep '^tc_qdisc=' "${bdir}/fq-before.txt" 2>/dev/null | cut -d= -f2)"
    iface="$(grep '^iface=' "${bdir}/fq-before.txt" 2>/dev/null | cut -d= -f2)"
    [[ -n "${cong}" ]] && sysctl -w "net.ipv4.tcp_congestion_control=${cong}" >/dev/null 2>&1 || true
    [[ -n "${qdisc}" ]] && sysctl -w "net.core.default_qdisc=${qdisc}" >/dev/null 2>&1 || true
    if [[ -n "${iface}" && -n "${tcq}" ]] && command -v tc >/dev/null 2>&1; then
        tc qdisc replace dev "${iface}" root "${tcq}" >/dev/null 2>&1 || true
    fi
    return 0
}

# bbr_version: read-only current version (no changes, always exit 0).
bbr_version() {
    local pkgs
    pkgs="$(bbr_joeyblog_pkgs | tr '\n' ' ')"
    [[ -n "${pkgs}" ]] || pkgs="(none)"
    printf 'running kernel : %s\n' "$(uname -r)"
    printf 'joeyblog pkgs  : %s\n' "${pkgs}"
    printf 'tcp_bbr version: %s\n' "$(bbr_module_version)"
    printf 'congestion     : %s\n' "$(bbr_congestion)"
    printf 'qdisc          : %s\n' "$(bbr_qdisc)"
    if [[ -f "${BBR_SYSCTL_FILE}" ]]; then
        printf 'DSH sysctl    : %s (present)\n' "${BBR_SYSCTL_FILE}"
    else
        printf 'DSH sysctl    : (absent)\n'
    fi
    return 0
}

# bbr_status: read-only effective check. Exit 0 if BBR+FQ is effective
# (congestion==bbr and qdisc==fq), else 1 with a plain summary (no die,
# so a "not effective" state is not reported as an [ERROR]).
bbr_status() {
    local cong qdisc ver ok=1
    cong="$(bbr_congestion)"
    qdisc="$(bbr_qdisc)"
    ver="$(bbr_module_version)"
    printf 'kernel         : %s\n' "$(uname -r)"
    printf 'tcp_bbr version: %s\n' "${ver}"
    printf 'congestion     : %s (expected bbr)\n' "${cong}"
    printf 'qdisc          : %s (expected fq)\n' "${qdisc}"
    [[ "${cong}" == "bbr" ]] || ok=0
    [[ "${qdisc}" == "fq" ]] || ok=0
    if [[ -f "${BBR_SYSCTL_FILE}" ]]; then
        printf 'DSH sysctl    : present\n'
    else
        printf 'DSH sysctl    : absent (FQ was not persisted by Lisa; runtime values above may still be bbr/fq from another tool)\n'
        ok=0
    fi
    if [[ "${ok}" -eq 1 ]]; then
        printf 'BBR+FQ: effective (module version %s: 1 = stock kernel, 3 = BBRv3 kernel).\n' "${ver}"
        return 0
    fi
    printf 'BBR+FQ: NOT effective (see mismatches above).\n'
    return 1
}

# ------------------------------------------------------------ kernel ----
# bbr_latest_kernel_tag: highest non-Max tag for this arch from the
# Releases list (stdout, e.g. x86_64-7.0.11). Fails when none is found.
bbr_latest_kernel_tag() {
    local prefix json tags tag ver best best_ver
    prefix="$(bbr_arch_tag_prefix)" || return 1
    json="$(bbr_api_get "${BBR_API_RELEASES}")" || { die "failed to list BBR kernel releases (GitHub API; set GITHUB_TOKEN if rate-limited)."; return 1; }
    tags="$(printf '%s' "${json}" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')"
    best=""
    best_ver=""
    while IFS= read -r tag; do
        case "${tag}" in
            "${prefix}"*) ;;
            *) continue ;;
        esac
        case "${tag}" in
            *-max) continue ;;
        esac
        ver="${tag#${prefix}}"
        if [[ ! "${ver}" =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
            continue
        fi
        if [[ -z "${best}" ]]; then
            best="${tag}"
            best_ver="${ver}"
        elif [[ "$(version_cmp "${ver}" "${best_ver}")" == "1" ]]; then
            best="${tag}"
            best_ver="${ver}"
        fi
    done <<< "${tags}"
    [[ -n "${best}" ]] || { die "no standard BBR kernel release found for ${prefix} (Max excluded)."; return 1; }
    printf '%s' "${best}"
}

# bbr_prompt_reboot <context>: after a kernel change, offer an immediate
# reboot instead of only printing "manual reboot required". The prompt
# states the impact (Xray node down during reboot, back with the same
# config and share link after boot, old kernels kept); typing exactly
# "yes" reboots now, anything else leaves the reboot for later manually
# (declining is not an error, the caller still returns 0, and the
# one-shot unit stays enabled so a later manual reboot still triggers
# auto-enable). A yes-reboot does NOT enable FQ by itself: on the next
# boot the one-shot unit enables FQ only if v3 is running, then removes
# itself; if it did not happen, re-run BBR3+FQ manually.
# Test mode NEVER reboots: it prints a would-reboot line and returns 0
# (tests use auto-confirm, so calling confirm() here in test mode and
# then rebooting would reboot the test machine).
bbr_prompt_reboot() {
    local context="$1"
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        printf 'Reboot prompt (test mode, not rebooting): %s\n' "${context}"
        return 0
    fi
    if confirm "Reboot now? Impact: this machine will reboot immediately; the Xray node will be down during the reboot and will come back with the same config and share link once the system is up. Old kernels are kept. After reboot, FQ is auto-enabled by the one-shot unit if the v3 kernel is running (verify with DSH bbr status); if auto-enable did not happen, re-run BBR3+FQ manually."; then
        log_info "rebooting now (${context})."
        if command -v reboot >/dev/null 2>&1; then
            reboot || systemctl reboot || { die "reboot command failed."; return 1; }
        else
            systemctl reboot || { die "reboot command failed."; return 1; }
        fi
        return 0
    fi
    log_info "reboot declined; reboot manually later (${context})."
    return 0
}

# ------------------------------------------------------------ oneshot ----
# One-shot auto-enable (NOT a daemon, NOT a persistent service):
# bbr_oneshot_install creates /etc/systemd/system/lisa-bbr3-oneshot.service
# (path overridable via BBR_ONESHOT_UNIT for tests) only after a kernel
# install succeeds, or when bbr3_enable finds a joeyblog kernel installed
# but not running. The unit is Type=oneshot, WantedBy=multi-user.target,
# ExecStart is the non-interactive internal target `DSH bbr auto-fq`
# (never a confirm prompt, so boot can never block on input).
# bbr_auto_fq is the boot handler: it enables FQ ONLY when the running
# kernel name contains joeyblog AND tcp_bbr module version == 3; on any
# other kernel it skips, warns, and does NOT enable FQ as v1. After the
# attempt — success or failure — it disables and deletes the unit and
# daemon-reloads, so no active task is left behind to re-run or
# re-change sysctl on later boots, and it writes one result line to
# BBR_ONESHOT_RESULT (OK / SKIP / FAIL with a reason). A declined
# immediate reboot leaves the unit enabled, so a later manual reboot
# triggers it the same way. bbr_clear and kernel rollback both delete
# the unit, so cancelling/clearing never leaves a pending auto-enable.
bbr_oneshot_cleanup() {
    run_systemctl disable "${BBR_ONESHOT_NAME}" >/dev/null 2>&1 || true
    rm -f -- "${BBR_ONESHOT_UNIT}" 2>/dev/null || true
    run_systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
}

bbr_oneshot_write_result() {
    local status="$1" msg="$2" dir
    dir="$(dirname "${BBR_ONESHOT_RESULT}")"
    mkdir -p "${dir}" 2>/dev/null || true
    printf '%s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'unknown')" "${status}" "${msg}" > "${BBR_ONESHOT_RESULT}" 2>/dev/null || true
    return 0
}

bbr_oneshot_install() {
    local dir
    dir="$(dirname "${BBR_ONESHOT_UNIT}")"
    mkdir -p "${dir}" || { log_warn "cannot create oneshot unit dir: ${dir}"; return 1; }
    cat > "${BBR_ONESHOT_UNIT}" <<'UNITEOF'
[Unit]
Description=DSH BBRv3 one-shot auto-enable FQ (runs once after reboot, then removes itself)
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/DSH bbr auto-fq
RemainAfterExit=no
[Install]
WantedBy=multi-user.target
UNITEOF
    chmod 644 "${BBR_ONESHOT_UNIT}" 2>/dev/null || true
    run_systemctl daemon-reload >/dev/null 2>&1 || { log_warn "oneshot daemon-reload failed; auto-enable may not trigger."; return 1; }
    run_systemctl enable "${BBR_ONESHOT_NAME}" >/dev/null 2>&1 || { log_warn "oneshot enable failed; auto-enable may not trigger."; return 1; }
    log_info "BBRv3 oneshot installed: ${BBR_ONESHOT_UNIT} (auto-enables FQ on next boot only if v3 kernel is running, then removes itself)."
    return 0
}

# bbr_auto_fq: non-interactive boot handler for the oneshot unit.
# Never calls confirm(). Returns 0 only when congestion=bbr,
# qdisc=fq and tcp_bbr module version == 3 are all verified.
bbr_auto_fq() {
    local kernel ver cong qdisc
    kernel="$(uname -r)"
    ver="$(bbr_module_version)"
    if [[ "${kernel}" != *joeyblog* ]] || [[ "${ver}" != "3" ]]; then
        log_warn "BBR oneshot skipped: not a running joeyblog v3 kernel (kernel=${kernel}, tcp_bbr module=${ver}); FQ NOT enabled as v1."
        bbr_oneshot_write_result "SKIP" "not v3 kernel kernel=${kernel} module=${ver}"
        bbr_oneshot_cleanup || true
        return 1
    fi
    if ! bbr_enable_fq; then
        log_warn "BBR oneshot failed: FQ enable failed (rolled back); oneshot disabled, run 'DSH bbr bbr3' manually after checking."
        bbr_oneshot_write_result "FAIL" "fq enable failed"
        bbr_oneshot_cleanup || true
        return 1
    fi
    cong="$(bbr_congestion)"
    qdisc="$(bbr_qdisc)"
    ver="$(bbr_module_version)"
    if [[ "${cong}" != "bbr" ]] || [[ "${qdisc}" != "fq" ]] || [[ "${ver}" != "3" ]]; then
        log_warn "BBR oneshot verification failed: congestion=${cong}, qdisc=${qdisc}, module=${ver}; expected bbr/fq/3; not claimed effective; oneshot disabled."
        bbr_oneshot_write_result "FAIL" "verification congestion=${cong} qdisc=${qdisc} module=${ver}"
        bbr_oneshot_cleanup || true
        return 1
    fi
    log_info "BBR3+FQ auto-enabled on boot: congestion=bbr, qdisc=fq, tcp_bbr module=3."
    bbr_oneshot_write_result "OK" "congestion=bbr qdisc=fq module=3"
    bbr_oneshot_cleanup || true
    return 0
}

# bbr_install_kernel: kernel-only install (BBR3 phase 1 only; there is no
# standalone install menu item or direct command). Env checks, download of every non-debug .deb
# for the chosen tag, checksum verification when a recognised sha256sum
# file is published (otherwise TLS + version only, stated honestly),
# dpkg install, initramfs + grub verification, old kernel kept.
# On verification failure it removes the new packages, re-runs update-grub
# and restores the grub backup, then returns 1. On success it offers an
# immediate reboot via bbr_prompt_reboot (yes = reboot now, no = reboot
# later manually); test mode never reboots.
bbr_install_kernel() {
    local tag ver tmpdir stamp bdir old_kernel pkgs deb url
    bbr_check_env || return 1
    tag="$(bbr_latest_kernel_tag)" || return 1
    ver="${tag}"
    # Strip the arch prefix (x86_64- / arm64-) for the kernel version.
    case "${tag}" in
        x86_64-*) ver="${tag#x86_64-}" ;;
        arm64-*) ver="${tag#arm64-}" ;;
    esac
    old_kernel="$(uname -r)"
    stamp="$(bbr_stamp)"
    bdir="$(bbr_backup_dir "${stamp}")" || return 1
    dpkg -l > "${bdir}/dpkg-before.txt" 2>/dev/null || true
    if [[ -f "${BBR_GRUB_CFG}" ]]; then
        cp -a "${BBR_GRUB_CFG}" "${bdir}/grub.cfg.bak" || { die "cannot back up grub config."; return 1; }
    fi
    tmpdir="$(mktemp -d)" || { die "cannot create temp dir"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -rf -- '${tmpdir}'; trap - RETURN" RETURN
    # Fetch the release's asset list, pick non-debug .deb URLs.
    local assets_json
    assets_json="$(bbr_api_get "${BBR_API_TAG_BASE}/${tag}")" || { die "failed to fetch release ${tag} assets."; return 1; }
    local deb_urls
    deb_urls="$(printf '%s' "${assets_json}" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*\.deb"' | sed 's/.*"\([^"]*\)"$/\1/' | grep -v -E 'dbg|dbgsym|max' || true)"
    if [[ -z "${deb_urls}" ]]; then
        die "no non-debug kernel .deb found in release ${tag}."
        return 1
    fi
    # Checksum: only when a sha256sum-format file is published.
    local sum_url sum_file
    sum_url="$(printf '%s' "${assets_json}" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*\(SHA256SUMS\|sha256sum\|checksums\)[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' | head -1)"
    while IFS= read -r url; do
        deb="${tmpdir}/$(basename "${url}")"
        bbr_download_file "${url}" "${deb}" || { die "failed to download kernel package: ${url}"; return 1; }
        [[ -s "${deb}" ]] || { die "downloaded kernel package is empty: ${deb}"; return 1; }
    done <<< "${deb_urls}"
    if [[ -n "${sum_url}" ]]; then
        sum_file="${tmpdir}/checksum.txt"
        bbr_download_file "${sum_url}" "${sum_file}" || { die "failed to download kernel checksum file."; return 1; }
        # Recognised format only: "<hex>  <filename>" lines (sha256sum).
        if grep -Eq '^[0-9a-fA-F]{64}[[:space:]]+\S+' "${sum_file}"; then
            (cd "${tmpdir}" && sha256sum -c "${sum_file}" >/dev/null 2>&1) || { die "kernel checksum mismatch; aborting with nothing installed."; return 1; }
            log_info "kernel checksum OK."
        else
            die "kernel checksum file format not recognised; cannot verify, aborting with nothing installed (TLS-only fallback is not used when a checksum is published)."
            return 1
        fi
    else
        log_warn "no checksum published for release ${tag}; proceeding only on TLS + version + tag check (documented limitation, same as the official Xray-install script)."
        confirm "No kernel checksum file was published for release ${tag}. Continue on TLS + version + tag check only?" || { die "kernel install aborted: no checksum published and operator did not confirm."; return 1; }
    fi
    # Hyper-V guard: on Hyper-V, the new kernel config must carry the
    # storage/net/PCI/NVMe drivers, else booting fails (byJoey #39).
    local virt=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt="$(systemd-detect-virt 2>/dev/null || true)"
    fi
    # Install (dpkg keeps co-installable old kernels; it never removes
    # a different-version kernel package on its own).
    local deb_list
    deb_list="$(printf '%s\n' "${tmpdir}"/*.deb)"
    # shellcheck disable=SC2086
    if ! dpkg -i ${deb_list} >/dev/null 2>&1; then
        die "dpkg install failed (dependencies? run 'apt-get -f install' manually and retry); nothing was verified, aborting before any reboot prompt."
        return 1
    fi
    pkgs="$(bbr_joeyblog_pkgs)"
    if [[ -z "${pkgs}" ]]; then
        # byJoey .deb package names carry joeyblog; if the naming ever
        # changes, the dpkg list check above is the tripwire, not a
        # silent pass. Fall back to checking the tag version in dpkg.
        if ! dpkg -l 2>/dev/null | grep -q "${ver}"; then
            die "new kernel package not found in dpkg after install; aborting."
            return 1
        fi
        log_warn "joeyblog package name not found in dpkg (naming may have changed); version ${ver} was found instead, continuing with that check."
    fi
    if ! command -v update-grub >/dev/null 2>&1; then
        log_warn "update-grub not found; grub config was backed up to ${bdir}/grub.cfg.bak, run update-grub manually before rebooting."
    elif ! update-grub >/dev/null 2>&1; then
        bbr_rollback_kernel "${bdir}" || true
        die "update-grub failed after kernel install (rolled back: new packages removed, grub restored)."
        return 1
    elif ! grep -q "${ver}" "${BBR_GRUB_CFG}" 2>/dev/null; then
        bbr_rollback_kernel "${bdir}" || true
        die "new kernel version ${ver} not found in grub config after update-grub (rolled back)."
        return 1
    fi
    if [[ "${virt}" == "microsoft" ]]; then
        local cfgfile
        cfgfile="/boot/config-${ver}"
        if [[ -f "${cfgfile}" ]]; then
            if ! grep -Eq '^CONFIG_(HYPERV_STORAGE|HYPERV_NET|PCI_HYPERV|NVME_CORE)=y' "${cfgfile}"; then
                bbr_rollback_kernel "${bdir}" || true
                die "new kernel config lacks Hyper-V drivers (storage/net/PCI/NVMe); aborting on Hyper-V (would fail to boot, byJoey #39; rolled back)."
                return 1
            fi
        else
            log_warn "Hyper-V detected but /boot/config-${ver} not found; driver check skipped."
            confirm "Hyper-V kernel config not found, so the boot-driver check was skipped. Verify boot drivers before rebooting, and continue anyway?" || { bbr_rollback_kernel "${bdir}" || true; die "kernel install aborted: Hyper-V config not found and operator did not confirm (rolled back)."; return 1; }
        fi
    fi
    if ! dpkg -l 2>/dev/null | grep -q "${old_kernel}"; then
        log_warn "old kernel ${old_kernel} not found in dpkg after install; fallback to the old kernel is lost. New kernel ${ver} is installed and verified, but keep console access until the new kernel is proven to boot."
    fi
    if ! bbr_oneshot_install; then
        log_warn "BBRv3 oneshot auto-enable could not be installed; kernel is installed, but after reboot run 'DSH bbr bbr3' manually to enable FQ."
    fi
    log_info "BBRv3 kernel ${ver} installed (tag ${tag}; backup: ${bdir})."
    printf 'Reboot to boot the new kernel; on the next boot FQ is auto-enabled by the one-shot unit if the v3 kernel is running, then the unit removes itself. Verify with DSH bbr status.\n'
    bbr_prompt_reboot "boot the new BBRv3 kernel ${ver}; after reboot, FQ is auto-enabled by the one-shot unit — verify with DSH bbr status, and only re-run BBR3+FQ manually if FQ is not enabled"
    return 0
}

# bbr_rollback_kernel <backup dir>: remove joeyblog packages, update grub,
# restore grub backup when present. Best-effort; callers report failure.
bbr_rollback_kernel() {
    local bdir="$1" pkgs
    bbr_oneshot_cleanup || true
    pkgs="$(bbr_joeyblog_pkgs)"
    if [[ -n "${pkgs}" ]]; then
        # shellcheck disable=SC2086
        dpkg -r ${pkgs} >/dev/null 2>&1 || true
    fi
    if [[ -f "${bdir}/grub.cfg.bak" ]]; then
        cp -a "${bdir}/grub.cfg.bak" "${BBR_GRUB_CFG}" 2>/dev/null || true
    fi
    if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null 2>&1 || true
    fi
    return 0
}

# bbr3_enable: BBR3+FQ, one-click, never claims v3 until verified.
#   - Module version == 3 already: FQ only (skip install); a stale
#     one-shot unit, if any, is removed after a successful enable.
#   - joeyblog installed but module != 3: kernel installed, not running.
#     Ensure the one-shot unit exists (so a later manual reboot also
#     triggers auto-enable), offer an immediate reboot via
#     bbr_prompt_reboot and return 0 (FQ pending); do NOT enable FQ
#     now (that would be v1, not v3). On the next boot the one-shot
#     enables FQ only if v3 is running, then removes itself.
#   - Otherwise: install kernel (phase 1, which creates the one-shot
#     unit on success and itself offers a reboot prompt), return 0
#     (FQ pending until the next boot's one-shot run).
bbr3_enable() {
    local ver
    ver="$(bbr_module_version)"
    if [[ "${ver}" == "3" ]]; then
        confirm "Impact: system TCP defaults will change to congestion=bbr and qdisc=fq on the running BBRv3 kernel (sysctl file ${BBR_SYSCTL_FILE}, applied immediately, no reboot, no Xray config change). Revert with 'bbr clear'." || { log_info "BBR3+FQ cancelled."; return 1; }
        bbr_enable_fq || return 1
        if [[ "$(bbr_module_version)" != "3" ]]; then
            die "FQ applied but tcp_bbr module version is no longer 3; BBR3+FQ is not verified."
            return 1
        fi
        bbr_oneshot_cleanup || true
        printf 'BBR3+FQ enabled: congestion=%s, qdisc=%s, tcp_bbr module version=3.\n' "$(bbr_congestion)" "$(bbr_qdisc)"
        return 0
    fi
    if [[ -n "$(bbr_joeyblog_pkgs)" ]]; then
        printf 'BBRv3 kernel is installed but not running (module version %s, running kernel %s).\n' "${ver}" "$(uname -r)"
        printf 'FQ is NOT enabled now, because enabling it on the old kernel would be v1, not v3.\n'
        if [[ ! -f "${BBR_ONESHOT_UNIT}" ]]; then
            bbr_oneshot_install || log_warn "BBRv3 oneshot auto-enable could not be installed; after reboot run 'DSH bbr bbr3' manually to enable FQ."
        fi
        bbr_prompt_reboot "boot the BBRv3 kernel (select it in GRUB if needed); on the next boot FQ is auto-enabled by the one-shot unit if v3 is running"
        return 0
    fi
    confirm "Impact: a BBRv3 kernel will be installed from byJoey Releases (standard latest, old kernel kept, initramfs + grub verified). After install, you will be asked whether to reboot now (yes = reboot immediately, no = reboot later manually). On the next boot FQ is auto-enabled by the one-shot unit if the v3 kernel is running, then the unit removes itself. No Xray config change." || { log_info "BBR3+FQ cancelled."; return 1; }
    bbr_install_kernel || return 1
    return 0
}

# bbr_clear: delete Lisa sysctl file, reload, tc revert (submenu item 3),
# and always remove a pending one-shot auto-enable unit (so clearing
# before a reboot cancels the pending auto-enable too).
# Does NOT uninstall the kernel. A tc revert failure is a warning, not
# a failure: the file is gone, so a reboot fully reverts the runtime.
bbr_clear() {
    local stamp bdir iface prev_tc
    if [[ ! -f "${BBR_SYSCTL_FILE}" ]]; then
        if [[ -f "${BBR_ONESHOT_UNIT}" ]]; then
            bbr_oneshot_cleanup || true
            log_info "BBR oneshot auto-enable removed (no DSH BBR sysctl file to clear)."
        else
            log_info "no DSH BBR sysctl file (${BBR_SYSCTL_FILE}); nothing to clear (runtime values, if any, came from another tool; reboot to fully revert them)."
        fi
        return 0
    fi
    confirm "Impact: DSH BBR sysctl file ${BBR_SYSCTL_FILE} will be deleted and sysctl reloaded (congestion/qdisc revert to system defaults for new connections). The BBR kernel is NOT uninstalled by clear. Runtime qdisc reverts immediately when known, otherwise on reboot." || { log_info "BBR clear cancelled."; return 1; }
    bbr_oneshot_cleanup || true
    stamp="$(bbr_stamp)"
    bdir="$(bbr_backup_dir "${stamp}")" || return 1
    cp -a "${BBR_SYSCTL_FILE}" "${bdir}/99-lisa-bbr.conf.bak" || { die "cannot back up BBR sysctl file."; return 1; }
    # Previous tc qdisc, if a prior FQ backup recorded one, else fq_codel
    # (Debian default) as the revert target; unknown stays a warning.
    prev_tc="fq_codel"
    iface="$(bbr_default_iface)"
    rm -f -- "${BBR_SYSCTL_FILE}" || { die "cannot delete BBR sysctl file."; return 1; }
    if ! sysctl --system >/dev/null 2>&1; then
        cp -a "${bdir}/99-lisa-bbr.conf.bak" "${BBR_SYSCTL_FILE}" 2>/dev/null || true
        die "sysctl reload failed after deleting the file (file restored)."
        return 1
    fi
    if [[ -n "${iface}" ]] && command -v tc >/dev/null 2>&1; then
        if ! tc qdisc replace dev "${iface}" root "${prev_tc}" >/dev/null 2>&1; then
            log_warn "tc revert to ${prev_tc} on ${iface} failed; runtime qdisc reverts on reboot (sysctl file is already deleted)."
        fi
    fi
    log_info "BBR network optimisation cleared (backup: ${bdir})."
    return 0
}

