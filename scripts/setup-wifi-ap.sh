#!/usr/bin/env bash
# Turn a Raspberry Pi into a Wi-Fi access point for an offline class demo, so phones
# can connect and browse the Flask app. Run ON THE PI, from the project root:
#   ./setuphotspot
# Or: sudo -E ./scripts/setup-wifi-ap.sh
# (after copying scripts/hotspot.env.example to .hotspot.env if you do not use setuphotspot)
#
# This script:
#  - Prefers NetworkManager (nmcli) when it is the active service (common on Pi OS Bookworm desktop).
#  - Otherwise sets up hostapd + dnsmasq + static IP 192.168.4.1/24 (common on Pi OS Lite or without NM).
#  - If nmcli hotspot fails, automatically falls back to hostapd (override with HOTSPOT_NM_NO_FALLBACK=1).
#
# Phones cannot open your website and join Wi-Fi from a *single* QR. Use:
#   ./scripts/generate-demo-qrs.sh --detect
# to create Wi-Fi + URL QRs. See docs/pi-wifi-hotspot.md
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${HOTSPOT_ENV:-$ROOT/.hotspot.env}"
# shellcheck source=/dev/null
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

SMARTAIR_AP_SSID="${SMARTAIR_AP_SSID:-SmartAirDemo}"
SMARTAIR_AP_PASS="${SMARTAIR_AP_PASS:-changeMe99}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
AP_IFACE="${AP_IFACE:-wlan0}"
SMARTAIR_PORT="${SMARTAIR_PORT:-5001}"
CON_NAME="${HOTSPOT_NM_CON_NAME:-SmartAir-AP}"
STATIC_PREFIX="${HOTSPOT_STATIC:-192.168.4}"

log() { printf "\n[smartair-ap] %s\n" "$*"; }
die() { log "ERROR: $*"; exit 1; }

if [[ $(id -u) -ne 0 ]]; then
  die "Run with sudo, e.g.  sudo -E $ROOT/scripts/setup-wifi-ap.sh"
fi

if ((${#SMARTAIR_AP_PASS} < 8)); then
  die "SMARTAIR_AP_PASS must be at least 8 characters (WPA2)."
fi

require_bin() { command -v "$1" &>/dev/null; }

nm_diag() {
  log "---- nmcli (for debugging) ----"
  nmcli general status 2>&1 | sed 's/^/  /' || true
  nmcli dev status 2>&1 | sed 's/^/  /' || true
  nmcli con show --active 2>&1 | sed 's/^/  /' || true
  if [[ -n "${AP_IFACE:-}" ]]; then
    nmcli -f all device show "$AP_IFACE" 2>&1 | sed 's/^/  /' || true
  fi
  log "---- (end) ----"
}

# Regulatory domain (many Pi drivers require it before hostapd)
if command -v iw &>/dev/null; then
  iw reg set "$WIFI_COUNTRY" 2>/dev/null || true
fi
if [[ -d /lib/firmware/brcm ]]; then
  if [[ -f /etc/wpa_supplicant/wpa_supplicant.conf ]] && ! grep -q "country=" /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null; then
    log "You may set country= in /etc/wpa_supplicant/wpa_supplicant.conf to $WIFI_COUNTRY (optional for client mode)"
  fi
fi

if rfkill list wifi 2>/dev/null | grep -q "Soft blocked: yes"; then
  log "Unblocking Wi-Fi (rfkill)"
  rfkill unblock wifi || true
fi

if require_bin apt-get; then
  log "Installing packages (qrencode optional, for generate-demo-qrs)…"
  apt-get update -qq
  apt-get install -y -qq hostapd dnsmasq qrencode 2>/dev/null || apt-get install -y -qq hostapd dnsmasq
fi

use_nm=0
if [[ "${HOTSPOT_USE_CLASSIC:-0}" == "1" ]]; then
  log "HOTSPOT_USE_CLASSIC=1 — skipping NetworkManager, using hostapd"
elif require_bin nmcli; then
  if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
    systemctl start NetworkManager 2>/dev/null || true
    sleep 2
  fi
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    use_nm=1
    log "Will try NetworkManager (nmcli) hotspot on $AP_IFACE first"
  fi
fi

# --- classic stack (hostapd) — used as primary or fallback -----------------
setup_classic_ap() {
  log "Using hostapd + dnsmasq; static $STATIC_PREFIX.1/24 on $AP_IFACE"
  log "Stopping NetworkManager for this session (re-enable: systemctl start NetworkManager)"
  systemctl stop wpa_supplicant@* 2>/dev/null || true
  systemctl stop wpa_supplicant 2>/dev/null || true
  systemctl stop NetworkManager 2>/dev/null || true
  for svc in wpa_supplicant; do
    systemctl stop "$svc" 2>/dev/null || true
  done
  if require_bin systemctl; then
    systemctl unmask hostapd 2>/dev/null || true
  fi
  if require_bin apt-get; then
    dpkg -l dhcpcd5 &>/dev/null || dpkg -l dhcpcd &>/dev/null || apt-get install -y -qq dhcpcd5 2>/dev/null || true
  fi
  DHCPCD_CONF="/etc/dhcpcd.conf"
  if ! grep -q "# --- smartair-ap dhcpcd begin ---" "$DHCPCD_CONF" 2>/dev/null; then
    cat >> "$DHCPCD_CONF" <<DHCPEOF

# --- smartair-ap dhcpcd begin --- (setup-wifi-ap.sh)
denyinterfaces ${AP_IFACE}
interface ${AP_IFACE}
static ip_address=${STATIC_PREFIX}.1/24
nohook wpa_supplicant
# --- smartair-ap dhcpcd end ---
DHCPEOF
  fi
  mkdir -p /etc/dnsmasq.d
  cat >/etc/dnsmasq.d/smartair-ap.conf <<DNS_EOF
# SmartAir
interface=${AP_IFACE}
bind-interfaces
dhcp-range=${STATIC_PREFIX}.2,${STATIC_PREFIX}.200,255.255.255.0,24h
DNS_EOF
  cat >/etc/hostapd/hostapd.conf <<HPEOF
# SmartAir
interface=${AP_IFACE}
driver=nl80211
ssid=${SMARTAIR_AP_SSID}
hw_mode=g
channel=6
wmm_enabled=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${SMARTAIR_AP_PASS}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
country_code=${WIFI_COUNTRY}
HPEOF
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >/etc/default/hostapd
  IP_AP="${STATIC_PREFIX}.1"
  METHOD="hostapd"
  if require_bin systemctl; then
    systemctl enable hostapd
    systemctl enable dnsmasq
    systemctl restart dhcpcd 2>/dev/null || true
    systemctl restart dnsmasq
    systemctl restart hostapd
  else
    service dnsmasq restart
    service hostapd restart
  fi
}

# Returns 0 if hotspot is up, 1 on failure
try_nm_ap() {
  require_bin nmcli || return 1

  log "Preparing $AP_IFACE: turn radio on, ensure managed, clear old connections…"
  nmcli radio wifi on 2>/dev/null || true
  nmcli device set "$AP_IFACE" managed yes 2>/dev/null || {
    log "NetworkManager does not see $AP_IFACE. Check: ip link, wrong AP_IFACE? (export AP_IFACE=wlan1)"
    return 1
  }

  # Bring down any active connection on this device (e.g. home Wi-Fi using wlan0)
  local ac
  ac=$(nmcli -g CONNECTION device show "$AP_IFACE" 2>/dev/null | head -1 | tr -d '\r' || true)
  if [[ -n "$ac" && "$ac" != "--" ]]; then
    log "Bringing down connection: $ac"
    nmcli con down "$ac" 2>/dev/null || true
  fi
  nmcli dev disconnect "$AP_IFACE" 2>/dev/null || true
  sleep 2

  # Remove our old AP profile and common leftovers that block "wifi hotspot" create
  nmcli con delete "$CON_NAME" 2>/dev/null || true
  nmcli con delete "Hotspot" 2>/dev/null || true
  nmcli con delete "preconfigured" 2>/dev/null || true
  # Delete any saved connection that uses this Wi-Fi device (frees the card for AP mode)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    u="${line%%:*}"
    d="${line#*:}"
    [[ -z "$u" || -z "$d" ]] && continue
    if [[ "$d" == "$AP_IFACE" ]]; then
      log "Removing saved profile (UUID) on $AP_IFACE: ${u:0:8}…"
      nmcli con delete uuid "$u" 2>/dev/null || true
    fi
  done < <(nmcli -t -f UUID,DEVICE con show 2>/dev/null || true)
  sleep 1

  log "Creating hotspot: SSID=\"$SMARTAIR_AP_SSID\" on $AP_IFACE…"
  if ! nmcli dev wifi hotspot ifname "$AP_IFACE" con-name "$CON_NAME" \
    ssid "$SMARTAIR_AP_SSID" password "$SMARTAIR_AP_PASS" 2>&1; then
    return 1
  fi

  if [[ "$(nmcli -g 802-11-wireless.country con show "$CON_NAME" 2>/dev/null)" == "" ]]; then
    nmcli con mod "$CON_NAME" 802-11-wireless.country "$WIFI_COUNTRY" 2>/dev/null || true
  fi
  nmcli con up "$CON_NAME" 2>/dev/null || true
  sleep 1
  IP_AP="$(ip -4 -o addr show dev "$AP_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
  METHOD="networkmanager"
  if [[ -z "$IP_AP" ]]; then
    log "nmcli reported success but no IPv4 on $AP_IFACE yet; waiting…"
    sleep 2
    IP_AP="$(ip -4 -o addr show dev "$AP_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
  fi
  return 0
}

IP_AP=""
METHOD=""

if [[ $use_nm -eq 1 ]]; then
  if ! try_nm_ap; then
    log "nmcli hotspot command failed (interface busy, wrong name, or driver quirk)."
    nm_diag
    if [[ "${HOTSPOT_NM_NO_FALLBACK:-0}" == "1" ]]; then
      die "Stuck on nmcli. Fix the issue above, or re-run without HOTSPOT_NM_NO_FALLBACK=1 to use hostapd automatically, or: HOTSPOT_USE_CLASSIC=1 ./setuphotspot"
    fi
    log "Automatic fallback: hostapd + dnsmasq (reliable for demo; NM will be stopped for this run)."
    use_nm=0
  fi
fi

if [[ $use_nm -eq 1 ]]; then
  : # IP_AP / METHOD set in try_nm_ap
else
  setup_classic_ap
fi

# Machine-written (safe to delete on Pi; not committed if .gitignore)
OUT_STATE="${SMARTAIR_AP_STATE_PATH:-$ROOT/.hotspot.state}"
if [[ -n "${IP_AP:-}" ]]; then
  umask 077
  {
    echo "# smartair: written by setup-wifi-ap.sh — $(date -Iseconds 2>/dev/null || date)"
    echo "AP_IP=$IP_AP"
    echo "HOTSPOT_METHOD=$METHOD"
    echo "AP_IFACE=$AP_IFACE"
    echo "SMARTAIR_PORT=$SMARTAIR_PORT"
    echo "SMARTAIR_URL=http://${IP_AP}:${SMARTAIR_PORT}/"
  } >"$OUT_STATE"
  if [[ -n "${SUDO_USER:-}" && -d "$ROOT" ]]; then
    chown "${SUDO_USER}:$(id -gn "$SUDO_USER" 2>/dev/null || echo root)" "$OUT_STATE" 2>/dev/null || true
  fi
fi

log "Done. Hotspot should be: SSID=\"$SMARTAIR_AP_SSID\" (WPA2)"
log "IP on $AP_IFACE: ${IP_AP:-unknown} — use in QR and for Flask: http://<that-ip>:$SMARTAIR_PORT"
log "Mode: $METHOD"
log "Next: run (as normal user)  $ROOT/scripts/generate-demo-qrs.sh --detect"
log "And run your app bound to 0.0.0.0, e.g.  SMARTAIR_PORT=$SMARTAIR_PORT ./run"
if [[ -z "${IP_AP:-}" ]]; then
  log "If IP is empty, wait a few seconds and: ip -4 a show $AP_IFACE"
fi
exit 0
