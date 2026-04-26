#!/usr/bin/env bash
# Configure NetworkManager: join a phone hotspot (open *or* WPA2) with static IPv4.
# Uses "nmcli device wifi connect" first (avoids "Secrets were required" on WPA2 hotspots
# when a profile was built as if the network were open). Run on the Pi with sudo.
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
IFACE="${CLIENT_DEMO_IFACE:-wlan0}"
# Android and iPhone hotspots usually use WPA2 — set the phone’s hotspot password here
CLIENT_DEMO_PSK="${CLIENT_DEMO_PSK:-${CLIENT_DEMO_PASSWORD:-}}"
SMARTAIR_PORT="${SMARTAIR_PORT:-5001}"

if ! command -v nmcli &>/dev/null; then
  echo "This script needs NetworkManager (nmcli). Install:  sudo apt-get install -y network-manager" >&2
  exit 1
fi

if [[ -z "$CLIENT_DEMO_SSID" || -z "$CLIENT_DEMO_IPV4" || -z "$CLIENT_DEMO_GW" ]]; then
  echo "Set CLIENT_DEMO_SSID, CLIENT_DEMO_IPV4, CLIENT_DEMO_GW in $ENV_FILE" >&2
  exit 1
fi
if ! ip link show "$IFACE" &>/dev/null; then
  echo "Wi‑Fi interface $IFACE not found. Set CLIENT_DEMO_IFACE (e.g. wlan1 for USB Wi‑Fi)." >&2
  exit 1
fi

# Stop Pi-as-AP stack if it was enabled, so the same radio can be a client
systemctl is-active --quiet hostapd 2>/dev/null && { systemctl stop hostapd 2>/dev/null || true; }
systemctl is-active --quiet dnsmasq 2>/dev/null && { systemctl stop dnsmasq 2>/dev/null || true; }
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

systemctl enable NetworkManager 2>/dev/null || true
if ! systemctl is-active --quiet NetworkManager; then
  systemctl start NetworkManager
fi
sleep 1

rfkill unblock wifi 2>/dev/null || true
nmcli radio wifi on 2>/dev/null || true

nmcli connection delete "$CLIENT_DEMO_CONN_NAME" 2>/dev/null || true
nmcli device disconnect "$IFACE" 2>/dev/null || true
sleep 1
nmcli device wifi rescan 2>/dev/null || true
sleep 2

echo "[setup-client-wifi] Joining SSID=\"$CLIENT_DEMO_SSID\" on $IFACE…"
if [[ -n "$CLIENT_DEMO_PSK" ]]; then
  if ! nmcli -w 120 device wifi connect "$CLIENT_DEMO_SSID" ifname "$IFACE" password "$CLIENT_DEMO_PSK" name "$CLIENT_DEMO_CONN_NAME"; then
    echo "Wi‑Fi join failed. Check SSID, CLIENT_DEMO_PSK (phone password), and that the hotspot is on." >&2
    exit 1
  fi
else
  # Truly open network (no WPA) — try connect without a key, then with empty password for older nmcli
  if ! nmcli -w 120 device wifi connect "$CLIENT_DEMO_SSID" ifname "$IFACE" name "$CLIENT_DEMO_CONN_NAME" 2>/dev/null; then
    if ! nmcli -w 120 device wifi connect "$CLIENT_DEMO_SSID" ifname "$IFACE" password "" name "$CLIENT_DEMO_CONN_NAME" 2>/dev/null; then
      echo "Open Wi‑Fi join failed. Most phone hotspots use WPA2 — set CLIENT_DEMO_PSK to the hotspot password (iPhone: Settings → Personal Hotspot)." >&2
      exit 1
    fi
  fi
fi

echo "[setup-client-wifi] Applying static IPv4 and autoconnect…"
# Bind profile to this Wi‑Fi device (avoids a stale/ambiguous connection name)
if [[ -n "$IFACE" ]]; then
  nmcli connection modify "$CLIENT_DEMO_CONN_NAME" connection.interface-name "$IFACE" 2>/dev/null || true
fi
nmcli connection modify "$CLIENT_DEMO_CONN_NAME" \
  connection.autoconnect yes \
  connection.autoconnect-priority 50 \
  ipv4.method manual \
  ipv4.addresses "$CLIENT_DEMO_IPV4" \
  ipv4.gateway "$CLIENT_DEMO_GW" \
  ipv4.dns "$CLIENT_DEMO_DNS" \
  ipv4.ignore-auto-dns yes \
  ipv4.never-default no \
  ipv4.may-fail no \
  ipv4.route-metric 200

# Re-apply: NM often leaves DHCP in place until the link cycles (same bug class as a “connected but wrong IP”)
echo "[setup-client-wifi] Cycling connection to apply static IP…"
nmcli connection down id "$CLIENT_DEMO_CONN_NAME" 2>/dev/null || true
nmcli device disconnect "$IFACE" 2>/dev/null || true
sleep 2
if ! nmcli connection up id "$CLIENT_DEMO_CONN_NAME"; then
  echo "Could not bring the connection up after static config. See: journalctl -u NetworkManager -n 50" >&2
  exit 1
fi
sleep 2

# ufw: default deny can block the Flask port from a phone on the same Wi‑Fi
if command -v ufw &>/dev/null; then
  if ufw status 2>/dev/null | grep -qiE 'Status:\s*active'; then
    echo "[setup-client-wifi] ufw is active — allowing TCP $SMARTAIR_PORT on $IFACE (web UI)…"
    ufw allow in on "$IFACE" to any port "$SMARTAIR_PORT" proto tcp 2>&1 | sed 's/^/  [ufw] /' || true
  fi
fi

echo ""
echo "[setup-client-wifi] OK — profile: $CLIENT_DEMO_CONN_NAME"
if [[ -n "$CLIENT_DEMO_PSK" ]]; then
  echo "  Security: WPA2-PSK (password from CLIENT_DEMO_PSK / CLIENT_DEMO_PASSWORD)"
else
  echo "  Security: open (no password)"
fi
echo "  IPv4: $CLIENT_DEMO_IPV4  gateway $CLIENT_DEMO_GW"
if ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | grep -qxF "$CLIENT_DEMO_IPV4"; then
  echo "  Confirmed: $IFACE has $CLIENT_DEMO_IPV4"
else
  echo "  WARNING: $IFACE may not have the static address yet. Actual:"
  ip -4 addr show dev "$IFACE" 2>/dev/null | sed 's/^/    /' || true
  echo "  Run:  nmcli -f IP4.ADDRESS,IP4.GATEWAY,IP4.METHOD,IP4.ROUTE c show \"$CLIENT_DEMO_CONN_NAME\""
  echo "  Android: expect 192.168.43.x/24. iPhone: usually 172.20.10.x/28. Compare to: ip -4 a show $IFACE  and  docs/client-demo-headless.md"
fi
echo "  Test:  ping -c1 $CLIENT_DEMO_GW  |  from phone:  http://$(echo "$CLIENT_DEMO_IPV4" | cut -d/ -f1):${SMARTAIR_PORT}/"
echo "  Diagnose:  $ROOT/scripts/verify-client-demo.sh"
exit 0
