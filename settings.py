import os
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent


def load_config() -> dict:
    path = os.environ.get("SMARTAIR_CONFIG", str(ROOT / "config.yaml"))
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def is_dry_run() -> bool:
    if os.environ.get("SENSORS_DRY_RUN", "").lower() in ("1", "true", "yes"):
        return True
    if os.environ.get("SMARTAIR_LAPTOP", "").lower() in ("1", "true", "yes"):
        return True
    try:
        cfg = load_config()
        return bool(cfg.get("sensors", {}).get("dry_run", False))
    except OSError:
        return False
