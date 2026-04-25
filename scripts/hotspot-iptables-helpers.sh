# shellcheck shell=bash
# Sourced from setup-wifi-ap.sh and restore-client-wifi.sh — captive portal NAT :80
hotspot_captive_nat_remove() {
  local to="${2:-5001}" iface="${1:-wlan0}"
  if ! command -v iptables &>/dev/null; then
    return 0
  fi
  while iptables -t nat -C PREROUTING -i "$iface" -p tcp --dport 80 -j REDIRECT --to-ports "$to" 2>/dev/null; do
    iptables -t nat -D PREROUTING -i "$iface" -p tcp --dport 80 -j REDIRECT --to-ports "$to" 2>/dev/null || break
  done
}

hotspot_captive_nat_add() {
  local to="${2:-5001}" iface="${1:-wlan0}"
  if ! command -v iptables &>/dev/null; then
    return 1
  fi
  hotspot_captive_nat_remove "$iface" "$to"
  iptables -t nat -A PREROUTING -i "$iface" -p tcp --dport 80 -j REDIRECT --to-ports "$to"
}
