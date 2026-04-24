#!/usr/bin/env python3
"""
Smart Air Checker — BME680 / I2C diagnostic.

Run on the Raspberry Pi from the project folder (same place as run.py)::

  python3 scripts/test_sensor.py

This checks config + environment (why the *web app* might show "simulated"),
scans the I2C bus, and tries to read the BME680 like the app does.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Allow imports when run as: python3 scripts/test_sensor.py
_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))


def _line(char: str = "=", w: int = 64) -> None:
    print(char * w)


def _sub(msg: str) -> None:
    print(f"  {msg}")


def _i2c_detect(bus: int) -> tuple[str | None, int]:
    exe = shutil.which("i2cdetect")
    if not exe:
        return None, 0
    try:
        r = subprocess.run(
            [exe, "-y", str(bus)],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return r.stdout + (r.stderr or ""), r.returncode
    except (OSError, subprocess.SubprocessError) as e:
        return f"(error: {e})", 1


def _has_dev_i2c(bus: int) -> bool:
    p = Path(f"/dev/i2c-{bus}")
    return p.is_char_device() if p.exists() else False


def main() -> int:
    print()
    _line()
    print("  Smart Air Checker — BME680 / I2C sensor test")
    _line()
    print()

    # ---- What the Flask app will do ----
    from settings import is_dry_run, load_config

    cfg = load_config()
    dry_cfg = bool(cfg.get("sensors", {}).get("dry_run", False))
    sdd = (os.environ.get("SENSORS_DRY_RUN") or "").lower()
    lap = (os.environ.get("SMARTAIR_LAPTOP") or "").lower()
    trues = ("1", "true", "yes", "on")

    print("1) Why the *dashboard* might say “simulated”")
    print()
    _sub(f"config.yaml → sensors.dry_run = {dry_cfg!r}  (should be False for a real sensor)")
    _sub(f"Environment SENSORS_DRY_RUN = {os.environ.get('SENSORS_DRY_RUN', '(unset)')!r}")
    if sdd in trues:
        _sub("  → Unset SENSORS_DRY_RUN in your shell, systemd, or ~/.profile (export -n SENSORS_DRY_RUN).")
    _sub(f"Environment SMARTAIR_LAPTOP = {os.environ.get('SMARTAIR_LAPTOP', '(unset)')!r}")
    if lap in trues:
        _sub("  → Unset SMARTAIR_LAPTOP (it forces dry-run for laptop testing).")
    if os.environ.get("SMARTAIR_CONFIG"):
        _sub(f"SMARTAIR_CONFIG = {os.environ.get('SMARTAIR_CONFIG')!r}")

    app_uses_synthetic = is_dry_run()
    print()
    if app_uses_synthetic:
        print("   RESULT: is_dry_run() = True  →  the *web app* will use SIMULATED numbers.")
    else:
        print("   RESULT: is_dry_run() = False  →  the *web app* will try the real I2C sensor.")
    print()

    # ---- /dev/i2c-* ----
    print("2) I2C device nodes on this machine")
    for b in (1, 0):
        path = f"/dev/i2c-{b}"
        ex = _has_dev_i2c(b)
        _sub(f"{path}  →  {'EXISTS' if ex else 'missing'}")
    if not any(_has_dev_i2c(b) for b in (0, 1)):
        _sub("If missing: enable I2C (sudo raspi-config → Interface Options → I2C) and reboot.")
    print()

    # ---- i2cdetect (optional) ----
    if shutil.which("i2cdetect"):
        print("3) i2cdetect (needs sudo on many systems if not in the i2c group)")
        for bus in (1, 0):
            if not _has_dev_i2c(bus):
                _sub(f"Bus {bus}: skip (no /dev/i2c-{bus})")
                continue
            out, code = _i2c_detect(bus)
            if out:
                print(f"   --- i2cdetect -y {bus} (exit {code}) ---")
                for line in out.rstrip().splitlines():
                    print(f"   {line}")
            else:
                _sub(f"Bus {bus}: i2cdetect failed or empty")
        _sub("Look for 76 (0x76) or 77 (0x77) — that is the BME680 address.")
    else:
        print("3) i2cdetect not found; install:  sudo apt install i2c-tools")
    print()

    # ---- Direct BME680 read (bypasses is_dry_run) ----
    print("4) Direct Python read (bypasses config dry_run — tests hardware + driver)")
    print()
    try:
        import bme680 as bme  # type: ignore[import-not-found]
    except ImportError as e:
        print(f"   FAIL: import bme680: {e}")
        print("   Install:  .venv/bin/pip install bme680   or   pip3 install bme680")
        return 1

    addrs: list[tuple[str, int]] = [
        ("I2C_ADDR_PRIMARY", bme.I2C_ADDR_PRIMARY),
        ("I2C_ADDR_SECONDARY", bme.I2C_ADDR_SECONDARY),
    ]
    s = None
    used_addr: int | None = None
    last_err: Exception | None = None
    for name, addr in addrs:
        try:
            s = bme.BME680(addr)
            used_addr = addr
            print(f"   OK: opened BME680 on {name} = 0x{addr:02x}")
            break
        except (RuntimeError, OSError) as e:
            last_err = e
            print(f"   … not at 0x{addr:02x}: {e}")
    if s is None:
        print()
        print("   FAIL: could not open the sensor on 0x76 or 0x77.")
        if last_err:
            _sub(f"Last error: {last_err!r}")
        _sub("Fix wiring, I2C enable, and permissions (i2c group, or run this script with sudo to test).")
        return 1

    s.set_humidity_oversample(bme.OS_2X)
    s.set_pressure_oversample(bme.OS_4X)
    s.set_temperature_oversample(bme.OS_8X)
    s.set_filter(bme.FILTER_SIZE_3)
    s.set_gas_heater_temperature(320)
    s.set_gas_heater_duration(150)

    t0 = time.time()
    got = 0
    for _ in range(200):
        if s.get_sensor_data():
            d = s.data
            got += 1
            heat = getattr(d, "heat_stable", None)
            t = f"{d.temperature:.2f} °C"
            h = f"{d.humidity:.1f} %"
            p = f"{d.pressure:.1f} hPa"
            gr = getattr(d, "gas_resistance", None)
            gas = f"{gr:.0f} Ω" if gr is not None else "—"
            print(
                f"   Sample {got}:  T {t}  |  H {h}  |  P {p}  |  gas {gas}  |  heat_stable={heat!r}"
            )
            if got >= 3:
                break
        time.sleep(0.1)
    dt = time.time() - t0
    if got == 0:
        print("   FAIL: get_sensor_data() never returned data (timeout ~20s).")
        return 1

    print()
    print(f"   OK: received {got} reading(s) in {dt:.1f}s  (address 0x{used_addr:02x})")
    print()

    if app_uses_synthetic:
        _line("-")
        print("  Your *hardware* works (section 4), but the *app* will still be simulated")
        print("  until is_dry_run() is false — fix section (1) above, then restart the app.")
        _line("-")
    else:
        _line("-")
        print("  If the dashboard still says simulated, restart the server after changing env/config,")
        print("  and check journal/terminal for:  BME680 not available  (I2C open failed at runtime).")
        _line("-")

    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
