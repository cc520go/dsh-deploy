#!/usr/bin/env bash
#
# lib/backup.sh — automatic snapshots before every change, retention, and
# restore for xray-reality-manager.
#
# Snapshot layout: ${SNAPSHOT_PARENT}/xray-backup-<YYYYMMDD-HHMMSS>-<ver>/
#   xray.bin            old binary (when present)
#   config.json         old node config (when present)
#   xray.service        old main unit (when present)
#   xray@.service       old template unit (when present)
#   xray.service.d/     old drop-in dir (when present)
#   share-xray/         old geodata dir (when present)
#   meta.txt            version, creation time, sha256 checksums
# Snapshot dirs are chmod 700 (root only). Only the newest 3 snapshots are
# kept, plus 1 extra "known-good" snapshot; older ones are pruned, and
# pruning only ever touches directories whose basename starts with
# "xray-backup-" directly under SNAPSHOT_PARENT.
#
# Known-good marking (decided in main chat 2026-11-03, post-change):
# the marker is placed on a snapshot of a configuration AFTER it has
# been verified (config test passes AND the service is listening), never
# on the pre-change snapshot. The marker is a file named "known-good"
# inside the snapshot dir. Pruning always skips a marked snapshot, so
# the total kept is newest 3 + 1 marked. Each time a new configuration
# is verified, the marker moves to that configuration's snapshot
# (snapshot_mark_verified_current); a marked snapshot whose config is
# identical to the current verified config is left alone, so repeated
# runs do not create duplicate marked snapshots.

_BKLIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "${_BKLIB_DIR}/common.sh"

SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-3}"

# current_version: prints the installed core version (e.g. 26.10.21), or
# "unknown" when no binary is present. Never dies (callers decide).
current_version() {
    local first ver
    if [[ ! -x "${XRAY_BIN}" ]]; then
        printf 'unknown'
        return 0
    fi
    first="$("${XRAY_BIN}" version 2>/dev/null | head -1)"
    ver="$(printf '%s' "${first}" | grep -oE '[0-9]+(\.[0-9]+){2}' | head -1)"
    if [[ -z "${ver}" ]]; then
        printf 'unknown'
    else
        printf '%s' "${ver}"
    fi
    return 0
}

# snapshot_create: takes a snapshot of the current install state and prints
# the snapshot directory (stdout). Prunes to the newest SNAPSHOT_KEEP.
snapshot_create() {
    local stamp ver dir bin_sha conf_sha suffix=1
    stamp="$(date +%Y%m%d-%H%M%S)"
    ver="$(current_version)"
    dir="${SNAPSHOT_PARENT}/xray-backup-${stamp}-${ver}"
    # Same-second snapshots would collide; append -2, -3, ... as needed.
    while [[ -e "${dir}" ]]; do
        suffix=$((suffix + 1))
        dir="${SNAPSHOT_PARENT}/xray-backup-${stamp}-${ver}-${suffix}"
    done
    mkdir -p "${dir}" || { die "cannot create snapshot dir: ${dir}"; return 1; }
    if [[ -f "${XRAY_BIN}" ]]; then
        cp -a "${XRAY_BIN}" "${dir}/xray.bin" || { die "snapshot: failed to copy binary"; return 1; }
    fi
    if [[ -f "${XRAY_CONF}" ]]; then
        cp -a "${XRAY_CONF}" "${dir}/config.json" || { die "snapshot: failed to copy config"; return 1; }
    fi
    if [[ -f "${XRAY_UNIT_DIR}/xray.service" ]]; then
        cp -a "${XRAY_UNIT_DIR}/xray.service" "${dir}/xray.service" 2>/dev/null || true
    fi
    if [[ -f "${XRAY_UNIT_DIR}/xray@.service" ]]; then
        cp -a "${XRAY_UNIT_DIR}/xray@.service" "${dir}/xray@.service" 2>/dev/null || true
    fi
    if [[ -d "${XRAY_UNIT_DIR}/xray.service.d" ]]; then
        cp -a "${XRAY_UNIT_DIR}/xray.service.d" "${dir}/xray.service.d" 2>/dev/null || true
    fi
    if [[ -d "${XRAY_SHARE_DIR}" ]]; then
        cp -a "${XRAY_SHARE_DIR}" "${dir}/share-xray" 2>/dev/null || true
    fi
    bin_sha="none"
    conf_sha="none"
    [[ -f "${dir}/xray.bin" ]] && bin_sha="$(sha256sum "${dir}/xray.bin" | cut -d' ' -f1)"
    [[ -f "${dir}/config.json" ]] && conf_sha="$(sha256sum "${dir}/config.json" | cut -d' ' -f1)"
    {
        printf 'version=%s\n' "${ver}"
        printf 'created=%s\n' "${stamp}"
        printf 'binary_sha256=%s\n' "${bin_sha}"
        printf 'config_sha256=%s\n' "${conf_sha}"
    } > "${dir}/meta.txt"
    chmod 700 "${dir}" || true
    log_info "snapshot created: ${dir} (version ${ver})"
    snapshot_prune || true
    printf '%s' "${dir}"
    return 0
}

# snapshot_list: prints snapshot dirs, newest first (stdout, one per line).
# Newest means newest by directory mtime, then by name descending as the
# tie-breaker. A plain name sort is wrong here: "ls -d .../" emits a
# trailing slash, and "/" sorts above "-", so a no-suffix snapshot would
# sort above a later same-second "-2"/"-4" snapshot and latest_snapshot
# would pick the older one. mtime first also stays correct when the
# version part of the name changes within the same second.
snapshot_list() {
    local -a dirs
    local dir mtime
    mapfile -t dirs < <(ls -d "${SNAPSHOT_PARENT}"/xray-backup-*/ 2>/dev/null || true)
    if [[ "${#dirs[@]}" -eq 0 ]]; then
        return 0
    fi
    for dir in "${dirs[@]}"; do
        mtime="$(stat -c %Y "${dir}" 2>/dev/null || echo 0)"
        # Sort key uses the name WITHOUT the trailing slash: with the
        # slash, "/" sorts above "-", which would again put a no-suffix
        # name above a later "-2" name. Without it, descending name
        # order is the creation order within one second.
        printf '%s %s %s\n' "${mtime}" "${dir%/}" "${dir}"
    done | sort -k1,1nr -k2,2r | cut -d' ' -f3- || true
}

# snapshot_mark_known_good <snapshot-dir>: moves the known-good
# marker to this snapshot. Callers MUST verify first (config test
# passes AND service listening); this function does not verify.
# Only one marked snapshot exists at a time.
snapshot_mark_known_good() {
    local snap="$1" dir
    if [[ ! -d "${snap}" ]]; then
        die "snapshot_mark_known_good: snapshot not found: ${snap}"
        return 1
    fi
    for dir in $(snapshot_list); do
        dir="${dir%/}"
        [[ "${dir}" != "${snap}" ]] && rm -f "${dir}/known-good" 2>/dev/null || true
    done
    printf '%s\n' "$(date +%Y%m%d-%H%M%S)" > "${snap}/known-good" 2>/dev/null || { die "cannot write known-good marker in ${snap}"; return 1; }
    log_info "known-good snapshot marked: ${snap}"
    return 0
}

# snapshot_known_good: prints the marked snapshot dir, or nothing.
snapshot_known_good() {
    local dir
    while IFS= read -r dir; do
        dir="${dir%/}"
        [[ -f "${dir}/known-good" ]] && { printf '%s' "${dir}"; return 0; }
    done < <(snapshot_list)
    return 0
}

# snapshot_mark_verified_current: if the live config passes config_test
# AND the service is listening on the params port, mark a snapshot of
# the current (post-change, verified) configuration as known-good.
# If the existing marked snapshot already has the same config, do
# nothing (no duplicate snapshot). Returns 1 when not verified;
# callers should treat a marking failure as a warning, never as a
# reason to fail an otherwise successful change.
snapshot_mark_verified_current() {
    local port cur_sha marked marked_sha snap
    port="$(read_node_param port 2>/dev/null || true)"
    if [[ -z "${port}" ]] || ! config_test "${XRAY_CONF}" 2>/dev/null; then
        return 1
    fi
    if ! verify_listening "${port}" 2>/dev/null; then
        return 1
    fi
    cur_sha="$(sha256sum "${XRAY_CONF}" 2>/dev/null | cut -d' ' -f1)"
    marked="$(snapshot_known_good)"
    if [[ -n "${marked}" && -f "${marked}/config.json" ]]; then
        marked_sha="$(sha256sum "${marked}/config.json" 2>/dev/null | cut -d' ' -f1)"
        if [[ "${marked_sha}" == "${cur_sha}" ]]; then
            log_info "known-good snapshot already matches current verified config: ${marked}"
            return 0
        fi
    fi
    snap="$(snapshot_create)" || return 1
    snapshot_mark_known_good "${snap}" || return 1
    return 0
}

# snapshot_prune: keeps the newest SNAPSHOT_KEEP snapshots, plus the
# marked known-good snapshot even when it falls outside the newest
# SNAPSHOT_KEEP. Deletion is guarded: only directories directly under
# SNAPSHOT_PARENT whose basename starts with "xray-backup-".
snapshot_prune() {
    local -a all
    local dir base count=0
    mapfile -t all < <(snapshot_list)
    for dir in "${all[@]}"; do
        # Marked snapshots never consume a keep slot and are never pruned.
        if [[ -f "${dir}/known-good" ]]; then
            continue
        fi
        count=$((count + 1))
        if [[ "${count}" -le "${SNAPSHOT_KEEP}" ]]; then
            continue
        fi
        base="$(basename "${dir}")"
        case "${base}" in
            xray-backup-*)
                log_info "pruning old snapshot: ${dir}"
                rm -rf -- "${dir}"
                ;;
            *)
                log_warn "refusing to prune unexpected directory: ${dir}"
                ;;
        esac
    done
    return 0
}

# snapshot_restore <snapshot-dir> <mode>: restores from a snapshot.
# mode "binary" restores only the binary; mode "full" restores binary +
# config + units + geodata. The caller is responsible for stopping the
# service first (restore never overwrites a running binary) and for
# running permission migration + config test + start afterwards.
snapshot_restore() {
    local snap="$1" mode="$2"
    if [[ ! -d "${snap}" ]]; then
        die "snapshot not found: ${snap}"
        return 1
    fi
    if [[ "${mode}" != "binary" && "${mode}" != "full" ]]; then
        die "snapshot_restore: unknown mode '${mode}' (expected binary|full)"
        return 1
    fi
    if [[ -f "${snap}/xray.bin" ]]; then
        cp -a "${snap}/xray.bin" "${XRAY_BIN}" || { die "restore: failed to restore binary"; return 1; }
        chmod 755 "${XRAY_BIN}" || true
        log_info "restored binary from ${snap}"
    else
        log_warn "snapshot has no binary; skipping binary restore."
    fi
    if [[ "${mode}" == "full" ]]; then
        if [[ -f "${snap}/config.json" ]]; then
            mkdir -p "${XRAY_CONF_DIR}" || { die "restore: cannot create config dir"; return 1; }
            cp -a "${snap}/config.json" "${XRAY_CONF}" || { die "restore: failed to restore config"; return 1; }
            log_info "restored config from ${snap}"
        fi
        if [[ -f "${snap}/xray.service" ]]; then
            cp -a "${snap}/xray.service" "${XRAY_UNIT_DIR}/xray.service" 2>/dev/null || true
        fi
        if [[ -f "${snap}/xray@.service" ]]; then
            cp -a "${snap}/xray@.service" "${XRAY_UNIT_DIR}/xray@.service" 2>/dev/null || true
        fi
        if [[ -d "${snap}/xray.service.d" ]]; then
            cp -a "${snap}/xray.service.d" "${XRAY_UNIT_DIR}/xray.service.d" 2>/dev/null || true
        fi
        if [[ -d "${snap}/share-xray" ]]; then
            cp -a "${snap}/share-xray/." "${XRAY_SHARE_DIR}/" 2>/dev/null || true
        fi
        log_info "restored units/geodata from ${snap}"
    fi
    return 0
}

# latest_snapshot: prints the newest snapshot dir (stdout), or nothing.
latest_snapshot() {
    snapshot_list | head -1
}
