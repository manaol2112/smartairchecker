#!/usr/bin/env bash
# Run on the Pi (no sudo) to see why http://<static-ip>:5001/ may not load.
# Optional:  SMARTAIR_PORT=5001  ./scripts/verify-client-demo.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${CLIENT_DEMO_ENV:-$ROOT/.client-demo.env}"
SMARTAIR_PORT="${SMARTAIR_PORT:-5001}"
IFACE="wlan0"
# shellcheck source=/dev/null
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE" 2>/dev/null || true
  set +a
  IFACE="${CLIENT_DEMO_IFACE:-$IFACE}"
fi

echo "=== 1) Address on $IFACE (expect your CLIENT_DEMO_IPV4) ==="
ip -4 addr show dev "$IFACE" 2>/dev/null | sed 's/^/  /' || echo "  (no such interface)"
echo ""
echo "=== 2) Default route (should point at phone gateway) ==="
ip -4 route 2>/dev/null | sed 's/^/  /' | head -15
echo ""
if command -v nmcli &>/dev/null; then
  echo "=== 3) NetworkManager: active + IPv4 for our profile ==="
  nmcli -f NAME,TYPE,DEVICE,IP4.ADDRESS,IP4.GATEWAY,IP4.METHOD,STATE con show --active 2>/dev/null | sed 's/^/  /' | head -30 || true
  echo ""
fi
echo "=== 4) Something listening on TCP $SMARTAIR_PORT? ==="
if command -v ss &>/dev/null; then
  if ss -tlnp 2>/dev/null | grep -qE ":$SMARTAIR_PORT\\b"; then
    ss -tlnp 2>/dev/null | grep -E ".:$SMARTAIR_PORT" | sed 's/^/  /'
  else
    echo "  nothing on $SMARTAIR_PORT — start:  $ROOT/run  or  sudo systemctl start smartair-web"
  fi
else
  echo "  (install iproute2 for ss)"
fi
echo ""
echo "=== 5) From this Pi to itself (proves app binds) ==="
if command -v curl &>/dev/null; then
  c=$(curl -sS -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${SMARTAIR_PORT}/" 2>/dev/null) || c="error"
  echo "  curl http://127.0.0.1:$SMARTAIR_PORT/  →  HTTP $c  (2xx/3xx = OK)"
else
  echo "  (install curl to test)"
fi
echo ""
echo "=== 6) Firewall (ufw can block a phone) ==="
if command -v ufw &>/dev/null; then
  ufw status 2>/dev/null | sed 's/^/  /' | head -12
  if ufw status 2>/dev/null | grep -qiE 'Status:\s*active'; then
    echo "  If active, on the host run:  sudo ufw allow in on $IFACE to any port $SMARTAIR_PORT"
  fi
else
  echo "  (ufw not installed)"
fi
echo ""
echo "=== Hints ==="
echo "  • Wrong static (Android is usually 192.168.43.x; iPhone is 172.20.10.x) — check ip output vs .client-demo.env, re-run setup-client-wifi.sh"
echo "  • Re-run:  sudo $ROOT/scripts/setup-client-wifi.sh (applies down/up so static IP sticks)"
echo "  • After editing env:  $ROOT/docs/client-demo-headless.md"
echo ""
