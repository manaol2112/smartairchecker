#!/usr/bin/env bash
# Configure NetworkManager: auto-connect to an open (no key) Wi‑Fi with a static IPv4.
# For headless demo: join your phone’s hotspot, stable IP for URL QR. Run on the Pi with sudo.
#
#   sudo ./scripts/setup-client-wifi.sh
#   sudo ./scripts/setup-client-wifi.sh /path/to/.client-demo.env
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-${CLIENT_DEMO_ENV:-$ROOT/.client-demo.env}}"

if [[ $(id -u) -ne 0 ]]; then
  echo "Run with: sudo $0" >&2
  exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — copy scripts/client-demo.env.example to $ROOT/.client-demo.env and edit." >&2
  exit 1
fi
# shellcheck source=/dev/null
set -a
source "$ENV_FILE"
set +a

CLIENT_DEMO_SSID="${CLIENT_DEMO_SSID:-}"
CLIENT_DEMO_CONN_NAME="${CLIENT_DEMO_CONN_NAME:-smartair-client}"
CLIENT_DEMO_IPV4="${CLIENT_DEMO_IPV4:-}"
CLIENT_DEMO_GW="${CLIENT_DEMO_GW:-}"
CLIENT_DEMO_DNS="${CLIENT_DEMO_DNS:-$CLIENT_DEMO_GW}"
IFACE_FLAG=()
if [[ -n "${CLIENT_DEMO_IFACE:-}" ]]; then
  IFACE_FLAG=(ifname "${CLIENT_DEMO_IFACE}")
fi

if ! command -v nmcli &>/dev/null; then
  echo "This script needs NetworkManager (nmcli). Install:  sudo apt-get install -y network-manager" >&2
  exit 1
fi

if [[ -z "$CLIENT_DEMO_SSID" || -z "$CLIENT_DEMO_IPV4" || -z "$CLIENT_DEMO_GW" ]]; then
  echo "Set CLIENT_DEMO_SSID, CLIENT_DEMO_IPV4, CLIENT_DEMO_GW in $ENV_FILE" >&2
  exit 1
fi

# Stop Pi-as-AP stack if it was enabled, so the same radio can be a client
systemctl is-active --quiet hostapd 2>/dev/null && { systemctl stop hostapd 2>/dev/null || true; }
systemctl is-active --quiet dnsmasq 2>/dev/null && { systemctl stop dnsmasq 2>/dev/null || true; }
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

# Ensure NetworkManager is running
systemctl enable NetworkManager 2>/dev/null || true
if ! systemctl is-active --quiet NetworkManager; then
  systemctl start NetworkManager
fi
sleep 1

rfkill unblock wifi 2>/dev/null || true
nmcli radio wifi on 2>/dev/null || true

# Remove our previous connection profile so the script is idempotent
nmcli con delete "$CLIENT_DEMO_CONN_NAME" 2>/dev/null || true

# Open network: key-mgmt none
if [[ ${#IFACE_FLAG[@]} -gt 0 ]]; then
  nmcli connection add type wifi con-name "$CLIENT_DEMO_CONN_NAME" "${IFACE_FLAG[@]}" \
    autoconnect yes autoconnect-priority 50 \
    ssid "$CLIENT_DEMO_SSID" \
    802-11-wireless.mode infrastructure \
    802-11-wireless-security.key-mgmt none \
    ipv4.method manual \
    ipv4.addresses "$CLIENT_DEMO_IPV4" \
    ipv4.gateway "$CLIENT_DEMO_GW" \
    ipv4.dns "$CLIENT_DEMO_DNS" \
    ipv4.ignore-auto-dns yes \
    ipv4.route-metric 200
else
  nmcli connection add type wifi con-name "$CLIENT_DEMO_CONN_NAME" \
    autoconnect yes autoconnect-priority 50 \
    ssid "$CLIENT_DEMO_SSID" \
    802-11-wireless.mode infrastructure \
    802-11-wireless-security.key-mgmt none \
    ipv4.method manual \
    ipv4.addresses "$CLIENT_DEMO_IPV4" \
    ipv4.gateway "$CLIENT_DEMO_GW" \
    ipv4.dns "$CLIENT_DEMO_DNS" \
    ipv4.ignore-auto-dns yes \
    ipv4.route-metric 200
fi

echo ""
echo "[setup-client-wifi] Created NetworkManager profile: $CLIENT_DEMO_CONN_NAME"
echo "  SSID: $CLIENT_DEMO_SSID  (open)"
echo "  IPv4: $CLIENT_DEMO_IPV4  gateway $CLIENT_DEMO_GW"
echo "Bringing the connection up (so you can test now)…"
if nmcli connection up id "$CLIENT_DEMO_CONN_NAME"; then
  echo "OK — use: ip -4 a show   and test the web port after ./run or the systemd service"
else
  echo "The connection could not be brought up. Check SSID, password (must be open), and IP range vs your phone. See docs/client-demo-headless.md" >&2
  exit 1
fi
exit 0
