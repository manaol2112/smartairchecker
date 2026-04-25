# Sourced by setup-wifi-ap.sh, setuphotspot, and generate-demo-qrs.sh after .hotspot.env
# is loaded. Normalizes SMARTAIR_AP_OPEN to "0" or "1" (yes/true/ON/1; strip CRLF).
smartair_resolve_open_var() {
  local _n
  _n="${SMARTAIR_AP_OPEN:-0}"
  _n="${_n%$'\r'}"
  _n=$(printf '%s' "$_n" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  case "$_n" in
  1|y|on|yes|true) SMARTAIR_AP_OPEN=1 ;;
  *) SMARTAIR_AP_OPEN=0 ;;
  esac
}
