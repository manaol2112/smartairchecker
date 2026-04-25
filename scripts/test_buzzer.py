#!/usr/bin/env python3
"""
Play a short beep test using ``config.yaml`` (same pins and buzzer kind as the app).

**On the Raspberry Pi**, from the project directory::

  ./test_buzzer
  .venv/bin/python3 scripts/test_buzzer.py
  # if the gpio group is not set up yet:
  sudo -E .venv/bin/python3 scripts/test_buzzer.py

**Passive** (``buzzer.kind: passive``) uses a tone; **active** uses DC on/off.

This script is not for macOS/Windows (no header GPIO). Use the real Pi.
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

os.chdir(_ROOT)  # stable relative paths in logs

from settings import is_dry_run, load_config  # noqa: E402

try:
    from typing import Any, cast
except ImportError:  # pragma: no cover
    pass


def _on_pi() -> bool:
    if is_dry_run():
        return False
    if sys.platform in ("darwin", "win32"):
        return False
    return True


def _init_buzzer():
    from gpiozero import LED, TonalBuzzer

    cfg = load_config()
    g = cfg.get("gpio", {}) if isinstance(cfg.get("gpio"), dict) else {}
    pin = int(g.get("buzzer", 18))
    bz_cfg = cfg.get("buzzer", {}) if isinstance(cfg.get("buzzer"), dict) else {}
    kind = str(bz_cfg.get("kind", "active")).lower().strip()
    passive = kind in ("passive", "piezo", "pzm", "5v_piezo")
    freq = float(bz_cfg.get("frequency_hz", 2500.0))

    if passive:
        dev = TonalBuzzer(pin)
    else:
        dev = LED(pin, active_high=True)
    return dev, pin, passive, freq


def _stop(dev: object, passive: bool) -> None:
    if passive:
        cast(Any, dev).stop()
    else:
        cast(Any, dev).off()


def _play(dev: object, passive: bool, freq: float) -> None:
    if passive:
        cast(Any, dev).play(float(freq))
    else:
        cast(Any, dev).on()


def main() -> int:
    if not _on_pi():
        print("Skip: not a target Pi (use SENSORS_DRY_RUN=0 and run on Linux/Pi for GPIO).", file=sys.stderr)
        return 1
    try:
        dev, pin, passive, freq = _init_buzzer()
    except Exception as e:  # noqa: BLE001
        print("Could not open GPIO / buzzer:", e, file=sys.stderr)
        print("Try:  sudo -E .venv/bin/python3 scripts/test_buzzer.py", file=sys.stderr)
        return 2

    kind = "passive (TonalBuzzer, tone)" if passive else "active (DC high)"
    print(f"Buzzer on BCM GPIO {pin} — {kind}")
    if passive:
        print(f"  frequency_hz={freq} (from config.yaml)")

    try:
        print("  Three short beeps…")
        for i in range(3):
            _play(dev, passive, freq)
            time.sleep(0.35)
            _stop(dev, passive)
            time.sleep(0.25)
            print(f"    beep {i + 1}/3")

        if passive:
            print("  1.5s steady tone (should be clearly audible)…")
            _play(dev, passive, freq)
            time.sleep(1.5)
            _stop(dev, passive)

        print("Done. If you heard nothing, check VCC/GND/IO wiring and: buzzer.enabled, buzzer.kind")
    finally:
        _stop(dev, passive)
        try:
            dev.close()  # type: ignore[attr-defined]
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
