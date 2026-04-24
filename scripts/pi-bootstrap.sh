#!/usr/bin/env bash
# First-time and repeat dependency setup (safe to run more than once).
# From the project root:  bash scripts/pi-bootstrap.sh
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
log "Done. Start the app with:  ./run   or:  ${VENV}/bin/python3 run.py"
