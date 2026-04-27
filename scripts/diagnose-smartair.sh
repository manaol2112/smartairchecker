#!/usr/bin/env bash
# Run the app the same way systemd does, in the foreground, so the error prints in your terminal.
# Usage (from the repo, as the same user the service uses — often not root):
#   ./scripts/diagnose-smartair.sh
# Or:
#   sudo -u pi bash -lc 'cd /path/to/smartairchecker && ./scripts/diagnose-smartair.sh'
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT"
VPY="$ROOT/.venv/bin/python3"
if [[ ! -x "$VPY" ]]; then
  echo "Missing $VPY — run:  ./pi-bootstrap.sh" >&2
  exit 1
fi
export PYTHONPATH="$ROOT"
export PYTHONUNBUFFERED=1
echo "[diagnose-smartair] Running:  PYTHONPATH=$ROOT $VPY $ROOT/run.py"
echo "[diagnose-smartair] (Ctrl+C to stop; fix any error you see, then: sudo systemctl restart smartair-web)"
echo ""
exec "$VPY" "$ROOT/run.py"
