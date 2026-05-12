#!/bin/bash
#
# convert_to_dhcp.sh
#
# Converts Ubiquiti AirOS devices from static IP to DHCP (batch mode).
#
# Connects to MikroTik ONCE, processes all AirOS IPs, outputs JSON per-IP results.
#
# Usage:
#   ./convert_to_dhcp.sh --airos-ips <IP,IP,...> --airos-port <PORT> \
#       --airos-login <USER> --airos-pass <PASS> \
#       --mt-ip <IP> [--mt-login <USER>] [--mt-pass <PASS>]
#
#   --mode test_mt    (only test MikroTik connection)
#   --mode convert    (default, full conversion)
#

set -o pipefail

CREDS_DIR="/var/www/.config/airos-to-dhcp"
CREDS_FILE="${CREDS_DIR}/mikrotik_creds"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR"
AIROS_SSH_OPTS="$SSH_OPTS -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 -o HostKeyAlgorithms=+ssh-rsa,ssh-dss -o Ciphers=+aes128-cbc,aes256-cbc,3des-cbc"

# ── Argument defaults ──────────────────────────────────────────────
AIROS_IPS=""
AIROS_PORT="22"
AIROS_LOGIN=""
AIROS_PASS=""
AIROS_PASS2=""
MT_IP=""
MT_LOGIN=""
MT_PASS=""
MODE="convert"
AC_HOST=""
AC_PORT="9082"
AC_LOGIN=""
AC_PASS=""
AC_PROTO="https"

# ── Parse arguments ───────────────────────────────────────────────
usage() {
    echo "Usage: $0 --airos-ips <IP,IP,...> --airos-port <PORT> --airos-login <USER> --airos-pass <PASS>"
    echo "          --mt-ip <IP> [--mt-login <USER>] [--mt-pass <PASS>] [--mode test_mt|convert]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --airos-ips|-airos-ips)     AIROS_IPS="$2";   shift 2 ;;
        --airos-ip|-airos-ip)       AIROS_IPS="$2";   shift 2 ;;
        --airos-port|-airos-port)   AIROS_PORT="$2";  shift 2 ;;
        --airos-login|-airos-login) AIROS_LOGIN="$2"; shift 2 ;;
        --airos-pass|-airos-pass)   AIROS_PASS="$2";  shift 2 ;;
        --airos-pass2|-airos-pass2) AIROS_PASS2="$2"; shift 2 ;;
        --mt-ip|-mt-ip)             MT_IP="$2";       shift 2 ;;
        --mt-login|-mt-login)       MT_LOGIN="$2";    shift 2 ;;
        --mt-pass|-mt-pass)         MT_PASS="$2";     shift 2 ;;
        --mode|-mode)               MODE="$2";        shift 2 ;;
        --ac-host|-ac-host)         AC_HOST="$2";     shift 2 ;;
        --ac-port|-ac-port)         AC_PORT="$2";     shift 2 ;;
        --ac-login|-ac-login)       AC_LOGIN="$2";    shift 2 ;;
        --ac-pass|-ac-pass)         AC_PASS="$2";     shift 2 ;;
        --ac-proto|-ac-proto)       AC_PROTO="$2";    shift 2 ;;
        *)                          echo "Unknown option: $1"; usage ;;
    esac
done

# ── Dependency check ──────────────────────────────────────────────
check_deps() {
    for cmd in sshpass ssh; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "[!] Required command '$cmd' not found. Install with: sudo apt install $cmd"
            exit 1
        fi
    done
}

# ── JSON output helper ────────────────────────────────────────────
# Outputs one JSON line per IP result so PHP can parse them
json_result() {
    local ip="$1" success="$2" message="$3"
    # Escape quotes in message
    message="${message//\\/\\\\}"
    message="${message//\"/\\\"}"
    echo "RESULT:{\"ip\":\"$ip\",\"success\":$success,\"message\":\"$message\"}"
}

# ── MikroTik credential storage ──────────────────────────────────
load_mt_creds() {
    local host="$1"
    if [[ -f "$CREDS_FILE" ]]; then
        local line
        line=$(grep "^${host} " "$CREDS_FILE" 2>/dev/null || true)
        if [[ -n "$line" ]]; then
            MT_LOGIN=$(echo "$line" | awk '{print $2}')
            MT_PASS=$(echo "$line" | awk '{print $3}')
        fi
    fi
}

save_mt_creds() {
    local host="$1" login="$2" pass="$3"
    mkdir -p "$CREDS_DIR" 2>/dev/null || true
    if [[ -f "$CREDS_FILE" ]]; then
        grep -v "^${host} " "$CREDS_FILE" > "${CREDS_FILE}.tmp" 2>/dev/null || true
        mv -f "${CREDS_FILE}.tmp" "$CREDS_FILE" 2>/dev/null || true
    fi
    echo "${host} ${login} ${pass}" >> "$CREDS_FILE" 2>/dev/null || true
    chmod 600 "$CREDS_FILE" 2>/dev/null || true
}

# ── MikroTik SSH helper ──────────────────────────────────────────
mt_exec() {
    local cmd="$1"
    sshpass -p "$MT_PASS" ssh $SSH_OPTS "${MT_LOGIN}@${MT_IP}" "$cmd" 2>/dev/null
}

# ── Connect to MikroTik (no interactive prompts in batch mode) ───
connect_mikrotik() {
    if [[ -z "$MT_LOGIN" || -z "$MT_PASS" ]]; then
        load_mt_creds "$MT_IP"
    fi

    if [[ -z "$MT_LOGIN" || -z "$MT_PASS" ]]; then
        # Interactive fallback for CLI usage
        echo "[?] MikroTik credentials required for $MT_IP" >&2
        read -rp "    Login: " MT_LOGIN
        read -rsp "    Password: " MT_PASS
        echo "" >&2
    fi

    local attempt=0
    local max_attempts=3

    while [[ $attempt -lt $max_attempts ]]; do
        attempt=$((attempt + 1))
        echo "[*] Connecting to MikroTik $MT_IP (attempt $attempt/$max_attempts)..." >&2

        local result
        if result=$(sshpass -p "$MT_PASS" ssh $SSH_OPTS "${MT_LOGIN}@${MT_IP}" \
                    "/system identity print" 2>&1); then
            echo "[+] Connected to MikroTik $MT_IP — $result" >&2
            save_mt_creds "$MT_IP" "$MT_LOGIN" "$MT_PASS"
            return 0
        else
            echo "[-] Authentication failed for $MT_IP" >&2
            if [[ $attempt -lt $max_attempts ]]; then
                # In CLI mode, prompt again
                if [[ -t 0 ]]; then
                    read -rp "    Login: " MT_LOGIN
                    read -rsp "    Password: " MT_PASS
                    echo "" >&2
                else
                    break
                fi
            fi
        fi
    done
    return 1
}

# ── MikroTik: ARP lookup ─────────────────────────────────────────
get_arp_entry() {
    local ip="$1"
    local arp_output
    arp_output=$(mt_exec "/ip arp print terse where address=\"$ip\"")

    ARP_MAC=$(echo "$arp_output" | grep -oP 'mac-address=\K[0-9A-Fa-f:]{17}' | head -1)
    ARP_IFACE=$(echo "$arp_output" | grep -oP 'interface=\K\S+' | head -1)

    if [[ -z "$ARP_MAC" || -z "$ARP_IFACE" ]]; then
        return 1
    fi

    ARP_MAC=$(echo "$ARP_MAC" | tr 'a-f' 'A-F')

    # Reject empty/null MACs
    if [[ "$ARP_MAC" == "00:00:00:00:00:00" ]]; then
        echo "ARP returned null MAC for $ip" >&2
        return 1
    fi

    return 0
}

# ── MikroTik: Find DHCP server for interface ─────────────────────
find_dhcp_server() {
    local iface="$1"

    # Check if interface is a bridge port
    local bridge_output
    bridge_output=$(mt_exec "/interface bridge port print terse where interface=\"$iface\"")
    local bridge
    bridge=$(echo "$bridge_output" | grep -oP 'bridge=\K\S+' | head -1)

    local search_iface="$iface"
    if [[ -n "$bridge" ]]; then
        search_iface="$bridge"
    fi

    local dhcp_output
    dhcp_output=$(mt_exec "/ip dhcp-server print terse")

    DHCP_SERVER=""
    while IFS= read -r line; do
        local srv_name srv_iface
        srv_name=$(echo "$line" | grep -oP 'name=\K\S+' || true)
        srv_iface=$(echo "$line" | grep -oP 'interface=\K\S+' || true)
        if [[ "$srv_iface" == "$search_iface" && -n "$srv_name" ]]; then
            DHCP_SERVER="$srv_name"
            return 0
        fi
    done <<< "$dhcp_output"
    return 1
}

# ── MikroTik: Create DHCP lease ──────────────────────────────────
create_dhcp_lease() {
    local ip="$1" mac="$2" server="$3" comment="${4:-}"

    # Check if lease already exists
    local existing
    existing=$(mt_exec "/ip dhcp-server lease print terse where mac-address=\"$mac\" address=\"$ip\"")
    if echo "$existing" | grep -qi "$mac"; then
        return 0
    fi

    # Try up to 2 times with a 5 second delay on failure
    local attempt=0
    while [[ $attempt -lt 2 ]]; do
        mt_exec "/ip dhcp-server lease add server=\"$server\" mac-address=\"$mac\" address=\"$ip\" comment=\"${comment:-auto-created by convert_to_dhcp}\""

        # Verify
        local verify
        verify=$(mt_exec "/ip dhcp-server lease print terse where mac-address=\"$mac\" address=\"$ip\"")
        if echo "$verify" | grep -qi "$mac"; then
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ $attempt -lt 2 ]]; then
            echo "DHCP lease creation failed, retrying in 5s..." >&2
            sleep 5
        fi
    done
    return 1
}

# ── AirOS SSH helper ─────────────────────────────────────────────
# Per-device password (resolved by try_airos_passwords)
AIROS_ACTIVE_PASS=""

airos_exec() {
    local ip="$1" cmd="$2"
    local pass="${AIROS_ACTIVE_PASS:-$AIROS_PASS}"
    sshpass -p "$pass" ssh $AIROS_SSH_OPTS \
        -p "$AIROS_PORT" "${AIROS_LOGIN}@${ip}" "$cmd" 2>/dev/null
}

# Try password 1, then password 2. Sets AIROS_ACTIVE_PASS on success.
# Sets AIROS_AUTH_ERROR with a descriptive message on failure.
try_airos_passwords() {
    local ip="$1"
    AIROS_ACTIVE_PASS=""
    AIROS_AUTH_ERROR=""

    # Try primary password
    local test_out
    test_out=$(sshpass -p "$AIROS_PASS" ssh $AIROS_SSH_OPTS \
        -p "$AIROS_PORT" "${AIROS_LOGIN}@${ip}" "echo OK" 2>&1) || true
    if [[ "$test_out" == *"OK"* ]]; then
        AIROS_ACTIVE_PASS="$AIROS_PASS"
        return 0
    fi

    # Check if it's a connection issue vs auth issue
    if [[ "$test_out" == *"Connection refused"* || "$test_out" == *"Connection timed out"* || "$test_out" == *"No route"* ]]; then
        AIROS_AUTH_ERROR="Offline or unreachable (SSH connection failed)"
        return 1
    fi

    # Try secondary password if provided
    if [[ -n "$AIROS_PASS2" ]]; then
        test_out=$(sshpass -p "$AIROS_PASS2" ssh $AIROS_SSH_OPTS \
            -p "$AIROS_PORT" "${AIROS_LOGIN}@${ip}" "echo OK" 2>&1) || true
        if [[ "$test_out" == *"OK"* ]]; then
            AIROS_ACTIVE_PASS="$AIROS_PASS2"
            return 0
        fi
    fi

    # Both passwords failed
    if [[ "$test_out" == *"Permission denied"* || "$test_out" == *"Authentication"* ]]; then
        AIROS_AUTH_ERROR="Wrong login credentials (both passwords failed)"
    elif [[ "$test_out" == *"Connection refused"* || "$test_out" == *"Connection timed out"* || "$test_out" == *"No route"* ]]; then
        AIROS_AUTH_ERROR="Offline or unreachable (SSH connection failed)"
    else
        AIROS_AUTH_ERROR="SSH failed: ${test_out:0:80}"
    fi

    return 1
}

# ── AirOS: Detect WAN interface and verify IP ────────────────────
detect_airos_wan() {
    local ip="$1"
    WAN_IFACE=""
    WAN_IDX=""
    AIROS_HOSTNAME=""

    # Test connectivity with password fallback
    if ! try_airos_passwords "$ip"; then
        echo "$AIROS_AUTH_ERROR" >&2
        return 1
    fi

    local cfg
    cfg=$(airos_exec "$ip" "cat /tmp/system.cfg")
    if [[ -z "$cfg" ]]; then
        echo "Could not read config" >&2
        return 1
    fi

    # Extract hostname
    AIROS_HOSTNAME=$(echo "$cfg" | grep -oP '^resolv\.host\.1\.name=\K.*' || true)

    WAN_IFACE=""
    WAN_IDX=""
    local indices
    indices=$(echo "$cfg" | grep -oP '^netconf\.\K\d+' | sort -u)

    for idx in $indices; do
        local devname role wan_ip
        devname=$(echo "$cfg" | grep -oP "^netconf\\.${idx}\\.devname=\K.*" || true)
        role=$(echo "$cfg" | grep -oP "^netconf\\.${idx}\\.role=\K.*" || true)
        wan_ip=$(echo "$cfg" | grep -oP "^netconf\\.${idx}\\.ip=\K.*" || true)

        if [[ "$role" == "wan" ]]; then
            if [[ -n "$wan_ip" && "$wan_ip" != "0.0.0.0" && "$wan_ip" != "$ip" ]]; then
                echo "WAN IP mismatch: $wan_ip != $ip" >&2
                return 1
            fi
            WAN_IFACE="$devname"
            WAN_IDX="$idx"
            return 0
        fi
    done

    echo "No role=wan interface found" >&2
    return 1
}

# ── AirOS: Convert WAN to DHCP ───────────────────────────────────
convert_airos_wan() {
    local ip="$1"

    # Backup config
    airos_exec "$ip" "cp /tmp/system.cfg /tmp/system.cfg.bak"
    local bak_check
    bak_check=$(airos_exec "$ip" "md5sum /tmp/system.cfg.bak" || true)
    if [[ -z "$bak_check" ]]; then
        echo "Failed to backup config" >&2
        return 1
    fi

    # Check if a dhcpc entry already exists for the WAN interface
    local existing_dhcpc
    existing_dhcpc=$(airos_exec "$ip" "grep '^dhcpc\.' /tmp/system.cfg" || true)

    local existing_idx=""
    if [[ -n "$existing_dhcpc" ]]; then
        # Find a dhcpc.N.devname that matches our WAN interface
        local idx_list
        idx_list=$(echo "$existing_dhcpc" | grep -oP '^dhcpc\.\K\d+' | sort -u)
        for idx in $idx_list; do
            local dev
            dev=$(echo "$existing_dhcpc" | grep -oP "^dhcpc\\.${idx}\\.devname=\K.*" || true)
            if [[ "$dev" == "$WAN_IFACE" ]]; then
                existing_idx="$idx"
                break
            fi
        done
    fi

    if [[ -n "$existing_idx" ]]; then
        # Existing dhcpc entry found — enable it
        echo "[*] Found existing dhcpc.$existing_idx for $WAN_IFACE, enabling it" >&2
        airos_exec "$ip" "sed -i 's/^dhcpc\\.${existing_idx}\\.status=disabled/dhcpc.${existing_idx}.status=enabled/' /tmp/system.cfg"

        # Ensure fallback_netmask exists
        local has_fb_nm
        has_fb_nm=$(echo "$existing_dhcpc" | grep "^dhcpc\\.${existing_idx}\\.fallback_netmask=" || true)
        if [[ -z "$has_fb_nm" ]]; then
            airos_exec "$ip" "sed -i '/^dhcpc\\.${existing_idx}\\.fallback=/a dhcpc.${existing_idx}.fallback_netmask=255.255.255.0' /tmp/system.cfg"
        fi

        # Remove any extra dhcpc entries we may have added in previous runs
        local other_idx
        for other_idx in $idx_list; do
            if [[ "$other_idx" != "$existing_idx" ]]; then
                local other_dev
                other_dev=$(echo "$existing_dhcpc" | grep -oP "^dhcpc\\.${other_idx}\\.devname=\K.*" || true)
                if [[ "$other_dev" == "$WAN_IFACE" ]]; then
                    airos_exec "$ip" "sed -i '/^dhcpc\\.${other_idx}\\./d' /tmp/system.cfg"
                fi
            fi
        done
    else
        # No existing entry — add a new one
        local dhcpc_idx=1
        if [[ -n "$existing_dhcpc" ]]; then
            local max_idx
            max_idx=$(echo "$existing_dhcpc" | grep -oP '^dhcpc\.\K\d+' | sort -n | tail -1 || echo "0")
            dhcpc_idx=$((max_idx + 1))
        fi

        echo "[*] Adding new dhcpc.$dhcpc_idx for $WAN_IFACE" >&2
        airos_exec "$ip" "cat >> /tmp/system.cfg << EOF
dhcpc.${dhcpc_idx}.status=enabled
dhcpc.${dhcpc_idx}.devname=${WAN_IFACE}
dhcpc.${dhcpc_idx}.fallback=192.168.1.10
dhcpc.${dhcpc_idx}.fallback_netmask=255.255.255.0
EOF"
    fi

    # Ensure dhcpc.status=enabled (remove dupes first)
    airos_exec "$ip" "sed -i '/^dhcpc\.status=/d' /tmp/system.cfg"
    airos_exec "$ip" "echo 'dhcpc.status=enabled' >> /tmp/system.cfg"

    # Set WAN IP to 0.0.0.0 instead of deleting (older firmware needs this)
    airos_exec "$ip" "sed -i 's/^netconf\\.${WAN_IDX}\\.ip=.*/netconf.${WAN_IDX}.ip=0.0.0.0/' /tmp/system.cfg"
    # Remove netmask for WAN (DHCP will provide it)
    airos_exec "$ip" "sed -i '/^netconf\\.${WAN_IDX}\\.netmask=/d' /tmp/system.cfg"

    # Disable static route (DHCP will provide gateway)
    airos_exec "$ip" "sed -i 's/^route\\.1\\.status=enabled/route.1.status=disabled/' /tmp/system.cfg"

    # Remove any leaked heredoc markers from previous runs
    airos_exec "$ip" "sed -i '/^DHCPEOF$/d' /tmp/system.cfg"

    # Verify changes
    local verify_dhcpc
    verify_dhcpc=$(airos_exec "$ip" "grep '^dhcpc\.' /tmp/system.cfg")

    if ! echo "$verify_dhcpc" | grep -qP "dhcpc\.\d+\.devname=${WAN_IFACE}"; then
        airos_exec "$ip" "cp /tmp/system.cfg.bak /tmp/system.cfg"
        echo "DHCP client entries missing after edit" >&2
        return 1
    fi

    if ! echo "$verify_dhcpc" | grep -qP "dhcpc\.\d+\.status=enabled"; then
        airos_exec "$ip" "cp /tmp/system.cfg.bak /tmp/system.cfg"
        echo "DHCP client not enabled after edit" >&2
        return 1
    fi

    # Apply: start DHCP client manually (don't write to flash yet)
    # This avoids needing a full soft restart and lets us roll back
    airos_exec "$ip" "killall udhcpc 2>/dev/null; udhcpc -i ${WAN_IFACE} -b" || true

    # Wait up to 2 minutes for DHCP lease
    echo "Waiting up to 2 minutes for DHCP lease on $WAN_IFACE..." >&2
    local waited=0
    local new_ip=""
    while [[ $waited -lt 120 ]]; do
        sleep 10
        waited=$((waited + 10))
        local iface_status
        if iface_status=$(airos_exec "$ip" "ifconfig $WAN_IFACE" 2>/dev/null); then
            new_ip=$(echo "$iface_status" | grep -oP 'inet addr:\K[\d.]+' || true)
            if [[ -n "$new_ip" && "$new_ip" != "0.0.0.0" ]]; then
                # Got an IP — write config to flash to make it permanent
                airos_exec "$ip" "cfgmtd -w" || true
                echo "OK: $WAN_IFACE now has IP $new_ip (after ${waited}s)" >&2
                return 0
            fi
        fi
        echo "  ...${waited}s elapsed, still waiting" >&2
    done

    # Failed — roll back
    echo "DHCP lease not obtained after 2 minutes. Rolling back..." >&2
    airos_exec "$ip" "killall udhcpc 2>/dev/null; cp /tmp/system.cfg.bak /tmp/system.cfg; /usr/etc/rc.d/rc.softrestart save" || true
    return 1
}

# ── MikroTik: Check if IP already has a dynamic DHCP lease ────────
check_existing_dhcp_lease() {
    local ip="$1"
    # Look for any DHCP lease (dynamic or static) for this IP
    local lease_output
    lease_output=$(mt_exec "/ip dhcp-server lease print terse where address=\"$ip\"")

    if [[ -z "$lease_output" ]]; then
        # No lease at all
        return 1
    fi

    # Check if there's a dynamic lease (flag "D" present, no static entry)
    LEASE_MAC=$(echo "$lease_output" | grep -oP 'mac-address=\K[0-9A-Fa-f:]{17}' | head -1)
    LEASE_SERVER=$(echo "$lease_output" | grep -oP 'server=\K\S+' | head -1)
    local lease_status
    lease_status=$(echo "$lease_output" | grep -oP 'status=\K\S+' | head -1)

    if [[ -n "$LEASE_MAC" ]]; then
        LEASE_MAC=$(echo "$LEASE_MAC" | tr 'a-f' 'A-F')

        # Reject null MACs
        if [[ "$LEASE_MAC" == "00:00:00:00:00:00" ]]; then
            return 1
        fi
        # Check if it's dynamic (has D flag) — dynamic leases have "D" in flags
        if echo "$lease_output" | grep -qP '^\s*\d+\s+D'; then
            LEASE_IS_DYNAMIC=true
        else
            LEASE_IS_DYNAMIC=false
        fi
        return 0
    fi
    return 1
}

# ── MikroTik: Make a dynamic lease static ─────────────────────────
make_lease_static() {
    local ip="$1" mac="$2"
    # Find the lease ID and make it static
    local lease_output lease_id
    lease_output=$(mt_exec "/ip dhcp-server lease print terse where address=\"$ip\" mac-address=\"$mac\"")
    lease_id=$(echo "$lease_output" | grep -oP '^\s*\K\d+' | head -1)

    if [[ -n "$lease_id" ]]; then
        mt_exec "/ip dhcp-server lease make-static numbers=$lease_id"
        # Add comment
        mt_exec "/ip dhcp-server lease set numbers=$lease_id comment=\"auto-static by convert_to_dhcp\""
        return 0
    fi
    return 1
}

# ── Process a single AirOS IP (MikroTik already connected) ───────
process_one_ip() {
    local ip="$1"

    # Step 0: Check if device already has a DHCP lease on MikroTik
    if check_existing_dhcp_lease "$ip"; then
        echo "[*] $ip has a DHCP lease on MikroTik (MAC=$LEASE_MAC, dynamic=$LEASE_IS_DYNAMIC)" >&2

        if [[ "$LEASE_IS_DYNAMIC" == "true" ]]; then
            # Dynamic lease = device IS actually using DHCP already
            echo "[*] Making dynamic lease static for $ip..." >&2
            make_lease_static "$ip" "$LEASE_MAC" || true

            json_result "$ip" true "Already DHCP (MAC=$LEASE_MAC, lease made static)"
            return
        fi

        # Static lease exists but device might still be on static IP
        # (e.g. lease was pre-created but AirOS conversion failed)
        # Check if AirOS is actually running DHCP by SSHing in
        echo "[*] Static lease exists. Checking if AirOS is actually using DHCP..." >&2
        local dhcpc_check
        # Try both passwords for the SSH check
        if try_airos_passwords "$ip"; then
            dhcpc_check=$(airos_exec "$ip" "grep -P 'dhcpc\.\d+\.status=enabled' /tmp/system.cfg" 2>/dev/null || true)
        else
            dhcpc_check=""
        fi

        if [[ -n "$dhcpc_check" ]]; then
            # Device is already on DHCP, nothing to do
            echo "[+] AirOS is already configured for DHCP" >&2
            json_result "$ip" true "Already DHCP (MAC=$LEASE_MAC)"
            return
        fi

        echo "[*] AirOS still on static IP despite lease existing. Proceeding with conversion..." >&2
        ARP_MAC="$LEASE_MAC"
    else
        # No lease at all — do ARP lookup and find DHCP server
        if ! get_arp_entry "$ip"; then
            json_result "$ip" false "No ARP entry found on MikroTik"
            return
        fi

        if ! find_dhcp_server "$ARP_IFACE"; then
            json_result "$ip" false "No DHCP server for interface $ARP_IFACE"
            return
        fi
    fi

    # Detect AirOS WAN (confirms device is online and reachable)
    if ! detect_airos_wan "$ip"; then
        json_result "$ip" false "${AIROS_AUTH_ERROR:-AirOS: Could not detect WAN interface}"
        return
    fi

    # Create DHCP lease only after confirming device is online
    if [[ -z "$LEASE_MAC" ]]; then
        if ! create_dhcp_lease "$ip" "$ARP_MAC" "$DHCP_SERVER" "$AIROS_HOSTNAME"; then
            json_result "$ip" false "Failed to create DHCP lease"
            return
        fi
    fi

    # Convert
    if convert_airos_wan "$ip"; then
        json_result "$ip" true "Converted $WAN_IFACE to DHCP (MAC=$ARP_MAC)"
    else
        json_result "$ip" false "AirOS conversion failed"
    fi
}

# ══════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════
main() {
    check_deps

    # Mode: test MikroTik connection only
    if [[ "$MODE" == "test_mt" ]]; then
        if [[ -z "$MT_IP" ]]; then
            echo '{"success":false,"message":"MikroTik IP required"}'
            exit 1
        fi
        if connect_mikrotik; then
            echo '{"success":true,"message":"Connected to MikroTik"}'
            exit 0
        else
            echo '{"success":false,"message":"MikroTik authentication failed"}'
            exit 1
        fi
    fi

    # Mode: convert
    if [[ -z "$AIROS_IPS" || -z "$AIROS_LOGIN" || -z "$AIROS_PASS" || -z "$MT_IP" ]]; then
        echo '{"success":false,"message":"Missing required parameters"}'
        exit 1
    fi

    # Connect to MikroTik once
    if ! connect_mikrotik; then
        echo '{"success":false,"message":"MikroTik authentication failed"}'
        exit 1
    fi

    echo "MT_OK" >&2

    # Split comma-separated IPs and process each
    IFS=',' read -ra IP_LIST <<< "$AIROS_IPS"
    for ip in "${IP_LIST[@]}"; do
        ip=$(echo "$ip" | tr -d ' ')
        [[ -z "$ip" ]] && continue
        process_one_ip "$ip"
    done
}

main
