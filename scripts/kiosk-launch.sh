#!/usr/bin/env bash
# Open the Smart Air dashboard in fullscreen (autostart in the Pi desktop session).
# Waits until http://127.0.0.1:$SMARTAIR_PORT/ responds, then runs Chromium or Firefox kiosk.
# Run from: ~/.config/autostart (see install-smartair-kiosk.sh). Not for SSH-only (Lite) images.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ROOT/.env" 2>/dev/null || true
  set +a
fi
PORT="${SMARTAIR_PORT:-5001}"
URL="${SMARTAIR_KIOSK_URL:-http://127.0.0.1:${PORT}/}"
MAX_WAIT="${SMARTAIR_KIOSK_MAX_WAIT:-90}"

i=0
while [[ $i -lt "$MAX_WAIT" ]]; do
  if command -v curl &>/dev/null; then
    curl -sfS -m 2 -o /dev/null "$URL" 2>/dev/null && break
  else
    [[ $i -ge 20 ]] && break
  fi
  sleep 1
  i=$((i + 1))
done

if command -v chromium &>/dev/null; then
  exec chromium --kiosk --noerrdialogs --disable-translate --disable-infobars \
    --disable-session-crashed-bubble --disable-restore-session-state \
    --check-for-update-interval=31536000 "$URL"
fi
if command -v chromium-browser &>/dev/null; then
  exec chromium-browser --kiosk --noerrdialogs --disable-translate --disable-infobars \
    --disable-session-crashed-bubble --check-for-update-interval=31536000 "$URL"
fi
if command -v google-chrome-stable &>/dev/null; then
  exec google-chrome-stable --kiosk --noerrdialogs "$URL"
fi
if command -v firefox &>/dev/null; then
  exec firefox -kiosk "$URL"
fi

echo "smartair-kiosk: install a browser, e.g.  sudo apt install -y chromium" >&2
exit 1
