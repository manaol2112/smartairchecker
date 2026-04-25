#!/usr/bin/env bash
# Stops the SmartAir hostapd + dnsmasq hotspot so you can use normal client Wi-Fi again.
# EMERGENCY: if the Pi is "frozen", use Ethernet + keyboard or power-cycle, then run this
# (or: sudo killall -9 hostapd dnsmasq; then this script from a TTY with sudo).
# Uses kill -9 on dnsmasq/hostapd first because systemctl can block when dbus is wedged.
# NetworkManager is started with "systemctl start --no-block" (we do not wait for NM to be
# "active" — that call can hang for minutes on a busy Pi) — Wi‑Fi may take 30–60s to return.
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

# Any systemctl can block if D-Bus is wedged; always bound by time (and prefer kill before systemctl for hotspot daemons)
run_with_timeout() {
  local sec="$1"
  shift
  if command -v timeout &>/dev/null; then
    timeout "$sec" "$@"
    return $?
  fi
  "$@" &
  local pid=$! w=0
  while (( w < sec )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      return $?
    fi
    sleep 1
    w=$((w + 1))
  done
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

H_HELP="$(cd "$(dirname "$0")" && pwd)/hotspot-iptables-helpers.sh"
log "Removing captive iptables :80 → :$SMARTAIR_PORT (if any; max 25s)…"
if declare -F hotspot_captive_nat_remove &>/dev/null; then
  if command -v timeout &>/dev/null; then
    # netfilter/iptables can block if the kernel is under heavy load
    if ! timeout 25s bash -c ". \"\$0\" 2>/dev/null; declare -F hotspot_captive_nat_remove &>/dev/null && hotspot_captive_nat_remove \"\$1\" \"\$2\"" \
      "$H_HELP" "$AP_IFACE" "$SMARTAIR_PORT" 2>/dev/null; then
      log "iptables NAT remove hit timeout or error — you may need  sudo reboot  if NAT rules linger"
    fi
  else
    hotspot_captive_nat_remove "$AP_IFACE" "$SMARTAIR_PORT" || true
  fi
else
  _n=0
  while ((_n < 32)) && iptables -t nat -C PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$SMARTAIR_PORT" 2>/dev/null; do
    _n=$((_n + 1))
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$SMARTAIR_PORT" 2>/dev/null || break
  done
fi

log "Killing hostapd + dnsmasq first (avoids a stuck systemctl stop when D-Bus is slow)…"
set +e
killall -9 hostapd 2>/dev/null || true
killall -9 dnsmasq 2>/dev/null || true
pkill -9 -x hostapd 2>/dev/null || true
pkill -9 -x dnsmasq 2>/dev/null || true
sleep 1
log "systemctl --no-block stop (best effort, 12s max)…"
run_with_timeout 12 systemctl --no-block stop hostapd 2>/dev/null || true
run_with_timeout 12 systemctl --no-block stop dnsmasq 2>/dev/null || true
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

set +e
run_with_timeout 4 systemctl is-failed NetworkManager 2>/dev/null
_nmf=$?
set -e
# 0 = unit is in failed state; 124 = skip reset
if [[ "$_nmf" -eq 0 ]]; then
  log "NetworkManager: reset-failed (best effort)…"
  run_with_timeout 4 systemctl reset-failed NetworkManager 2>/dev/null || true
fi

# Plain "systemctl start NetworkManager" waits until the unit is active — on a busy Pi that can
# sit for *many* minutes and look like a hang. Only queue the job; do not wait for activation.
log "Queuing NetworkManager start (no-block, max 15s for D-Bus) — script exits without waiting for Wi‑Fi…"
set +e
run_with_timeout 15 systemctl start --no-block NetworkManager 2>/dev/null
_nms=$?
set -e
if [[ "$_nms" -eq 124 ]]; then
  log "Even --no-block start hit the timeout; D-Bus is likely stuck. Last resort:  sudo reboot  (or Ethernet shell)"
else
  log "NetworkManager start was queued. Allow up to 1–2 min for the desktop Wi‑Fi icon, or:  nmtui / nmcli"
fi

log "Unblocking radio (best effort)…"
run_with_timeout 5 rfkill unblock wifi 2>/dev/null || true

log "Disabling hostapd + dnsmasq on boot (no-block) so the hotspot does not return after reboot…"
set +e
run_with_timeout 8 systemctl --no-block disable hostapd 2>/dev/null || true
run_with_timeout 8 systemctl --no-block disable dnsmasq 2>/dev/null || true
set -e

log "If Wi‑Fi does not return:  sudo systemctl restart NetworkManager   |   still broken:  sudo reboot"
log "Re-run demo:  ./setuphotspot  |  If captive made the Pi unresponsive, keep HOTSPOT_CAPTIVE_WILDCARD=0"
exit 0
