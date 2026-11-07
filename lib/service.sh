#!/usr/bin/env bash
#
# lib/service.sh — service control, safe binary swap, upgrade / downgrade /
# rollback orchestration, and official update checks for
# DSH.
#
# The safe-swap order (NEVER violated): backup -> download+verify ->
# stop service -> replace files -> migrate permissions -> config test ->
# start service -> verify version. On ANY failure after the stop, restore
# the snapshot, re-migrate permissions, re-test, re-start, and report.
# A running binary is never overwritten (Linux refuses with ETXTBSY, and
# even if it did not, it would corrupt the running service).

_SVLIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "${_SVLIB_DIR}/common.sh"
# shellcheck disable=SC1091
source "${_SVLIB_DIR}/download.sh"
# shellcheck disable=SC1091
source "${_SVLIB_DIR}/backup.sh"
# shellcheck disable=SC1091
source "${_SVLIB_DIR}/perm.sh"
# shellcheck disable=SC1091
source "${_SVLIB_DIR}/node.sh"

# ------------------------------------------------------ service control ----
service_stop()    { run_systemctl stop xray; }
service_restart() { run_systemctl restart xray; }
service_enable()  { run_systemctl enable xray; }

# service_reload_units: daemon-reload after unit files change.
service_reload_units() { run_systemctl daemon-reload; }

# -------------------------------------------------------- version query ----
# official_latest_version: prints the latest official tag (no leading v)
# from the GitHub API, parsed with grep/sed (no jq). Empty on failure.
official_latest_version() {
    local body tag
    body="$(curl -fsSL -A "DSH/1.1" \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null)" \
        || { die "failed to query GitHub API for the latest release."; return 1; }
    tag="$(printf '%s' "${body}" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 \
        | sed -E 's/.*"(v?[0-9][^"]*)".*/\1/')"
    if [[ -z "${tag}" ]]; then
        die "could not parse latest version from GitHub API response."
        return 1
    fi
    normalize_version "${tag}"
}

# -------------------------------------------------------- upgrade flow ----
# upgrade_core <version> [installer-path]: full upgrade/downgrade flow.
# When installer-path is omitted, the official installer is downloaded
# (TLS + sanity). When given (tests use a stub), it is used directly.
# Steps: confirm -> snapshot -> tempdir download+verify -> stop -> swap
# (via official installer --local) -> migrate perms -> config test ->
# start -> verify version. Any failure after the snapshot restores it.
upgrade_core() {
    local target installer tmpdir zip snap cur
    target="$(normalize_version "$1")" || return 1
    installer="${2:-}"
    cur="$(current_version)"
    if [[ "${cur}" == "unknown" ]]; then
        die "no installed core found; use install.sh for a fresh install first."
        return 1
    fi
    if [[ "$(version_cmp "${target}" "${cur}")" == "0" ]]; then
        log_info "already on ${target}; nothing to do (same-version install is a no-op)."
        return 0
    fi
    confirm "Impact: the xray service will restart and the core will change from ${cur} to ${target}. A snapshot backup will be taken first." || { log_info "upgrade cancelled."; return 1; }
    snap="$(snapshot_create)" || return 1
    tmpdir="$(mktemp -d)" || { die "cannot create temp dir"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -rf -- '${tmpdir}'; trap - RETURN" RETURN
    local arch
    arch="$(detect_arch_suffix)" || return 1
    zip="$(download_core "${target}" "${arch}" "${tmpdir}")" || return 1
    if [[ -z "${installer}" ]]; then
        installer="$(fetch_installer "${tmpdir}/install-release.sh")" || return 1
    fi
    service_stop || log_warn "stop reported an error; continuing (service may already be stopped)."
    # The official installer replaces the binary + units from the verified
    # zip. It never overwrites an existing config (official behaviour).
    install_with_official "${installer}" "${zip}" || {
        log_error "official installer failed; restoring snapshot."
        snapshot_restore "${snap}" full || true
        migrate_permissions || true
        service_restart || true
        die "upgrade aborted: installer failed; previous state restored."
        return 1
    }
    # Units changed: reload before any (re)start so systemd sees the new units.
    service_reload_units || true
    migrate_permissions || {
        log_error "permission migration failed; restoring snapshot."
        snapshot_restore "${snap}" full || true
        migrate_permissions || true
        service_restart || true
        die "upgrade aborted: permission migration failed; previous state restored."
        return 1
    }
    if ! config_test "${XRAY_CONF}"; then
        log_error "config test failed after upgrade; restoring snapshot."
        snapshot_restore "${snap}" full || true
        migrate_permissions || true
        service_restart || true
        die "upgrade aborted: config test failed; previous state restored."
        return 1
    fi
    # Root-run test may have created root-owned log files; re-migrate
    # before restart, or the xray-user service fails (exit 23).
    migrate_permissions || {
        log_error "permission migration failed after upgrade test; restoring snapshot."
        snapshot_restore "${snap}" full || true
        migrate_permissions || true
        service_restart || true
        die "upgrade aborted: permission migration failed; previous state restored."
        return 1
    }
    service_restart || {
        log_error "service failed to start after upgrade; restoring snapshot."
        snapshot_restore "${snap}" full || true
        migrate_permissions || true
        service_restart || true
        die "upgrade aborted: service restart failed; previous state restored."
        return 1
    }
    local newver
    newver="$(current_version)"
    if [[ "${newver}" != "${target}" ]]; then
        log_error "post-upgrade version is ${newver}, expected ${target}; restoring snapshot."
        snapshot_restore "${snap}" full || true
        migrate_permissions || true
        service_restart || true
        die "upgrade aborted: version verification failed; previous state restored."
        return 1
    fi
    log_info "upgrade complete: ${cur} -> ${target} (snapshot kept: ${snap})."
    return 0
}

# ------------------------------------------------------- rollback flow ----
# rollback_core [snapshot-dir]: restores the newest snapshot by default
# (binary + config + units), with the shared migrate/test/restart flow.
# Confirmation is mandatory: rollback changes the running version.
rollback_core() {
    local snap="$1"
    if [[ -z "${snap}" ]]; then
        snap="$(latest_snapshot)"
    fi
    if [[ -z "${snap}" || ! -d "${snap}" ]]; then
        die "no snapshot found to roll back to."
        return 1
    fi
    local snap_ver cur
    snap_ver="$(grep '^version=' "${snap}/meta.txt" 2>/dev/null | cut -d'=' -f2)"
    cur="$(current_version)"
    confirm "Impact: the xray service will restart and the core will roll back from ${cur} to snapshot ${snap} (version ${snap_ver:-unknown}), including its config and units." || { log_info "rollback cancelled."; return 1; }
    local pre
    pre="$(snapshot_create)" || return 1
    service_stop || log_warn "stop reported an error; continuing (service may already be stopped)."
    snapshot_restore "${snap}" full || {
        log_error "snapshot restore failed; attempting to restore the pre-rollback snapshot."
        snapshot_restore "${pre}" full || true
        migrate_permissions || true
        service_restart || true
        die "rollback aborted: restore failed; pre-rollback state restored."
        return 1
    }
    migrate_permissions || { die "permission migration failed after rollback."; return 1; }
    if ! config_test "${XRAY_CONF}"; then
        log_error "config test failed after rollback; restoring pre-rollback snapshot."
        snapshot_restore "${pre}" full || true
        migrate_permissions || true
        service_restart || true
        die "rollback aborted: config test failed; pre-rollback state restored."
        return 1
    fi
    migrate_permissions || { die "permission migration failed after rollback test."; return 1; }
    service_restart || { die "service failed to restart after rollback."; return 1; }
    log_info "rollback complete: now on $(current_version) (pre-rollback snapshot kept: ${pre})."
    return 0
}
