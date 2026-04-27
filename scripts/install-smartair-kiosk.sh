#!/usr/bin/env bash
# Install a desktop autostart entry so a browser opens the dashboard at login (Raspberry Pi OS with GUI).
# Requires smartair-web.service (./run on boot). Headless/SSH-only images: skip; use a phone/QR instead.
#
#   sudo ./scripts/install-smartair-kiosk.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-$ROOT/.client-demo.env}"
LAUNCHER="$ROOT/scripts/kiosk-launch.sh"
ENTRY_NAME="smartair-kiosk.desktop"

if [[ $(id -u) -ne 0 ]]; then
  echo "Run with: sudo $0" >&2
  exit 1
fi
if [[ ! -x "$LAUNCHER" ]]; then
  echo "Run:  chmod +x $LAUNCHER" >&2
  exit 1
fi
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE" 2>/dev/null || true
  set +a
fi
U=""
if [[ -n "${CLIENT_DEMO_USER:-}" ]] && id -u "$CLIENT_DEMO_USER" &>/dev/null; then
  U="$CLIENT_DEMO_USER"
fi
if [[ -z "$U" && -n "${SUDO_USER:-}" ]] && id -u "$SUDO_USER" &>/dev/null; then
  U="$SUDO_USER"
fi
if [[ -z "$U" ]]; then
  U="$(getent passwd 2>/dev/null | awk -F: '$3==1000{print $1; exit}')"
fi
if [[ -z "$U" ]] || ! id -u "$U" &>/dev/null; then
  echo "Could not find desktop user. Set CLIENT_DEMO_USER in $ENV_FILE or run as: sudo -u <user> $0" >&2
  exit 1
fi
H="$(eval echo ~"$U")"
[[ -d "$H" ]] || { echo "Home for $U not found: $H" >&2; exit 1; }
AUTOD="$H/.config/autostart"
mkdir -p "$AUTOD"
chown -R "$U": "$H/.config" 2>/dev/null || true

# Desktop session runs as user — full path, keep env in wrapper
cat >"$AUTOD/$ENTRY_NAME" <<EOF
[Desktop Entry]
Type=Application
Name=Smart Air dashboard
Comment=Kiosk browser to local Smart Air (default port 5001, after smartair-web is up)
Exec=$LAUNCHER
X-GNOME-Autostart-enabled=true
Hidden=false
Terminal=false
Categories=Network;
EOF
chown "$U": "$AUTOD/$ENTRY_NAME"
chmod 644 "$AUTOD/$ENTRY_NAME"

echo "[install-smartair-kiosk] Installed: $AUTOD/$ENTRY_NAME (user $U)"
echo "  Reboot the Pi or log out/in to start the kiosk, or:  su - $U -c 'DISPLAY=:0 $LAUNCHER' (if display :0 is active)"
echo "  Remove:  rm -f $AUTOD/$ENTRY_NAME"
exit 0
