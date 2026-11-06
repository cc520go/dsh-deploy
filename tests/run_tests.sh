#!/usr/bin/env bash
#
# tests/run_tests.sh — test-environment validation for xray-reality-manager.
#
# Runs entirely in a temp sandbox with a fake xray binary, fake installer
# stub, and test-mode service helpers. NEVER touches the live VPS, real
# system paths, or real credentials. All node parameters used here are
# obvious placeholders (PLACEHOLDER-*), never real secrets.
#
# Usage: bash tests/run_tests.sh
# Exit code: 0 when every test passes, 1 otherwise.

TESTS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(dirname "${TESTS_DIR}")"

SANDBOX="$(mktemp -d)"
trap 'rm -rf -- "${SANDBOX}"' EXIT

# ---- hermetic environment (must be exported BEFORE sourcing libs) ----
export XRAY_TEST_MODE=1
export XRAY_TEST_AUTO_CONFIRM=1
export XRAY_TEST_SERVICE_STATE=inactive
export XRAY_TEST_SERVICE_ENABLED=disabled
export XRAY_TEST_LISTEN_PORTS=""
export XRAY_TEST_LOG="${SANDBOX}/systemctl.log"
export XRAY_BIN="${SANDBOX}/bin/xray"
export XRAY_CONF_DIR="${SANDBOX}/etc/xray"
export XRAY_CONF="${SANDBOX}/etc/xray/config.json"
export XRAY_SHARE_DIR="${SANDBOX}/share/xray"
export XRAY_LOG_DIR="${SANDBOX}/log/xray"
export XRAY_UNIT_DIR="${SANDBOX}/units"
export SNAPSHOT_PARENT="${SANDBOX}/backups"
export NODE_PARAMS_FILE="${SANDBOX}/node.params"
export LAUNCHER_DIR="${SANDBOX}/launchers"
export TOOL_INSTALL_DIR="${SANDBOX}/tool"
# Sandbox isolation for log rotation: every install-path test must
# write its logrotate config here, never to the real /etc/logrotate.d.
# This global default is the backstop; install-path tests also set it
# explicitly so a forgotten assignment cannot leak to the real system.
export LOGROTATE_DIR="${SANDBOX}/logrotate.d"
mkdir -p "${SANDBOX}/bin" "${XRAY_CONF_DIR}" "${XRAY_SHARE_DIR}" \
    "${XRAY_LOG_DIR}" "${XRAY_UNIT_DIR}" "${SNAPSHOT_PARENT}" "${LAUNCHER_DIR}" \
    "${LOGROTATE_DIR}"
# Snapshot of the real logrotate file at suite start, for the
# isolation guard test at the end: if it was absent it must stay
# absent; if it was present its content must be unchanged. This
# distinguishes a test leak from a legitimate formal install, which
# happens only after the test suite has finished.
REAL_LOGROTATE_FILE="/etc/logrotate.d/xray-reality-manager"
if [[ -f "${REAL_LOGROTATE_FILE}" ]]; then
    TEST_START_LOGROTATE_HASH="$(sha256sum "${REAL_LOGROTATE_FILE}" | cut -d' ' -f1)"
else
    TEST_START_LOGROTATE_HASH="absent"
fi

# ---- fake xray binary (version embedded in the script; the fake
# installer stub rewrites the FAKE_VERSION line, so snapshots restore the
# version correctly without any sidecar file) ----
cat > "${XRAY_BIN}" <<'FAKEEOF'
#!/usr/bin/env bash
FAKE_VERSION="26.3.27"
if [[ "$1" == "version" ]]; then
  echo "Xray ${FAKE_VERSION} (Xray, Penetrates Everything.) fake (go1.27.3 linux/amd64)"
  exit 0
fi
if [[ "$1" == "run" && "$2" == "-test" ]]; then
  cfg="${@: -1}"
  if [[ -f "${cfg}" ]] && grep -q '"inbounds"' "${cfg}"; then
    # Mimic Xray: Reality dest must be host:port (a bare domain fails).
    if grep -q '"dest":' "${cfg}"; then
      dval="$(sed -n 's/.*"dest": "\([^"]*\)".*/\1/p' "${cfg}" | head -1)"
      case "${dval}" in
        *:* ) ;;
        * ) echo "Configuration failed (dest must include a port)."; exit 1 ;;
      esac
    fi
    echo "Configuration OK."
    exit 0
  fi
  echo "Configuration failed."
  exit 1
fi
if [[ "$1" == "x25519" ]]; then
  echo "PrivateKey: TEST-PRIVATE-KEY-AAAA"
  echo "Password (PublicKey): TEST-PUBLIC-KEY-AAAA"
  echo "Hash32: TEST-HASH32-AAAA"
  exit 0
fi
echo "fake xray: unknown args: $*" >&2
exit 1
FAKEEOF
chmod 755 "${XRAY_BIN}"
cp -a "${XRAY_BIN}" "${SANDBOX}/fake-new-bin"
export FAKE_NEW_BIN="${SANDBOX}/fake-new-bin"

# ---- fake official installer stub ----
cat > "${SANDBOX}/fake-installer.sh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$1" == "install" && "$2" == "--local" ]]; then
  sed "s/^FAKE_VERSION=.*/FAKE_VERSION=\"${FAKE_TARGET_VERSION}\"/" "${FAKE_NEW_BIN}" > "${XRAY_BIN}" || exit 1
  chmod 755 "${XRAY_BIN}"
  mkdir -p "${XRAY_UNIT_DIR}"
  echo "# fake xray.service" > "${XRAY_UNIT_DIR}/xray.service"
  echo "# fake xray@.service" > "${XRAY_UNIT_DIR}/xray@.service"
  exit 0
fi
exit 1
STUBEOF
chmod 755 "${SANDBOX}/fake-installer.sh"

# ---- Debian 12 env-check fixture (sandbox, before sourcing install.sh) ----
# env_check targets Debian 12 only, but the suite host itself may be
# Ubuntu, so the suite must not read the host's /etc/os-release here.
# Production behaviour is unchanged: ENV_OS_RELEASE defaults to
# /etc/os-release when this variable is not set.
export ENV_OS_RELEASE="${SANDBOX}/env-os-release"
printf 'ID=debian\nVERSION_ID="12"\n' > "${ENV_OS_RELEASE}"
export BBR_MODULE_VERSION_FILE="${SANDBOX}/tcp_bbr_version"
printf '3' > "${BBR_MODULE_VERSION_FILE}"

# ---- BBR test paths (sandbox, before sourcing lib/bbr.sh) ----
export BBR_SYSCTL_FILE="${SANDBOX}/bbr-sysctl.conf"
export BBR_BACKUP_DIR="${SANDBOX}/bbr-backups"
export BBR_OS_RELEASE="${SANDBOX}/os-release"
export BBR_GRUB_CFG="${SANDBOX}/grub.cfg"
export BBR_ONESHOT_UNIT="${SANDBOX}/lisa-bbr3-oneshot.service"
export BBR_ONESHOT_RESULT="${SANDBOX}/bbr-oneshot-result.log"
export FAKE_SYSCTL_STATE="${SANDBOX}/fake-sysctl-state"
export FAKE_TC_STATE="${SANDBOX}/fake-tc-state"
export FAKE_DPKG_MARKER="${SANDBOX}/fake-dpkg-marker"
mkdir -p "${SANDBOX}/bbr-fakes"
# Fake sysctl (state file: congestion= / qdisc= lines).
cat > "${SANDBOX}/bbr-fakes/sysctl" <<'FAKEEOF'
#!/usr/bin/env bash
state="${FAKE_SYSCTL_STATE:-/tmp/fake-sysctl-state}"
if [[ "$1" == "-n" ]]; then
  case "$2" in
    net.ipv4.tcp_congestion_control) grep '^congestion=' "${state}" 2>/dev/null | cut -d= -f2 ;;
    net.core.default_qdisc) grep '^qdisc=' "${state}" 2>/dev/null | cut -d= -f2 ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [[ "$1" == "-w" ]]; then
  case "$2" in
    net.ipv4.tcp_congestion_control=*) sed -i "s/^congestion=.*/congestion=${2#*=}/" "${state}" ;;
    net.core.default_qdisc=*) sed -i "s/^qdisc=.*/qdisc=${2#*=}/" "${state}" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [[ "$1" == "--system" ]]; then
  if [[ -f "${BBR_SYSCTL_FILE:-}" ]]; then
    c="$(grep '^net.ipv4.tcp_congestion_control=' "${BBR_SYSCTL_FILE}" | cut -d= -f2)"
    q="$(grep '^net.core.default_qdisc=' "${BBR_SYSCTL_FILE}" | cut -d= -f2)"
    [[ -n "${c}" ]] && sed -i "s/^congestion=.*/congestion=${c}/" "${state}"
    [[ -n "${q}" ]] && sed -i "s/^qdisc=.*/qdisc=${q}/" "${state}"
  else
    sed -i "s/^congestion=.*/congestion=cubic/" "${state}"
    sed -i "s/^qdisc=.*/qdisc=fq_codel/" "${state}"
  fi
  exit 0
fi
exit 1
FAKEEOF
# Fake tc (state file holds the root qdisc name).
cat > "${SANDBOX}/bbr-fakes/tc" <<'FAKEEOF'
#!/usr/bin/env bash
state="${FAKE_TC_STATE:-/tmp/fake-tc-state}"
if [[ "$1" == "qdisc" && "$2" == "show" ]]; then
  printf 'qdisc %s 0: root refcnt 2\n' "$(cat "${state}" 2>/dev/null || printf 'fq_codel')"
  exit 0
fi
if [[ "$1" == "qdisc" && "$2" == "replace" ]]; then
  if [[ "${FAKE_TC_FAIL:-0}" == "1" ]]; then exit 1; fi
  printf '%s\n' "${@: -1}" > "${state}"
  exit 0
fi
exit 1
FAKEEOF
# Fake ip (default route only).
cat > "${SANDBOX}/bbr-fakes/ip" <<'FAKEEOF'
#!/usr/bin/env bash
if [[ "$1" == "route" ]]; then
  printf 'default via 203.0.113.1 dev eth0 proto static\n'
  exit 0
fi
exit 1
FAKEEOF
# Fake uname (-r / -m only; BBR code never calls it otherwise).
cat > "${SANDBOX}/bbr-fakes/uname" <<'FAKEEOF'
#!/usr/bin/env bash
if [[ "$1" == "-r" ]]; then printf '%s\n' "${FAKE_UNAME_R:-6.1.0-18-amd64}"; exit 0; fi
if [[ "$1" == "-m" ]]; then printf 'x86_64\n'; exit 0; fi
exit 1
FAKEEOF
# Fake modinfo (tcp_bbr version only).
cat > "${SANDBOX}/bbr-fakes/modinfo" <<'FAKEEOF'
#!/usr/bin/env bash
if [[ "${FAKE_MODINFO_FAIL:-0}" == "1" ]]; then exit 1; fi
printf 'version: %s\n' "${FAKE_BBR_VERSION:-1}"
exit 0
FAKEEOF
# Fake dpkg (marker file = joeyblog installed).
cat > "${SANDBOX}/bbr-fakes/dpkg" <<'FAKEEOF'
#!/usr/bin/env bash
marker="${FAKE_DPKG_MARKER:-/tmp/fake-dpkg-marker}"
if [[ "$1" == "-l" ]]; then
  if [[ -f "${marker}" ]]; then printf 'ii  linux-image-7.0.11-joeyblog  7.0.11  amd64  fake\n'; fi
  exit 0
fi
if [[ "$1" == "-i" ]]; then
  if [[ "${FAKE_DPKG_FAIL:-0}" == "1" ]]; then exit 1; fi
  touch "${marker}"
  exit 0
fi
if [[ "$1" == "-r" || "$1" == "--remove" ]]; then
  rm -f "${marker}"
  exit 0
fi
exit 1
FAKEEOF
# Fake update-grub (appends the new version to the sandbox grub cfg).
cat > "${SANDBOX}/bbr-fakes/update-grub" <<'FAKEEOF'
#!/usr/bin/env bash
if [[ "${FAKE_UPDATE_GRUB_FAIL:-0}" == "1" ]]; then exit 1; fi
printf 'menuentry "Debian GNU/Linux, with Linux %s" {}\n' "${FAKE_GRUB_VERSION:-7.0.11}" >> "${BBR_GRUB_CFG:-/tmp/fake-grub.cfg}"
exit 0
FAKEEOF
# Fake systemd-detect-virt (not Hyper-V in tests).
cat > "${SANDBOX}/bbr-fakes/systemd-detect-virt" <<'FAKEEOF'
#!/usr/bin/env bash
printf 'kvm\n'
exit 0
FAKEEOF
chmod 755 "${SANDBOX}/bbr-fakes/"*
export PATH="${SANDBOX}/bbr-fakes:${PATH}"

# ---- source libs under test ----
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/download.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/backup.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/perm.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/node.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/service.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/bbr.sh"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# run_test <name>: runs the test function in a subshell (env changes do
# not leak between tests) and counts the result. A test that returns
# 77 is a SKIP (tool genuinely missing, not a failure); skips are
# reported separately and are never counted as passes.
run_test() {
    local name="$1" rc
    ( "$name" ); rc=$?
    if [[ "${rc}" -eq 77 ]]; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        printf 'SKIP: %s\n' "${name}"
    elif [[ "${rc}" -eq 0 ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf 'PASS: %s\n' "${name}"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAIL: %s\n' "${name}"
    fi
}

# expect_fail <command...>: succeeds only when the command FAILS.
expect_fail() {
    if "$@" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# ------------------------------------------------------------ tests ----
t_version() {
    [[ "$(normalize_version "v26.10.21")" == "26.10.21" ]] || return 1
    [[ "$(normalize_version "26.10.21")" == "26.10.21" ]] || return 1
    expect_fail normalize_version "26.10" || return 1
    expect_fail normalize_version "abc" || return 1
    [[ "$(version_cmp "26.10.21" "26.3.27")" == "1" ]] || return 1
    [[ "$(version_cmp "26.10.21" "26.10.21")" == "0" ]] || return 1
    [[ "$(version_cmp "26.3.27" "26.10.21")" == "-1" ]] || return 1
    return 0
}

t_dgst() {
    local d="${SANDBOX}/dgst"
    local f="${d}/file.bin"
    local dg="${d}/file.bin.dgst"
    mkdir -p "${d}"
    printf 'test-content-123' > "${f}"
    {
        printf 'MD5 = %s\n' "$(md5sum "${f}" | cut -d' ' -f1)"
        printf 'SHA1 = %s\n' "$(sha1sum "${f}" | cut -d' ' -f1)"
        printf 'SHA256 = %s\n' "$(sha256sum "${f}" | cut -d' ' -f1)"
        printf 'SHA512 = %s\n' "$(sha512sum "${f}" | cut -d' ' -f1)"
    } > "${dg}"
    verify_dgst "${f}" "${dg}" || return 1
    # Colon spelling is also accepted (official-format tolerance).
    sed 's/ = /: /g' "${dg}" > "${dg}.colon"
    verify_dgst "${f}" "${dg}.colon" || return 1
    # Current official format (real 26.10.21 asset): hyphenated labels
    # with "=" directly after the label ("SHA2-256= <hex>").
    {
        printf 'MD5= %s\n' "$(md5sum "${f}" | cut -d' ' -f1)"
        printf 'SHA1= %s\n' "$(sha1sum "${f}" | cut -d' ' -f1)"
        printf 'SHA2-256= %s\n' "$(sha256sum "${f}" | cut -d' ' -f1)"
        printf 'SHA2-512= %s\n' "$(sha512sum "${f}" | cut -d' ' -f1)"
    } > "${dg}.real"
    verify_dgst "${f}" "${dg}.real" || return 1
    # A missing SHA2-256 line must fail (the hyphenated label is really checked).
    grep -v '^SHA2-256' "${dg}.real" > "${dg}.real.nos256"
    expect_fail verify_dgst "${f}" "${dg}.real.nos256" || return 1
    # Tampered content must fail.
    printf 'tampered' > "${f}"
    expect_fail verify_dgst "${f}" "${dg}" || return 1
    printf 'test-content-123' > "${f}"
    # Missing digest line must fail.
    grep -v '^SHA512' "${dg}" > "${dg}.nol512"
    expect_fail verify_dgst "${f}" "${dg}.nol512" || return 1
    # Missing .dgst file must fail (never warn-and-continue).
    expect_fail verify_dgst "${f}" "${d}/missing.dgst" || return 1
    return 0
}

t_node_auto() {
    # --auto node setup asks nothing: with stdin closed, any prompt for
    # the host would fail, so success proves the non-interactive path.
    source "${REPO_ROOT}/install.sh"
    export XRAY_NODE_HOST="203.0.113.1"
    AUTO_INSTALL=1
    node_setup </dev/null || return 1
    grep -q '^host=203.0.113.1$' "${NODE_PARAMS_FILE}" || return 1
    grep -q '^port=443$' "${NODE_PARAMS_FILE}" || return 1
    grep -q '^sni=www.apple.com$' "${NODE_PARAMS_FILE}" || return 1
    grep -q '^dest=www.apple.com:443$' "${NODE_PARAMS_FILE}" || return 1
    grep -q '"dest": "www.apple.com:443"' "${XRAY_CONF}" || return 1
    grep -q '^flow=vision$' "${NODE_PARAMS_FILE}" || return 1
    grep -q '"inbounds"' "${XRAY_CONF}" || return 1
    return 0
}

t_node_sni() {
    # Setup: a node with an old SNI (placeholders only, never real keys).
    source "${REPO_ROOT}/manage.sh"
    local uuid="11111111-2222-4333-8444-555555555555" priv="TESTPRIVKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" pub="TESTPUBKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" sid="aabbccdd"
    render_config "${uuid}" "${sid}" "${priv}" "old.example.com" "443" "vision" "www.apple.com:443" "${XRAY_CONF}" || return 1
    write_node_params "${uuid}" "${priv}" "${pub}" "${sid}" "203.0.113.9" "443" "old.example.com" "www.apple.com:443" "vision" || return 1
    # Set to a new domain (auto-confirm in test mode).
    node_set_sni "new.example.com" || return 1
    [[ "$(read_node_param sni)" == "new.example.com" ]] || return 1
    grep -q '"new.example.com"' "${XRAY_CONF}" || return 1
    grep -q '"old.example.com"' "${XRAY_CONF}" && return 1
    [[ "$(read_node_param uuid)" == "${uuid}" ]] || return 1
    [[ "$(read_node_param host)" == "203.0.113.9" ]] || return 1
    [[ "$(read_node_param dest)" == "www.apple.com:443" ]] || return 1
    # IP SNI must fail and leave config + params unchanged.
    expect_fail node_set_sni "203.0.113.10" || return 1
    [[ "$(read_node_param sni)" == "new.example.com" ]] || return 1
    grep -q '"new.example.com"' "${XRAY_CONF}" || return 1
    # Empty input defaults to www.apple.com.
    printf '\n' | node_set_sni || return 1
    [[ "$(read_node_param sni)" == "www.apple.com" ]] || return 1
    grep -q '"www.apple.com"' "${XRAY_CONF}" || return 1
    return 0
}

t_archive_xray() {
    # Regression: the old `(^|/)xray$` pattern missed top-level entries
    # (unzip -l puts length/date/time columns before the name), so it
    # rejected real release zips. Official layout: top-level xray.
    # Tool-aware: the fixture is built with zip, but production
    # archive checking uses unzip -l only, so a missing zip is a
    # SKIP (test cannot build its fixture), never a production FAIL.
    if ! command -v zip >/dev/null 2>&1; then
        printf 't_archive_xray: zip not installed, skipping fixture build (production uses unzip -l)\n' >&2
        return 77
    fi
    local d="${SANDBOX}/zips"
    mkdir -p "${d}/top" "${d}/nested/bin" "${d}/none" "${d}/fake"
    printf 'x' > "${d}/top/xray"
    printf 'x' > "${d}/top/geosite.dat"
    printf 'x' > "${d}/top/geoip.dat"
    (cd "${d}/top" && zip -q "${d}/top.zip" xray geosite.dat geoip.dat) || return 1
    archive_has_xray "${d}/top.zip" || return 1
    printf 'x' > "${d}/nested/bin/xray"
    (cd "${d}/nested" && zip -q "${d}/nested.zip" bin/xray) || return 1
    archive_has_xray "${d}/nested.zip" || return 1
    printf 'x' > "${d}/none/geosite.dat"
    printf 'x' > "${d}/none/geoip.dat"
    (cd "${d}/none" && zip -q "${d}/none.zip" geosite.dat geoip.dat) || return 1
    expect_fail archive_has_xray "${d}/none.zip" || return 1
    printf 'x' > "${d}/fake/notxray"
    printf 'x' > "${d}/fake/xray2"
    (cd "${d}/fake" && zip -q "${d}/fake.zip" notxray xray2) || return 1
    expect_fail archive_has_xray "${d}/fake.zip" || return 1
    return 0
}

t_keypair_formats() {
    # gen_keypair must parse both the new format (PrivateKey /
    # Password (PublicKey), no spaces, verified on real 26.10.21) and
    # the old spaced format (Private key / Public key).
    local d="${SANDBOX}/keypairs" save_bin="${XRAY_BIN}" out
    mkdir -p "${d}"
    cat > "${d}/xray-new" <<'EOF'
#!/usr/bin/env bash
echo "PrivateKey: NEW-PRIV-AAAA"
echo "Password (PublicKey): NEW-PUB-AAAA"
echo "Hash32: NEW-HASH-AAAA"
EOF
    cat > "${d}/xray-old" <<'EOF'
#!/usr/bin/env bash
echo "Private key: OLD-PRIV-AAAA"
echo "Public key: OLD-PUB-AAAA"
EOF
    chmod 755 "${d}/xray-new" "${d}/xray-old"
    XRAY_BIN="${d}/xray-new"
    out="$(gen_keypair)" || return 1
    [[ "${out}" == "NEW-PRIV-AAAA NEW-PUB-AAAA" ]] || return 1
    XRAY_BIN="${d}/xray-old"
    out="$(gen_keypair)" || return 1
    [[ "${out}" == "OLD-PRIV-AAAA OLD-PUB-AAAA" ]] || return 1
    XRAY_BIN="${save_bin}"
    return 0
}

t_env_check_debian12() {
    # Debian 12 pre-check (2026-11-02, main-chat confirmed scope):
    # Debian 12 passes; Debian 11 / Ubuntu fail; 443 occupied by a
    # non-xray service fails, occupied by an active xray passes;
    # BBR is report-only (effective / not effective never fails the
    # check). Network check is skipped in test mode by design, and
    # apt is never run in test mode. State touched here is restored
    # at the end so later tests (notably t_install_completion, which
    # relies on the leftover active service state) are unaffected.
    source "${REPO_ROOT}/install.sh"
    local ok=1 out
    local save_os="${ENV_OS_RELEASE}" save_ports="${XRAY_TEST_LISTEN_PORTS:-}" save_state="${XRAY_TEST_SERVICE_STATE:-inactive}"
    local save_sysctl="" save_sysctl_exists=0 save_modver=""
    if [[ -f "${FAKE_SYSCTL_STATE}" ]]; then save_sysctl_exists=1; save_sysctl="$(cat "${FAKE_SYSCTL_STATE}")"; fi
    if [[ -f "${BBR_MODULE_VERSION_FILE}" ]]; then save_modver="$(cat "${BBR_MODULE_VERSION_FILE}")"; fi
    local test_os="${SANDBOX}/env-test-os-release"
    printf 'ID=debian\nVERSION_ID="12"\n' > "${test_os}"
    export ENV_OS_RELEASE="${test_os}"
    export XRAY_TEST_LISTEN_PORTS="" XRAY_TEST_SERVICE_STATE=inactive
    printf 'congestion=bbr\nqdisc=fq\n' > "${FAKE_SYSCTL_STATE}"
    printf '3' > "${BBR_MODULE_VERSION_FILE}"
    out="$(env_check 2>&1)" || ok=0
    printf '%s' "${out}" | grep -q "BBRv3+FQ effective" || ok=0
    printf '%s' "${out}" | grep -q "port 443 free" || ok=0
    export XRAY_TEST_LISTEN_PORTS="443"
    if env_check >/dev/null 2>&1; then ok=0; fi
    export XRAY_TEST_SERVICE_STATE=active
    out="$(env_check 2>&1)" || ok=0
    printf '%s' "${out}" | grep -q "reinstall/upgrade path" || ok=0
    export XRAY_TEST_SERVICE_STATE=inactive XRAY_TEST_LISTEN_PORTS=""
    printf 'congestion=cubic\nqdisc=fq_codel\n' > "${FAKE_SYSCTL_STATE}"
    printf '1' > "${BBR_MODULE_VERSION_FILE}"
    out="$(env_check 2>&1)" || ok=0
    printf '%s' "${out}" | grep -q "BBRv3+FQ not effective" || ok=0
    printf 'ID=debian\nVERSION_ID="11"\n' > "${test_os}"
    if env_check >/dev/null 2>&1; then ok=0; fi
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "${test_os}"
    if env_check >/dev/null 2>&1; then ok=0; fi
    # Restore.
    export ENV_OS_RELEASE="${save_os}" XRAY_TEST_LISTEN_PORTS="${save_ports}" XRAY_TEST_SERVICE_STATE="${save_state}"
    if [[ "${save_sysctl_exists}" -eq 1 ]]; then printf '%s' "${save_sysctl}" > "${FAKE_SYSCTL_STATE}"; else rm -f "${FAKE_SYSCTL_STATE}"; fi
    printf '%s' "${save_modver}" > "${BBR_MODULE_VERSION_FILE}"
    [[ "${ok}" -eq 1 ]]
}

t_install_completion() {
    # install.sh on an already-installed machine with the installer's
    # empty placeholder config ({}) must COMPLETE node setup, not
    # silently preserve the placeholder. Regression: the 26.10.21
    # partial install left a {} config and no node.
    # Sandbox isolation (explicit): this path calls main, which
    # installs the logrotate config; it must land in the sandbox.
    export LOGROTATE_DIR="${SANDBOX}/logrotate.d"
    mkdir -p "${LOGROTATE_DIR}"
    source "${REPO_ROOT}/install.sh"
    export XRAY_NODE_HOST="203.0.113.2"
    printf '{}' > "${XRAY_CONF}"
    # Partial-install completion now verifies listening after restart;
    # simulate a listening service in test mode. The Debian 12
    # pre-check treats 443 + active xray as the reinstall/upgrade
    # path, so the service state must be active here, not just the
    # port list.
    export XRAY_TEST_LISTEN_PORTS="443" XRAY_TEST_SERVICE_STATE=active
    local out
    out="$(main --auto 2>&1)" || { printf '%s\n' "${out}"; return 1; }
    grep -q '"inbounds"' "${XRAY_CONF}" || return 1
    grep -q '^host=203.0.113.2$' "${NODE_PARAMS_FILE}" || return 1
    grep -q '^port=443$' "${NODE_PARAMS_FILE}" || return 1
    grep -q '安装已完成' <<< "${out}" || return 1
    grep -q 'vless://' <<< "${out}" || return 1
    return 0
}

t_urlencode() {
    [[ "$(url_encode "hello world")" == "hello%20world" ]] || return 1
    [[ "$(url_encode "中文")" == "%E4%B8%AD%E6%96%87" ]] || return 1
    [[ "$(url_encode "a/b?c=d&e")" == "a%2Fb%3Fc%3Dd%26e" ]] || return 1
    [[ "$(url_encode "abc-._~123")" == "abc-._~123" ]] || return 1
    # Locale-independence (regression for the en_US.UTF-8 bug, where
    # the old character-indexing version produced %E4B8AD): the same
    # input must encode identically in a byte locale and in UTF-8
    # locales. C.utf8 is used because it is a real multibyte UTF-8
    # locale even on machines without en_US.UTF-8 installed.
    [[ "$(LC_ALL=C url_encode "中文")" == "%E4%B8%AD%E6%96%87" ]] || return 1
    [[ "$(LC_ALL=C.utf8 url_encode "中文")" == "%E4%B8%AD%E6%96%87" ]] || return 1
    [[ "$(LC_ALL=C.utf8 url_encode "a b 中")" == "a%20b%20%E4%B8%AD" ]] || return 1
    if locale -a 2>/dev/null | grep -qx "en_US.UTF-8"; then
        [[ "$(LC_ALL=en_US.UTF-8 url_encode "中文")" == "%E4%B8%AD%E6%96%87" ]] || return 1
    fi
    return 0
}

t_config_render() {
    local d="${SANDBOX}/render"
    local v="${d}/vision.json"
    local n="${d}/novision.json"
    mkdir -p "${d}"
    render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "vision" "www.apple.com:443" "${v}" || return 1
    render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "none" "www.apple.com:443" "${n}" || return 1
    grep -q 'xtls-rprx-vision' "${v}" || return 1
    grep -q '"port": 443' "${v}" || return 1
    grep -q '"security": "reality"' "${v}" || return 1
    if grep -q 'xtls-rprx-vision' "${n}"; then return 1; fi
    grep -q '"decryption": "none"' "${v}" || return 1
    # Multiline array extraction (the old single-line-grep bug).
    cat > "${d}/multi.json" <<'JSONEOF'
{
  "streamSettings": {
    "realitySettings": {
      "serverNames": [
        "sni-a.example",
        "sni-b.example"
      ],
      "shortIds": [
        "abcd1234",
        "ef567890"
      ],
      "empty": []
    }
  }
}
JSONEOF
    local names
    names="$(json_array_values "${d}/multi.json" "serverNames")"
    [[ "${names}" == $'sni-a.example\nsni-b.example' ]] || return 1
    local sids
    sids="$(json_array_values "${d}/multi.json" "shortIds")"
    [[ "${sids}" == $'abcd1234\nef567890' ]] || return 1
    [[ -z "$(json_array_values "${d}/multi.json" "empty")" ]] || return 1
    # Bare-domain dest must fail (Reality requires host:port).
    if render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "vision" "www.apple.com" "${d}/bad.json"; then return 1; fi
    return 0
}

t_share_link() {
    local link nov
    link="$(build_share_link "PLACEHOLDER-UUID" "example.com" "443" "vision" \
        "sni.example" "PLACEHOLDER-PUBLIC-KEY" "PLACEHOLDER-SID" "test-node")"
    case "${link}" in
        vless://PLACEHOLDER-UUID@example.com:443'?'*) ;;
        *) return 1 ;;
    esac
    case "${link}" in
        *'flow=xtls-rprx-vision'*'security=reality'*'sni=sni.example'*'type=tcp'*) ;;
        *) return 1 ;;
    esac
    case "${link}" in
        *'PLACEHOLDER-PRIVATE-KEY'*) return 1 ;;
    esac
    nov="$(build_share_link "PLACEHOLDER-UUID" "example.com" "443" "none" \
        "sni.example" "PLACEHOLDER-PUBLIC-KEY" "PLACEHOLDER-SID" "test-node")"
    case "${nov}" in
        *'flow='*) return 1 ;;
    esac
    return 0
}

t_backup() {
    local d="${SANDBOX}/backup-case"
    mkdir -p "${d}"
    local old_parent="${SNAPSHOT_PARENT}"
    SNAPSHOT_PARENT="${d}"
    # Fake installed state for the snapshot.
    render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "vision" "www.apple.com:443" "${XRAY_CONF}" || return 1
    local snap
    snap="$(snapshot_create)" || return 1
    [[ -d "${snap}" ]] || return 1
    [[ -f "${snap}/xray.bin" && -f "${snap}/config.json" && -f "${snap}/meta.txt" ]] || return 1
    grep -q '^version=' "${snap}/meta.txt" || return 1
    grep -q '^created=' "${snap}/meta.txt" || return 1
    grep -q '^binary_sha256=' "${snap}/meta.txt" || return 1
    # Retain-3: create 4 more snapshots rapidly (collision suffixes keep
    # them distinct); only the newest 3 may remain.
    local i
    for i in 1 2 3 4; do
        snapshot_create >/dev/null || return 1
    done
    local count
    count="$(snapshot_list | wc -l)"
    [[ "${count}" -eq 3 ]] || return 1
    SNAPSHOT_PARENT="${old_parent}"
    return 0
}

t_launcher() {
    local src="${SANDBOX}/src"
    mkdir -p "${src}/lib"
    printf '#!/usr/bin/env bash\n# fake manage\n' > "${src}/manage.sh"
    printf '#!/usr/bin/env bash\n# fake lib\n' > "${src}/lib/common.sh"
    printf '#!/usr/bin/env bash\n# fake diag\n' > "${src}/diagnose.sh"
    printf '26.10.21\n' > "${src}/VERSION"
    local target="${src}/manage.sh"
    local link="${LAUNCHER_DIR}/DSH"
    local persist="${TOOL_INSTALL_DIR}/manage.sh"
    rm -f -- "${link}"
    install_lisa_launcher "${target}" || return 1
    # Persistent copy exists with matching content and is executable.
    [[ -f "${persist}" ]] || return 1
    [[ -x "${persist}" ]] || return 1
    [[ "$(cat "${persist}")" == "$(cat "${target}")" ]] || return 1
    [[ -f "${TOOL_INSTALL_DIR}/lib/common.sh" ]] || return 1
    [[ -f "${TOOL_INSTALL_DIR}/diagnose.sh" ]] || return 1
    [[ -f "${TOOL_INSTALL_DIR}/VERSION" ]] || return 1
    # Symlink points at the persistent copy, not the source.
    [[ -L "${link}" && "$(readlink "${link}")" == "${persist}" ]] || return 1
    # Idempotent, and refreshes the persistent copy from a newer source.
    printf '#!/usr/bin/env bash\n# fake manage v2\n' > "${target}"
    install_lisa_launcher "${target}" || return 1
    [[ "$(cat "${persist}")" == "$(cat "${target}")" ]] || return 1
    [[ "$(readlink "${link}")" == "${persist}" ]] || return 1
    # Repoint when the link points elsewhere (e.g. an old /tmp download).
    ln -sfn "/tmp/xrm/manage.sh" "${link}"
    install_lisa_launcher "${target}" || return 1
    [[ "$(readlink "${link}")" == "${persist}" ]] || return 1
    # Refuse to overwrite a regular file.
    rm -f -- "${link}"
    printf 'keep me\n' > "${link}"
    expect_fail install_lisa_launcher "${target}" || return 1
    [[ "$(cat "${link}")" == "keep me" ]] || return 1
    rm -f -- "${link}"
    return 0
}

t_menu_smoke() {
    local out rc
    out="$(printf '0\n' | bash "${REPO_ROOT}/manage.sh" menu 2>&1)"
    rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    printf '%s' "${out}" | grep -q "D S H" || return 1
    printf '%s' "${out}" | grep -q "Reality · Hysteria2" || return 1
    printf '%s' "${out}" | grep -q "通用链接" || return 1
    # HY2 add-on (v5): six items live in the same menu.
    printf '%s' "${out}" | grep -q "13 安装/升级" || return 1
    printf '%s' "${out}" | grep -q "18 轮换证书" || return 1
    printf '%s' "${out}" | grep -q "回滚快照" || return 1
    printf '%s' "${out}" | grep -q "BBR 加速" || return 1
    printf '%s' "${out}" | grep -q "请选择 \[0-18\]" || return 1
    # Menu 1 changed (2026-11-03, main-chat approved): 系统安全, not outbound test.
    printf '%s' "${out}" | grep -q "认证方式" || return 1
    printf '%s' "${out}" | grep -q "运维" || return 1
    printf '%s' "${out}" | grep -q "安装指定版本核心" && return 1 || true
    printf '%s' "${out}" | grep -q "退出" || return 1
    bash "${REPO_ROOT}/manage.sh" help >/dev/null 2>&1 || return 1
    bash "${REPO_ROOT}/install.sh" --help >/dev/null 2>&1 || return 1
    return 0
}

t_diagnose_nocore() {
    local out rc
    export XRAY_BIN="/nonexistent/xray"
    export XRAY_CONF_DIR="/nonexistent/etc"
    export XRAY_CONF="/nonexistent/etc/config.json"
    out="$(bash "${REPO_ROOT}/diagnose.sh" 2>&1)"
    rc=$?
    [[ "${rc}" -eq 1 ]] || return 1
    printf '%s' "${out}" | grep -q "FAIL" || return 1
    printf '%s' "${out}" | grep -q "Summary:" || return 1
    return 0
}

t_diagnose_mocked() {
    export XRAY_TEST_SERVICE_STATE=active
    export XRAY_TEST_SERVICE_ENABLED=enabled
    export XRAY_TEST_LISTEN_PORTS="443"
    render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "vision" "www.apple.com:443" "${XRAY_CONF}" || return 1
    migrate_permissions || return 1
    local out rc
    out="$(bash "${REPO_ROOT}/diagnose.sh" 2>&1)"
    rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    printf '%s' "${out}" | grep -q "Result: OK" || return 1
    return 0
}

t_upgrade_rollback() {
    # Test-double: skip the real network download.
    download_core() {
        local destdir="$3" fakezip
        fakezip="${destdir}/Xray-linux-64.zip"
        printf 'fake-zip' > "${fakezip}"
        printf 'fake-dgst' > "${fakezip}.dgst"
        printf '%s' "${fakezip}"
    }
    export FAKE_TARGET_VERSION="26.10.21"
    render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "vision" "www.apple.com:443" "${XRAY_CONF}" || return 1
    [[ "$(current_version)" == "26.3.27" ]] || return 1
    local before
    before="$(snapshot_list | wc -l)"
    # Same-version install is a no-op and takes no snapshot.
    upgrade_core "26.3.27" "${SANDBOX}/fake-installer.sh" || return 1
    [[ "$(snapshot_list | wc -l)" -eq "${before}" ]] || return 1
    # Upgrade 26.3.27 -> 26.10.21.
    upgrade_core "26.10.21" "${SANDBOX}/fake-installer.sh" || return 1
    [[ "$(current_version)" == "26.10.21" ]] || return 1
    grep -q "stop" "${XRAY_TEST_LOG}" || return 1
    grep -q "restart" "${XRAY_TEST_LOG}" || return 1
    # Rollback to the upgrade snapshot.
    rollback_core || return 1
    [[ "$(current_version)" == "26.3.27" ]] || return 1
    # Post-rollback re-upgrade works.
    upgrade_core "26.10.21" "${SANDBOX}/fake-installer.sh" || return 1
    [[ "$(current_version)" == "26.10.21" ]] || return 1
    return 0
}

t_perm() {
    mkdir -p "${XRAY_CONF_DIR}" "${XRAY_LOG_DIR}"
    printf '{}' > "${XRAY_CONF}"
    chmod 755 "${XRAY_CONF_DIR}"
    chmod 666 "${XRAY_CONF}"
    chmod 755 "${XRAY_LOG_DIR}"
    printf 'stray' > "${XRAY_CONF_DIR}/stray.txt"
    chmod 644 "${XRAY_CONF_DIR}/stray.txt"
    # A log file with wrong mode (e.g. left by a root-run config test).
    printf 'log' > "${XRAY_LOG_DIR}/access.log"
    chmod 644 "${XRAY_LOG_DIR}/access.log"
    # Validation must fail while modes are wrong / stray file is readable.
    expect_fail validate_permissions || return 1
    migrate_permissions || return 1
    [[ "$(stat -c '%a' "${XRAY_CONF_DIR}")" == "750" ]] || return 1
    [[ "$(stat -c '%a' "${XRAY_CONF}")" == "640" ]] || return 1
    [[ "$(stat -c '%a' "${XRAY_LOG_DIR}")" == "700" ]] || return 1
    [[ "$(stat -c '%a' "${XRAY_LOG_DIR}/access.log")" == "600" ]] || return 1
    # Removing the stray readable file makes validation pass.
    rm -f "${XRAY_CONF_DIR}/stray.txt"
    validate_permissions >/dev/null || return 1
    return 0
}

t_service_display_state() {
    export XRAY_TEST_SERVICE_STATE=active
    export XRAY_TEST_LISTEN_PORTS="443"
    [[ "$(service_display_state 443)" == "active" ]] || return 1
    export XRAY_TEST_LISTEN_PORTS=""
    [[ "$(service_display_state 443)" == "active (no listener)" ]] || return 1
    export XRAY_TEST_SERVICE_STATE=inactive
    export XRAY_TEST_LISTEN_PORTS="443"
    [[ "$(service_display_state 443)" == "inactive" ]] || return 1
    export XRAY_TEST_SERVICE_STATE=active
    [[ "$(service_display_state)" == "active" ]] || return 1
    return 0
}

t_install_repair() {
    # Sandbox isolation (explicit): handle_already_installed installs
    # the logrotate config; it must land in the sandbox.
    export LOGROTATE_DIR="${SANDBOX}/logrotate.d"
    mkdir -p "${LOGROTATE_DIR}"
    source "${REPO_ROOT}/install.sh"
    export AUTO_INSTALL=1
    export REPAIR_INSTALL=1
    export XRAY_TEST_LISTEN_PORTS="443"
    : > "${XRAY_TEST_LOG}"
    # Fake installed state: invalid config (bare dest) + complete params (bare dest).
    render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "vision" "www.apple.com:443" "${XRAY_CONF}" || return 1
    sed -i 's/www.apple.com:443/www.apple.com/' "${XRAY_CONF}" || return 1
    grep -q '"dest": "www.apple.com"' "${XRAY_CONF}" || return 1
    write_node_params "PLACEHOLDER-UUID" "TESTPRIVKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "TESTPUBKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "aabbccdd" "203.0.113.1" "443" "www.apple.com" "www.apple.com" "vision" || return 1
    handle_already_installed || return 1
    grep -q '"dest": "www.apple.com:443"' "${XRAY_CONF}" || return 1
    grep -q '^dest=www.apple.com:443$' "${NODE_PARAMS_FILE}" || return 1
    [[ -L "${LAUNCHER_DIR}/DSH" ]] || return 1
    [[ "$(readlink "${LAUNCHER_DIR}/DSH")" == "${TOOL_INSTALL_DIR}/manage.sh" ]] || return 1
    grep -q "systemctl restart xray" "${XRAY_TEST_LOG}" || return 1
    # The pre-repair snapshot (bare dest) must still exist, and the
    # post-repair verified config must be the known-good snapshot.
    local snap pre="" known
    for snap in $(snapshot_list); do
        if grep -q '"dest": "www.apple.com"' "${snap}/config.json" 2>/dev/null; then
            pre="${snap}"
        fi
    done
    [[ -n "${pre}" ]] || return 1
    [[ -f "${pre}/node.params" ]] || return 1
    known="$(snapshot_known_good)" || return 1
    [[ -n "${known}" ]] || return 1
    grep -q '"dest": "www.apple.com:443"' "${known}/config.json" || return 1
    return 0
}

t_install_repair_fail() {
    # Sandbox isolation (explicit): handle_already_installed installs
    # the logrotate config before the repair fails; it must land in
    # the sandbox even on this failure path.
    export LOGROTATE_DIR="${SANDBOX}/logrotate.d"
    mkdir -p "${LOGROTATE_DIR}"
    source "${REPO_ROOT}/install.sh"
    export AUTO_INSTALL=1
    export XRAY_TEST_LISTEN_PORTS="443"
    : > "${XRAY_TEST_LOG}"
    # Invalid config (bare dest) + INCOMPLETE params (empty private key):
    # repair cannot safely re-render, so it must fail without touching files,
    # but the launcher must still be installed.
    render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "vision" "www.apple.com:443" "${XRAY_CONF}" || return 1
    sed -i 's/www.apple.com:443/www.apple.com/' "${XRAY_CONF}" || return 1
    write_node_params "PLACEHOLDER-UUID" "" "TESTPUBKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "aabbccdd" "203.0.113.1" "443" "www.apple.com" "www.apple.com" "vision" || return 1
    expect_fail handle_already_installed || return 1
    [[ -L "${LAUNCHER_DIR}/DSH" ]] || return 1
    grep -q '"dest": "www.apple.com"' "${XRAY_CONF}" || return 1
    return 0
}

t_install_auto_no_repair() {
    # --auto alone must NEVER repair: invalid config + AUTO_INSTALL=1
    # without REPAIR_INSTALL=1 must fail without touching the config.
    export LOGROTATE_DIR="${SANDBOX}/logrotate.d"
    mkdir -p "${LOGROTATE_DIR}"
    source "${REPO_ROOT}/install.sh"
    export AUTO_INSTALL=1
    unset REPAIR_INSTALL
    export XRAY_TEST_LISTEN_PORTS="443"
    : > "${XRAY_TEST_LOG}"
    render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "vision" "www.apple.com:443" "${XRAY_CONF}" || return 1
    sed -i 's/www.apple.com:443/www.apple.com/' "${XRAY_CONF}" || return 1
    write_node_params "PLACEHOLDER-UUID" "TESTPRIVKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "TESTPUBKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "aabbccdd" "203.0.113.1" "443" "www.apple.com" "www.apple.com" "vision" || return 1
    expect_fail handle_already_installed || return 1
    grep -q '"dest": "www.apple.com"' "${XRAY_CONF}" || return 1
    return 0
}


t_verify_listening() {
    export XRAY_TEST_LISTEN_PORTS="443"
    verify_listening 443 || return 1
    export XRAY_TEST_LISTEN_PORTS=""
    expect_fail verify_listening 443 || return 1
    export XRAY_TEST_LISTEN_PORTS="22 443"
    verify_listening 443 || return 1
    verify_listening "" || return 1
    expect_fail verify_listening 80 || return 1
    return 0
}

t_wait_for_listening() {
    export XRAY_TEST_LISTEN_PORTS="443"
    wait_for_listening 443 || return 1
    export XRAY_TEST_LISTEN_PORTS=""
    expect_fail wait_for_listening 443 || return 1
    wait_for_listening "" || return 1
    return 0
}

t_bbr_joeyblog_rc_filter() {
    local rc_dir="${SANDBOX}/rc-fakes" out
    mkdir -p "${rc_dir}" || return 1
    cat > "${rc_dir}/dpkg" <<'FAKEEOF'
#!/usr/bin/env bash
if [[ "$1" == "-l" ]]; then printf 'rc  linux-image-7.3.0-joeyblog-bbrv3  7.3.0  amd64  fake\n'; exit 0; fi
exit 1
FAKEEOF
    chmod 755 "${rc_dir}/dpkg" || return 1
    export PATH="${rc_dir}:${PATH}"
    [[ -z "$(bbr_joeyblog_pkgs)" ]] || return 1
    # BBRv3-only version: no standalone uninstall command; an rc-only package must
    # still count as not installed in version output.
    out="$(bbr_version 2>&1)" || return 1
    printf '%s' "${out}" | grep -q "joeyblog pkgs  : (none)" || return 1
    return 0
}

t_bbr_module_version_blank() {
    local blank_dir="${SANDBOX}/blank-fakes" out
    mkdir -p "${blank_dir}" || return 1
    cat > "${blank_dir}/modinfo" <<'FAKEEOF'
#!/usr/bin/env bash
printf 'filename: /lib/modules/fake/tcp_bbr.ko\nlicense: GPL\n'
exit 0
FAKEEOF
    chmod 755 "${blank_dir}/modinfo" || return 1
    export PATH="${blank_dir}:${PATH}"
    [[ "$(bbr_module_version)" == "1" ]] || return 1
    out="$(bbr_version 2>&1)" || return 1
    printf '%s' "${out}" | grep -q "tcp_bbr version: 1" || return 1
    return 0
}



# ------------------------------------------------------------ BBR ----
# bbr_test_setup: resets all fake BBR state to stock defaults
# (Debian 12, kernel 6.1, module v1, Cubic + fq_codel, no Lisa file,
# no joeyblog package, empty grub cfg). Called first in every BBR test
# because the sandbox state files are shared across test subshells.
bbr_test_setup() {
    printf 'congestion=cubic\nqdisc=fq_codel\n' > "${FAKE_SYSCTL_STATE}"
    printf 'fq_codel\n' > "${FAKE_TC_STATE}"
    printf 'ID=debian\nVERSION_ID="12"\n' > "${BBR_OS_RELEASE}"
    : > "${BBR_GRUB_CFG}"
    rm -f -- "${BBR_SYSCTL_FILE}" "${FAKE_DPKG_MARKER}" "${BBR_ONESHOT_UNIT}" "${BBR_ONESHOT_RESULT}"
    rm -rf -- "${BBR_BACKUP_DIR}"
    mkdir -p "${BBR_BACKUP_DIR}"
    export FAKE_BBR_VERSION=1
    export FAKE_UNAME_R="6.1.0-18-amd64"
    export FAKE_GRUB_VERSION="7.0.11"
    export FAKE_TC_FAIL=0
    export FAKE_DPKG_FAIL=0
    export FAKE_UPDATE_GRUB_FAIL=0
    export FAKE_MODINFO_FAIL=0
    return 0
}

t_bbr_check_env_debian12_only() {
    # Debian 12 exclusive (2026-11-02): BBR kernel install accepts
    # Debian 12 only; Ubuntu and Debian 11 are rejected. This locks
    # in that only the Ubuntu branch was removed — BBR itself,
    # including its read-only version/status checks, is unchanged.
    bbr_test_setup || return 1
    bbr_check_env || return 1
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "${BBR_OS_RELEASE}"
    expect_fail bbr_check_env || return 1
    printf 'ID=debian\nVERSION_ID="11"\n' > "${BBR_OS_RELEASE}"
    expect_fail bbr_check_env || return 1
    printf 'ID=debian\nVERSION_ID="12"\n' > "${BBR_OS_RELEASE}"
    bbr_check_env || return 1
    return 0
}

t_bbr3_fq_rollback() {
    # FQ enable on a running v3 kernel, with tc failing: sysctl file must
    # be rolled back, not left as a partial success.
    bbr_test_setup || return 1
    export FAKE_BBR_VERSION=3
    export FAKE_UNAME_R="7.0.11-joeyblog"
    export FAKE_TC_FAIL=1
    expect_fail bbr3_enable || return 1
    [[ ! -f "${BBR_SYSCTL_FILE}" ]] || return 1
    [[ "$(bbr_congestion)" == "cubic" ]] || return 1
    [[ "$(bbr_qdisc)" == "fq_codel" ]] || return 1
    [[ "$(cat "${FAKE_TC_STATE}")" == "fq_codel" ]] || return 1
    return 0
}

t_bbr_version_status() {
    local out
    bbr_test_setup || return 1
    out="$(bbr_version 2>&1)" || return 1
    printf '%s' "${out}" | grep -q "running kernel : 6.1.0-18-amd64" || return 1
    printf '%s' "${out}" | grep -q "tcp_bbr version: 1" || return 1
    printf '%s' "${out}" | grep -q "congestion     : cubic" || return 1
    expect_fail bbr_status || return 1
    export FAKE_BBR_VERSION=3
    export FAKE_UNAME_R="7.0.11-joeyblog"
    bbr3_enable >/dev/null 2>&1 || return 1
    out="$(bbr_status 2>&1)" || return 1
    printf '%s' "${out}" | grep -q "effective" || return 1
    return 0
}

t_bbr_clear() {
    bbr_test_setup || return 1
    export FAKE_BBR_VERSION=3
    export FAKE_UNAME_R="7.0.11-joeyblog"
    bbr3_enable >/dev/null 2>&1 || return 1
    [[ -f "${BBR_SYSCTL_FILE}" ]] || return 1
    bbr_clear || return 1
    [[ ! -f "${BBR_SYSCTL_FILE}" ]] || return 1
    [[ "$(bbr_congestion)" == "cubic" ]] || return 1
    [[ "$(bbr_qdisc)" == "fq_codel" ]] || return 1
    [[ "$(cat "${FAKE_TC_STATE}")" == "fq_codel" ]] || return 1
    return 0
}


t_bbr3_already_v3() {
    local out
    bbr_test_setup || return 1
    export FAKE_BBR_VERSION=3
    export FAKE_UNAME_R="7.0.11-joeyblog"
    out="$(bbr3_enable 2>&1)" || return 1
    printf '%s' "${out}" | grep -q "BBR3+FQ enabled" || return 1
    printf '%s' "${out}" | grep -q "version=3" || return 1
    [[ -f "${BBR_SYSCTL_FILE}" ]] || return 1
    [[ ! -f "${FAKE_DPKG_MARKER}" ]] || return 1
    return 0
}

t_bbr3_installed_not_running() {
    # joeyblog kernel installed but not running: offer a reboot prompt
    # (test mode prints would-reboot, never reboots), return 0, FQ pending
    # after reboot; never enable FQ as v1.
    local out
    bbr_test_setup || return 1
    touch "${FAKE_DPKG_MARKER}"
    out="$(bbr3_enable 2>&1)" || return 1
    printf '%s' "${out}" | grep -q "not running" || return 1
    printf '%s' "${out}" | grep -q "NOT enabled now" || return 1
    printf '%s' "${out}" | grep -q "test mode, not rebooting" || return 1
    [[ ! -f "${BBR_SYSCTL_FILE}" ]] || return 1
    [[ "$(bbr_congestion)" == "cubic" ]] || return 1
    return 0
}

t_bbr3_install_from_stock() {
    # Clean stock VPS path: no joeyblog, module v1 -> install kernel
    # (mocked API/download), grub verified, reboot prompt in test mode,
    # return 0, FQ still pending (not enabled on the old kernel).
    local out
    bbr_test_setup || return 1
    bbr_api_get() {
        case "$1" in
            *"/releases/tags/"*) printf '%s' '{"assets":[{"browser_download_url":"https://example.invalid/linux-image-7.0.11-joeyblog.deb"}]}' ;;
            *) printf '%s' '{"tag_name":"x86_64-7.0.11"}' ;;
        esac
    }
    bbr_download_file() { printf 'fake-deb\n' > "$2"; }
    out="$(bbr3_enable 2>&1)" || return 1
    printf '%s' "${out}" | grep -q "BBRv3 kernel 7.0.11 installed" || return 1
    printf '%s' "${out}" | grep -q "test mode, not rebooting" || return 1
    [[ -f "${FAKE_DPKG_MARKER}" ]] || return 1
    grep -q "7.0.11" "${BBR_GRUB_CFG}" || return 1
    [[ ! -f "${BBR_SYSCTL_FILE}" ]] || return 1
    [[ "$(bbr_congestion)" == "cubic" ]] || return 1
    return 0
}

t_bbr_oneshot_created_on_install() {
    # Kernel install success creates the oneshot unit (Type=oneshot,
    # ExecStart is the internal auto-fq target); FQ is still pending.
    local out
    bbr_test_setup || return 1
    bbr_api_get() {
        case "$1" in
            *"/releases/tags/"*) printf '%s' '{"assets":[{"browser_download_url":"https://example.invalid/linux-image-7.0.11-joeyblog.deb"}]}' ;;
            *) printf '%s' '{"tag_name":"x86_64-7.0.11"}' ;;
        esac
    }
    bbr_download_file() { printf 'fake-deb\n' > "$2"; }
    out="$(bbr3_enable 2>&1)" || return 1
    [[ -f "${BBR_ONESHOT_UNIT}" ]] || return 1
    grep -q "Type=oneshot" "${BBR_ONESHOT_UNIT}" || return 1
    grep -q "ExecStart=/usr/local/bin/lisa bbr auto-fq" "${BBR_ONESHOT_UNIT}" || return 1
    grep -q "systemctl enable lisa-bbr3-oneshot.service" "${XRAY_TEST_LOG}" || return 1
    [[ ! -f "${BBR_SYSCTL_FILE}" ]] || return 1
    printf '%s' "${out}" | grep -q "BBRv3 kernel 7.0.11 installed" || return 1
    return 0
}

t_bbr_oneshot_auto_fq_v3() {
    # Boot handler on a real v3 kernel: non-interactive (auto-confirm
    # off must not block it), enables FQ, verifies, then removes itself
    # and leaves an OK result line.
    bbr_test_setup || return 1
    export FAKE_BBR_VERSION=3
    export FAKE_UNAME_R="7.0.11-joeyblog"
    bbr_oneshot_install || return 1
    [[ -f "${BBR_ONESHOT_UNIT}" ]] || return 1
    export XRAY_TEST_AUTO_CONFIRM=0
    bbr_auto_fq </dev/null || return 1
    export XRAY_TEST_AUTO_CONFIRM=1
    [[ -f "${BBR_SYSCTL_FILE}" ]] || return 1
    [[ "$(bbr_congestion)" == "bbr" ]] || return 1
    [[ "$(bbr_qdisc)" == "fq" ]] || return 1
    [[ ! -f "${BBR_ONESHOT_UNIT}" ]] || return 1
    grep -q "systemctl disable lisa-bbr3-oneshot.service" "${XRAY_TEST_LOG}" || return 1
    grep -q " OK " "${BBR_ONESHOT_RESULT}" || return 1
    return 0
}

t_bbr_oneshot_skips_non_v3() {
    # Stock kernel: boot handler skips, never enables FQ as v1, and
    # still removes the unit so no active task is left behind.
    bbr_test_setup || return 1
    bbr_oneshot_install || return 1
    expect_fail bbr_auto_fq || return 1
    [[ ! -f "${BBR_SYSCTL_FILE}" ]] || return 1
    [[ "$(bbr_congestion)" == "cubic" ]] || return 1
    [[ ! -f "${BBR_ONESHOT_UNIT}" ]] || return 1
    grep -q " SKIP " "${BBR_ONESHOT_RESULT}" || return 1
    grep -q "systemctl disable lisa-bbr3-oneshot.service" "${XRAY_TEST_LOG}" || return 1
    return 0
}

t_bbr_oneshot_fq_failure_no_leftover() {
    # v3 kernel but tc fails: FQ rolls back, unit is removed, result
    # is FAIL, and nothing is claimed effective.
    bbr_test_setup || return 1
    export FAKE_BBR_VERSION=3
    export FAKE_UNAME_R="7.0.11-joeyblog"
    export FAKE_TC_FAIL=1
    bbr_oneshot_install || return 1
    expect_fail bbr_auto_fq || return 1
    [[ ! -f "${BBR_SYSCTL_FILE}" ]] || return 1
    [[ "$(bbr_congestion)" == "cubic" ]] || return 1
    [[ ! -f "${BBR_ONESHOT_UNIT}" ]] || return 1
    grep -q " FAIL " "${BBR_ONESHOT_RESULT}" || return 1
    return 0
}

t_bbr_oneshot_rollback_and_clear_remove() {
    # Rollback removes the unit; clear removes it both when no sysctl
    # file exists and when a confirmed clear deletes the sysctl file.
    bbr_test_setup || return 1
    bbr_oneshot_install || return 1
    bbr_rollback_kernel "${BBR_BACKUP_DIR}/dummy" || return 1
    [[ ! -f "${BBR_ONESHOT_UNIT}" ]] || return 1
    bbr_test_setup || return 1
    bbr_oneshot_install || return 1
    bbr_clear || return 1
    [[ ! -f "${BBR_ONESHOT_UNIT}" ]] || return 1
    bbr_test_setup || return 1
    export FAKE_BBR_VERSION=3
    export FAKE_UNAME_R="7.0.11-joeyblog"
    bbr3_enable >/dev/null 2>&1 || return 1
    bbr_oneshot_install || return 1
    bbr_clear || return 1
    [[ ! -f "${BBR_SYSCTL_FILE}" ]] || return 1
    [[ ! -f "${BBR_ONESHOT_UNIT}" ]] || return 1
    return 0
}

t_bbr3_manual_confirm_unchanged() {
    # Manual bbr3 still requires confirmation: with auto-confirm off
    # it must fail (not auto-confirm), and with it on it succeeds.
    bbr_test_setup || return 1
    export FAKE_BBR_VERSION=3
    export FAKE_UNAME_R="7.0.11-joeyblog"
    export XRAY_TEST_AUTO_CONFIRM=0
    expect_fail bbr3_enable </dev/null || return 1
    export XRAY_TEST_AUTO_CONFIRM=1
    bbr3_enable >/dev/null 2>&1 || return 1
    [[ -f "${BBR_SYSCTL_FILE}" ]] || return 1
    return 0
}

t_bbr_menu_smoke() {
    local out
    bbr_test_setup || return 1
    out="$(printf '12\n0\n0\n' | bash "${REPO_ROOT}/manage.sh" menu 2>&1)"
    printf '%s' "${out}" | grep -q "BBR 加速方案" || return 1
    printf '%s' "${out}" | grep -q "BBRv3+FQ" || return 1
    printf '%s' "${out}" | grep -q "检查版本与状态" || return 1
    printf '%s' "${out}" | grep -q "清空网络优化配置" || return 1
    printf '%s' "${out}" | grep -q "请选择 \[0-3\]" || return 1
    printf '%s' "${out}" | grep -q "Reality · Hysteria2" || return 1
    if printf '%s' "${out}" | grep -q "BBR1+FQ"; then return 1; fi
    # Direct commands: version/status work, bbr1/bbr2/install/uninstall fail.
    bash "${REPO_ROOT}/manage.sh" bbr version >/dev/null 2>&1 || return 1
    bash "${REPO_ROOT}/manage.sh" bbr status >/dev/null 2>&1 || true
    expect_fail bash "${REPO_ROOT}/manage.sh" bbr bbr1 || return 1
    expect_fail bash "${REPO_ROOT}/manage.sh" bbr bbr2 || return 1
    expect_fail bash "${REPO_ROOT}/manage.sh" bbr badcmd || return 1
    expect_fail bash "${REPO_ROOT}/manage.sh" bbr install || return 1
    expect_fail bash "${REPO_ROOT}/manage.sh" bbr uninstall || return 1
    return 0
}


# ---- Phase 1-3 optimisation tests (original code, sandbox only) ----
# NOTE: workflow/CI file intentionally removed (2026-10-30, user decision):
# no .github/workflows/test.yml, no t_ci_workflow test. CI is not a core
# file; regressions are caught by running tests/run_tests.sh manually.

t_menu_install_upgrade() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/manage.sh"
    # Core is present (fake binary), so option 1 must refuse, not upgrade.
    expect_fail cmd_install || return 1
    # Half-installed hint: if the config is not built yet, re-running
    # the one-click install builds it; option 4 upgrade does not.
    local out
    out="$(cmd_install 2>&1)" || true
    printf '%s' "${out}" | grep -q "请重跑一键安装补建" || return 1
    # Menu wording: menu 1 changed (2026-11-03, main-chat approved name 更改认证方式);
    # direct `lisa install` command is kept as a fallback, menu must not show install as 1.
    grep -q "认证方式" "${REPO_ROOT}/manage.sh" || return 1
    grep -q "去程线路测试" "${REPO_ROOT}/manage.sh" && return 1 || true
    grep -q "cmd_outbound_test" "${REPO_ROOT}/manage.sh" && return 1 || true
    grep -q "安装指定版本核心（未装时用）" "${REPO_ROOT}/manage.sh" && return 1 || true
    grep -q "4 升级核心" "${REPO_ROOT}/manage.sh" || return 1
    grep -q "请选择 \[0-18\]" "${REPO_ROOT}/manage.sh" || return 1
    grep -q "通用链接" "${REPO_ROOT}/manage.sh" || return 1
    grep -q "13 安装/升级" "${REPO_ROOT}/manage.sh" || return 1
    grep -q "12 BBR" "${REPO_ROOT}/manage.sh" || return 1
    return 0
}

t_banner_top_align() {
    local out
    out="$(printf '0
' | bash "${REPO_ROOT}/manage.sh" menu 2>&1)"
    printf '%s' "${out}" | grep -q 'Reality · Hysteria2' || return 1
    printf '%s' "${out}" | grep -q '▄' || return 1
    printf '%s' "${out}" | grep -q 'Xray' || return 1
}

t_menu_auth_test() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/manage.sh"
    local tmpdir auth_keys sshd_config sshd_dir out
    tmpdir="$(mktemp -d)" || return 1
    auth_keys="${tmpdir}/authorized_keys"
    sshd_config="${tmpdir}/sshd_config"
    sshd_dir="${tmpdir}/sshd_config.d"
    mkdir -p "${sshd_dir}"
    printf 'PasswordAuthentication yes\nPubkeyAuthentication yes\n' > "${sshd_config}"
    printf '# drop-in\nPasswordAuthentication yes\n' > "${sshd_dir}/00-test.conf"
    # Valid pubkey, auto-confirm, test mode: must append, set perms, close (simulated).
    out="$(XRAY_TEST_MODE=1 XRAY_TEST_AUTO_CONFIRM=1 XRAY_TEST_AUTH_KEYS="${auth_keys}" XRAY_TEST_SSHD_CONFIG="${sshd_config}" XRAY_TEST_SSHD_DIR="${sshd_dir}" cmd_auth "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test-comment" 2>&1)" || { rm -rf "${tmpdir}"; return 1; }
    printf '%s' "${out}" | grep -q "test-comment" || { rm -rf "${tmpdir}"; return 1; }
    printf '%s' "${out}" | grep -q "更改完成" || { rm -rf "${tmpdir}"; return 1; }
    grep -q "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" "${auth_keys}" || { rm -rf "${tmpdir}"; return 1; }
    # Key material must NOT be printed in output (only comment).
    printf '%s' "${out}" | grep -q "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" && { rm -rf "${tmpdir}"; return 1; } || true
    # Private key must be rejected, nothing appended.
    out="$(XRAY_TEST_MODE=1 XRAY_TEST_AUTO_CONFIRM=1 XRAY_TEST_AUTH_KEYS="${auth_keys}" XRAY_TEST_SSHD_CONFIG="${sshd_config}" XRAY_TEST_SSHD_DIR="${sshd_dir}" cmd_auth "-----BEGIN OPENSSH PRIVATE KEY-----" 2>&1)" && { rm -rf "${tmpdir}"; return 1; } || true
    printf '%s' "${out}" | grep -q "私钥" || { rm -rf "${tmpdir}"; return 1; }
    # Empty must be rejected.
    out="$(XRAY_TEST_MODE=1 XRAY_TEST_AUTO_CONFIRM=1 XRAY_TEST_AUTH_KEYS="${auth_keys}" XRAY_TEST_SSHD_CONFIG="${sshd_config}" XRAY_TEST_SSHD_DIR="${sshd_dir}" cmd_auth "" 2>&1 < /dev/null)" && { rm -rf "${tmpdir}"; return 1; } || true
    rm -rf "${tmpdir}"
    return 0
}

t_firewall() {
    local out rc
    out="$(XRAY_TEST_FIREWALL=active-allow firewall_status)"; rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    printf '%s' "${out}" | grep -q "443/tcp ALLOW IN" || return 1
    printf '%s' "${out}" | grep -q "不覆盖 SSH" || return 1
    out="$(XRAY_TEST_FIREWALL=active-deny firewall_status)"; rc=$?
    [[ "${rc}" -eq 2 ]] || return 1
    printf '%s' "${out}" | grep -q "NOT allowed" || return 1
    printf '%s' "${out}" | grep -q "never opens" || return 1
    out="$(XRAY_TEST_FIREWALL=active-allow-out firewall_status)"; rc=$?
    [[ "${rc}" -eq 2 ]] || return 1
    printf '%s' "${out}" | grep -q "only ALLOW OUT" || return 1
    out="$(XRAY_TEST_FIREWALL=active-allow-source firewall_status)"; rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    printf '%s' "${out}" | grep -q "specific source" || return 1
    # ufw inactive is now WARN, not PASS: the tool cannot see the
    # cloud security group, so "inactive" must not read as "firewall OK".
    out="$(XRAY_TEST_FIREWALL=inactive firewall_status)"; rc=$?
    [[ "${rc}" -eq 2 ]] || return 1
    printf '%s' "${out}" | grep -q "云厂商安全组未查" || return 1
    printf '%s' "${out}" | grep -q "不覆盖 SSH" || return 1
    out="$(XRAY_TEST_FIREWALL=absent firewall_status)"; rc=$?
    [[ "${rc}" -eq 3 ]] || return 1
    printf '%s' "${out}" | grep -q "skip" || return 1
    printf '%s' "${out}" | grep -q "不覆盖 SSH" || return 1
    return 0
}

t_logrotate_and_rotated_log() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/install.sh"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/diagnose.sh"
    local lrdir="${SANDBOX}/logrotate.d"
    mkdir -p "${lrdir}"
    LOGROTATE_DIR="${lrdir}" install_logrotate_config || return 1
    [[ -f "${lrdir}/xray-reality-manager" ]] || return 1
    grep -q "copytruncate" "${lrdir}/xray-reality-manager" || return 1
    grep -q "rotate 7" "${lrdir}/xray-reality-manager" || return 1
    grep -q "/var/log/xray/\*.log" "${lrdir}/xray-reality-manager" || return 1
    # Rotated-log helper: current file wins; rotated file is the fallback.
    local logd="${SANDBOX}/xray-logs"
    mkdir -p "${logd}"
    export XRAY_LOG_DIR="${logd}"
    printf 'rotated\n' > "${logd}/error.log.1.gz"
    [[ "$(latest_error_log_file)" == "${logd}/error.log.1.gz" ]] || return 1
    printf 'current\n' > "${logd}/error.log"
    [[ "$(latest_error_log_file)" == "${logd}/error.log" ]] || return 1
    return 0
}

t_loopback_optin() {
    export XRAY_TEST_SERVICE_STATE=active
    export XRAY_TEST_SERVICE_ENABLED=enabled
    export XRAY_TEST_LISTEN_PORTS="443"
    render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "vision" "www.apple.com:443" "${XRAY_CONF}" || return 1
    migrate_permissions || return 1
    local out rc
    # Default: skipped, does not fail the run.
    out="$(bash "${REPO_ROOT}/diagnose.sh" 2>&1)"; rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    printf '%s' "${out}" | grep -q "loopback Reality test skipped" || return 1
    # Opt-in pass.
    out="$(XRAY_TEST_LOOPBACK_RESULT=pass bash "${REPO_ROOT}/diagnose.sh" --loopback 2>&1)"; rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    printf '%s' "${out}" | grep -q "loopback Reality test passed" || return 1
    # Opt-in fail must surface as a failure, not be swallowed.
    out="$(XRAY_TEST_LOOPBACK_RESULT=fail bash "${REPO_ROOT}/diagnose.sh" --loopback 2>&1)"; rc=$?
    [[ "${rc}" -eq 1 ]] || return 1
    printf '%s' "${out}" | grep -q "loopback Reality test FAILED" || return 1
    return 0
}

t_loopback_client_config_generation() {
    # Real config-generation coverage for the loopback probe: build the
    # actual client config (not a mocked probe result) and inspect it.
    # This is the regression test for the bug where flow=vision was
    # written verbatim as "vision" instead of "xtls-rprx-vision".
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/diagnose.sh"
    local d="${SANDBOX}/loopback-config"
    mkdir -p "${d}"
    local cfg_vision="${d}/vision.json" cfg_none="${d}/none.json" cfg_empty="${d}/empty.json"
    build_loopback_client_config "${cfg_vision}" "PLACEHOLDER-UUID" "sni.example" \
        "PLACEHOLDER-PUB" "PLACEHOLDER-SID" "vision" "23456" || return 1
    build_loopback_client_config "${cfg_none}" "PLACEHOLDER-UUID" "sni.example" \
        "PLACEHOLDER-PUB" "PLACEHOLDER-SID" "none" "23456" || return 1
    build_loopback_client_config "${cfg_empty}" "PLACEHOLDER-UUID" "sni.example" \
        "PLACEHOLDER-PUB" "PLACEHOLDER-SID" "" "23456" || return 1
    # vision maps to the only valid client flow value.
    grep -q '"flow": "xtls-rprx-vision"' "${cfg_vision}" || return 1
    grep -q '"flow": "vision"' "${cfg_vision}" && return 1
    # none and empty omit the flow field entirely (no "none", no "vision").
    grep -q '"flow"' "${cfg_none}" && return 1
    grep -q '"flow"' "${cfg_empty}" && return 1
    # Everything else in the generated config is intact, and files are 600.
    grep -q '"port": 23456' "${cfg_vision}" || return 1
    grep -q '"serverName": "sni.example"' "${cfg_vision}" || return 1
    grep -q '"publicKey": "PLACEHOLDER-PUB"' "${cfg_vision}" || return 1
    [[ "$(stat -c '%a' "${cfg_vision}")" == "600" ]] || return 1
    # The generated client config must be identical under C and
    # C.UTF-8 locales (config generation must not depend on locale,
    # same class of bug as the old url_encode issue).
    local cfg_c="${d}/c.json" cfg_utf8="${d}/c-utf8.json"
    LC_ALL=C build_loopback_client_config "${cfg_c}" "PLACEHOLDER-UUID" "sni.example" \
        "PLACEHOLDER-PUB" "PLACEHOLDER-SID" "vision" "23456" || return 1
    LC_ALL=C.UTF-8 build_loopback_client_config "${cfg_utf8}" "PLACEHOLDER-UUID" "sni.example" \
        "PLACEHOLDER-PUB" "PLACEHOLDER-SID" "vision" "23456" || return 1
    cmp -s "${cfg_c}" "${cfg_utf8}" || return 1
    cmp -s "${cfg_c}" "${cfg_vision}" || return 1
    # The mapping helper agrees with the share-link mapping in node.sh:
    # vision -> xtls-rprx-vision in the link, none -> no flow in the link.
    local link
    link="$(build_share_link "PLACEHOLDER-UUID" "example.com" "443" "vision" \
        "sni.example" "PLACEHOLDER-PUB" "PLACEHOLDER-SID" "test")" || return 1
    printf '%s' "${link}" | grep -q 'flow=xtls-rprx-vision' || return 1
    link="$(build_share_link "PLACEHOLDER-UUID" "example.com" "443" "none" \
        "sni.example" "PLACEHOLDER-PUB" "PLACEHOLDER-SID" "test")" || return 1
    printf '%s' "${link}" | grep -q 'flow=' && return 1
    return 0
}



t_status_enrichment() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/manage.sh"
    export XRAY_TEST_SERVICE_STATE=active
    export XRAY_TEST_SERVICE_ENABLED=enabled
    export XRAY_TEST_LISTEN_PORTS="443"
    export XRAY_TEST_SERVICE_UPTIME="2026-10-30 10:00:00"
    export XRAY_TEST_LAST_ERROR_TIME="2026-10-30 09:00:00"
    render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "vision" "www.apple.com:443" "${XRAY_CONF}" || return 1
    migrate_permissions || return 1
    local out
    out="$(cmd_status 2>&1)" || return 1
    # Labels are start time / log mtime, not duration / error time.
    printf '%s' "${out}" | grep -q "service start" || return 1
    printf '%s' "${out}" | grep -q "2026-10-30 10:00:00" || return 1
    printf '%s' "${out}" | grep -q "log last mod" || return 1
    printf '%s' "${out}" | grep -q "2026-10-30 09:00:00" || return 1
    printf '%s' "${out}" | grep -q "uptime" && return 1
    printf '%s' "${out}" | grep -q "last error" && return 1
    return 0
}

t_ip_display() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/install.sh"
    # Auto branch with an explicit host must log the host it will use.
    local out
    out="$(AUTO_INSTALL=1 XRAY_NODE_HOST=203.0.113.10 node_setup 2>&1)" || return 1
    printf '%s' "${out}" | grep -q "using XRAY_NODE_HOST: 203.0.113.10" || return 1
    return 0
}

t_detect_public_ip() {
    # Fake curl by service: last argument is the URL. Three cases,
    # no network, no real IP values used (TEST-NET documentation IPs).
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/install.sh"
    local ip
    curl() {
        local url="${@: -1}"
        case "${url}" in
            *ifconfig.me*) printf '203.0.113.10' ;;
            *ipify*) printf '203.0.113.10' ;;
            *icanhazip*) printf '203.0.113.20' ;;
        esac
    }
    detect_public_ip ip || return 1
    [[ "${ip}" == "203.0.113.10" && "${DETECT_IP_VERIFIED}" == "1" ]] || return 1
    curl() {
        local url="${@: -1}"
        case "${url}" in
            *ifconfig.me*) printf '203.0.113.10' ;;
            *ipify*) printf '203.0.113.20' ;;
            *icanhazip*) printf '203.0.113.30' ;;
        esac
    }
    detect_public_ip ip 2>/dev/null || return 1
    [[ "${ip}" == "203.0.113.10" && "${DETECT_IP_VERIFIED}" == "0" ]] || return 1
    curl() { printf ''; }
    if detect_public_ip ip 2>/dev/null; then return 1; fi
    return 0
}

t_check_update_readme() {
    # VERSION stays pinned; README must say re-evaluation is manual-only.
    grep -q "^26\.10\.21$" "${REPO_ROOT}/VERSION" || return 1
    grep -q "手动评估" "${REPO_ROOT}/README.md" || return 1
    grep -q "不会自动" "${REPO_ROOT}/README.md" || return 1
    return 0
}

t_test_override_production() {
    # Test overrides must be inert outside test mode. Run each helper
    # in a subshell with XRAY_TEST_MODE unset: it must NOT return the
    # canned value, and must warn on stderr (stdout stays clean).
    local out rc err
    out="$(env -u XRAY_TEST_MODE XRAY_TEST_FIREWALL=active-allow bash -c 'source "'"${REPO_ROOT}"'/lib/common.sh"; firewall_status' 2>"${SANDBOX}/fw.err")"; rc=$?
    [[ "${rc}" -ne 0 ]] || return 1
    printf '%s' "${out}" | grep -q "test mode" && return 1
    grep -q "ignoring test override XRAY_TEST_FIREWALL" "${SANDBOX}/fw.err" || return 1
    out="$(env -u XRAY_TEST_MODE XRAY_TEST_SERVICE_UPTIME=2099-01-01 bash -c 'source "'"${REPO_ROOT}"'/lib/common.sh"; service_uptime' 2>"${SANDBOX}/up.err")"
    [[ "${out}" != "2099-01-01" ]] || return 1
    grep -q "ignoring test override XRAY_TEST_SERVICE_UPTIME" "${SANDBOX}/up.err" || return 1
    out="$(env -u XRAY_TEST_MODE XRAY_TEST_LAST_ERROR_TIME=2099-01-01 bash -c 'source "'"${REPO_ROOT}"'/lib/common.sh"; XRAY_LOG_DIR="'"${SANDBOX}"'/nolog"; last_error_log_time' 2>"${SANDBOX}/le.err")"
    [[ "${out}" != "2099-01-01" ]] || return 1
    grep -q "ignoring test override XRAY_TEST_LAST_ERROR_TIME" "${SANDBOX}/le.err" || return 1
    # Loopback: with test mode off, a set RESULT must not produce a
    # test-mode pass. Params are incomplete in this subshell, so the
    # real path must skip, not pass.
    out="$(env -u XRAY_TEST_MODE XRAY_TEST_LOOPBACK_RESULT=pass NODE_PARAMS_FILE="${SANDBOX}/no-such.params" bash -c 'source "'"${REPO_ROOT}"'/diagnose.sh"; loopback_reality_test' 2>"${SANDBOX}/lb.err")"; rc=$?
    [[ "${rc}" -eq 2 ]] || return 1
    printf '%s' "${out}" | grep -q "test mode" && return 1
    grep -q "ignoring test override XRAY_TEST_LOOPBACK_RESULT" "${SANDBOX}/lb.err" || return 1
    # In test mode the same overrides still work (regression guard).
    out="$(XRAY_TEST_FIREWALL=active-allow firewall_status)"; rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    printf '%s' "${out}" | grep -q "test mode" || return 1
    return 0
}

t_node_apply_rollback() {
    # Test-then-switch + auto-rollback for node param changes.
    source "${REPO_ROOT}/manage.sh"
    local uuid="11111111-2222-4333-8444-555555555555" priv="TESTPRIVKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" pub="TESTPUBKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" sid="aabbccdd"
    render_config "${uuid}" "${sid}" "${priv}" "old.example.com" "443" "vision" "www.apple.com:443" "${XRAY_CONF}" || return 1
    write_node_params "${uuid}" "${priv}" "${pub}" "${sid}" "203.0.113.9" "443" "old.example.com" "www.apple.com:443" "vision" || return 1
    # Success path: SNI change applies and params follow the live config.
    node_set_sni "new.example.com" >/dev/null 2>&1 || return 1
    [[ "$(read_node_param sni)" == "new.example.com" ]] || return 1
    grep -q '"new.example.com"' "${XRAY_CONF}" || return 1
    # Failure path: force service_restart to fail (mocked systemctl).
    # apply_node_config must restore the snapshot and leave the
    # previous config AND params untouched.
    export XRAY_TEST_SYSTEMCTL_FAIL="restart"
    expect_fail node_set_sni "fail.example.com" >/dev/null 2>&1 || { unset XRAY_TEST_SYSTEMCTL_FAIL; return 1; }
    unset XRAY_TEST_SYSTEMCTL_FAIL
    [[ "$(read_node_param sni)" == "new.example.com" ]] || return 1
    grep -q '"new.example.com"' "${XRAY_CONF}" || return 1
    grep -q '"fail.example.com"' "${XRAY_CONF}" && return 1
    # Slim restore-main re-renders Vision from params through
    # apply_node_config: first switch the live config to a no-flow
    # temp config via apply_node_config directly, then restore-main
    # must bring Vision back.
    local tmpconf
    tmpconf="${SANDBOX}/noflow-config.json"
    render_config "${uuid}" "${sid}" "${priv}" "new.example.com" "443" "none" "www.apple.com:443" "${tmpconf}" || return 1
    config_test "${tmpconf}" || return 1
    apply_node_config "${tmpconf}" "no-flow test switch" >/dev/null 2>&1 || return 1
    grep -q '"flow"' "${XRAY_CONF}" && return 1
    node_restore_main >/dev/null 2>&1 || return 1
    grep -q '"flow": "xtls-rprx-vision"' "${XRAY_CONF}" || return 1
    return 0
}


t_snapshot_latest_order() {
    local d="${SANDBOX}/latest-order"
    mkdir -p "${d}"
    SNAPSHOT_PARENT="${d}"
    render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "vision" "www.apple.com:443" "${XRAY_CONF}" || return 1
    local snap1 snap2
    snap1="$(snapshot_create)" || return 1
    snap2="$(snapshot_create)" || return 1
    # Same-second snapshots get a numeric suffix; the later one must win,
    # even though a plain "ls -d .../" name sort would put the no-suffix
    # name first ("/" sorts above "-").
    [[ "$(latest_snapshot)" == "${snap2}/" ]] || return 1
    # mtime wins over name: make the older-named snapshot newer.
    touch -d "2030-01-01 00:00:00" "${snap1}" || return 1
    [[ "$(latest_snapshot)" == "${snap1}/" ]] || return 1
    touch -d "2031-01-01 00:00:00" "${snap2}" || return 1
    [[ "$(latest_snapshot)" == "${snap2}/" ]] || return 1
    return 0
}

t_snapshot_known_good_prune() {
    local d="${SANDBOX}/known-good"
    mkdir -p "${d}"
    SNAPSHOT_PARENT="${d}"
    render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "vision" "www.apple.com:443" "${XRAY_CONF}" || return 1
    # snapshot_create prunes to SNAPSHOT_KEEP on every call, so keep 5
    # during creation, then restore 3 for the prune under test.
    local s1 s2 s3 s4 s5
    SNAPSHOT_KEEP=5
    s1="$(snapshot_create)" || return 1
    sleep 1
    s2="$(snapshot_create)" || return 1
    sleep 1
    s3="$(snapshot_create)" || return 1
    sleep 1
    s4="$(snapshot_create)" || return 1
    sleep 1
    s5="$(snapshot_create)" || return 1
    SNAPSHOT_KEEP=3
    # Mark the oldest as known-good (post-change verified, per main-chat decision).
    snapshot_mark_known_good "${s1}" || return 1
    [[ "$(snapshot_known_good)" == "${s1}" ]] || return 1
    snapshot_prune || return 1
    # Newest 3 + marked oldest survive; the 4th (s2) is pruned.
    [[ -d "${s1}" ]] || return 1
    [[ -d "${s3}" ]] || return 1
    [[ -d "${s4}" ]] || return 1
    [[ -d "${s5}" ]] || return 1
    [[ ! -d "${s2}" ]] || return 1
    return 0
}

t_diag_restore_offer() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/diagnose.sh"
    # Setup: a valid config plus one snapshot.
    render_config "PLACEHOLDER-UUID" "PLACEHOLDER-SID" "PLACEHOLDER-PRIVATE-KEY" \
        "sni.example" "443" "vision" "www.apple.com:443" "${XRAY_CONF}" || return 1
    local snap out
    snap="$(snapshot_create)" || return 1
    # No-snapshot case: prints the fact, does not restore anything.
    local empty_parent="${SANDBOX}/no-snaps"
    mkdir -p "${empty_parent}"
    SNAPSHOT_PARENT="${empty_parent}" diagnose_restore_offer >/dev/null 2>&1 || true
    out="$(SNAPSHOT_PARENT="${empty_parent}" diagnose_restore_offer 2>&1)" || true
    printf '%s' "${out}" | grep -q "no snapshot available" || return 1
    # With a snapshot and the test flag, restore is exercised and the
    # config test after restore is reported OK.
    out="$(XRAY_TEST_DIAG_RESTORE=1 diagnose_restore_offer 2>&1)" || return 1
    printf '%s' "${out}" | grep -q "${snap}" || return 1
    printf '%s' "${out}" | grep -q "config test OK after restore" || return 1
    # Non-interactive main run must NOT auto-restore: break the config,
    # run diagnose with stdin closed, and assert the config is still
    # broken but the restore option was printed.
    printf 'not json' > "${XRAY_CONF}"
    out="$(bash "${REPO_ROOT}/diagnose.sh" </dev/null 2>&1)" || true
    printf '%s' "${out}" | grep -q "Restore option:" || return 1
    printf '%s' "${out}" | grep -q "latest snapshot:" || return 1
    grep -q "not json" "${XRAY_CONF}" || return 1
    return 0
}

t_sni_precheck() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/lib/node.sh"
    local fakebin="${SANDBOX}/sni-fakebin"
    mkdir -p "${fakebin}"
    cat > "${fakebin}/getent" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "hosts" ]]; then
    printf '%s %s\n' "${FAKE_DNS_IP:-93.184.216.34}" "$2"
    exit 0
fi
exit 1
EOF
    cat > "${fakebin}/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod 755 "${fakebin}/getent" "${fakebin}/curl"
    local out rc
    # Camouflage: DNS to this machine is NOT required, SNI != dest is
    # a note, and the precheck never hard-blocks.
    out="$(PATH="${fakebin}:${PATH}" sni_precheck "sni.example" "www.apple.com:443" "camouflage" "" 2>&1)"; rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    printf '%s' "${out}" | grep -q "not required to resolve to this VPS" || return 1
    printf '%s' "${out}" | grep -q "differs from dest host" || return 1
    # Own domain, resolves to this machine: pass note.
    out="$(PATH="${fakebin}:${PATH}" FAKE_DNS_IP=203.0.113.99 sni_precheck "own.example" "www.apple.com:443" "own" "203.0.113.99" 2>&1)"; rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    printf '%s' "${out}" | grep -q "resolves to this machine" || return 1
    # Own domain, resolves elsewhere: WARN only, still returns 0
    # (warn-only contract: the caller asks the user, it does not block).
    out="$(PATH="${fakebin}:${PATH}" FAKE_DNS_IP=198.51.100.7 sni_precheck "own.example" "www.apple.com:443" "own" "203.0.113.99" 2>&1)"; rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    printf '%s' "${out}" | grep -q "does not resolve to this machine" || return 1
    # IP SNI: warned, still warn-only.
    out="$(PATH="${fakebin}:${PATH}" sni_precheck "203.0.113.10" "www.apple.com:443" "camouflage" "" 2>&1)"; rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    printf '%s' "${out}" | grep -q "looks like an IP" || return 1
    return 0
}

t_logrotate_smart_install_present() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/install.sh"
    local d="${SANDBOX}/logrotate-smart-present"
    mkdir -p "${d}/bin" "${d}/lr"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${d}/bin/logrotate"
    chmod +x "${d}/bin/logrotate"
    export PATH="${d}/bin:${PATH}"
    export LOGROTATE_DIR="${d}/lr"
    unset LOGROTATE_TEST_APT_CMD
    install_logrotate_config || return 1
    [[ -f "${d}/lr/xray-reality-manager" ]] || return 1
    grep -q "copytruncate" "${d}/lr/xray-reality-manager" || return 1
    grep -q "rotate 7" "${d}/lr/xray-reality-manager" || return 1
    return 0
}

t_logrotate_smart_install_apt_success() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/install.sh"
    local d="${SANDBOX}/logrotate-smart-apt-ok"
    mkdir -p "${d}/bin" "${d}/lr"
    export LOGROTATE_FAKE_BIN="${d}/bin"
    export LOGROTATE_FAKE_APT_LOG="${d}/apt.log"
    printf '#!/usr/bin/env bash\nprintf "apt-invoked\\n" >> "${LOGROTATE_FAKE_APT_LOG}"\nprintf "#!/usr/bin/env bash\\nexit 0\\n" > "${LOGROTATE_FAKE_BIN}/logrotate"\nchmod +x "${LOGROTATE_FAKE_BIN}/logrotate"\nexit 0\n' > "${d}/fake-apt"
    chmod +x "${d}/fake-apt"
    export PATH="${d}/bin:${PATH}"
    export LOGROTATE_DIR="${d}/lr"
    export LOGROTATE_TEST_APT_CMD="${d}/fake-apt"
    local out
    out="$(install_logrotate_config 2>&1)" || return 1
    printf '%s' "${out}" | grep -q "机器上没有 logrotate，现在帮你装一个" || return 1
    [[ -f "${d}/apt.log" ]] || return 1
    [[ -f "${d}/lr/xray-reality-manager" ]] || return 1
    grep -q "copytruncate" "${d}/lr/xray-reality-manager" || return 1
    return 0
}

t_logrotate_smart_install_apt_failure() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/install.sh"
    local d="${SANDBOX}/logrotate-smart-apt-fail"
    mkdir -p "${d}/bin" "${d}/lr"
    export LOGROTATE_FAKE_APT_LOG="${d}/apt.log"
    printf '#!/usr/bin/env bash\nprintf "apt-invoked\\n" >> "${LOGROTATE_FAKE_APT_LOG}"\nexit 1\n' > "${d}/fake-apt"
    chmod +x "${d}/fake-apt"
    export PATH="${d}/bin:${PATH}"
    export LOGROTATE_DIR="${d}/lr"
    export LOGROTATE_TEST_APT_CMD="${d}/fake-apt"
    local out rc
    out="$(install_logrotate_config 2>&1)"; rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
    [[ -f "${d}/apt.log" ]] || return 1
    [[ ! -f "${d}/lr/xray-reality-manager" ]] || return 1
    printf '%s' "${out}" | grep -q "install failed" || return 1
    return 0
}

t_logrotate_test_mode_no_real_apt() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/install.sh"
    local d="${SANDBOX}/logrotate-smart-no-apt"
    mkdir -p "${d}/bin" "${d}/lr"
    export LOGROTATE_FAKE_APT_LOG="${d}/apt.log"
    printf '#!/usr/bin/env bash\nprintf "apt-invoked\\n" >> "${LOGROTATE_FAKE_APT_LOG}"\nexit 0\n' > "${d}/bin/apt-get"
    chmod +x "${d}/bin/apt-get"
    export PATH="${d}/bin:${PATH}"
    export LOGROTATE_DIR="${d}/lr"
    unset LOGROTATE_TEST_APT_CMD
    # XRAY_TEST_MODE=1 is already exported by the suite: the function
    # must never invoke apt-get (real or fake) in this mode without
    # an explicit test-apt injection.
    install_logrotate_config || return 1
    [[ ! -f "${d}/apt.log" ]] || return 1
    return 0
}

t_test_sandbox_isolation() {
    # Guard, run last: no test may have written to the real system
    # logrotate dir. Install-path tests must have written to the
    # sandbox instead, and the real file (if any) must be exactly
    # as it was when the suite started. A formal install after the
    # suite is a separate, expected step and is not covered here.
    [[ "${LOGROTATE_DIR}" == "${SANDBOX}"/* ]] || return 1
    [[ -f "${SANDBOX}/logrotate.d/xray-reality-manager" ]] || return 1
    if [[ "${TEST_START_LOGROTATE_HASH}" == "absent" ]]; then
        [[ ! -f "${REAL_LOGROTATE_FILE}" ]] || return 1
    else
        [[ -f "${REAL_LOGROTATE_FILE}" ]] || return 1
        [[ "$(sha256sum "${REAL_LOGROTATE_FILE}" | cut -d' ' -f1)" == "${TEST_START_LOGROTATE_HASH}" ]] || return 1
    fi
    return 0
}


t_hy2_link_and_guard() {
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/manage.sh"
    local tmp link out d
    tmp="$(mktemp -d)"
    export HY2_BIN="${tmp}/bin/hysteria"
    export HY2_CONF_DIR="${tmp}/etc/hysteria"
    export HY2_CONF="${HY2_CONF_DIR}/config.yaml"
    export HY2_UNIT_DIR="${tmp}/units"
    export HY2_UNIT="${HY2_UNIT_DIR}/hysteria-server.service"
    export HY2_MARKER="${HY2_CONF_DIR}/.managed-by-hy2addon"
    export HY2_SNAPSHOT_PARENT="${tmp}/snapshots"
    export HY2_PORT=443
    export HY2_SNI=www.bing.com

    # Link shape for V2rayNG: hysteria2://<pw>@<ip>:<port>/?sni=..&pinSHA256=<hex>
    link="$(hy2_build_link 'pa+ss/word' '203.0.113.10' 'abc123')"
    printf '%s' "${link}" | grep -q '^hysteria2://' || return 1
    printf '%s' "${link}" | grep -q '@203.0.113.10:443/' || return 1
    printf '%s' "${link}" | grep -q 'sni=www.bing.com' || return 1
    printf '%s' "${link}" | grep -q 'pinSHA256=abc123' || return 1
    printf '%s' "${link}" | grep -q 'pa%2Bss%2Fword' || return 1

    # A foreign /etc/hysteria (no marker) must be refused, never overwritten.
    mkdir -p "${HY2_CONF_DIR}"
    out="$(hy2_preflight 2>&1)" && return 1
    printf '%s' "${out}" | grep -q '拒绝覆盖' || return 1

    # With our marker the same dir is ours and preflight passes.
    : > "${HY2_MARKER}"
    hy2_preflight >/dev/null 2>&1 || return 1

    # HY2 snapshots live in their own namespace, never with xray ones.
    mkdir -p "${HY2_SNAPSHOT_PARENT}"
    d="$(hy2_snapshot_create 2>/dev/null)"
    printf '%s' "${d}" | grep -q '/hy2-backup-' || return 1
    [[ -d "${d}" ]] || return 1
    hy2_snapshot_list | grep -q 'hy2-backup-' || return 1

    unset HY2_BIN HY2_CONF_DIR HY2_CONF HY2_UNIT_DIR HY2_UNIT HY2_MARKER HY2_SNAPSHOT_PARENT
    return 0
}

run_test t_version
run_test t_dgst
run_test t_urlencode
run_test t_config_render
run_test t_share_link
run_test t_backup
run_test t_launcher
run_test t_menu_smoke
run_test t_hy2_link_and_guard
run_test t_banner_top_align
run_test t_diagnose_nocore
run_test t_diagnose_mocked
run_test t_upgrade_rollback
run_test t_perm
run_test t_node_auto
run_test t_node_sni
run_test t_archive_xray
run_test t_keypair_formats
run_test t_env_check_debian12
run_test t_install_completion
run_test t_service_display_state
run_test t_install_repair
run_test t_menu_install_upgrade
run_test t_menu_auth_test
run_test t_firewall
run_test t_logrotate_and_rotated_log
run_test t_loopback_optin
run_test t_loopback_client_config_generation
run_test t_status_enrichment
run_test t_ip_display
run_test t_detect_public_ip
run_test t_check_update_readme
run_test t_install_repair_fail
run_test t_install_auto_no_repair
run_test t_verify_listening
run_test t_wait_for_listening
run_test t_bbr_joeyblog_rc_filter
run_test t_bbr_module_version_blank
run_test t_bbr_check_env_debian12_only
run_test t_bbr3_fq_rollback
run_test t_bbr_version_status
run_test t_bbr_clear
run_test t_bbr3_already_v3
run_test t_bbr3_installed_not_running
run_test t_bbr3_install_from_stock
run_test t_bbr_oneshot_created_on_install
run_test t_bbr_oneshot_auto_fq_v3
run_test t_bbr_oneshot_skips_non_v3
run_test t_bbr_oneshot_fq_failure_no_leftover
run_test t_bbr_oneshot_rollback_and_clear_remove
run_test t_bbr3_manual_confirm_unchanged
run_test t_bbr_menu_smoke
run_test t_test_override_production
run_test t_node_apply_rollback
run_test t_snapshot_latest_order
run_test t_snapshot_known_good_prune
run_test t_diag_restore_offer
run_test t_sni_precheck
run_test t_logrotate_smart_install_present
run_test t_logrotate_smart_install_apt_success
run_test t_logrotate_smart_install_apt_failure
run_test t_logrotate_test_mode_no_real_apt
run_test t_test_sandbox_isolation

printf '================================\n'
printf 'Tests: %s passed, %s failed, %s skipped\n' "${PASS_COUNT}" "${FAIL_COUNT}" "${SKIP_COUNT}"
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
exit 0
