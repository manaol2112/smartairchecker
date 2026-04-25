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
#  - If nmcli hotspot fails or the card never reaches real AP mode (per iw), falls back to hostapd
#    (override with HOTSPOT_NM_NO_FALLBACK=1, or set HOTSPOT_NM_STRICT=1 to keep the NM result anyway).
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
# 2.4 GHz channel; 1 is widely compatible. Override with AP_CHANNEL=6 in .hotspot.env
AP_CHANNEL="${AP_CHANNEL:-1}"
SMARTAIR_PORT="${SMARTAIR_PORT:-5001}"
CON_NAME="${HOTSPOT_NM_CON_NAME:-SmartAir-AP}"
STATIC_PREFIX="${HOTSPOT_STATIC:-192.168.4}"

log() { printf "\n[smartair-ap] %s\n" "$*"; }
die() { log "ERROR: $*"; exit 1; }

if [[ $(id -u) -ne 0 ]]; then
  die "Run with sudo, e.g.  sudo -E $ROOT/scripts/setup-wifi-ap.sh"
fi

if [[ "${SMARTAIR_AP_OPEN:-0}" != "1" ]] && ((${#SMARTAIR_AP_PASS} < 8)); then
  die "SMARTAIR_AP_PASS must be at least 8 characters (WPA2), or set SMARTAIR_AP_OPEN=1 for an open network (no password)."
fi

require_bin() { command -v "$1" &>/dev/null; }

if ! ip link show "$AP_IFACE" &>/dev/null; then
  log "No Wi-Fi interface $AP_IFACE. Available links:"
  ip -br link 2>/dev/null | sed 's/^/  /' || true
  die "Set AP_IFACE in .hotspot.env (e.g. wlan1 if you use a USB Wi-Fi adapter)."
fi

# 192.168.4.1 must exist on the AP iface before dnsmasq can hand out leases (or phones show "unable to connect")
ensure_classic_ap_ip() {
  local cidr="${STATIC_PREFIX}.1/24"
  if ! ip -4 -o addr show dev "$AP_IFACE" 2>/dev/null | grep -qF "${STATIC_PREFIX}.1/"; then
    log "No ${STATIC_PREFIX}.1 on $AP_IFACE after dhcpcd — setting address (required for phone DHCP)…"
    ip link set dev "$AP_IFACE" up 2>/dev/null || true
    ip -4 address replace "$cidr" dev "$AP_IFACE" 2>/dev/null || ip -4 address add "$cidr" dev "$AP_IFACE" 2>/dev/null || true
  fi
  if ! ip -4 -o addr show dev "$AP_IFACE" 2>/dev/null | grep -qF "${STATIC_PREFIX}.1/"; then
    log "ERROR: $AP_IFACE still has no ${STATIC_PREFIX}.1 — check /etc/dhcpcd.conf; phones will not get an IP from dnsmasq."
  else
    log "AP IPv4 on $AP_IFACE: ${STATIC_PREFIX}.1 (OK for dnsmasq DHCP to clients)"
  fi
}

# AP mode is required for the network to be visible; checked after setup
ap_mode_is_up() {
  if ! command -v iw &>/dev/null; then
    return 1
  fi
  iw dev "$AP_IFACE" info 2>/dev/null | grep -qi "type ap"
}

# Captive-style demo: send phones’ HTTP probes to Flask without binding :80
captive_iptables() {
  if [[ "${HOTSPOT_CAPTIVE:-0}" != "1" ]]; then
    return 0
  fi
  if ! require_bin iptables; then
    log "HOTSPOT_CAPTIVE=1 but iptables not found — install iptables to redirect :80 to :$SMARTAIR_PORT"
    return 0
  fi
  while iptables -t nat -C PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$SMARTAIR_PORT" 2>/dev/null; do
    iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$SMARTAIR_PORT" 2>/dev/null || break
  done
  if ! iptables -t nat -A PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$SMARTAIR_PORT" 2>/dev/null; then
    log "WARNING: iptables redirect failed; HTTP on port 80 may not reach Flask"
  else
    log "Captive: TCP port 80 on $AP_IFACE → 127.0.0.1:$SMARTAIR_PORT (run ./run; .hotspot.env loads HOTSPOT_CAPTIVE for /generate_204 etc.)"
  fi
}

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
  log "Installing packages (iw, hostapd, dnsmasq, qrencode optional)…"
  apt-get update -qq
  apt-get install -y -qq iw hostapd dnsmasq wpasupplicant qrencode 2>/dev/null || apt-get install -y -qq iw hostapd dnsmasq wpasupplicant
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

if [[ "${SMARTAIR_AP_OPEN:-0}" == "1" ]]; then
  log "SMARTAIR_AP_OPEN=1 — open network (no WPA); using hostapd + dnsmasq (not nmcli)"
  use_nm=0
fi
if [[ "${HOTSPOT_CAPTIVE:-0}" == "1" ]]; then
  log "HOTSPOT_CAPTIVE=1 — captive-style DNS + iptables need hostapd path; not using NetworkManager for this run"
  use_nm=0
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
    dpkg -l iw &>/dev/null || apt-get install -y -qq iw 2>/dev/null || true
  fi
  ip link set dev "$AP_IFACE" up 2>/dev/null || true
  iw dev "$AP_IFACE" set power_save off 2>/dev/null || true
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
  if [[ "${HOTSPOT_CAPTIVE:-0}" == "1" ]]; then
    log "HOTSPOT_CAPTIVE=1 — dnsmasq answers DNS on :53 (${STATIC_PREFIX}.1 only); all names → Pi (see docs/pi-wifi-hotspot.md)"
    cat >/etc/dnsmasq.d/smartair-ap.conf <<DNS_EOF
# SmartAir — DHCP + resolve all A records to the AP (captive-style demo)
port=53
no-resolv
interface=${AP_IFACE}
bind-dynamic
listen-address=${STATIC_PREFIX}.1
domain-needed
bogus-priv
dhcp-authoritative
dhcp-range=${STATIC_PREFIX}.2,${STATIC_PREFIX}.200,255.255.255.0,24h
dhcp-option=3,${STATIC_PREFIX}.1
dhcp-option=6,${STATIC_PREFIX}.1
address=/#/${STATIC_PREFIX}.1
DNS_EOF
  else
    cat >/etc/dnsmasq.d/smartair-ap.conf <<DNS_EOF
# SmartAir — DHCP only (port=0) so we do not bind DNS :53 (avoids clash with systemd-resolved)
port=0
interface=${AP_IFACE}
# bind-dynamic: more reliable on Pi than bind-interfaces if iface comes up late
bind-dynamic
dhcp-authoritative
dhcp-range=${STATIC_PREFIX}.2,${STATIC_PREFIX}.200,255.255.255.0,24h
dhcp-option=3,${STATIC_PREFIX}.1
dhcp-option=6,${STATIC_PREFIX}.1
DNS_EOF
  fi
  if [[ "${SMARTAIR_AP_OPEN:-0}" == "1" ]]; then
    log "SMARTAIR_AP_OPEN=1 — open access point (no password); wpa=0"
    cat >/etc/hostapd/hostapd.conf <<HPEOF
# SmartAir (open / no WPA)
interface=${AP_IFACE}
driver=nl80211
ssid=${SMARTAIR_AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
ieee80211n=1
wmm_enabled=1
beacon_int=100
auth_algs=1
ignore_broadcast_ssid=0
wpa=0
country_code=${WIFI_COUNTRY}
HPEOF
  else
    # 64-hex wpa_psk avoids hostapd # comments; wpa_passphrase(8) from wpasupplicant
    HAP_WPA_LINE="wpa_passphrase=${SMARTAIR_AP_PASS}"
    if require_bin wpa_passphrase; then
      if pmk=$(wpa_passphrase "$SMARTAIR_AP_SSID" "$SMARTAIR_AP_PASS" 2>/dev/null | sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p' | head -1) && [[ -n "$pmk" ]]; then
        HAP_WPA_LINE="wpa_psk=$pmk"
      else
        log "wpa_passphrase: could not derive PSK; using wpa_passphrase= in hostapd (avoid # in the password, or install wpasupplicant)"
      fi
    else
      log "wpa_passphrase not found; install wpasupplicant for the most reliable WPA2 password handling"
    fi
    cat >/etc/hostapd/hostapd.conf <<HPEOF
# SmartAir
interface=${AP_IFACE}
driver=nl80211
ssid=${SMARTAIR_AP_SSID}
# 2.4 GHz; channel must be legal in WIFI_COUNTRY
hw_mode=g
channel=${AP_CHANNEL}
ieee80211n=1
# WMM on helps many phones list the network; ignore_broadcast=0 = SSID not hidden
wmm_enabled=1
beacon_int=100
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
${HAP_WPA_LINE}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
country_code=${WIFI_COUNTRY}
HPEOF
  fi
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >/etc/default/hostapd
  IP_AP="${STATIC_PREFIX}.1"
  METHOD="hostapd"
  if require_bin systemctl; then
    systemctl unmask hostapd 2>/dev/null || true
    systemctl stop hostapd 2>/dev/null || true
    pkill -x hostapd 2>/dev/null || true
    sleep 1
    if require_bin hostapd; then
      if hp_test=$(hostapd -t /etc/hostapd/hostapd.conf 2>&1); then
        log "hostapd: config OK (hostapd -t)"
      else
        log "hostapd -t: $hp_test"
      fi
    fi
    systemctl enable hostapd
    systemctl enable dnsmasq
    systemctl restart dhcpcd 2>/dev/null || true
    sleep 2
    ensure_classic_ap_ip
    # Not captive: port=0; captive: :53 (see HOTSPOT_CAPTIVE) — if dnsmasq fails, check: journalctl -u dnsmasq
    systemctl restart dnsmasq 2>&1 | sed 's/^/  [dnsmasq] /' || true
    if ! systemctl is-active --quiet dnsmasq 2>/dev/null; then
      log "ERROR: dnsmasq is not running — clients will not get an IP; Wi-Fi will show 'unable to connect' on many phones. journal:"
      journalctl -u dnsmasq -n 25 --no-pager 2>&1 | sed 's/^/  /' || true
    fi
    if ! systemctl start hostapd 2>/dev/null; then
      log "systemctl start hostapd failed — will try hostapd -B if still down…"
    fi
    if ! systemctl is-active --quiet hostapd 2>/dev/null && ! pgrep -x hostapd &>/dev/null; then
      log "Starting hostapd without systemd (hostapd -B)…"
      if hp_out=$(hostapd -B /etc/hostapd/hostapd.conf 2>&1); then
        [[ -n "$hp_out" ]] && log "hostapd -B: $hp_out"
      else
        log "hostapd -B failed: $hp_out"
      fi
    fi
    sleep 2
    if ! systemctl is-active --quiet hostapd 2>/dev/null && ! pgrep -x hostapd &>/dev/null; then
      log "hostapd is still not running. Last hostapd journal:"
      journalctl -u hostapd -n 50 --no-pager 2>&1 | sed 's/^/  /' || true
    elif ! ap_mode_is_up; then
      log "hostapd is running but $AP_IFACE is not in AP mode yet. Driver issue? try USB Wi-Fi (AP_IFACE=wlan1)"
    fi
    captive_iptables
  else
    service dnsmasq restart 2>/dev/null || true
    service hostapd restart 2>/dev/null || true
    captive_iptables
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
  sleep 2
  if ! ap_mode_is_up; then
    log "NetworkManager did not put $AP_IFACE in real AP mode (iw shows no 'type ap')."
    if [[ "${HOTSPOT_NM_STRICT:-0}" == "1" ]]; then
      log "HOTSPOT_NM_STRICT=1 — not falling back; verify-hotspot may still warn. Prefer unsetting this or use HOTSPOT_USE_CLASSIC=1."
      return 0
    fi
    return 1
  fi
  return 0
}

IP_AP=""
METHOD=""

if [[ $use_nm -eq 1 ]]; then
  if ! try_nm_ap; then
    log "NetworkManager path did not yield a real AP (nmcli failed, or iw never shows type ap)."
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
  if [[ "${HOTSPOT_CAPTIVE:-0}" == "1" ]]; then
    PUB_URL="http://${IP_AP}/"
  else
    PUB_URL="http://${IP_AP}:${SMARTAIR_PORT}/"
  fi
  {
    echo "# smartair: written by setup-wifi-ap.sh — $(date -Iseconds 2>/dev/null || date)"
    echo "AP_IP=$IP_AP"
    echo "HOTSPOT_METHOD=$METHOD"
    echo "AP_IFACE=$AP_IFACE"
    echo "SMARTAIR_PORT=$SMARTAIR_PORT"
    echo "HOTSPOT_CAPTIVE=${HOTSPOT_CAPTIVE:-0}"
    echo "SMARTAIR_AP_OPEN=${SMARTAIR_AP_OPEN:-0}"
    echo "SMARTAIR_URL=$PUB_URL"
  } >"$OUT_STATE"
  if [[ -n "${SUDO_USER:-}" && -d "$ROOT" ]]; then
    chown "${SUDO_USER}:$(id -gn "$SUDO_USER" 2>/dev/null || echo root)" "$OUT_STATE" 2>/dev/null || true
  fi
fi

if [[ "${SMARTAIR_AP_OPEN:-0}" == "1" ]]; then
  log "Done. Hotspot: SSID=\"$SMARTAIR_AP_SSID\" (open, no password)"
else
  log "Done. Hotspot should be: SSID=\"$SMARTAIR_AP_SSID\" (WPA2)"
fi
if [[ "${HOTSPOT_CAPTIVE:-0}" == "1" && -n "${IP_AP:-}" ]]; then
  log "Captive mode: run ./run (loads .hotspot.env), then on a phone try http://$IP_AP/  (port 80 is redirected to the app)"
fi
log "IP on $AP_IFACE: ${IP_AP:-unknown} — use in QR and for Flask: http://<that-ip>:$SMARTAIR_PORT"
log "Mode: $METHOD"
log "Next: run (as normal user)  $ROOT/scripts/generate-demo-qrs.sh --detect"
log "And run your app bound to 0.0.0.0, e.g.  SMARTAIR_PORT=$SMARTAIR_PORT ./run"
if [[ -z "${IP_AP:-}" ]]; then
  log "If IP is empty, wait a few seconds and: ip -4 a show $AP_IFACE"
fi
if ap_mode_is_up; then
  log "AP mode looks OK on $AP_IFACE (2.4 GHz) — the SSID should appear on phones in range."
else
  if [[ -n "${IP_AP:-}" ]]; then
    log "WARNING: $AP_IFACE is not in AP mode — phones will usually NOT see '$SMARTAIR_AP_SSID'."
    log "  Diagnose:  sudo $ROOT/scripts/verify-hotspot.sh"
    log "  Often fixed:  HOTSPOT_USE_CLASSIC=1 $ROOT/setuphotspot   OR  USB Wi-Fi (set AP_IFACE=wlan1)"
  fi
fi
exit 0
