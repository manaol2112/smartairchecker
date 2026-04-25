#!/usr/bin/env bash
# Stops the SmartAir hostapd + dnsmasq hotspot so you can use normal client Wi-Fi again.
# EMERGENCY: if the Pi is "frozen", use Ethernet + keyboard or power-cycle, then run this
# (or: sudo killall -9 hostapd dnsmasq; then this script from a TTY with sudo).
# Uses kill -9 on dnsmasq/hostapd first because systemctl can block when dbus is wedged.
#
# From project root:  sudo ./scripts/restore-client-wifi.sh
# Optional: HOTSPOT_ENV=/path/to/.hotspot.env
set -euo pipefail
_R="$(cd "$(dirname "$0")" && pwd)/.."
if [[ -n "${HOTSPOT_ENV:-}" && -f "${HOTSPOT_ENV}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${HOTSPOT_ENV}" 2>/dev/null || true
  set +a
elif [[ -f "$_R/.hotspot.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$_R/.hotspot.env" 2>/dev/null || true
  set +a
fi
if [[ -f "$_R/.hotspot.state" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$_R/.hotspot.state" 2>/dev/null || true
  set +a
fi
# shellcheck source=hotspot-iptables-helpers.sh
# shellcheck disable=SC1090
. "$(cd "$(dirname "$0")" && pwd)/hotspot-iptables-helpers.sh" 2>/dev/null || true

AP_IFACE="${AP_IFACE:-wlan0}"
SMARTAIR_PORT="${SMARTAIR_PORT:-5001}"
log() { printf "\n[restore-client-wifi] %s\n" "$*"; }
if [[ $(id -u) -ne 0 ]]; then
  echo "Run with: sudo $0" >&2
  exit 1
fi

log "Removing captive iptables :80 → :$SMARTAIR_PORT (if any)…"
if declare -F hotspot_captive_nat_remove &>/dev/null; then
  hotspot_captive_nat_remove "$AP_IFACE" "$SMARTAIR_PORT" || true
else
  while iptables -t nat -C PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$SMARTAIR_PORT" 2>/dev/null; do
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$SMARTAIR_PORT" 2>/dev/null || break
  done
fi

log "Stopping hostapd and dnsmasq (SIGKILL if needed so SSH can recover)…"
set +e
systemctl --no-block stop hostapd 2>/dev/null
systemctl --no-block stop dnsmasq 2>/dev/null
sleep 1
killall -9 hostapd 2>/dev/null || true
killall -9 dnsmasq 2>/dev/null || true
sleep 1
set -e
if pgrep -x hostapd &>/dev/null; then
  pkill -9 -x hostapd 2>/dev/null || true
fi
if pgrep -x dnsmasq &>/dev/null; then
  pkill -9 -x dnsmasq 2>/dev/null || true
fi

ip link set dev "$AP_IFACE" down 2>/dev/null || true
if ip -4 -o addr show dev "$AP_IFACE" 2>/dev/null | grep -q .; then
  ip -4 address flush dev "$AP_IFACE" 2>/dev/null || true
fi
ip link set dev "$AP_IFACE" up 2>/dev/null || true

if systemctl is-failed NetworkManager 2>/dev/null; then
  log "NetworkManager: reset-failed (after kill during hotspot)…"
  systemctl reset-failed NetworkManager 2>/dev/null || true
fi

log "Starting NetworkManager (timeout 45s)…"
set +e
if command -v timeout &>/dev/null; then
  timeout 45s systemctl start NetworkManager
  rc=$?
else
  systemctl start NetworkManager
  rc=$?
fi
set -e
if [[ "$rc" -ne 0 ]]; then
  log "NetworkManager start failed (rc=$rc). If Pi is very stuck:  sudo reboot"
  log "  journal:  journalctl -u NetworkManager -b -n 30"
  exit 1
fi
log "OK — Wi-Fi back in a few seconds (nmtui / nmcli). No hotspot on boot:  systemctl disable hostapd dnsmasq"
log "Re-run demo:  ./setuphotspot  |  If captive made the Pi unresponsive, keep HOTSPOT_CAPTIVE_WILDCARD=0 and use the default 'light' DNS in setup."
exit 0
