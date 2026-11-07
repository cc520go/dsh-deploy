#!/usr/bin/env bash
#
# lib/perm.sh — permission migration + validation for DSH.
#
# The one layout the tool enforces (the official Xray-install layout, as
# audited on the live machine):
#   config dir   750  root:xray
#   config.json  640  root:xray
#   log dir      700  xray:xray
#   log files    600  xray:xray (files inside the log dir — a root-run
#                config test can create root-owned log files, and the
#                xray-user service then fails with exit 23 "permission
#                denied" on them; migrate must fix file ownership too,
#                not just the directory)
#   geodata      644  xray:xray (files; dir left as installed)
#   binary       755  root:root (a public binary; no secret in it)
#
# Why this exists: an install that previously ran as root leaves a
# root-only 600 config in a root-only 700 dir, and the official xray-user
# unit then fails to start with "permission denied" (exit status 23).
# Upgrade, downgrade and rollback MUST all run migrate_permissions()
# after swapping files and before the config test, or a rollback can
# silently leave the service unable to start.
#
# Test mode (XRAY_TEST_MODE=1): ownership changes are skipped (the test
# sandbox has no xray user) and validation checks modes only. Production
# always validates ownership too.

_PMLIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "${_PMLIB_DIR}/common.sh"

# migrate_permissions: tightens config/log/geodata to the official layout.
# Creates the config dir and log dir when missing. Never loosens anything.
migrate_permissions() {
    if [[ "${XRAY_TEST_MODE:-0}" != "1" ]]; then
        if ! id xray >/dev/null 2>&1; then
            die "service user 'xray' does not exist; run the official installer first (it creates the user)."
            return 1
        fi
    fi
    mkdir -p "${XRAY_CONF_DIR}" || { die "cannot create config dir: ${XRAY_CONF_DIR}"; return 1; }
    mkdir -p "${XRAY_LOG_DIR}" || { die "cannot create log dir: ${XRAY_LOG_DIR}"; return 1; }
    if [[ "${XRAY_TEST_MODE:-0}" != "1" ]]; then
        chown root:xray "${XRAY_CONF_DIR}" || { die "chown config dir failed"; return 1; }
        chown xray:xray "${XRAY_LOG_DIR}" || { die "chown log dir failed"; return 1; }
        find "${XRAY_LOG_DIR}" -type f -exec chown xray:xray {} + || { die "chown log files failed"; return 1; }
    fi
    chmod 750 "${XRAY_CONF_DIR}" || { die "chmod config dir failed"; return 1; }
    chmod 700 "${XRAY_LOG_DIR}" || { die "chmod log dir failed"; return 1; }
    find "${XRAY_LOG_DIR}" -type f -exec chmod 600 {} + || { die "chmod log files failed"; return 1; }
    if [[ -f "${XRAY_CONF}" ]]; then
        if [[ "${XRAY_TEST_MODE:-0}" != "1" ]]; then
            chown root:xray "${XRAY_CONF}" || { die "chown config failed"; return 1; }
        fi
        chmod 640 "${XRAY_CONF}" || { die "chmod config failed"; return 1; }
    fi
    if [[ -d "${XRAY_SHARE_DIR}" ]]; then
        if [[ "${XRAY_TEST_MODE:-0}" != "1" ]]; then
            chown xray:xray "${XRAY_SHARE_DIR}" 2>/dev/null || true
            find "${XRAY_SHARE_DIR}" -type f -exec chown xray:xray {} + 2>/dev/null || true
        fi
        find "${XRAY_SHARE_DIR}" -type f -exec chmod 644 {} + 2>/dev/null || true
    fi
    log_info "permissions migrated to official layout (conf 750 root:xray, config 640 root:xray, logs 700 xray:xray)."
    return 0
}

# validate_permissions: prints one PASS/FAIL line per check and returns 0
# only when every check passes. Read-only: it fixes nothing (use migrate).
validate_permissions() {
    local fail=0 mode owner other_readable
    if [[ -d "${XRAY_CONF_DIR}" ]]; then
        mode="$(stat -c '%a' "${XRAY_CONF_DIR}")"
        if [[ "${mode}" == "750" ]]; then
            printf '[PASS] config dir mode 750: %s\n' "${XRAY_CONF_DIR}"
        else
            printf '[FAIL] config dir mode is %s, expected 750: %s\n' "${mode}" "${XRAY_CONF_DIR}"
            fail=1
        fi
        if [[ "${XRAY_TEST_MODE:-0}" != "1" ]]; then
            owner="$(stat -c '%U:%G' "${XRAY_CONF_DIR}")"
            if [[ "${owner}" == "root:xray" ]]; then
                printf '[PASS] config dir owner root:xray\n'
            else
                printf '[FAIL] config dir owner is %s, expected root:xray\n' "${owner}"
                fail=1
            fi
        fi
        other_readable="$(find "${XRAY_CONF_DIR}" -type f -perm -o+r 2>/dev/null | head -5)"
        if [[ -z "${other_readable}" ]]; then
            printf '[PASS] no other-readable files under config dir\n'
        else
            printf '[FAIL] other-readable files under config dir:\n%s\n' "${other_readable}"
            fail=1
        fi
    else
        printf '[FAIL] config dir missing: %s\n' "${XRAY_CONF_DIR}"
        fail=1
    fi
    if [[ -f "${XRAY_CONF}" ]]; then
        mode="$(stat -c '%a' "${XRAY_CONF}")"
        if [[ "${mode}" == "640" ]]; then
            printf '[PASS] config file mode 640\n'
        else
            printf '[FAIL] config file mode is %s, expected 640\n' "${mode}"
            fail=1
        fi
        if [[ "${XRAY_TEST_MODE:-0}" != "1" ]]; then
            owner="$(stat -c '%U:%G' "${XRAY_CONF}")"
            if [[ "${owner}" == "root:xray" ]]; then
                printf '[PASS] config file owner root:xray\n'
            else
                printf '[FAIL] config file owner is %s, expected root:xray\n' "${owner}"
                fail=1
            fi
        fi
    else
        printf '[FAIL] config file missing: %s\n' "${XRAY_CONF}"
        fail=1
    fi
    if [[ -d "${XRAY_LOG_DIR}" ]]; then
        mode="$(stat -c '%a' "${XRAY_LOG_DIR}")"
        if [[ "${mode}" == "700" ]]; then
            printf '[PASS] log dir mode 700\n'
        else
            printf '[FAIL] log dir mode is %s, expected 700\n' "${mode}"
            fail=1
        fi
        if [[ "${XRAY_TEST_MODE:-0}" != "1" ]]; then
            owner="$(stat -c '%U:%G' "${XRAY_LOG_DIR}")"
            if [[ "${owner}" == "xray:xray" ]]; then
                printf '[PASS] log dir owner xray:xray\n'
            else
                printf '[FAIL] log dir owner is %s, expected xray:xray\n' "${owner}"
                fail=1
            fi
        fi
        local lf lmode lowner
        for lf in "${XRAY_LOG_DIR}"/*; do
            [[ -f "${lf}" ]] || continue
            lmode="$(stat -c '%a' "${lf}")"
            if [[ "${lmode}" == "600" ]]; then
                printf '[PASS] log file mode 600: %s\n' "${lf}"
            else
                printf '[FAIL] log file mode is %s, expected 600: %s\n' "${lmode}" "${lf}"
                fail=1
            fi
            if [[ "${XRAY_TEST_MODE:-0}" != "1" ]]; then
                lowner="$(stat -c '%U:%G' "${lf}")"
                if [[ "${lowner}" == "xray:xray" ]]; then
                    printf '[PASS] log file owner xray:xray: %s\n' "${lf}"
                else
                    printf '[FAIL] log file owner is %s, expected xray:xray: %s\n' "${lowner}" "${lf}"
                    fail=1
                fi
            fi
        done
    else
        printf '[WARN] log dir missing: %s (will be created on migrate)\n' "${XRAY_LOG_DIR}"
    fi
    return "${fail}"
}
