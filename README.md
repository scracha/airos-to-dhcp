# airOS to DHCP Converter

A web-based tool for batch-converting Ubiquiti AirOS devices from static IP to DHCP, with automatic MikroTik DHCP lease creation and AirControl2 device tagging.

## What it does

1. **Connects to your MikroTik router** via SSH
2. **Looks up the ARP entry** for each target IP to find the MAC and interface
3. **Creates a static DHCP lease** on the appropriate MikroTik DHCP server
4. **SSHs into the AirOS device** and reconfigures the WAN interface from static to DHCP
5. **Waits for the device to obtain a lease** (with automatic rollback on failure)
6. **Optionally tags the device** in AirControl2 with `{DHCP}` in the description

## Features

- Batch processing — convert multiple devices in one go
- Dual password support — tries a primary and fallback password for AirOS devices
- Automatic rollback — if DHCP lease isn't obtained within 2 minutes, config is restored
- MikroTik credential caching — stored securely for reuse
- AirControl2 integration — tags converted devices via the AC2 REST API
- Web UI with real-time progress feedback
- Handles devices already on DHCP (makes dynamic leases static)

## Requirements

- PHP 7.4+ with `proc_open` enabled
- `sshpass` and `ssh` installed on the server
- Network access to MikroTik router (SSH) and AirOS devices (SSH)
- Optional: AirControl2 instance for device tagging

## Files

| File | Purpose |
|------|---------|
| `index.php` | Web UI — form for entering IPs and credentials |
| `run.php` | Backend — executes the conversion via shell scripts |
| `convert_to_dhcp.sh` | Core script — handles MikroTik + AirOS conversion |
| `aircontrol_tag.sh` | Tags devices in AirControl2 after conversion |
| `before.cfg` | Example AirOS config (static IP) |
| `after.cfg` | Example AirOS config (DHCP enabled) |
| `airControl.yaml` | AirControl2 REST API OpenAPI spec (reference) |

## Usage

1. Navigate to the web UI
2. Enter the IP addresses of AirOS devices to convert (one per line or comma-separated)
3. Enter AirOS SSH credentials (default: admin/ubnt)
4. Enter your MikroTik router IP (credentials are cached after first use)
5. Optionally configure AirControl2 for device tagging
6. Click "Convert" and monitor progress

## How credentials are stored

Runtime credentials are stored in `/var/www/.config/airos-to-dhcp/` with `600` permissions. These are **not** included in the repository.

## Supported devices

- Ubiquiti AirOS 5.x / 6.x / 8.x devices (NanoStation, LiteBeam, PowerBeam, etc.)
- MikroTik RouterOS 6.x / 7.x

## License

MIT
