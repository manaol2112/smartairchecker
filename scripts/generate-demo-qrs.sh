#!/usr/bin/env bash
# Generate two PNGs for your demo table: Wi-Fi join QR + project URL QR
# From project root. Requires: qrencode  (apt install qrencode)
#
#   ./scripts/generate-demo-qrs.sh
#   AP_IP=10.42.0.1 SMARTAIR_PORT=5001 ./scripts/generate-demo-qrs.sh
#   ./scripts/generate-demo-qrs.sh --detect   # parse IP from wlan0 (or AP_IFACE)
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT_DIR="${DEMO_QR_DIR:-$ROOT/docs/generated}"
ENV_FILE="${HOTSPOT_ENV:-$ROOT/.hotspot.env}"
STATE_FILE="${HOTSPOT_STATE:-$ROOT/.hotspot.state}"
# shellcheck source=/dev/null
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi
# shellcheck source=/dev/null
if [[ -f "$STATE_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$STATE_FILE"
  set +a
fi

SMARTAIR_AP_SSID="${SMARTAIR_AP_SSID:-SmartAirDemo}"
SMARTAIR_AP_PASS="${SMARTAIR_AP_PASS:-changeMe99}"
SMARTAIR_PORT="${SMARTAIR_PORT:-5001}"
AP_IFACE="${AP_IFACE:-wlan0}"
WIFI_TYPE="${WIFI_TYPE:-WPA2}"

if ! command -v qrencode &>/dev/null; then
  echo "Install qrencode:  sudo apt-get install -y qrencode" >&2
  exit 1
fi

detect_ip() {
  if [[ -n "${AP_IP:-}" ]]; then
    echo "$AP_IP"
    return
  fi
  ip -4 -o addr show dev "$AP_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

if [[ "${1:-}" == "--detect" ]]; then
  export AP_IP="$(detect_ip)"
  if [[ -z "$AP_IP" ]]; then
    echo "Could not detect IP on $AP_IFACE. Set AP_IP=… yourself." >&2
    exit 1
  fi
  echo "Detected AP_IP=$AP_IP"
fi

AP_IP="${AP_IP:-$(detect_ip)}"
if [[ -z "$AP_IP" ]]; then
  echo "Set AP_IP (e.g. 10.42.0.1 or 192.168.4.1) or run with --detect while hotspot is on." >&2
  exit 1
fi

# Escape for WIFI:... QR (ZEbra crossing style — backslash, quote, semicolon, comma, colon in P)
# https://github.com/zxing/zxing/wiki/Barcode-Contents
escape_wifi_pass() {
  local s=$1
  local o=""
  local i
  for ((i = 0; i < ${#s}; i++)); do
    local c=${s:$i:1}
    case $c in
    \\) o+=\\\\ ;;
    \") o+=\\\" ;;
    \;) o+=\; ;;
    \,) o+=\\, ;;
    \:) o+=\\: ;;
    *) o+=$c ;;
    esac
  done
  printf '%s' "$o"
}

P_ESC="$(escape_wifi_pass "$SMARTAIR_AP_PASS")"
WIFI_STR="WIFI:T:${WIFI_TYPE};S:${SMARTAIR_AP_SSID};P:${P_ESC};;"
URL="http://${AP_IP}:${SMARTAIR_PORT}/"

mkdir -p "$OUT_DIR"
WF="$OUT_DIR/demo-wifi-join.png"
UR="$OUT_DIR/demo-project-url.png"

printf '%s' "$WIFI_STR" | qrencode -t PNG -o "$WF" -s 8 -m 2
printf '%s' "$URL" | qrencode -t PNG -o "$UR" -s 8 -m 2

# Small text file for the poster
cat > "$OUT_DIR/demo-poster-hints.txt" <<EOF
=== Smart Air Checker — demo table ===

1) First QR  →  Join Wi-Fi (demo-wifi-join.png)
2) Then open  →  $URL
   (second QR: demo-project-url.png)

SSID:     $SMARTAIR_AP_SSID
Password: (hotspot password you set; not shown here if you re-copy this file)
EOF

echo "Wrote:"
echo "  $WF  (scan to join Wi-Fi)"
echo "  $UR  (open project — after connected)"
echo "  $OUT_DIR/demo-poster-hints.txt"
echo "Project URL: $URL"
