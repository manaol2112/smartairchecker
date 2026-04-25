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
# shellcheck source=scripts/hotspot-iptables-helpers.sh
# shellcheck disable=SC1090
. "${ROOT}/scripts/hotspot-iptables-helpers.sh" 2>/dev/null || true
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
SMARTAIR_AP_OPEN="${SMARTAIR_AP_OPEN:-0}"
# shellcheck source=scripts/hotspot-normalize.sh
# shellcheck disable=SC1090
. "${ROOT}/scripts/hotspot-normalize.sh"
smartair_resolve_open_var
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

if [[ "$SMARTAIR_AP_OPEN" != "1" ]] && ((${#SMARTAIR_AP_PASS} < 8)); then
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
  local have
  have=0
  if ip -4 -o addr show dev "$AP_IFACE" 2>/dev/null | grep -qF "${STATIC_PREFIX}.1/"; then
    have=1
  fi
  if [[ $have -eq 0 ]]; then
    log "No ${STATIC_PREFIX}.1 on $AP_IFACE — setting address (required for phone DHCP)…"
  else
    log "Ensuring ${STATIC_PREFIX}.1/24 is bound to $AP_IFACE (hostapd/AP mode can clear it)…"
  fi
  ip link set dev "$AP_IFACE" up 2>/dev/null || true
  ip -4 address replace "$cidr" dev "$AP_IFACE" 2>/dev/null || ip -4 address add "$cidr" dev "$AP_IFACE" 2>/dev/null || true
  if ! ip -4 -o addr show dev "$AP_IFACE" 2>/dev/null | grep -qF "${STATIC_PREFIX}.1/"; then
    log "ERROR: $AP_IFACE still has no ${STATIC_PREFIX}.1. Old dhcpcd used denyinterfaces+static together (we fix that in setup). Set manually:  sudo ip -4 address add $cidr dev $AP_IFACE"
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

# UFW/iptables: phones need UDP 67; captive also needs :80 and app TCP port into Flask after NAT REJECT
hotspot_allow_dhcp_firewall() {
  if require_bin ufw; then
    if ufw status 2>/dev/null | grep -qiE 'Status:\s*active'; then
      ufw allow in on "$AP_IFACE" to any port 67 proto udp 2>&1 | sed 's/^/  [ufw] /' || true
      if [[ "${HOTSPOT_CAPTIVE:-0}" == "1" ]]; then
        ufw allow in on "$AP_IFACE" to any port 53 proto udp 2>&1 | sed 's/^/  [ufw] /' || true
        ufw allow in on "$AP_IFACE" to any port 80 proto tcp 2>&1 | sed 's/^/  [ufw] /' || true
        ufw allow in on "$AP_IFACE" to any port "$SMARTAIR_PORT" proto tcp 2>&1 | sed 's/^/  [ufw] /' || true
        log "ufw: allowed TCP 80 and $SMARTAIR_PORT on $AP_IFACE (phones use :80; Flask sits on :$SMARTAIR_PORT; NAT REDIRECT must reach the app)"
      else
        ufw allow in on "$AP_IFACE" to any port "$SMARTAIR_PORT" proto tcp 2>&1 | sed 's/^/  [ufw] /' || true
        log "ufw: allowed TCP $SMARTAIR_PORT on $AP_IFACE (open http://<pi-ip>:$SMARTAIR_PORT/ — no :80 without HOTSPOT_CAPTIVE+iptables)"
      fi
    fi
  fi
  if require_bin iptables; then
    if iptables -L INPUT 2>/dev/null | head -1 | grep -qE 'policy (DROP|REJECT)'; then
      if ! iptables -C INPUT -i "$AP_IFACE" -p udp -m udp --dport 67 -j ACCEPT 2>/dev/null; then
        if iptables -I INPUT 1 -i "$AP_IFACE" -p udp -m udp --dport 67 -j ACCEPT 2>/dev/null; then
          log "iptables: added INPUT accept for UDP 67 on $AP_IFACE (firewall was DROP/REJECT)"
        fi
      fi
      if [[ "${HOTSPOT_CAPTIVE:-0}" == "1" ]]; then
        if ! iptables -C INPUT -i "$AP_IFACE" -p tcp -m tcp --dport 80 -j ACCEPT 2>/dev/null; then
          iptables -I INPUT 1 -i "$AP_IFACE" -p tcp -m tcp --dport 80 -j ACCEPT 2>/dev/null && log "iptables: INPUT accept TCP 80 on $AP_IFACE (http://<ip>/ from phones)" || true
        fi
        if ! iptables -C INPUT -i "$AP_IFACE" -p tcp -m tcp --dport "$SMARTAIR_PORT" -j ACCEPT 2>/dev/null; then
          iptables -I INPUT 1 -i "$AP_IFACE" -p tcp -m tcp --dport "$SMARTAIR_PORT" -j ACCEPT 2>/dev/null && log "iptables: INPUT accept TCP $SMARTAIR_PORT on $AP_IFACE" || true
        fi
      else
        if ! iptables -C INPUT -i "$AP_IFACE" -p tcp -m tcp --dport "$SMARTAIR_PORT" -j ACCEPT 2>/dev/null; then
          iptables -I INPUT 1 -i "$AP_IFACE" -p tcp -m tcp --dport "$SMARTAIR_PORT" -j ACCEPT 2>/dev/null && log "iptables: INPUT accept TCP $SMARTAIR_PORT on $AP_IFACE" || true
        fi
      fi
    fi
  fi
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
  if declare -F hotspot_captive_nat_add &>/dev/null; then
    if ! hotspot_captive_nat_add "$AP_IFACE" "$SMARTAIR_PORT" 2>/dev/null; then
      log "WARNING: iptables redirect failed; HTTP on port 80 may not reach Flask"
    else
      log "Captive: TCP port 80 on $AP_IFACE → 127.0.0.1:$SMARTAIR_PORT (run ./run; .hotspot.env loads HOTSPOT_CAPTIVE for /generate_204 etc.)"
    fi
  else
    while iptables -t nat -C PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$SMARTAIR_PORT" 2>/dev/null; do
      iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$SMARTAIR_PORT" 2>/dev/null || break
    done
    if iptables -t nat -A PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$SMARTAIR_PORT" 2>/dev/null; then
      log "Captive: TCP port 80 on $AP_IFACE → 127.0.0.1:$SMARTAIR_PORT (helpers missing; used inline iptables)"
    else
      log "WARNING: iptables redirect failed; HTTP on port 80 may not reach Flask"
    fi
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

if [[ "$SMARTAIR_AP_OPEN" == "1" ]]; then
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
  log "Stopping NetworkManager for this session. To get normal Wi-Fi back:  sudo $ROOT/scripts/restore-client-wifi.sh  (not just start NetworkManager — hostapd must stop first; see docs.)"
  log "  → wpa_supplicant…"
  systemctl stop wpa_supplicant@* 2>/dev/null || true
  systemctl stop wpa_supplicant 2>/dev/null || true
  for svc in wpa_supplicant; do
    systemctl stop "$svc" 2>/dev/null || true
  done
  # Plain "systemctl stop NetworkManager" can block 60s+ on some Pi images; use --no-block first.
  log "  → NetworkManager (non-blocking stop; if this step worried you before, that wait is gone)…"
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    systemctl --no-block stop NetworkManager 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
      if command -v timeout &>/dev/null; then
        log "  → still active — waiting up to 60s (or open another terminal: sudo systemctl stop NetworkManager)"
        timeout 60s systemctl stop NetworkManager 2>/dev/null || true
      else
        systemctl stop NetworkManager 2>/dev/null || true
      fi
    fi
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
      log "  → forcing kill so hostapd can use $AP_IFACE (desktop Wi-Fi will drop until you start NetworkManager again)"
      systemctl kill -s KILL NetworkManager 2>/dev/null || true
      sleep 1
    fi
  fi
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
  # do NOT use denyinterfaces here: on Raspberry Pi OS, dhcpcd ignores the whole interface, so
  # the static ip_address in the block below is never applied (no 192.168.4.1, dnsmasq cannot DHCP).
  if ! grep -q "# --- smartair-ap dhcpcd begin ---" "$DHCPCD_CONF" 2>/dev/null; then
    cat >> "$DHCPCD_CONF" <<DHCPEOF

# --- smartair-ap dhcpcd begin --- (setup-wifi-ap.sh)
interface ${AP_IFACE}
static ip_address=${STATIC_PREFIX}.1/24
nohook wpa_supplicant
# --- smartair-ap dhcpcd end ---
DHCPEOF
  else
    # one-time fix for systems that got the old block with denyinterfaces
    if grep -A20 "# --- smartair-ap dhcpcd begin ---" "$DHCPCD_CONF" 2>/dev/null | grep -qE '^[[:space:]]*denyinterfaces[[:space:]]'; then
      log "Patching /etc/dhcpcd.conf: removing denyinterfaces from smartair block (it prevented static ${STATIC_PREFIX}.1 on some Pi OS images)"
      if command -v sed &>/dev/null; then
        sed -i '/# --- smartair-ap dhcpcd begin ---/,/# --- smartair-ap dhcpcd end ---/ {/^[[:space:]]*denyinterfaces/d;}' "$DHCPCD_CONF" 2>/dev/null || true
      fi
    fi
  fi
  mkdir -p /etc/dnsmasq.d
  # bind-interfaces is more reliable for DHCP in AP mode; if dnsmasq fails to start, set HOTSPOT_DNSMASQ_BIND_DYNAMIC=1 in .hotspot.env
  if [[ "${HOTSPOT_DNSMASQ_BIND_DYNAMIC:-0}" == "1" ]]; then
    H_DNS_BIND="bind-dynamic"
  else
    H_DNS_BIND="bind-interfaces"
  fi
  if [[ "${HOTSPOT_CAPTIVE:-0}" == "1" ]]; then
    P_IP="${STATIC_PREFIX}.1"
    if [[ "${HOTSPOT_CAPTIVE_WILDCARD:-0}" == "1" ]]; then
      log "HOTSPOT_CAPTIVE_WILDCARD=1 — all DNS → ${P_IP} (can overload a Pi: many clients × every hostname; use 0 and default light mode instead if the Pi locks up)"
      cat >/etc/dnsmasq.d/smartair-ap.conf <<DNS_EOF
# SmartAir — full captive (every name → AP); heavy; see HOTSPOT_CAPTIVE_WILDCARD
port=53
no-resolv
no-poll
cache-size=20000
interface=${AP_IFACE}
${H_DNS_BIND}
listen-address=${P_IP}
domain-needed
bogus-priv
dhcp-authoritative
dhcp-range=${STATIC_PREFIX}.2,${STATIC_PREFIX}.200,255.255.255.0,24h
dhcp-option=3,${P_IP}
dhcp-option=6,${P_IP}
address=/#/${P_IP}
DNS_EOF
    else
      log "HOTSPOT_CAPTIVE: selective-DNS (default) — only known phone check hosts → ${P_IP}; other queries use upstream (less likely to freeze the Pi). Set HOTSPOT_CAPTIVE_WILDCARD=1 in .hotspot.env for the old all-names behavior."
      cat >/etc/dnsmasq.d/smartair-ap.conf <<DNS_EOF
# SmartAir — light captive: DHCP on AP; only well-known *probe* hostnames go to the Pi; others → upstream
# (Do not send www.google.com / all of gstatic to the Pi or browsing breaks. HOTSPOT_CAPTIVE_WILDCARD=1 = old catch-all.)
port=53
no-resolv
no-poll
cache-size=20000
interface=${AP_IFACE}
${H_DNS_BIND}
listen-address=${P_IP}
server=1.1.1.1
server=8.8.8.8
strict-order
domain-needed
bogus-priv
dhcp-authoritative
dhcp-range=${STATIC_PREFIX}.2,${STATIC_PREFIX}.200,255.255.255.0,24h
dhcp-option=3,${P_IP}
dhcp-option=6,${P_IP}
address=/connectivitycheck.gstatic.com/${P_IP}
address=/connectivitycheck.android.com/${P_IP}
address=/captive.g.aaplimg.com/${P_IP}
address=/captive.apple.com/${P_IP}
address=/www.msftncsi.com/${P_IP}
address=/msftncsi.com/${P_IP}
address=/msftconnecttest.com/${P_IP}
address=/connectivitycheck.platform.hicloud.com/${P_IP}
address=/play.googleapis.com/${P_IP}
address=/connect.rom.miui.com/${P_IP}
address=/global.market.xiaomi.com/${P_IP}
address=/clients3.google.com/${P_IP}
address=/detectportal.firefox.com/${P_IP}
address=/gsp-ssl-redirect.ls.apple.com/${P_IP}
DNS_EOF
    fi
  else
    cat >/etc/dnsmasq.d/smartair-ap.conf <<DNS_EOF
# SmartAir — DHCP only (port=0) so we do not bind DNS :53 (avoids clash with systemd-resolved)
port=0
no-resolv
# bookworm AP: try bind-interfaces; if dnsmasq fails, HOTSPOT_DNSMASQ_BIND_DYNAMIC=1 in .hotspot.env
interface=${AP_IFACE}
${H_DNS_BIND}
no-dhcp-interface=lo
dhcp-authoritative
dhcp-range=${STATIC_PREFIX}.2,${STATIC_PREFIX}.200,255.255.255.0,24h
dhcp-option=3,${STATIC_PREFIX}.1
dhcp-option=6,${STATIC_PREFIX}.1
# Uncomment on Pi to debug lease problems:  log-facility=/var/log/dnsmasq-dhcp.log  log-dhcp
DNS_EOF
  fi
  if [[ "$SMARTAIR_AP_OPEN" == "1" ]]; then
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
  log "Wrote /etc/hostapd/hostapd.conf and /etc/default/hostapd (next: enable services, dhcpcd, then hostapd + dnsmasq)…"
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >/etc/default/hostapd
  IP_AP="${STATIC_PREFIX}.1"
  METHOD="hostapd"
  if require_bin systemctl; then
    systemctl unmask hostapd 2>/dev/null || true
    systemctl stop hostapd 2>/dev/null || true
    pkill -x hostapd 2>/dev/null || true
    sleep 1
    if require_bin hostapd; then
      # hostapd -t can hang on some brcmf / nl80211 stacks; never run it without a time limit
      HAP_TMO="${HOTSPOT_HOSTAPD_TEST_SEC:-15}"
      if require_bin timeout; then
        log "Verifying hostapd config (max ${HAP_TMO}s, then continue on timeout or error)…"
        set +e
        hp_test=$(timeout "${HAP_TMO}"s hostapd -t /etc/hostapd/hostapd.conf 2>&1)
        rc=$?
        set -e
        if [[ "$rc" -eq 124 ]]; then
          log "hostapd -t: timed out (driver quirk on many Pis) — skipping; real test is the next 'Starting hostapd' step. You can set HOTSPOT_HOSTAPD_TEST_SEC=1 in .hotspot.env to shorten the wait."
        elif [[ "$rc" -eq 0 ]]; then
          log "hostapd: config OK (hostapd -t)"
        else
          log "hostapd -t (exit $rc): $hp_test"
        fi
      else
        log "SKIPPING hostapd -t: install  sudo apt install -y coreutils  for the 'timeout' command (on some chips hostapd -t never returns, which blocks setup here)."
      fi
    fi
    log "Enabling hostapd and dnsmasq to start on boot, then restarting dhcpcd (this can take 15–30s on a Pi; not frozen)…"
    systemctl enable hostapd
    systemctl enable dnsmasq
    systemctl restart dhcpcd 2>/dev/null || true
    log "Waiting for dhcpcd to settle, then setting ${STATIC_PREFIX}.1 on $AP_IFACE…"
    sleep 2
    ensure_classic_ap_ip
    # Start AP *before* dnsmasq: on many Pis, DHCP is unreliable if dnsmasq starts when wlan0 is not yet in AP mode
    log "Starting hostapd (AP mode on $AP_IFACE) — may take a few seconds…"
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
    # AP bring-up can clear the address — re-apply, then start dnsmasq (DHCP) so phones get 192.168.4.x
    ensure_classic_ap_ip
    hotspot_allow_dhcp_firewall
    log "Starting dnsmasq (DHCP for phones) on $AP_IFACE — if this fails, phones show 'couldn't get an IP'…"
    systemctl stop dnsmasq 2>/dev/null || true
    systemctl restart dnsmasq 2>&1 | sed 's/^/  [dnsmasq] /' || true
    sleep 1
    if ! systemctl is-active --quiet dnsmasq 2>/dev/null; then
      log "ERROR: dnsmasq is not running — no DHCP for clients. journal:"
      journalctl -u dnsmasq -n 35 --no-pager 2>&1 | sed 's/^/  /' || true
      if [[ "${HOTSPOT_CAPTIVE:-0}" == "1" ]]; then
        log "If you see 'address already in use' on port 53, set HOTSPOT_CAPTIVE=0 in .hotspot.env and re-run. See docs/pi-wifi-hotspot.md"
      fi
    else
      log "dnsmasq is running — if phones still have no IP, run:  sudo ufw allow 67/udp,  and see journal if bind-interfaces failed"
    fi
    captive_iptables
  else
    service dhcpcd restart 2>/dev/null || true
    sleep 2
    ensure_classic_ap_ip
    service hostapd restart 2>/dev/null || true
    sleep 2
    ensure_classic_ap_ip
    hotspot_allow_dhcp_firewall
    service dnsmasq stop 2>/dev/null || true
    service dnsmasq start 2>/dev/null || true
    ensure_classic_ap_ip
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

# hostapd path runs these inside setup_classic_ap; NetworkManager path never entered that
# function — must still open ufw/INPUT for the app port (and 80 if HOTSPOT_CAPTIVE* iptables is used)
if [[ $use_nm -eq 1 ]]; then
  hotspot_allow_dhcp_firewall
  captive_iptables
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
    echo "HOTSPOT_CAPTIVE_WILDCARD=${HOTSPOT_CAPTIVE_WILDCARD:-0}"
    echo "SMARTAIR_AP_OPEN=$SMARTAIR_AP_OPEN"
    echo "SMARTAIR_URL=$PUB_URL"
  } >"$OUT_STATE"
  if [[ -n "${SUDO_USER:-}" && -d "$ROOT" ]]; then
    chown "${SUDO_USER}:$(id -gn "$SUDO_USER" 2>/dev/null || echo root)" "$OUT_STATE" 2>/dev/null || true
  fi
fi

if [[ "$SMARTAIR_AP_OPEN" == "1" ]]; then
  log "Done. Hotspot: SSID=\"$SMARTAIR_AP_SSID\" (open, no password)"
  if [[ -f /etc/hostapd/hostapd.conf ]] && ! grep -qE '^[[:space:]]*wpa=0' /etc/hostapd/hostapd.conf; then
    log "ERROR: you asked for an open AP but /etc/hostapd/hostapd.conf has no wpa=0. Re-run ./setuphotspot from the project root with SMARTAIR_AP_OPEN=1 in .hotspot.env"
  fi
  log "Phones often cache the old network as \"secured\": on each device use Forget / Remove, then rejoin this SSID — it should not ask for a password."
else
  log "Done. Hotspot should be: SSID=\"$SMARTAIR_AP_SSID\" (WPA2)"
  if systemctl is-active --quiet hostapd 2>/dev/null && [[ -f /etc/hostapd/hostapd.conf ]]; then
    if grep -qE '^[[:space:]]*wpa=0' /etc/hostapd/hostapd.conf; then
      log "NOTE: hostapd has wpa=0 (open) but SMARTAIR_AP_OPEN is not 1 in the env you used. Check .hotspot.env and re-run, or the phone will expect WPA."
    fi
  fi
fi
if [[ "${HOTSPOT_CAPTIVE:-0}" == "1" && -n "${IP_AP:-}" ]]; then
  log "Captive mode: run ./run (loads .hotspot.env), then on a phone try http://$IP_AP/  (port 80 is redirected to the app)"
fi
log "IP on $AP_IFACE: ${IP_AP:-unknown} — use in QR and for Flask: http://<that-ip>:$SMARTAIR_PORT"
log "Mode: $METHOD"
log "Next: run (as normal user)  $ROOT/scripts/generate-demo-qrs.sh --detect"
log "And run your app bound to 0.0.0.0, e.g.  SMARTAIR_PORT=$SMARTAIR_PORT ./run"
if [[ "$METHOD" == "hostapd" ]]; then
  log "To restore your home/ campus Wi-Fi (stop hotspot first):  sudo $ROOT/scripts/restore-client-wifi.sh"
fi
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
