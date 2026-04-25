#!/usr/bin/env bash
# Stops the SmartAir hostapd + dnsmasq hotspot so you can use normal client Wi-Fi again.
# While hostapd holds wlan0 in AP mode, "systemctl start NetworkManager" cannot use that card.
# A force-kill of NetworkManager (used during setup) can leave the unit in "failed" — we reset that.
#
# On the Pi, from the project root:
#   sudo ./scripts/restore-client-wifi.sh
#
# Or:  sudo bash /path/to/scripts/restore-client-wifi.sh
# Optional:  HOTSPOT_ENV=/path/to/.hotspot.env  (for AP_IFACE, default wlan0)
set -euo pipefail
if [[ -n "${HOTSPOT_ENV:-}" && -f "${HOTSPOT_ENV}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${HOTSPOT_ENV}" 2>/dev/null || true
  set +a
else
  _here="$(cd "$(dirname "$0")" && pwd)/.."
  if [[ -f "$_here/.hotspot.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$_here/.hotspot.env" 2>/dev/null || true
    set +a
  fi
fi
AP_IFACE="${AP_IFACE:-wlan0}"
log() { printf "\n[restore-client-wifi] %s\n" "$*"; }
if [[ $(id -u) -ne 0 ]]; then
  echo "Run with: sudo $0" >&2
  exit 1
fi

log "Stopping hotspot (hostapd, dnsmasq) so $AP_IFACE is free for NetworkManager…"
systemctl stop hostapd 2>/dev/null || true
pkill -x hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
sleep 1
if systemctl is-active --quiet hostapd 2>/dev/null || pgrep -x hostapd &>/dev/null; then
  log "hostapd is still up —  sudo killall -9 hostapd  (only if the card stays stuck in AP mode)"
fi

ip link set dev "$AP_IFACE" down 2>/dev/null || true
if ip -4 -o addr show dev "$AP_IFACE" 2>/dev/null | grep -q .; then
  ip -4 address flush dev "$AP_IFACE" 2>/dev/null || true
fi
ip link set dev "$AP_IFACE" up 2>/dev/null || true

if systemctl is-failed NetworkManager 2>/dev/null; then
  log "NetworkManager is in 'failed' state (common after a force stop during hotspot setup) — reset-failed…"
  systemctl reset-failed NetworkManager 2>/dev/null || true
fi

log "Starting NetworkManager…"
if systemctl start NetworkManager; then
  log "OK. In a few seconds: desktop Wi-Fi, or:  nmtui  /  nmcli dev wifi rescan"
else
  log "Start failed. See:  journalctl -u NetworkManager -b -n 40"
  log "Raspberry Pi OS Lite may not have NetworkManager:  sudo apt install network-manager"
  exit 1
fi
log "Optional — no hotspot on boot:  sudo systemctl disable hostapd dnsmasq"
log "To run the demo hotspot again:  ./setuphotspot  (from the project tree)"
exit 0
