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
echo "=== 2b) IP + DHCP (phones need an IP; without this you see 'Unable to connect') ==="
PREFIX="${HOTSPOT_STATIC:-192.168.4}"
if ip -4 -o addr show dev "$AP_IFACE" 2>/dev/null | grep -qF "${PREFIX}.1/"; then
  echo "OK: $AP_IFACE has ${PREFIX}.1/24 (or /…)"
  ip -4 -o addr show dev "$AP_IFACE" 2>/dev/null | sed 's/^/  /'
else
  echo "PROBLEM: $AP_IFACE has no ${PREFIX}.1 — dnsmasq cannot serve DHCP; fix dhcpcd or re-run setup."
  ip -4 -o addr show dev "$AP_IFACE" 2>/dev/null | sed 's/^/  /' || true
fi
if systemctl is-active --quiet dnsmasq 2>/dev/null; then
  echo "dnsmasq: active (DHCP for clients OK)"
  if command -v ss &>/dev/null; then
    if ss -ulpen 2>/dev/null | grep -qE '(:67|bootps)'; then
      echo "  something is listening for DHCP (udp 67) on the Pi: OK for phones"
    else
      echo "  WARNING: nothing is listening on UDP 67; phones may get 'no IP' — check: sudo journalctl -u dnsmasq -n 30"
    fi
  fi
else
  if systemctl is-active --quiet hostapd 2>/dev/null; then
    echo "PROBLEM: dnsmasq is not active but hostapd is — clients will not get an IP. journal: journalctl -u dnsmasq -n 20"
  else
    echo "dnsmasq: not active (see hostapd / NM path above)"
  fi
fi

echo ""
echo "=== 2c) Open vs password (hostapd) ==="
if [[ -f /etc/hostapd/hostapd.conf ]]; then
  if grep -qE '^[[:space:]]*wpa=0' /etc/hostapd/hostapd.conf 2>/dev/null; then
    echo "hostapd has wpa=0 → this SSID is OPEN (no passphrase). If the phone still shows a key icon, use Forget on that network and rejoin."
  else
    echo "hostapd has WPA → the phone will ask for SMARTAIR_AP_PASS from .hotspot.env (8+ characters)."
  fi
  if ! systemctl is-active --quiet hostapd 2>/dev/null; then
    echo "  (hostapd is not running — another stack may be active; the file above may be stale.)"
  fi
else
  echo "No /etc/hostapd/hostapd.conf — you may be on the NetworkManager hotspot (WPA2 from nmcli) only."
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

AP_IP="${AP_IP:-192.168.4.1}"
SMARTAIR_PORT="${SMARTAIR_PORT:-5001}"
echo ""
echo "=== 7) HTTP / Flask (why http://$AP_IP/ fails but the server is running) ==="
echo "  The app listens on TCP $SMARTAIR_PORT, not 80. Phones should open:"
echo "    http://$AP_IP:$SMARTAIR_PORT/"
if command -v ss &>/dev/null; then
  if ss -tlnp 2>/dev/null | grep -qE ":${SMARTAIR_PORT}\b"; then
    echo "  OK: something is listening on TCP $SMARTAIR_PORT (likely Flask if ./run is active)."
  else
    echo "  WARNING: nothing on TCP $SMARTAIR_PORT — start the app: ./run"
  fi
fi
if command -v ufw &>/dev/null; then
  if ufw status 2>/dev/null | grep -qiE 'Status:\s*active'; then
    echo "  ufw: active — setuphotspot with HOTSPOT_CAPTIVE=1 should add rules for 80 and $SMARTAIR_PORT on $AP_IFACE."
    ufw status 2>/dev/null | sed 's/^/    /' | head -25
  else
    echo "  ufw: inactive or not installed"
  fi
fi
if command -v iptables &>/dev/null; then
  echo "  iptables nat PREROUTING (captive :80 → :$SMARTAIR_PORT; empty if HOTSPOT_CAPTIVE=0 or rule missing):"
  iptables -t nat -L PREROUTING -n -v 2>/dev/null | sed 's/^/    /' || true
  echo "  If HOTSPOT_CAPTIVE=1, you should see REDIRECT 80 to $SMARTAIR_PORT. Re-run: ./setuphotspot"
fi
if command -v curl &>/dev/null; then
  c1=""; c80=""
  c1=$(curl -sS -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${SMARTAIR_PORT}/" 2>/dev/null) || c1="fail"
  c80=$(curl -sS -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:80/" 2>/dev/null) || c80="fail"
  echo "  curl from Pi: 127.0.0.1:${SMARTAIR_PORT} → ${c1} (expect 2xx)   127.0.0.1:80 → ${c80} (2xx if NAT redirect to Flask; else connection refused is OK)"
fi

echo ""
echo "=== Hints (phones do not list the network) ==="
echo "  - The Pi's built-in Wi-Fi is *not* always reliable in AP mode. A cheap USB"
echo "    Wi-Fi dongle and AP_IFACE=wlan1 in .hotspot.env often works better."
echo "  - Use 2.4 GHz only (our script uses hw_mode=g). Turn off 5GHz-only filter on phone."
echo "  - Re-run:  HOTSPOT_USE_CLASSIC=1 ./setuphotspot"
echo "  - Full doc:  $ROOT/docs/pi-wifi-hotspot.md"
echo ""
