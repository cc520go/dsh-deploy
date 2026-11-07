#!/usr/bin/env bash
#
# lib/download.sh — download + official .dgst verification + official
# installer wrapping for DSH.
#
# Design rule: this tool downloads a core zip AND its .dgst into a temp
# dir and verifies ALL FOUR digests itself BEFORE invoking the official
# installer. The official installer in local-file mode only warns (and
# continues) when a .dgst is missing; our pre-verification makes that gap
# unreachable. Any missing digest line, missing tool, or mismatch is a
# HARD failure — never warn-and-continue.
#
# The official installer script itself has no published checksum. It is
# fetched over TLS and sanity-checked (size + marker strings); this is
# honestly documented as TLS + sanity, NOT signature verification,
# UNLESS a pinned hash below has been set (see fetch_installer):
# when a real pinned SHA-256 is set, a mismatch is a HARD failure.
#
# Pinned installer (pinned 2026-11-04, C's main-chat yes to close
# this item; commit and hash verified from the official repo, not
# invented: commit is the XTLS/Xray-install main HEAD at pin time,
# hash is the SHA-256 of install-release.sh at that commit, and the
# main-branch file matched the pinned-commit file byte for byte):
#   INSTALLER_PINNED_COMMIT / INSTALLER_PINNED_SHA256, or the
#   XRAY_INSTALLER_SHA256 environment override for testing.
# When the pinned hash is still PLACEHOLDER, fetch_installer logs a
# clear warning and falls back to TLS + sanity only; it does not
# pretend to be pinned. README documents how to update these values
# when changing the installer version.

_DDLIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "${_DDLIB_DIR}/common.sh"

INSTALLER_URL_DEFAULT="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
INSTALLER_PINNED_COMMIT="04e6f3bd9534811ed901a48c47b2c042dd64eb3a"
INSTALLER_PINNED_SHA256="934ecb26ded1089f849ac238d5170f1159fe4b6ca300d4f1e67730bd41fe58cf"

# download_file <url> <dest>: curl (preferred) or wget, TLS verification
# always on. Never --no-check-certificate, never curl|bash.
download_file() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 -o "${dest}" "${url}" || { die "download failed: ${url}"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${dest}" "${url}" || { die "download failed: ${url}"; return 1; }
    else
        die "neither curl nor wget is available"
        return 1
    fi
    return 0
}

# dgst_value <dgst-file> <KEY>: extracts one digest value from a .dgst
# file. Current official format (verified against the real 26.10.21
# release asset) is lines like "SHA2-256= <hex>" and "SHA2-512= <hex>";
# older spellings "SHA256 = <hex>" / "SHA512 = <hex>" and a "KEY: <hex>"
# spelling are also accepted. Prints the hex value (stdout) or nothing
# when absent.
dgst_value() {
    local dgst_file="$1" key="$2"
    # NOTE: pat is assigned in a separate statement on purpose. In a
    # single `local a=... b=$a` list, $a expands before the local
    # assignment takes effect, so pat would pick up the caller's $key
    # (or empty) instead of this function's key.
    local pat="${key}"
    # The SHA families changed labels across releases: accept both the
    # plain label (SHA256/SHA512) and the hyphenated one (SHA2-256/
    # SHA2-512). The value is always verified against a computed hash,
    # so accepting label variants cannot weaken the check.
    case "${key}" in
        SHA256) pat='SHA2?-?256' ;;
        SHA512) pat='SHA2?-?512' ;;
    esac
    grep -iE "^[[:space:]]*${pat}[[:space:]]*[:=]" "${dgst_file}" 2>/dev/null | head -1 \
        | sed -E 's/^[^:=]+[:=][[:space:]]*([0-9a-fA-F]+).*/\1/'
}

# verify_dgst <file> <dgst-file>: hard-fails when the .dgst is missing,
# any of the four digest lines is missing, any digest tool is missing,
# or any digest mismatches.
verify_dgst() {
    local file="$1" dgst_file="$2"
    local key tool expected actual
    if [[ ! -f "${dgst_file}" ]]; then
        die "checksum file missing: ${dgst_file} — refusing to install unverified code."
        return 1
    fi
    for key in MD5 SHA1 SHA256 SHA512; do
        case "${key}" in
            MD5)    tool="md5sum" ;;
            SHA1)   tool="sha1sum" ;;
            SHA256) tool="sha256sum" ;;
            SHA512) tool="sha512sum" ;;
        esac
        command -v "${tool}" >/dev/null 2>&1 || { die "missing checksum tool: ${tool}"; return 1; }
        expected="$(dgst_value "${dgst_file}" "${key}")"
        if [[ -z "${expected}" ]]; then
            die "checksum file ${dgst_file} has no ${key} line — refusing to install."
            return 1
        fi
        actual="$("${tool}" "${file}" | cut -d' ' -f1)"
        if [[ "${actual,,}" != "${expected,,}" ]]; then
            die "${key} mismatch for ${file} (expected ${expected}, got ${actual})."
            return 1
        fi
    done
    log_info "checksum OK: all four digests match (${file})."
    return 0
}

# archive_has_xray <zip>: returns 0 when `unzip -l` lists a file named
# exactly `xray` (top-level or nested). The name is the LAST field of each
# listing line, so a top-level entry is preceded by whitespace (the
# length/date/time columns) and a nested entry by a slash. A previous
# pattern `(^|/)xray$` missed the whitespace case, so it rejected every
# real release zip (whose xray is top-level) — regression test t_archive_xray.
archive_has_xray() {
    unzip -l "$1" 2>/dev/null | grep -qE '(^|[[:space:]/])xray$'
}

# download_core <version> <arch-suffix> <dest-dir>: downloads the official
# zip + .dgst, verifies all four digests, and checks the zip actually
# contains an xray binary. Prints the zip path (stdout).
download_core() {
    local ver arch destdir tag zip_name zip_url dgst_url zip_path dgst_path
    ver="$(normalize_version "$1")" || return 1
    arch="$2"
    destdir="$3"
    tag="v${ver}"
    zip_name="Xray-${arch}.zip"
    zip_url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${zip_name}"
    dgst_url="${zip_url}.dgst"
    zip_path="${destdir}/${zip_name}"
    dgst_path="${destdir}/${zip_name}.dgst"
    log_info "downloading ${zip_name} (${tag}) ..."
    download_file "${zip_url}" "${zip_path}" || return 1
    log_info "downloading ${zip_name}.dgst ..."
    download_file "${dgst_url}" "${dgst_path}" || return 1
    verify_dgst "${zip_path}" "${dgst_path}" || return 1
    if ! archive_has_xray "${zip_path}"; then
        die "downloaded archive does not contain an xray binary: ${zip_path}"
        return 1
    fi
    printf '%s' "${zip_path}"
    return 0
}

# fetch_installer <dest>: downloads the official installer over TLS and
# sanity-checks it (non-trivial size + marker strings). This is TLS +
# sanity, NOT signature verification — the installer has no published
# checksum, and this function never claims otherwise — UNLESS a pinned
# SHA-256 is set: then a mismatch is a HARD failure and the installer
# is never executed. The pinned commit (when real) selects the raw URL;
# the placeholder commit keeps the default main-branch URL.
fetch_installer() {
    local dest="$1" size pinned_hash actual
    local url="${XRAY_INSTALLER_URL:-${INSTALLER_URL_DEFAULT}}"
    if [[ "${INSTALLER_PINNED_COMMIT}" != "PLACEHOLDER" ]]; then
        url="https://github.com/XTLS/Xray-install/raw/${INSTALLER_PINNED_COMMIT}/install-release.sh"
    fi
    pinned_hash="${XRAY_INSTALLER_SHA256:-${INSTALLER_PINNED_SHA256}}"
    log_info "downloading official installer ..."
    download_file "${url}" "${dest}" || return 1
    size="$(wc -c < "${dest}" | tr -d ' ')"
    if [[ "${size}" -lt 5000 ]]; then
        die "downloaded installer looks truncated (${size} bytes)."
        return 1
    fi
    if ! grep -qi "xray" "${dest}" || ! grep -qi "install" "${dest}"; then
        die "downloaded installer failed sanity check (marker strings missing)."
        return 1
    fi
    if [[ "${pinned_hash}" != "PLACEHOLDER" && -n "${pinned_hash}" ]]; then
        actual="$(sha256sum "${dest}" 2>/dev/null | awk '{print $1}')"
        if [[ "${actual}" != "${pinned_hash}" ]]; then
            die "installer hash mismatch: expected pinned SHA-256, refusing to run it."
            return 1
        fi
        log_info "installer pinned hash verified (${size} bytes)."
    else
        log_info "installer hash NOT pinned yet (placeholder); TLS + sanity only."
    fi
    printf '%s' "${dest}"
    return 0
}

# install_with_official <installer> <zip>: runs the official installer in
# local mode against an already-verified zip. Deliberately does NOT pass
# -u root: the service must run as the official low-privilege xray user.
# NOTE: --version and --reinstall are mutually exclusive in the official
# installer; local installs do not take a version flag (the zip itself
# determines the version), so neither is passed here.
install_with_official() {
    local installer="$1" zip="$2"
    log_info "running official installer (local mode, xray user) ..."
    bash "${installer}" install --local "${zip}" || { die "official installer failed."; return 1; }
    return 0
}
