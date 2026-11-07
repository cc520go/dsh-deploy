#!/usr/bin/env bash
#
# diagnose.sh — read-only diagnostics for DSH.
#
# Checks: core presence + version, service state + autostart, config
# existence + test, permission audit, port listening (+ owner), recent
# error logs, IPv4/IPv6, DNS, routing, packet loss, firewall, and
# failure causes. An optional loopback Reality test is available only
# with `diagnose.sh --loopback` (see loopback_reality_test below).
# It is read-only for the server: it builds a temporary client config
# from the root-only params file, runs it, deletes it, and never prints
# any secret and never changes the server config.
# Exception, only on explicit confirmation: when any check FAILs, the
# script offers a one-click restore to the latest snapshot
# (diagnose_restore_offer below). Nothing is restored automatically,
# and without a snapshot it only says so. The restore itself reuses
# rollback_core (snapshot, migrate, config test, restart).
#
# Output: one [PASS]/[FAIL]/[WARN]/[SKIP] line per check, a summary, and
# a troubleshooting order. Exit code is 1 when any check FAILs, else 0.
#
# Read-only except the confirmed restore above: it never prints config
# content, uuids, keys, or share links. Log excerpts are limited to
# error lines.
#
# Test mode (XRAY_TEST_MODE=1): service/port checks use the canned values
# from lib/common.sh; network checks report SKIP (the sandbox has no
# reliable network). See tests/run_tests.sh.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/backup.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/perm.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/node.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/service.sh"

PASS=0
FAIL=0
WARN=0
SKIP=0

check_pass() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
check_fail() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }
check_warn() { WARN=$((WARN + 1)); printf '[WARN] %s\n' "$1"; }
check_skip() { SKIP=$((SKIP + 1)); printf '[SKIP] %s\n' "$1"; }

in_test_mode() { [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; }

# latest_error_log_file: current error.log if present, else the newest
# rotated error.log.1* file, else nothing. This is what keeps diagnose
# working after logrotate (copytruncate normally keeps error.log, but
# a rename-based rotation must not turn a healthy node into "no log").
latest_error_log_file() {
    if [[ -f "${XRAY_LOG_DIR}/error.log" ]]; then
        printf '%s' "${XRAY_LOG_DIR}/error.log"; return 0
    fi
    local f
    f="$(ls -t "${XRAY_LOG_DIR}"/error.log.1* 2>/dev/null | head -1 || true)"
    if [[ -n "${f}" ]]; then printf '%s' "${f}"; return 0; fi
    return 1
}

# loopback_flow_line <flow>: client-side flow fragment, or empty.
# Server params store "vision"/"none" (see lib/node.sh render_config
# and build_share_link, which use the same mapping). The Xray client
# only accepts "xtls-rprx-vision" as a flow value, or no flow field
# at all — writing the server-side value "vision" (or "none") verbatim
# makes the client config invalid, which is exactly the bug this
# helper exists to prevent. Unknown/empty values omit the field.
loopback_flow_line() {
    if [[ "${1:-}" == "vision" ]]; then
        printf ', "flow": "xtls-rprx-vision"'
    fi
}

# build_loopback_client_config <outfile> <uuid> <sni> <pub> <sid> <flow> <port>
# Writes the temporary loopback client config used by
# loopback_reality_test (600, no secrets printed). Extracted as its
# own function so tests can inspect the generated config directly
# instead of only mocking the probe result.
build_loopback_client_config() {
    local outfile="$1" uuid="$2" sni="$3" pub="$4" sid="$5" flow="$6" port="$7"
    local flow_line
    flow_line="$(loopback_flow_line "${flow}")"
    cat > "${outfile}" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"port": ${port}, "listen": "127.0.0.1", "protocol": "socks", "settings": {"udp": true}}],
  "outbounds": [{"protocol": "vless", "settings": {"vnext": [{"address": "127.0.0.1", "port": 443, "users": [{"id": "${uuid}", "encryption": "none"${flow_line}}]}]}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"show": false, "fingerprint": "chrome", "serverName": "${sni}", "publicKey": "${pub}", "shortId": "${sid}"}}}]
}
EOF
    chmod 600 "${outfile}" || true
}

# loopback_reality_test: opt-in end-to-end probe, server read-only.
# Returns 0 = pass, 1 = fail, 2 = skip. In test mode ONLY
# (XRAY_TEST_MODE=1) the result is driven by XRAY_TEST_LOOPBACK_RESULT
# (pass|fail|skip) so tests never touch the network; in production a
# set XRAY_TEST_LOOPBACK_RESULT is ignored (with a stderr warning).
# In production it needs node params, the xray
# binary, and curl; it writes a temporary client config (600, mktemp
# dir, deleted on return), runs xray as a local socks client, fetches
# one URL through it, then kills the client. Secrets are never printed.
loopback_reality_test() {
    local lb_override
    if lb_override="$(test_override XRAY_TEST_LOOPBACK_RESULT)"; then
        case "${lb_override}" in
            pass) printf 'loopback Reality test passed (test mode)\n'; return 0 ;;
            fail) printf 'loopback Reality test FAILED (test mode)\n'; return 1 ;;
            skip) printf 'loopback Reality test skipped (test mode)\n'; return 2 ;;
        esac
    fi
    local uuid sni pub sid flow port tmpdir tmpconf pid
    uuid="$(read_node_param uuid)"; sni="$(read_node_param sni)"
    pub="$(read_node_param public_key)"; sid="$(read_node_param shortid)"
    flow="$(read_node_param flow)"
    if [[ -z "${uuid}" || -z "${sni}" || -z "${pub}" || -z "${sid}" ]]; then
        printf 'loopback Reality test skipped (node params incomplete)\n'; return 2
    fi
    if [[ ! -x "${XRAY_BIN}" ]]; then
        printf 'loopback Reality test skipped (core binary missing)\n'; return 2
    fi
    if ! command -v curl >/dev/null 2>&1; then
        printf 'loopback Reality test skipped (curl not available)\n'; return 2
    fi
    tmpdir="$(mktemp -d)" || { printf 'loopback Reality test skipped (cannot create temp dir)\n'; return 2; }
    tmpconf="${tmpdir}/client.json"
    port=$((20000 + RANDOM % 20000))
    build_loopback_client_config "${tmpconf}" "${uuid}" "${sni}" "${pub}" "${sid}" "${flow}" "${port}"
    "${XRAY_BIN}" run -config "${tmpconf}" >/dev/null 2>&1 &
    pid=$!
    # Wait up to ~5s for the local socks listener, then probe once.
    local i ok=1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if (echo > "/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then ok=0; break; fi
        sleep 0.5
    done
    if [[ "${ok}" -eq 0 ]]; then
        if curl -fsSL --socks5-hostname "127.0.0.1:${port}" --max-time 10 "https://example.com" -o /dev/null 2>/dev/null; then
            kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true
            rm -rf -- "${tmpdir}"
            printf 'loopback Reality test passed (local client -> 127.0.0.1:443 -> internet)\n'; return 0
        fi
    fi
    kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true
    rm -rf -- "${tmpdir}"
    printf 'loopback Reality test FAILED (local client could not complete a request through 127.0.0.1:443; server config itself is unchanged)\n'; return 1
}

# diagnose_restore_offer: called only when main() saw a FAIL.
# Prints the latest snapshot (name, version, created time from
# meta.txt) and offers a one-click restore. It NEVER restores
# automatically: in test mode it restores only when
# XRAY_TEST_DIAG_RESTORE=1; in production it restores only when stdin
# is a terminal and the user confirms (rollback_core asks again, so
# the user confirms the snapshot explicitly). In non-interactive runs
# it only prints the restore command, so piping diagnose output can
# never trigger a restore. After a restore it re-runs the config test
# and reports the result, but it does not change main()'s exit code:
# the original FAIL is still reported, and the operator should re-run
# diagnostics to verify all checks.
diagnose_restore_offer() {
    local snap snap_ver snap_time
    snap="$(latest_snapshot)"
    if [[ -z "${snap}" || ! -d "${snap}" ]]; then
        printf 'Restore option: no snapshot available to restore (no xray-backup-* snapshot found).\n'
        return 1
    fi
    snap_ver="$(grep '^version=' "${snap}/meta.txt" 2>/dev/null | cut -d'=' -f2)"
    snap_time="$(grep '^created=' "${snap}/meta.txt" 2>/dev/null | cut -d'=' -f2)"
    printf 'Restore option: latest snapshot: %s (version %s, created %s)\n' "${snap}" "${snap_ver:-unknown}" "${snap_time:-unknown}"
    printf 'Restore option: to restore to this snapshot, run: DSH restore %s  (or menu 6 restore)\n' "${snap}"
    if [[ "${XRAY_TEST_MODE:-0}" == "1" ]]; then
        if [[ "${XRAY_TEST_DIAG_RESTORE:-0}" != "1" ]]; then
            printf 'Restore option: test mode, restore not performed automatically (set XRAY_TEST_DIAG_RESTORE=1 to exercise it).\n'
            return 0
        fi
        # Test mode with the flag: rollback_core auto-confirms.
        if rollback_core "${snap}"; then
            if config_test "${XRAY_CONF}" >/dev/null 2>&1; then
                printf 'Restore result: config test OK after restore to %s.\n' "${snap}"
            else
                printf 'Restore result: config test FAILED after restore to %s; check the snapshot and re-run diagnostics.\n' "${snap}"
            fi
            return 0
        fi
        printf 'Restore result: restore to %s FAILED.\n' "${snap}"
        return 1
    fi
    if [[ ! -t 0 ]]; then
        printf 'Restore option: non-interactive run, restore not performed; re-run interactively to confirm.\n'
        return 0
    fi
    # Interactive: rollback_core itself asks for confirmation (with
    # the snapshot path and version in its impact statement), so the
    # user confirms explicitly before anything changes.
    if rollback_core "${snap}"; then
        if config_test "${XRAY_CONF}" >/dev/null 2>&1; then
            printf 'Restore result: config test OK after restore to %s.\n' "${snap}"
        else
            printf 'Restore result: config test FAILED after restore to %s; check the snapshot and re-run diagnostics.\n' "${snap}"
        fi
        return 0
    fi
    printf 'Restore result: restore to %s FAILED or cancelled.\n' "${snap}"
    return 1
}

main() {
    local loopback=0
    if [[ "${1:-}" == "--loopback" || "${1:-}" == "loopback" ]]; then loopback=1; fi
    printf 'DSH diagnostics\n'
    printf '================================\n'

    # 1. Core presence + version.
    if [[ -x "${XRAY_BIN}" ]]; then
        local ver
        ver="$(current_version)"
        if [[ "${ver}" == "unknown" ]]; then
            check_warn "core binary present but version unreadable: ${XRAY_BIN}"
        else
            check_pass "core present: ${ver} (default $(default_version))"
        fi
    else
        check_fail "core binary missing: ${XRAY_BIN}"
    fi

    # 2. Service state + autostart.
    local state enabled
    state="$(service_state)"
    enabled="$(service_enabled)"
    if [[ "${state}" == "active" ]]; then
        check_pass "service active"
    else
        check_fail "service not active (state: ${state})"
    fi
    if [[ "${enabled}" == "enabled" ]]; then
        check_pass "service autostart enabled"
    else
        check_warn "service autostart is ${enabled} (expected enabled)"
    fi

    # 3. Config existence + test.
    if [[ -f "${XRAY_CONF}" ]]; then
        if config_test "${XRAY_CONF}" >/dev/null 2>&1; then
            check_pass "config test passed: ${XRAY_CONF}"
        else
            check_fail "config test FAILED: ${XRAY_CONF}"
        fi
    else
        check_fail "config file missing: ${XRAY_CONF}"
    fi

    # 4. Permission audit (read-only report; migrate fixes, diagnose does not).
    local perms_tmp
    perms_tmp="$(mktemp)"
    if validate_permissions > "${perms_tmp}" 2>&1; then
        check_pass "permission audit passed (official layout)"
    else
        check_fail "permission audit failed (run the migrate step from install/manage to fix)"
    fi
    cat "${perms_tmp}" 2>/dev/null || true
    rm -f "${perms_tmp}"

    # 5. Port listening (443) + owner.
    if in_test_mode; then
        local ports
        ports="$(listen_ports)"
        case " ${ports} " in
            *" 443 "*) check_pass "port 443 listening (test-mode ports: ${ports})" ;;
            *) check_fail "port 443 NOT listening (test-mode ports: ${ports})" ;;
        esac
        check_skip "port owner check (test mode)"
    elif command -v ss >/dev/null 2>&1; then
        local line443
        line443="$(ss -tlnp 2>/dev/null | grep -E ':(443)[[:space:]]' | head -1)"
        if [[ -z "${line443}" ]]; then
            check_fail "port 443 NOT listening"
        elif printf '%s' "${line443}" | grep -q 'xray'; then
            check_pass "port 443 listening (process: xray)"
        else
            check_warn "port 443 listening but owner is not xray: ${line443}"
        fi
    else
        check_skip "ss not found; port check unavailable"
    fi

    # 6. Recent error logs (context for failures; WARN, not FAIL, on errors).
    # After log rotation, error.log may be rotated away; the helper above
    # finds the newest rotated file so this check does not go missing.
    if in_test_mode; then
        check_skip "recent error logs (test mode)"
    elif command -v journalctl >/dev/null 2>&1; then
        local errs
        errs="$(journalctl -u xray --no-pager -p err --since '1 hour ago' 2>/dev/null | grep -vcE '^(-- Logs|-- No)' || true)"
        if [[ "${errs}" -gt 0 ]]; then
            check_warn "recent error log lines in the last hour: ${errs} (see logs menu for details)"
        else
            check_pass "no error log lines in the last hour"
        fi
    elif latest_error_log_file >/dev/null 2>&1; then
        check_pass "error log present: $(latest_error_log_file)"
    else
        check_skip "no journalctl and no error log file"
    fi

    # 7. IPv4 / IPv6.
    if in_test_mode; then
        check_skip "IPv4/IPv6 presence (test mode)"
    elif command -v ip >/dev/null 2>&1; then
        if ip -4 addr show scope global 2>/dev/null | grep -q 'inet '; then
            check_pass "global IPv4 address present"
        else
            check_fail "no global IPv4 address"
        fi
        if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 '; then
            check_pass "global IPv6 address present"
        else
            check_warn "no global IPv6 address (IPv6-only targets will fail)"
        fi
    else
        check_skip "ip command not found; address checks unavailable"
    fi

    # 8. DNS.
    if in_test_mode; then
        check_skip "DNS resolution (test mode)"
    elif command -v getent >/dev/null 2>&1; then
        if getent hosts www.google.com >/dev/null 2>&1; then
            check_pass "DNS resolution works (www.google.com)"
        else
            check_fail "DNS resolution failed (www.google.com)"
        fi
    else
        check_skip "getent not found; DNS check unavailable"
    fi

    # 9. Routing (default route).
    if in_test_mode; then
        check_skip "default route (test mode)"
    elif command -v ip >/dev/null 2>&1; then
        if ip route show default 2>/dev/null | grep -q .; then
            check_pass "default route present"
        else
            check_fail "no default route"
        fi
    else
        check_skip "ip command not found; route check unavailable"
    fi

    # 10. Packet loss (best-effort; WARN on partial loss, FAIL on total).
    if in_test_mode; then
        check_skip "packet loss probe (test mode)"
    elif command -v ping >/dev/null 2>&1; then
        local loss
        loss="$(ping -c 3 -W 2 1.1.1.1 2>/dev/null | grep -oE '[0-9]+% packet loss' | grep -oE '[0-9]+' | head -1)"
        if [[ -z "${loss}" ]]; then
            check_warn "packet loss probe produced no result"
        elif [[ "${loss}" == "0" ]]; then
            check_pass "packet loss 0% to 1.1.1.1"
        elif [[ "${loss}" == "100" ]]; then
            check_fail "packet loss 100% to 1.1.1.1"
        else
            check_warn "packet loss ${loss}% to 1.1.1.1"
        fi
    else
        check_skip "ping not found; loss probe unavailable"
    fi

    # 11. Firewall (read-only, never auto-opens anything).
    local fw_out fw_rc
    fw_out="$(firewall_status 2>&1)"; fw_rc=$?
    case "${fw_rc}" in
        0) check_pass "${fw_out}" ;;
        2) check_warn "${fw_out}" ;;
        3) check_skip "${fw_out}" ;;
        *) check_warn "${fw_out}" ;;
    esac

    # 12. Loopback Reality test (OPT-IN ONLY).
    if [[ "${loopback}" -eq 0 ]]; then
        check_skip "loopback Reality test skipped (run: diag --loopback; read-only, temporary client config, never changes server config). 默认诊断不证明 Reality 握手能通，改过节点参数后请跑 diag --loopback (default diagnostics do not prove the Reality handshake; after changing node parameters, run diag --loopback)"
    else
        local lb_out lb_rc
        lb_out="$(loopback_reality_test 2>&1)"; lb_rc=$?
        case "${lb_rc}" in
            0) check_pass "${lb_out}" ;;
            2) check_skip "${lb_out}" ;;
            *) check_fail "${lb_out}" ;;
        esac
    fi

    # Failure context: when the service is down, show recent log lines.
    if [[ "${state}" != "active" ]]; then
        printf 'Failure context (recent service log):\n'
        if command -v journalctl >/dev/null 2>&1; then
            journalctl -u xray --no-pager -n 20 2>&1 | tail -20 || true
        elif [[ -f "${XRAY_LOG_DIR}/error.log" ]]; then
            tail -20 "${XRAY_LOG_DIR}/error.log" || true
        else
            printf '(no journalctl and no error log file available)\n'
        fi
    fi

    printf '================================\n'
    printf 'Summary: %s PASS, %s FAIL, %s WARN, %s SKIP\n' "${PASS}" "${FAIL}" "${WARN}" "${SKIP}"
    printf 'Troubleshooting order: service state -> config test -> permissions -> ports -> DNS/route/loss.\n'
    if [[ "${loopback}" -eq 0 ]]; then
        printf 'Note: 默认诊断不证明 Reality 握手能通，改过节点参数后请跑 diag --loopback.\n'
    fi
    if [[ "${FAIL}" -gt 0 ]]; then
        printf 'Result: FAIL — fix the failed checks above, then re-run diagnostics.\n'
        diagnose_restore_offer || true
        return 1
    fi
    printf 'Result: OK.\n'
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
    exit $?
fi
