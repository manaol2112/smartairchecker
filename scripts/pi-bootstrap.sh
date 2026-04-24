#!/usr/bin/env bash
# First-time and repeat dependency setup (safe to run more than once).
# From the project root:  ./pi-bootstrap.sh  OR  bash scripts/pi-bootstrap.sh
# On Raspberry Pi, creates .venv with --system-site-packages so the BME680
# I2C library can use the OS smbus module (from the python3-smbus package).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PYTHON="python3"
VENV="${ROOT}/.venv"

is_pi() {
  if [[ -f /proc/device-tree/model ]] && grep -q -i Raspberry /proc/device-tree/model 2>/dev/null; then
    return 0
  fi
  return 1
}

need_sudo() {
  [[ "$(id -u)" -ne 0 ]]
}

log() { printf "\n[smartair] %s\n" "$*"; }

apt_install() {
  if ! command -v apt-get &>/dev/null; then
    log "apt-get not found — install Python 3 and venv with your package manager, then re-run this script."
    return 0
  fi
  if [[ "${SKIP_APT:-0}" == "1" ]]; then
    log "SKIP_APT=1 — not installing system packages."
    return 0
  fi
  if need_sudo && ! command -v sudo &>/dev/null; then
    log "Need sudo to install system packages, or set SKIP_APT=1 and install python3-venv, python3-smbus, i2c-tools yourself."
    exit 1
  fi

  # python3-yaml: so `import yaml` works for system python3, not only the venv
  local -a PKGS=(python3 python3-venv python3-pip python3-yaml i2c-tools)
  if is_pi; then
    PKGS+=(python3-smbus)
    if apt-cache show python3-rpi-lgpio &>/dev/null; then
      PKGS+=(python3-rpi-lgpio)
    fi
  fi

  log "Installing system packages: ${PKGS[*]}"
  if need_sudo; then
    sudo apt-get update -qq
    sudo apt-get install -y "${PKGS[@]}"
  else
    apt-get update -qq
    apt-get install -y "${PKGS[@]}"
  fi
}

enable_i2c_if_pi() {
  is_pi || return 0
  if ! command -v raspi-config &>/dev/null; then
    return 0
  fi
  if ! need_sudo; then
    return 0
  fi
  log "Enabling I2C (for BME680) if not already on…"
  sudo raspi-config nonint do_i2c 0 2>/dev/null || true
}

add_user_groups() {
  is_pi || return 0
  local u="${SUDO_USER:-}"
  if [[ -z "$u" ]]; then
    u="${USER:-}"
  fi
  if [[ -z "$u" || "$u" == "root" ]]; then
    return 0
  fi
  if getent group i2c &>/dev/null; then
    log "Adding user $u to groups i2c,gpio (re-login or reboot for /dev/i2c-* access to take effect)."
    sudo usermod -aG i2c,gpio "$u" 2>/dev/null || true
  fi
}

if ! command -v "$PYTHON" &>/dev/null; then
  echo "Error: $PYTHON not found. Install Python 3.10+ first."
  exit 1
fi

log "Project root: $ROOT"
apt_install
enable_i2c_if_pi
add_user_groups

VENV_FLAGS=()
if is_pi; then
  if [[ "${SMARTAIR_NO_SYSTEM_SITE:-0}" == "1" ]]; then
    log "SMARTAIR_NO_SYSTEM_SITE=1 — venv is isolated (BME680 may need --system-site-packages on Pi)."
  else
    VENV_FLAGS+=(--system-site-packages)
    log "Raspberry Pi detected: creating venv with --system-site-packages (for I2C smbus)."
  fi
fi

if [[ ! -d "$VENV" ]]; then
  log "Creating virtual environment: $VENV"
  $PYTHON -m venv "$VENV" "${VENV_FLAGS[@]}"
fi

# shellcheck source=/dev/null
source "$VENV/bin/activate"
log "Upgrading pip…"
pip install -U pip setuptools wheel
log "Installing Python dependencies from requirements.txt…"
pip install -r requirements.txt

verify_imports() {
  "$VENV/bin/python3" -c "import yaml; import bme680; import flask; import gpiozero" 2>/dev/null
}

if verify_imports; then
  log "Verified: import yaml, bme680, flask, gpiozero — OK"
else
  log "Some imports failed; re-running pip with --no-cache-dir…"
  pip install --no-cache-dir -U pip setuptools wheel
  pip install --no-cache-dir -r requirements.txt
fi

if ! verify_imports; then
  log "Retrying with explicit PyPI names (bme680, PyYAML, flask, gpiozero)…"
  pip install --no-cache-dir "bme680>=1.0.5" "PyYAML>=6.0.1" "flask>=3.0" "gpiozero>=2.0" || true
fi

if ! verify_imports; then
  echo "" >&2
  log "ERROR: Still cannot import bme680 / yaml / flask / gpiozero in $VENV"
  echo "--------------------------------------------------------------------------------" >&2
  echo "  On Raspberry Pi, try:  sudo apt update && sudo apt install -y python3-smbus python3-yaml" >&2
  echo "  Then run:  ./fix-dependencies.sh" >&2
  echo "  Start the app with:  ./run  (not plain: python3 run.py) " >&2
  echo "--------------------------------------------------------------------------------" >&2
  "$VENV/bin/python3" -c "import yaml; import bme680; import flask; import gpiozero" 2>&1 || true
  exit 1
fi

log "Done. Start the app with:  ./run   or:  ${VENV}/bin/python3 run.py"
log "Re-run this anytime dependencies break:  ./fix-dependencies.sh  or  ./pi-bootstrap.sh"
