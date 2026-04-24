#!/bin/sh
cd "$(dirname "$0")" || exit 1
export PYTHONPATH=.
if [ ! -x .venv/bin/python3 ]; then
  echo ""
  echo "  First run: no .venv — running ./pi-bootstrap.sh"
  echo ""
  if command -v bash >/dev/null 2>&1; then
    bash ./pi-bootstrap.sh || exit 1
  else
    echo "Install bash, or run: bash ./pi-bootstrap.sh" >&2
    exit 1
  fi
fi
if [ -x .venv/bin/python3 ]; then
  exec .venv/bin/python3 run.py "$@"
else
  exec python3 run.py "$@"
fi
