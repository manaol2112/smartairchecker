#!/usr/bin/env bash
# Install or repair ALL system + Python dependencies for Smart Air Checker.
# Run from the project folder (where this file and config.yaml live):
#   chmod +x fix-dependencies.sh   # once, if needed
#   ./fix-dependencies.sh
#
# Same as:  ./pi-bootstrap.sh  or  bash scripts/pi-bootstrap.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec bash "$ROOT/scripts/pi-bootstrap.sh" "$@"
