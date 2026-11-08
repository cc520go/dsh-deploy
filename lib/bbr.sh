#!/usr/bin/env bash
#
# lib/bbr.sh — official-kernel BBR+FQ for DSH (menu 12).
#
# Scope: only the in-tree BBR algorithm plus the fq qdisc. This module does
# NOT install a third-party kernel, does NOT reboot, and does NOT touch Xray
# config, service, keys or share links.
#
# Design:
#   - write /etc/sysctl.d/99-dsh-bbr.conf with bbr + fq
#   - apply immediately: sysctl -w + tc qdisc replace <iface> root fq
#   - verify congestion/qdisc and roll back on failure
#   - idempotent; safe to run repeatedly
#   - migrate the old /etc/sysctl.d/99-lisa-bbr.conf
#   - remove a stale BBRv3 oneshot unit if an older install left one
#
# tcp_bbr is normally a loadable module that Debian does not preload; the
# sysctl write would autoload it, but the pre-check must not reject the
# kernel before that happens. bbr_supported() tries `modprobe tcp_bbr` once
# before failing closed, and still never installs a kernel.
#
# Testability: BBR_SYSCTL_FILE, BBR_LEGACY_SYSCTL_FILE, BBR_BACKUP_DIR and
# BBR_LEGACY_ONESHOT_UNIT are overridable so tests can redirect every write
# into a temp dir. On success, BBR+FQ is "effective" only when both sysctl
# values and the persisted file are present.

BBR_SYSCTL_FILE="${BBR_SYSCTL_FILE:-/etc/sysctl.d/99-dsh-bbr.conf}"
BBR_LEGACY_SYSCTL_FILE="${BBR_LEGACY_SYSCTL_FILE:-/etc/sysctl.d/99-lisa-bbr.conf}"
BBR_BACKUP_DIR="${BBR_BACKUP_DIR:-${DSH_STATE_DIR:-/root/.dsh-deploy}/bbr-backups}"
BBR_LEGACY_ONESHOT_UNIT="${BBR_LEGACY_ONESHOT_UNIT:-/etc/systemd/system/lisa-bbr3-oneshot.service}"

# bbr_congestion: current sysctl congestion (stdout, empty on failure).
bbr_congestion() {
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf ''
}

# bbr_qdisc: current sysctl default qdisc (stdout, empty on failure).
bbr_qdisc() {
    sysctl -n net.core.default_qdisc 2>/dev/null || printf ''
}

# bbr_module_version: tcp_bbr module version. A stock in-tree BBR kernel
# has no version field in modinfo; that is BBR v1, not unknown. A custom
# BBRv3 kernel prints 3.
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

# bbr_current_sysctl_file: existing DSH BBR file, preferring the new name;
# prints the new path when neither exists (for status/creation).
bbr_current_sysctl_file() {
    if [[ -f "${BBR_SYSCTL_FILE}" ]]; then
        printf '%s' "${BBR_SYSCTL_FILE}"
    elif [[ -f "${BBR_LEGACY_SYSCTL_FILE}" ]]; then
        printf '%s' "${BBR_LEGACY_SYSCTL_FILE}"
    else
        printf '%s' "${BBR_SYSCTL_FILE}"
    fi
}

# bbr_stamp: timestamp for backup dirs (seconds + pid, collision-safe).
bbr_stamp() {
    printf '%s-%s' "$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf 'unknown')" "$$"
}

# bbr_backup_dir <stamp>: creates (idempotent) a timestamped backup dir.
bbr_backup_dir() {
    local d="${BBR_BACKUP_DIR}/$1"
    mkdir -p "${d}" || { die "cannot create BBR backup dir: ${d}"; return 1; }
    printf '%s' "${d}"
}

# bbr_supported: fail closed when the running kernel has no tcp_bbr.
# The in-tree module is usually not loaded yet, so try loading it once
# (the persisted sysctl would autoload it on first write anyway) instead
# of reporting a false "kernel has no BBR".
bbr_supported() {
    local available
    available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    case " ${available} " in
        *" bbr "*) return 0 ;;
    esac
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
        case " ${available} " in
            *" bbr "*) log_info "loaded in-tree tcp_bbr module."; return 0 ;;
        esac
    fi
    die "当前内核没有可用的 tcp_bbr；请使用带 BBR 的 Debian 官方内核，本工具不会安装第三方内核。"
    return 1
}

# bbr_enable_fq: persist bbr+fq, apply now, verify, roll back on failure.
bbr_enable_fq() {
    local stamp bdir prev_file prev_cong prev_qdisc prev_tc iface
    stamp="$(bbr_stamp)"
    bdir="$(bbr_backup_dir "${stamp}")" || return 1
    prev_file="$(bbr_current_sysctl_file)"
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
    if [[ -f "${prev_file}" ]]; then
        cp -a "${prev_file}" "${bdir}/bbr-sysctl.conf.bak" \
            || { die "cannot back up existing BBR sysctl file."; return 1; }
    fi
    {
        printf '# DSH BBR+FQ (official Debian kernel; no third-party kernel installed)\n'
        printf 'net.ipv4.tcp_congestion_control=bbr\n'
        printf 'net.core.default_qdisc=fq\n'
    } > "${BBR_SYSCTL_FILE}" || { die "cannot write BBR sysctl file: ${BBR_SYSCTL_FILE}"; return 1; }
    chmod 644 "${BBR_SYSCTL_FILE}" 2>/dev/null || true
    # Migrate old name only after the new file is in place.
    if [[ "${BBR_LEGACY_SYSCTL_FILE}" != "${BBR_SYSCTL_FILE}" ]]; then
        rm -f -- "${BBR_LEGACY_SYSCTL_FILE}" 2>/dev/null || true
    fi
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
            log_warn "tc not found; root qdisc on ${iface} left unchanged (sysctl persists; fq applies to new queues after reboot)."
        fi
    else
        log_warn "no default route; tc replace skipped (sysctl persists; fq applies to new queues after reboot)."
    fi
    if [[ "$(bbr_congestion)" != "bbr" ]] || [[ "$(bbr_qdisc)" != "fq" ]]; then
        bbr_rollback_fq "${bdir}" || true
        die "FQ verification failed (congestion=$(bbr_congestion), qdisc=$(bbr_qdisc); expected bbr/fq; rolled back)."
        return 1
    fi
    log_info "BBR+FQ enabled on official kernel (backup: ${bdir})."
    return 0
}

# bbr_rollback_fq <backup dir>: restore the sysctl file and runtime values.
bbr_rollback_fq() {
    local bdir="$1" cong qdisc tcq iface
    [[ -d "${bdir}" ]] || return 1
    if [[ -f "${bdir}/bbr-sysctl.conf.bak" ]]; then
        cp -a "${bdir}/bbr-sysctl.conf.bak" "${BBR_SYSCTL_FILE}" || true
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

# bbr_enable: menu 12 / DSH bbr enable. One-key official BBR+FQ.
bbr_enable() {
    bbr_supported || return 1
    if bbr_status >/dev/null 2>&1 && [[ -f "${BBR_SYSCTL_FILE}" ]]; then
        log_info "BBR+FQ 已经生效（官方内核），无需重复操作。"
        return 0
    fi
    confirm "Impact: 将把 TCP 拥塞控制设为 bbr、队列设为 fq，并写入 ${BBR_SYSCTL_FILE}。不安装内核、不重启、不改 Xray 配置或链接。回退用 'DSH bbr clear'。" \
        || { log_info "BBR+FQ cancelled."; return 1; }
    bbr_enable_fq
}

# bbr_version: read-only current version (no changes, always exit 0).
bbr_version() {
    printf 'running kernel : %s\n' "$(uname -r)"
    printf 'tcp_bbr version: %s\n' "$(bbr_module_version)"
    printf 'congestion     : %s\n' "$(bbr_congestion)"
    printf 'qdisc          : %s\n' "$(bbr_qdisc)"
    local f
    f="$(bbr_current_sysctl_file)"
    if [[ -f "${f}" ]]; then
        printf 'DSH sysctl     : %s (present)\n' "${f}"
    else
        printf 'DSH sysctl     : (absent)\n'
    fi
    return 0
}

# bbr_status: read-only effective check. Exit 0 when congestion=bbr,
# qdisc=fq and a persisted DSH sysctl file exists; else 1.
bbr_status() {
    local cong qdisc ver f ok=1
    cong="$(bbr_congestion)"
    qdisc="$(bbr_qdisc)"
    ver="$(bbr_module_version)"
    f="$(bbr_current_sysctl_file)"
    printf 'kernel         : %s\n' "$(uname -r)"
    printf 'tcp_bbr version: %s\n' "${ver}"
    printf 'congestion     : %s (expected bbr)\n' "${cong}"
    printf 'qdisc          : %s (expected fq)\n' "${qdisc}"
    [[ "${cong}" == "bbr" ]] || ok=0
    [[ "${qdisc}" == "fq" ]] || ok=0
    if [[ -f "${f}" ]]; then
        printf 'DSH sysctl     : present (%s)\n' "${f}"
    else
        printf 'DSH sysctl     : absent (runtime bbr/fq may come from another tool and will not persist)\n'
        ok=0
    fi
    if [[ "${ok}" -eq 1 ]]; then
        printf 'BBR+FQ: effective (module version %s: 1 = official BBRv1, 3 = external BBRv3 kernel).\n' "${ver}"
        return 0
    fi
    printf 'BBR+FQ: NOT effective (see mismatches above).\n'
    return 1
}

# bbr_remove_persisted: delete the DSH BBR sysctl files (after copying them
# into the BBR backup dir), drop a stale BBRv3 oneshot unit, reload sysctl
# and reset the two runtime values to the Debian defaults. No confirmation
# here: bbr_clear and menu 21 uninstall already asked their own question.
# Never uninstalls a kernel. Prints nothing; logs the backup path.
bbr_remove_persisted() {
    local stamp bdir f iface prev_tc
    f="$(bbr_current_sysctl_file)"
    if [[ ! -f "${BBR_SYSCTL_FILE}" && ! -f "${BBR_LEGACY_SYSCTL_FILE}" \
        && ! -f "${BBR_LEGACY_ONESHOT_UNIT}" ]]; then
        return 0
    fi
    stamp="$(bbr_stamp)"
    bdir="$(bbr_backup_dir "${stamp}")" || return 1
    if [[ -f "${f}" ]]; then
        cp -a "${f}" "${bdir}/bbr-sysctl.conf.bak" || { die "cannot back up BBR sysctl file."; return 1; }
    fi
    rm -f -- "${BBR_SYSCTL_FILE}" "${BBR_LEGACY_SYSCTL_FILE}" || { die "cannot delete BBR sysctl file."; return 1; }
    if [[ -f "${BBR_LEGACY_ONESHOT_UNIT}" ]]; then
        run_systemctl disable --now "$(basename "${BBR_LEGACY_ONESHOT_UNIT}")" >/dev/null 2>&1 || true
        rm -f -- "${BBR_LEGACY_ONESHOT_UNIT}" 2>/dev/null || true
        run_systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if ! sysctl --system >/dev/null 2>&1; then
        if [[ -f "${bdir}/bbr-sysctl.conf.bak" ]]; then
            cp -a "${bdir}/bbr-sysctl.conf.bak" "${BBR_SYSCTL_FILE}" 2>/dev/null || true
        fi
        die "sysctl reload failed after deleting the file (file restored)."
        return 1
    fi
    # sysctl --system only reloads files; removed keys keep their runtime
    # values. Explicitly reset the two values we own to Debian defaults so
    # "clear" really means clear for new connections.
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 \
        || log_warn "failed to reset congestion to cubic; value will revert on reboot."
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 \
        || log_warn "failed to reset default qdisc to fq_codel; value will revert on reboot."
    prev_tc="fq_codel"
    iface="$(bbr_default_iface)"
    if [[ -n "${iface}" ]] && command -v tc >/dev/null 2>&1; then
        if ! tc qdisc replace dev "${iface}" root "${prev_tc}" >/dev/null 2>&1; then
            log_warn "tc revert to ${prev_tc} on ${iface} failed; runtime qdisc reverts on reboot (sysctl file is already deleted)."
        fi
    fi
    log_info "BBR sysctl 已删除（备份: ${bdir}）；运行时已尽量恢复 cubic/fq_codel。"
    return 0
}

# bbr_clear: remove the persisted file, reload sysctl, revert fq to fq_codel.
# Does NOT uninstall a kernel; the official kernel stays as-is.
bbr_clear() {
    local f
    f="$(bbr_current_sysctl_file)"
    if [[ ! -f "${f}" && ! -f "${BBR_LEGACY_ONESHOT_UNIT}" ]]; then
        log_info "no DSH BBR sysctl file; nothing to clear."
        return 0
    fi
    confirm "Impact: 删除 DSH 的 BBR sysctl 文件并重载 sysctl（新连接的 congestion/qdisc 回到系统默认）；不会卸载内核。运行中的 qdisc 会尽量立即恢复 fq_codel。" \
        || { log_info "BBR clear cancelled."; return 1; }
    bbr_remove_persisted || return 1
    return 0
}
