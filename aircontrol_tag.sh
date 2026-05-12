#!/bin/bash
#
# aircontrol_tag.sh
#
# Tags a device in Ubiquiti AirControl2 with "DHCP" tag and prepends
# "DHCP" to its description via the AC2 REST API.
#
# API endpoints used (from /api/v1/documentation/airControl.yaml):
#   POST /api/v1/login                     - authenticate
#   GET  /api/v1/devices/mac/{mac}         - find device by MAC
#   POST /api/v1/devices/basic-properties  - get current properties
#   PATCH /api/v1/devices/basic-properties - update tag + description
#
# Usage:
#   ./aircontrol_tag.sh --mac <MAC> --ac-host <HOST> [--ac-port <PORT>]
#                       [--ac-login <USER>] [--ac-pass <PASS>] [--ac-proto https]
#
#   --macs <MAC,MAC,...>   process multiple MACs in one session
#   --mode test            only test connection
#

set -o pipefail

CREDS_DIR="/var/www/.config/airos-to-dhcp"
CREDS_FILE="${CREDS_DIR}/aircontrol_creds"
AC_HOST=""
AC_PORT="9082"
AC_LOGIN=""
AC_PASS=""
AC_PROTO="https"
MACS=""
MODE="tag"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mac|-mac)           MACS="$2";      shift 2 ;;
        --macs|-macs)         MACS="$2";      shift 2 ;;
        --ac-host|-ac-host)   AC_HOST="$2";   shift 2 ;;
        --ac-port|-ac-port)   AC_PORT="$2";   shift 2 ;;
        --ac-login|-ac-login) AC_LOGIN="$2";  shift 2 ;;
        --ac-pass|-ac-pass)   AC_PASS="$2";   shift 2 ;;
        --ac-proto|-ac-proto) AC_PROTO="$2";  shift 2 ;;
        --mode|-mode)         MODE="$2";      shift 2 ;;
        *)  echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

AC_BASE="${AC_PROTO}://${AC_HOST}:${AC_PORT}/api/v1"
CURL_OPTS="-s -k --connect-timeout 10"
COOKIE_JAR="/tmp/ac2_cookies_$$"

json_result() {
    local mac="$1" success="$2" message="$3"
    message="${message//\\/\\\\}"
    message="${message//\"/\\\"}"
    echo "AC_RESULT:{\"mac\":\"$mac\",\"success\":$success,\"message\":\"$message\"}"
}

# ── Credential storage ────────────────────────────────────────────
load_ac_creds() {
    if [[ -f "$CREDS_FILE" ]]; then
        local line
        line=$(grep "^${AC_HOST} " "$CREDS_FILE" 2>/dev/null || true)
        if [[ -n "$line" ]]; then
            AC_LOGIN=$(echo "$line" | awk '{print $2}')
            AC_PASS=$(echo "$line" | awk '{print $3}')
            AC_PORT=$(echo "$line" | awk '{print $4}')
            AC_PROTO=$(echo "$line" | awk '{print $5}')
            AC_PORT="${AC_PORT:-9082}"
            AC_PROTO="${AC_PROTO:-https}"
            AC_BASE="${AC_PROTO}://${AC_HOST}:${AC_PORT}/api/v1"
        fi
    fi
}

save_ac_creds() {
    mkdir -p "$CREDS_DIR" 2>/dev/null || true
    if [[ -f "$CREDS_FILE" ]]; then
        grep -v "^${AC_HOST} " "$CREDS_FILE" > "${CREDS_FILE}.tmp" 2>/dev/null || true
        mv "${CREDS_FILE}.tmp" "$CREDS_FILE"
    fi
    echo "${AC_HOST} ${AC_LOGIN} ${AC_PASS} ${AC_PORT} ${AC_PROTO}" >> "$CREDS_FILE"
    chmod 600 "$CREDS_FILE" 2>/dev/null || true
}

# ── Login: POST /api/v1/login ─────────────────────────────────────
CSRF_TOKEN=""

ac_login() {
    local resp http_code body

    resp=$(curl $CURL_OPTS -c "$COOKIE_JAR" -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${AC_LOGIN}\",\"password\":\"${AC_PASS}\"}" \
        "${AC_BASE}/login" 2>&1)

    http_code=$(echo "$resp" | tail -1)
    body=$(echo "$resp" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        # Extract CSRF token from login response
        CSRF_TOKEN=$(echo "$body" | grep -oP '"csrfToken"\s*:\s*"\K[^"]+' || true)
        return 0
    fi
    return 1
}

# ── Connect with retry ────────────────────────────────────────────
connect_aircontrol() {
    if [[ -z "$AC_LOGIN" || -z "$AC_PASS" ]]; then
        load_ac_creds
    fi

    local attempt=0
    local max_attempts=3

    while [[ $attempt -lt $max_attempts ]]; do
        if [[ -z "$AC_LOGIN" || -z "$AC_PASS" ]]; then
            if [[ -t 0 ]]; then
                echo "[?] AirControl2 credentials required for $AC_HOST" >&2
                read -rp "    Login: " AC_LOGIN
                read -rsp "    Password: " AC_PASS
                echo "" >&2
            else
                return 1
            fi
        fi

        attempt=$((attempt + 1))
        echo "[*] Connecting to AirControl2 $AC_BASE (attempt $attempt/$max_attempts)..." >&2

        if ac_login; then
            echo "[+] Connected to AirControl2" >&2
            save_ac_creds
            return 0
        else
            echo "[-] AirControl2 login failed" >&2
            if [[ $attempt -lt $max_attempts && -t 0 ]]; then
                AC_LOGIN=""
                AC_PASS=""
            fi
        fi
    done
    return 1
}

# ── Tag a single device by MAC ────────────────────────────────────
ac_tag_device() {
    local mac="$1"
    mac=$(echo "$mac" | tr 'a-f' 'A-F')

    # Step 1: Find device by MAC -> GET /api/v1/devices/mac/{mac}
    local device_resp device_id
    device_resp=$(curl $CURL_OPTS -b "$COOKIE_JAR" "${AC_BASE}/devices/mac/${mac}" 2>/dev/null)

    if [[ -z "$device_resp" || "$device_resp" == *"not found"* || "$device_resp" == *"404"* ]]; then
        json_result "$mac" false "Device not found in AirControl2"
        return
    fi

    # deviceId is the correct field name
    device_id=$(echo "$device_resp" | grep -oP '"deviceId"\s*:\s*\K\d+' | head -1)
    if [[ -z "$device_id" ]]; then
        json_result "$mac" false "Could not parse deviceId from AirControl2"
        return
    fi

    # Get current description from properties
    cur_desc=$(echo "$device_resp" | grep -oP '"description"\s*:\s*"\K[^"]*' | head -1)

    # Step 2: Get current properties -> POST /api/v1/devices/basic-properties
    local props_resp
    props_resp=$(curl $CURL_OPTS -b "$COOKIE_JAR" \
        -H "Content-Type: application/json" \
        -d "[$device_id]" \
        "${AC_BASE}/devices/basic-properties" 2>/dev/null)

    # Extract current description and tag from basic-properties response
    local cur_tag
    # Use basic-properties description if available, fall back to device response
    local bp_desc
    bp_desc=$(echo "$props_resp" | grep -oP '"description"\s*:\s*"\K[^"]*' | head -1)
    if [[ -n "$bp_desc" ]]; then
        cur_desc="$bp_desc"
    fi
    cur_tag=$(echo "$props_resp" | grep -oP '"tag"\s*:\s*"\K[^"]*' | head -1)

    echo "[*] Found device $device_id, description: '$cur_desc', tag: '$cur_tag'" >&2

    # Build new description: prepend "{DHCP} " if not already there
    local new_desc="$cur_desc"
    if [[ "$cur_desc" != "{DHCP}"* ]]; then
        # Also handle if it was previously tagged with plain "DHCP"
        if [[ "$cur_desc" == "DHCP "* ]]; then
            cur_desc="${cur_desc#DHCP }"
        fi
        if [[ -n "$cur_desc" ]]; then
            new_desc="{DHCP} $cur_desc"
        else
            new_desc="{DHCP}"
        fi
    fi

    # Build new tag: leave unchanged (don't set DHCP tag)
    local new_tag="$cur_tag"

    # Step 3: Update -> PATCH /api/v1/devices/basic-properties
    # Only update description, keep tag as-is
    local update_payload
    update_payload="[{\"deviceId\":${device_id},\"description\":\"${new_desc}\"}]"

    local update_resp http_code
    update_resp=$(curl $CURL_OPTS -b "$COOKIE_JAR" -w "\n%{http_code}" \
        -X PATCH -H "Content-Type: application/json" \
        -H "X-Csrf-Token: ${CSRF_TOKEN}" \
        -d "$update_payload" \
        "${AC_BASE}/devices/basic-properties" 2>&1)

    http_code=$(echo "$update_resp" | tail -1)

    if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
        json_result "$mac" true "Tagged: desc='$new_desc'"
    else
        json_result "$mac" false "Update failed (HTTP $http_code)"
    fi
}

# ══════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════
main() {
    if ! command -v curl &>/dev/null; then
        echo "[!] curl is required" >&2
        exit 1
    fi

    if [[ -z "$AC_HOST" ]]; then
        echo '{"success":false,"message":"AirControl2 host required (--ac-host)"}'
        exit 1
    fi

    # Test mode
    if [[ "$MODE" == "test" ]]; then
        if connect_aircontrol; then
            echo '{"success":true,"message":"Connected to AirControl2"}'
        else
            echo '{"success":false,"message":"AirControl2 login failed"}'
            exit 1
        fi
        rm -f "$COOKIE_JAR"
        exit 0
    fi

    # Tag mode
    if [[ -z "$MACS" ]]; then
        echo '{"success":false,"message":"MAC address(es) required (--mac or --macs)"}'
        exit 1
    fi

    if ! connect_aircontrol; then
        echo '{"success":false,"message":"Could not connect to AirControl2"}'
        rm -f "$COOKIE_JAR"
        exit 1
    fi

    IFS=',' read -ra MAC_LIST <<< "$MACS"
    for mac in "${MAC_LIST[@]}"; do
        mac=$(echo "$mac" | tr -d ' ')
        [[ -z "$mac" ]] && continue
        ac_tag_device "$mac"
    done

    rm -f "$COOKIE_JAR"
}

main
