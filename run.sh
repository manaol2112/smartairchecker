#!/bin/sh
cd "$(dirname "$0")" || exit 1
export PYTHONPATH=.
if [ -x .venv/bin/python3 ]; then
  exec .venv/bin/python3 run.py "$@"
else
  exec python3 run.py "$@"
fi
