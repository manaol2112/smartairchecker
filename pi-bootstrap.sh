#!/usr/bin/env bash
# Wrapper in the project root. The real script lives in scripts/ — you can run either:
#   ./fix-dependencies.sh   (recommended name)
#   ./pi-bootstrap.sh
#   bash scripts/pi-bootstrap.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec bash "$ROOT/scripts/pi-bootstrap.sh" "$@"
