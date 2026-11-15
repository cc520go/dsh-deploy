#!/usr/bin/env bash
#
# lib/backup.sh — automatic snapshots before every change, retention, and
# restore for DSH.
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

# _snapshot_payload_digest <snapshot-dir> <entry...>: stable digest over the
# given snapshot entries (a file, or a whole directory tree). Entry paths and
# file names go into the digest, so a rename, a dropped file or a modified
# file all change it. Prints "none" when no entry exists at all.
_snapshot_payload_digest() {
    local dir="$1"; shift
    local entry manifest digest found=0 f
    manifest="$(mktemp)" || return 1
    for entry in "$@"; do
        if [[ -d "${dir}/${entry}" ]]; then
            found=1
            while IFS= read -r -d '' f; do
                printf '%s %s\n' "${f#"${dir}"/}" "$(sha256sum "${f}" | cut -d' ' -f1)"
            done < <(find "${dir}/${entry}" -type f -print0 | LC_ALL=C sort -z) >> "${manifest}"
        elif [[ -f "${dir}/${entry}" ]]; then
            found=1
            printf '%s %s\n' "${entry}" "$(sha256sum "${dir}/${entry}" | cut -d' ' -f1)" >> "${manifest}"
        fi
    done
    if [[ "${found}" -eq 0 ]]; then
        rm -f "${manifest}" 2>/dev/null || true
        printf 'none'
        return 0
    fi
    digest="$(sha256sum "${manifest}" | cut -d' ' -f1)"
    rm -f "${manifest}" 2>/dev/null || true
    printf '%s' "${digest}"
    return 0
}

# snapshot_create: takes a snapshot of the current install state and prints
# the snapshot directory (stdout). Prunes to the newest SNAPSHOT_KEEP.
snapshot_create() {
    local stamp ver dir bin_sha conf_sha params_sha units_sha geodata_sha bin_sha_now suffix=1
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
        bin_sha_now="$(sha256sum "${XRAY_BIN}" | cut -d' ' -f1)"
        # Same binary as an older snapshot: hardlink that snapshot's copy,
        # never the live path, so an in-place upgrade cannot corrupt it.
        if ! snapshot_link_previous "${bin_sha_now}" "${dir}" "${SNAPSHOT_PARENT}" \
                'xray-backup-*' 'xray.bin'; then
            cp -a "${XRAY_BIN}" "${dir}/xray.bin" \
                || { die "snapshot: failed to copy binary"; return 1; }
        fi
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
    # node.params is the node identity behind the config (uuid, keys, host,
    # port, sni). A snapshot without it can restore the config but not the
    # params, which is how a menu rollback used to leave the share link and
    # the live config disagreeing. Capture it with the rest of the payload.
    if [[ -f "${NODE_PARAMS_FILE}" ]]; then
        cp -a "${NODE_PARAMS_FILE}" "${dir}/node.params" \
            || { die "snapshot: failed to copy node.params"; return 1; }
    fi
    bin_sha="none"
    conf_sha="none"
    params_sha="none"
    [[ -f "${dir}/xray.bin" ]] && bin_sha="$(sha256sum "${dir}/xray.bin" | cut -d' ' -f1)"
    [[ -f "${dir}/config.json" ]] && conf_sha="$(sha256sum "${dir}/config.json" | cut -d' ' -f1)"
    [[ -f "${dir}/node.params" ]] && params_sha="$(sha256sum "${dir}/node.params" | cut -d' ' -f1)"
    # Units and geodata are part of the rollback payload too: a truncated
    # unit can leave the service unstartable while binary/config still match.
    units_sha="$(_snapshot_payload_digest "${dir}" xray.service xray@.service xray.service.d)"
    geodata_sha="$(_snapshot_payload_digest "${dir}" share-xray)"
    {
        printf 'version=%s\n' "${ver}"
        printf 'created=%s\n' "${stamp}"
        printf 'binary_sha256=%s\n' "${bin_sha}"
        printf 'config_sha256=%s\n' "${conf_sha}"
        printf 'params_sha256=%s\n' "${params_sha}"
        printf 'units_sha256=%s\n' "${units_sha}"
        printf 'geodata_sha256=%s\n' "${geodata_sha}"
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

# snapshot_verify_meta <snapshot-dir> <mode>: verify the snapshot payload
# against its meta.txt before any live file is touched. A snapshot whose
# binary/config hash does not match meta.txt is not a trustworthy rollback
# target: restoring it could silently install a truncated or tampered file.
# Missing meta.txt, missing hash fields, a hash/file mismatch, or a file
# that meta.txt does not record all fail closed (return 1).
snapshot_verify_meta() {
    local snap="$1" mode="$2" meta b_meta c_meta p_meta u_meta g_meta actual
    meta="${snap}/meta.txt"
    if [[ ! -f "${meta}" ]]; then
        die "snapshot meta.txt missing; refusing to restore ${snap}"
        return 1
    fi
    b_meta="$(awk -F= '$1=="binary_sha256"{print $2; exit}' "${meta}" | tr -d '\r')"
    c_meta="$(awk -F= '$1=="config_sha256"{print $2; exit}' "${meta}" | tr -d '\r')"
    if [[ -z "${b_meta}" || -z "${c_meta}" ]]; then
        die "snapshot meta.txt lacks binary_sha256/config_sha256; refusing to restore ${snap}"
        return 1
    fi
    if [[ -f "${snap}/xray.bin" ]]; then
        if [[ "${b_meta}" == "none" ]]; then
            die "snapshot has xray.bin but meta.txt records no binary hash; refusing to restore ${snap}"
            return 1
        fi
        actual="$(sha256sum "${snap}/xray.bin" | cut -d' ' -f1)"
        if [[ "${actual}" != "${b_meta}" ]]; then
            die "snapshot binary SHA256 mismatch; refusing to restore ${snap}"
            return 1
        fi
    elif [[ "${b_meta}" != "none" ]]; then
        die "snapshot meta.txt records a binary but xray.bin is missing; refusing to restore ${snap}"
        return 1
    fi
    if [[ "${mode}" == "full" ]]; then
        # node.params belongs to the config: restoring config.json without
        # it leaves the share link and the live node disagreeing. Snapshots
        # written before 1.4.3 have no params_sha256 line; those stay
        # restorable (legacy) but are reported, never silently trusted as
        # params-bearing.
        p_meta="$(awk -F= '$1=="params_sha256"{print $2; exit}' "${meta}" | tr -d '\r')"
        if [[ -f "${snap}/node.params" ]]; then
            if [[ -z "${p_meta}" || "${p_meta}" == "none" ]]; then
                die "snapshot has node.params but meta.txt records no params hash; refusing to restore ${snap}"
                return 1
            fi
            actual="$(sha256sum "${snap}/node.params" | cut -d' ' -f1)"
            if [[ "${actual}" != "${p_meta}" ]]; then
                die "snapshot node.params SHA256 mismatch; refusing to restore ${snap}"
                return 1
            fi
        elif [[ -n "${p_meta}" && "${p_meta}" != "none" ]]; then
            die "snapshot meta.txt records node.params but the file is missing; refusing to restore ${snap}"
            return 1
        elif [[ -z "${p_meta}" ]]; then
            log_warn "snapshot ${snap} predates params capture (no params_sha256); node.params will not be restored."
        fi
        u_meta="$(awk -F= '$1=="units_sha256"{print $2; exit}' "${meta}" | tr -d '\r')"
        g_meta="$(awk -F= '$1=="geodata_sha256"{print $2; exit}' "${meta}" | tr -d '\r')"
        if [[ -z "${u_meta}" || -z "${g_meta}" ]]; then
            log_warn "snapshot ${snap} predates units/geodata verification (no digest); those payload parts will be restored unverified."
        else
            if [[ "$(_snapshot_payload_digest "${snap}" xray.service xray@.service xray.service.d)" != "${u_meta}" ]]; then
                die "snapshot systemd units SHA256 mismatch; refusing to restore ${snap}"
                return 1
            fi
            if [[ "$(_snapshot_payload_digest "${snap}" share-xray)" != "${g_meta}" ]]; then
                die "snapshot geodata SHA256 mismatch; refusing to restore ${snap}"
                return 1
            fi
        fi
        if [[ -f "${snap}/config.json" ]]; then
            if [[ "${c_meta}" == "none" ]]; then
                die "snapshot has config.json but meta.txt records no config hash; refusing to restore ${snap}"
                return 1
            fi
            actual="$(sha256sum "${snap}/config.json" | cut -d' ' -f1)"
            if [[ "${actual}" != "${c_meta}" ]]; then
                die "snapshot config SHA256 mismatch; refusing to restore ${snap}"
                return 1
            fi
        elif [[ "${c_meta}" != "none" ]]; then
            die "snapshot meta.txt records a config but config.json is missing; refusing to restore ${snap}"
            return 1
        fi
    fi
    return 0
}

# snapshot_restore <snapshot-dir> <mode>: restores from a snapshot.
# mode "binary" restores only the binary; mode "full" restores binary +
# config + units + geodata. The snapshot payload is verified against
# meta.txt before anything is written; a mismatch aborts the restore.
# The caller is responsible for stopping the service first (restore never
# overwrites a running binary) and for running permission migration +
# config test + start afterwards.
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
    snapshot_verify_meta "${snap}" "${mode}" || return 1
    if [[ -f "${snap}/xray.bin" ]]; then
        # --remove-destination: snapshots are hardlinked, so the live path
        # must be unlinked before the copy or it would write through the
        # shared inode and change the snapshot too.
        cp -a --remove-destination "${snap}/xray.bin" "${XRAY_BIN}" \
            || { die "restore: failed to restore binary"; return 1; }
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
            cp -a --remove-destination "${snap}/share-xray/." "${XRAY_SHARE_DIR}/" 2>/dev/null || true
        fi
        if [[ -f "${snap}/node.params" ]]; then
            mkdir -p "$(dirname "${NODE_PARAMS_FILE}")" || { die "restore: cannot create state dir"; return 1; }
            cp -a --remove-destination "${snap}/node.params" "${NODE_PARAMS_FILE}"                 || { die "restore: failed to restore node.params"; return 1; }
            chmod 600 "${NODE_PARAMS_FILE}" 2>/dev/null || true
            log_info "restored node.params from ${snap}"
        fi
        log_info "restored units/geodata from ${snap}"
    fi
    return 0
}

# latest_snapshot: prints the newest snapshot dir (stdout), or nothing.
latest_snapshot() {
    snapshot_list | head -1
}
