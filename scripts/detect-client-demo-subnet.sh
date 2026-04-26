#!/usr/bin/env bash
# Read-only: with the Pi connected to the phone hotspot (DHCP), print the subnet and
# copy-paste lines for .client-demo.env. Run:  ./scripts/detect-client-demo-subnet.sh [wlan0]
# Not all Android builds use 192.168.43.0/24 — many use 10.x or other private ranges.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
IFACE="${1:-${CLIENT_DEMO_IFACE:-wlan0}}"
export CLIENT_DEMO_IFACE="${IFACE}"
PICK="$ROOT/scripts/pick-client-static.py"
export CLIENT_DEMO_HOST_LAST="${CLIENT_DEMO_HOST_LAST:-200}"

if ! ip link show "$IFACE" &>/dev/null; then
  echo "Interface $IFACE not found. Usage:  $0 [wlan0|wlan1]" >&2
  exit 1
fi

get_act_cidr() {
  ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk 'NR==1{print $4}'
}

get_act_gw() {
  local g
  g=$(ip -4 route show default dev "$IFACE" 2>/dev/null | head -1 | awk '{for (i=1; i<NF; i++) if ($i == "via") { print $(i+1); exit }}')
  if [[ -z "$g" ]]; then
    g=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<NF; i++) if ($i == "via") { print $(i+1); exit }}')
  fi
  echo "${g:-}"
}

ACT_CIDR=$(get_act_cidr)
ACT_GW=$(get_act_gw)
if [[ -z "$ACT_CIDR" || -z "$ACT_GW" ]]; then
  echo "No IPv4 on $IFACE or no default route — join the hotspot (DHCP) first, then re-run." >&2
  echo "  ip -4 a show $IFACE" >&2
  echo "  ip -4 route" >&2
  exit 1
fi
if ! [[ -f "$PICK" ]]; then
  echo "Missing $PICK" >&2
  exit 1
fi
SUGG=$(ACT_CIDR="$ACT_CIDR" CLIENT_DEMO_HOST_LAST="$CLIENT_DEMO_HOST_LAST" python3 "$PICK" "$ACT_CIDR")

echo "Interface: $IFACE"
echo "  Current lease:  $ACT_CIDR  (use this to infer the phone’s subnet)"
echo "  Default gateway: $ACT_GW  (set CLIENT_DEMO_GW to this)"
echo ""
echo "Copy into .client-demo.env (or merge with your SSID/PSK):"
echo "CLIENT_DEMO_GW=$ACT_GW"
echo "CLIENT_DEMO_DNS=$ACT_GW"
echo "CLIENT_DEMO_IPV4=$SUGG"
echo ""
echo "Optional:  CLIENT_DEMO_HOST_LAST=200  (last octet for /24 when pick-client-static / setup aligns)"
echo "Then:  sudo $ROOT/scripts/setup-client-wifi.sh"
