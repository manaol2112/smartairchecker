#!/usr/bin/env python3
"""
Cycle the RGB module through pure R, G, B, then the app colors (amber / red / green).

Uses ``config.yaml`` → ``gpio`` (``rgb_red``, ``rgb_green``, ``rgb_blue``, ``common_anode``).
Run **on the Raspberry Pi** from the project folder::

  .venv/bin/python3 scripts/test_rgb_led.py
  # or, if the gpio group is not set up yet:
  sudo -E .venv/bin/python3 scripts/test_rgb_led.py

**Mapping** (same as the live app: ``outputs.AirQualityIndicator``):

- **Good**  → green only
- **Moderate**  → red + green (amber / orange)
- **Bad**  → red only

If a color is wrong, swap the pin numbers in ``config.yaml`` to match the **R / G / B** silkscreen
on your module, or fix ``common_anode``.
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

os.chdir(_ROOT)

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


def _init_rgb():
    from gpiozero import LED
    from gpiozero.exc import BadPinFactory

    cfg = load_config()
    g = cfg.get("gpio", {}) if isinstance(cfg.get("gpio"), dict) else {}
    pr = int(g.get("rgb_red", 17))
    pg = int(g.get("rgb_green", 27))
    pb = int(g.get("rgb_blue", 22))
    anode = bool(g.get("common_anode", False))
    high = not anode
    r = LED(pr, active_high=high)
    g_ = LED(pg, active_high=high)
    b = LED(pb, active_high=high)
    return (r, g_, b, pr, pg, pb, anode)


def _all_off(r: object, g: object, b: object) -> None:
    cast(Any, r).off()
    cast(Any, g).off()
    cast(Any, b).off()


def _pause(label: str, hold: float) -> None:
    print(f"  {label} ({hold:.1f}s)…", flush=True)
    time.sleep(hold)


def main() -> int:
    if not _on_pi():
        print("Skip: not a target Pi (run on the Raspberry Pi for GPIO).", file=sys.stderr)
        return 1
    try:
        r, g, b, pr, pg, pb, anode = _init_rgb()
    except Exception as e:  # noqa: BLE001
        print("Could not open GPIO / LEDs:", e, file=sys.stderr)
        print("Try:  sudo -E .venv/bin/python3 scripts/test_rgb_led.py", file=sys.stderr)
        return 2

    print("RGB from config: BCM (not physical) pins  R=%d  G=%d  B=%d  common_anode=%s" % (pr, pg, pb, anode))
    print("  If colors do not match the label, change gpio.rgb_red/green/blue in config.yaml.\n")

    hold = 1.4

    def step(name: str, r_on: bool, g_on: bool, b_on: bool) -> None:
        _all_off(r, g, b)
        if r_on:
            cast(Any, r).on()
        if g_on:
            cast(Any, g).on()
        if b_on:
            cast(Any, b).on()
        _pause(name, hold)

    try:
        print("Channel test (R, G, B one at a time):")
        step("RED channel only (should look red)", True, False, False)
        step("GREEN channel only (should look green)", False, True, False)
        step("BLUE channel only (should look blue; app usually leaves blue off)", False, False, True)
        _all_off(r, g, b)
        time.sleep(0.4)
        print("\nApp colors (same as live air quality):")
        step("GOOD  →  green (like dashboard 'good')", False, True, False)
        step("MODERATE  →  amber  red+green (like 'moderate')", True, True, False)
        step("BAD  →  red only (like 'bad')", True, False, False)
        _all_off(r, g, b)
        print("\nAll off. Done.")
    finally:
        _all_off(r, g, b)
        for d in (r, g, b):
            try:
                d.close()  # type: ignore[attr-defined]
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
