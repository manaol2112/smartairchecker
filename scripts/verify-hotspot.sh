#!/usr/bin/env bash
# Run ON THE Pi (sudo) to see why phones might not see the SmartAir hotspot.
#   sudo ./scripts/verify-hotspot.sh
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVF="${HOTSPOT_ENV:-$ROOT/.hotspot.env}"
STATEF="${HOTSPOT_STATE:-$ROOT/.hotspot.state}"
set +u
# shellcheck source=/dev/null
[[ -f "$ENVF" ]] && . "$ENVF"
# shellcheck source=/dev/null
[[ -f "$STATEF" ]] && . "$STATEF"
set -u
AP_IFACE="${AP_IFACE:-wlan0}"
WANT_SSID="${SMARTAIR_AP_SSID:-SmartAirDemo}"

if [[ $(id -u) -ne 0 ]]; then
  echo "Run with: sudo $0" >&2
  exit 1
fi

echo "=== 1) Interface exists? ==="
if ! ip link show "$AP_IFACE" &>/dev/null; then
  echo "NO: $AP_IFACE missing. Your Wi-Fi might be wlan1 (USB) — set AP_IFACE in .hotspot.env"
  echo "Available:"
  ip -br link
  exit 1
fi
echo "OK: $AP_IFACE present"

echo ""
echo "=== 2) AP mode? (should contain 'type AP' for a working hotspot) ==="
if command -v iw &>/dev/null; then
  if iw dev "$AP_IFACE" info 2>/dev/null | grep -qi "type ap"; then
    echo "OK: interface is in access-point mode."
    iw dev "$AP_IFACE" info 2>/dev/null | sed 's/^/  /'
  else
    echo "PROBLEM: not in AP mode. Phones will not see the network."
    iw dev "$AP_IFACE" info 2>/dev/null | sed 's/^/  /' || true
  fi
else
  echo "iw not installed: apt install iw"
fi

echo ""
echo "=== 3) hostapd (if you use the classic / fallback stack) ==="
if systemctl is-active --quiet hostapd 2>/dev/null; then
  echo "hostapd: active"
  if pgrep -x hostapd &>/dev/null; then
    echo "  process: OK (pid $(pgrep -x hostapd | head -1))"
  else
    echo "  process: not found (unusual if systemd is active)"
  fi
  systemctl is-enabled hostapd 2>/dev/null | sed 's/^/  enabled: /' || true
else
  echo "hostapd: not active (OK if you use only NetworkManager hotspot)"
fi
if systemctl is-active --quiet hostapd 2>/dev/null || ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
  if [[ -f /var/log/daemon.log ]]; then
    :
  fi
  journalctl -u hostapd -n 20 --no-pager 2>/dev/null | sed 's/^/  [hostapd] /' || true
fi

echo ""
echo "=== 4) NetworkManager hotspot (if you use nmcli path) ==="
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
  echo "NetworkManager: active"
  nmcli -t -f STATE,CONNECTION,DEVICE dev status 2>/dev/null | sed 's/^/  /' || true
  nmcli con show --active 2>/dev/null | sed 's/^/  /' || true
else
  echo "NetworkManager: not active (OK for hostapd-only)"
fi

echo ""
echo "=== 5) Radio / blocking ==="
rfkill list 2>/dev/null | sed 's/^/  /' || true
iw reg get 2>/dev/null | head -3 | sed 's/^/  /' || true

echo ""
echo "=== 6) Self-scan (optional; many Pis cannot see their *own* AP in scan) ==="
echo "  If sections 2–3 look good, use another device to list networks — or walk closer"
echo "  to the Pi (2.4 GHz, low power on internal Wi-Fi)."

echo ""
echo "=== Hints (phones do not list the network) ==="
echo "  - The Pi's built-in Wi-Fi is *not* always reliable in AP mode. A cheap USB"
echo "    Wi-Fi dongle and AP_IFACE=wlan1 in .hotspot.env often works better."
echo "  - Use 2.4 GHz only (our script uses hw_mode=g). Turn off 5GHz-only filter on phone."
echo "  - Re-run:  HOTSPOT_USE_CLASSIC=1 ./setuphotspot"
echo "  - Full doc:  $ROOT/docs/pi-wifi-hotspot.md"
echo ""
