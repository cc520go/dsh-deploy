#!/usr/bin/env bash
#
# lib/node.sh — node parameter generation, config rendering, config test,
# share-link building, and the operator's local parameter file for
# DSH.
#
# Security rule: NOTHING in this library prints a real secret. The share
# link is printed to stdout only (the operator copies it into their own
# client); masked summaries never include uuid/keys. The parameter file
# lives on the server only (root-only, 600), never in the repo.

_NDLIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck disable=SC1091
source "${_NDLIB_DIR}/common.sh"

# ------------------------------------------------------- param generation ----
# gen_uuid: kernel random UUID, with a /dev/urandom fallback that sets the
# version (4) and variant (10xx) bits.
gen_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
        return 0
    fi
    local b
    b="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s-%s-4%s-%s-%s\n' "${b:0:8}" "${b:8:4}" "${b:13:3}" \
        "$(printf 'a%s' "${b:17:3}")" "${b:20:12}"
}

# gen_shortid: 8 lowercase hex chars (Reality shortId, 0-16 hex chars).
gen_shortid() {
    od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
}

# gen_keypair: prints "<private> <public>" (one line) via `xray x25519`.
# The caller keeps these out of logs; only the public key goes in links.
# Output format changed across releases, so accept both:
#   new (26.10.21, verified against the real binary): "PrivateKey: <priv>"
#     and "Password (PublicKey): <pub>" (plus an unused "Hash32:" line)
#   old: "Private key: <priv>" and "Public key: <pub>" (with spaces)
gen_keypair() {
    local out priv pub
    out="$("${XRAY_BIN}" x25519 2>/dev/null)" || { die "failed to generate Reality keypair (is the xray binary present?)"; return 1; }
    priv="$(printf '%s' "${out}" | grep -iE -m1 'private[ ]?key' | awk '{print $NF}')"
    pub="$(printf '%s' "${out}" | grep -iE -m1 'public[ ]?key' | awk '{print $NF}')"
    if [[ -z "${priv}" || -z "${pub}" ]]; then
        die "could not parse Reality keypair from xray x25519 output."
        return 1
    fi
    printf '%s %s' "${priv}" "${pub}"
}

# --------------------------------------------------------- params file ----
# The operator's own parameter file: KEY=VALUE lines, root-only 600.
# It lives on the server only and is NEVER committed to the repo.
write_node_params() {
    # args: uuid private_key public_key shortid host port sni dest flow
    local dir
    dir="$(dirname "${NODE_PARAMS_FILE}")"
    mkdir -p "${dir}" || { die "cannot create params dir: ${dir}"; return 1; }
    chmod 700 "${dir}" || true
    {
        printf 'uuid=%s\n' "$1"
        printf 'private_key=%s\n' "$2"
        printf 'public_key=%s\n' "$3"
        printf 'shortid=%s\n' "$4"
        printf 'host=%s\n' "$5"
        printf 'port=%s\n' "$6"
        printf 'sni=%s\n' "$7"
        printf 'dest=%s\n' "$8"
        printf 'flow=%s\n' "$9"
    } > "${NODE_PARAMS_FILE}" || { die "cannot write params file"; return 1; }
    chmod 600 "${NODE_PARAMS_FILE}" || true
    return 0
}

# read_node_param <key>: prints the value (stdout) or nothing.
read_node_param() {
    local key="$1"
    [[ -f "${NODE_PARAMS_FILE}" ]] || return 0
    grep "^${key}=" "${NODE_PARAMS_FILE}" 2>/dev/null | cut -d'=' -f2- | head -1
}

# ------------------------------------------------------- config rendering ----
# render_config <uuid> <shortid> <privatekey> <servernames-csv> <port>
#               <flow: vision|none> <dest> <outfile>
# Writes the server config JSON. Vision adds flow xtls-rprx-vision on the
# inbound client; the no-Vision variant omits flow entirely (it is a
# separate troubleshooting config and must never silently replace the
# main node — callers keep it in a separate file).
render_config() {
    local uuid="$1" shortid="$2" privkey="$3" servernames_csv="$4"
    local port="$5" flow="$6" dest="$7" outfile="$8"
    # Reality dest must be host:port — a bare domain makes Xray fail
    # with "please fill in a valid value for target". Fail here, before
    # writing anything, instead of producing an invalid config.
    if [[ "${dest}" != *":"* ]]; then die "reality dest must include a port, e.g. www.apple.com:443 (got: ${dest})"; return 1; fi
    local names_json="" name flow_line=""
    local oldifs="$IFS"
    IFS=',' read -r -a _names <<< "${servernames_csv}"
    IFS="${oldifs}"
    local n
    for n in "${_names[@]}"; do
        n="$(printf '%s' "${n}" | tr -d '[:space:]')"
        [[ -n "${n}" ]] || continue
        if [[ -n "${names_json}" ]]; then names_json+=", "; fi
        names_json+="\"${n}\""
    done
    if [[ "${flow}" == "vision" ]]; then
        flow_line=', "flow": "xtls-rprx-vision"'
    fi
    cat > "${outfile}" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${XRAY_LOG_DIR}/access.log",
    "error": "${XRAY_LOG_DIR}/error.log"
  },
  "inbounds": [
    {
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"${flow_line}
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest}",
          "xver": 0,
          "serverNames": [${names_json}],
          "privateKey": "${privkey}",
          "shortIds": ["${shortid}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF
    return 0
}

# config_test <file>: runs `xray run -test`. On failure prints the tail
# of the output plus recovery steps and returns 1. Never restarts on
# a failed test — callers must honour the return code.
config_test() {
    local file="$1" out
    out="$("${XRAY_BIN}" run -test -config "${file}" 2>&1)"
    local rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        log_info "config test passed: ${file}"
        return 0
    fi
    log_error "config test FAILED: ${file}"
    printf '%s\n' "${out}" | tail -20 >&2
    printf 'Recovery: fix the config, or restore the last snapshot with the backup menu (option 6), then re-run the config test.\n' >&2
    return 1
}

# ------------------------------------------------------------ share link ----
# build_share_link <uuid> <host> <port> <flow: vision|none> <sni> <pbk>
#                  <sid> <name>: prints the vless:// link (stdout ONLY).
# The private key is never an argument and never appears in the link.
build_share_link() {
    local uuid="$1" host="$2" port="$3" flow="$4" sni="$5" pbk="$6" sid="$7" name="$8"
    local link="vless://${uuid}@${host}:${port}?encryption=none"
    if [[ "${flow}" == "vision" ]]; then
        link+="&flow=xtls-rprx-vision"
    fi
    link+="&security=reality"
    link+="&sni=$(url_encode "${sni}")"
    link+="&fp=chrome"
    link+="&pbk=$(url_encode "${pbk}")"
    link+="&sid=$(url_encode "${sid}")"
    link+="&type=tcp"
    link+="#$(url_encode "${name}")"
    printf '%s' "${link}"
}

# masked_summary <host> <port> <flow> <sni> <dest>: prints a summary with
# NO secret material (no uuid, no keys, no link).
masked_summary() {
    printf 'host: %s\n' "$1"
    printf 'port: %s\n' "$2"
    printf 'flow: %s\n' "$3"
    printf 'security: reality\n'
    printf 'sni: %s\n' "$4"
    printf 'dest: %s\n' "$5"
    printf 'type: tcp\n'
    printf '(uuid/keys live only in the root-only params file and are never printed here.)\n'
}

# ------------------------------------------------------ JSON extraction ----
# validate_sni <domain>: rejects empty, IP addresses, and malformed domains.
# An IP SNI breaks the Reality handshake (the certificate carries no IP
# SANs, so the client fails X.509 validation) — this was a real failure
# on the live node, so the tool must never accept an IP SNI again.
validate_sni() {
    local sni="$1"
    if [[ -z "${sni}" ]]; then
        die "SNI must not be empty (default www.apple.com)."
        return 1
    fi
    if [[ "${sni}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "SNI must be a domain, not an IP address (${sni}): an IP SNI breaks the Reality handshake (certificate has no IP SANs)."
        return 1
    fi
    if [[ "${sni}" == *:* ]]; then
        die "SNI must be a domain, not an IP address (${sni})."
        return 1
    fi
    if [[ ! "${sni}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]; then
        die "invalid SNI domain: ${sni} (expected a domain like www.apple.com)."
        return 1
    fi
    return 0
}
# sni_precheck <sni> <dest> [kind] [local_ip]: non-destructive,
# warn-only precheck before an SNI change. It NEVER hard-blocks: it
# always returns 0, prints warnings, and lets the caller (which asks
# for confirmation next) decide whether to continue. It never prints
# secrets, never changes config, and starts no resident service.
# Two cases, deliberately different (do NOT copy the "DNS must point
# to this machine" rule from one case to the other):
#   kind=camouflage (default, Reality camouflage SNI such as
#   www.apple.com): check domain format (not an IP), DNS resolution
#   of the SNI itself, and a TLS probe of the DEST host. Do NOT
#   require the camouflage domain to resolve to this VPS: a camouflage
#   domain is supposed to point at the dest site, not at this machine.
#   If SNI differs from the dest host, print a note (Reality camouflage
#   usually matches dest) but do not block.
#   kind=own (the operator's own domain, to be used for a certificate
#   or a site): check DNS resolution of the domain AND whether it
#   resolves to local_ip. Only in this case is "resolves to this
#   machine" the right check. If local_ip is unknown, say so and ask
#   for a manual check instead of failing.
sni_precheck() {
    local sni="$1" dest="${2:-}" kind="${3:-camouflage}" local_ip="${4:-}"
    local dest_host="${dest%%:*}"
    if [[ -z "${sni}" ]]; then
        printf '[WARN] SNI precheck: empty SNI; skipping precheck (validation will reject it).\n' >&2
        return 0
    fi
    if [[ "${sni}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "${sni}" == *:* ]]; then
        printf '[WARN] SNI precheck: SNI looks like an IP (%s); an IP SNI breaks the Reality handshake.\n' "${sni}" >&2
        return 0
    fi
    # DNS lookup for the SNI itself (best-effort; missing getent = skip).
    local dns_out=""
    if command -v getent >/dev/null 2>&1; then
        dns_out="$(getent hosts "${sni}" 2>/dev/null | head -1 || true)"
        if [[ -z "${dns_out}" ]]; then
            printf '[WARN] SNI precheck: SNI domain %s does not resolve (DNS lookup failed); continuing may break the handshake.\n' "${sni}" >&2
        else
            printf '[INFO] SNI precheck: SNI %s resolves to %s.\n' "${sni}" "$(printf '%s' "${dns_out}" | awk '{print $1}')" >&2
        fi
    else
        printf '[INFO] SNI precheck: getent not available; DNS check skipped, check manually.\n' >&2
    fi
    if [[ "${kind}" == "own" ]]; then
        # Only here is "resolves to this machine" the right check.
        if [[ -z "${local_ip}" ]]; then
            printf '[WARN] SNI precheck (own domain): local public IP unknown; cannot verify %s resolves to this machine, check manually.\n' "${sni}" >&2
        elif [[ -n "${dns_out}" ]] && printf '%s' "${dns_out}" | grep -qw "${local_ip}"; then
            printf '[INFO] SNI precheck (own domain): %s resolves to this machine (%s).\n' "${sni}" "${local_ip}" >&2
        else
            printf '[WARN] SNI precheck (own domain): %s does not resolve to this machine (%s); a certificate/site using it may fail.\n' "${sni}" "${local_ip}" >&2
        fi
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL --max-time 10 "https://${sni}/" -o /dev/null 2>/dev/null; then
                printf '[INFO] SNI precheck (own domain): TLS probe to %s succeeded.\n' "${sni}" >&2
            else
                printf '[WARN] SNI precheck (own domain): TLS probe to %s failed; check the domain and certificate.\n' "${sni}" >&2
            fi
        else
            printf '[INFO] SNI precheck (own domain): curl not available; TLS check skipped, check manually.\n' >&2
        fi
        return 0
    fi
    # Camouflage case: do NOT require DNS to point at this machine.
    printf '[INFO] SNI precheck (camouflage): %s is not required to resolve to this VPS; the camouflage domain should point at the dest site, not at this machine.\n' "${sni}" >&2
    if [[ -n "${dest_host}" && "${sni}" != "${dest_host}" ]]; then
        printf '[WARN] SNI precheck (camouflage): SNI %s differs from dest host %s; Reality camouflage usually matches dest, confirm this is intentional.\n' "${sni}" "${dest_host}" >&2
    fi
    if [[ -n "${dest_host}" ]]; then
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL --max-time 10 "https://${dest_host}/" -o /dev/null 2>/dev/null; then
                printf '[INFO] SNI precheck (camouflage): TLS probe to dest %s succeeded.\n' "${dest_host}" >&2
            else
                printf '[WARN] SNI precheck (camouflage): TLS probe to dest %s failed; check the dest site.\n' "${dest_host}" >&2
            fi
        else
            printf '[INFO] SNI precheck (camouflage): curl not available; dest TLS check skipped, check manually.\n' >&2
        fi
    fi
    return 0
}

# json_array_values <file> <key>: prints the string values of a JSON
# array, one per line, handling arrays that span multiple lines (the
# single-line-grep approach fails on these — this was a real bug in the
# previous draft). Example: serverNames / shortIds in a rendered config.
json_array_values() {
    local file="$1" key="$2"
    awk -v k="${key}" '
        BEGIN { in_arr = 0 }
        {
            if (!in_arr && index($0, "\"" k "\"")) {
                in_arr = 1
                sub(/^[^[]*\[/, "")
            }
            if (in_arr) {
                while (match($0, /"[^"]*"/)) {
                    print substr($0, RSTART + 1, RLENGTH - 2)
                    $0 = substr($0, RSTART + RLENGTH)
                }
                if (/\]/) { exit }
            }
        }
    ' "${file}"
}
