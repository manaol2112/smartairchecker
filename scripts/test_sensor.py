#!/usr/bin/env python3
"""
Smart Air Checker — BME680 / I2C diagnostic.

On the Raspberry Pi, from the project folder (where config.yaml lives)::

  ./fix-dependencies.sh          # once, so .venv has bme680 + PyYAML
  .venv/bin/python3 scripts/test_sensor.py

Or (this script will switch to .venv automatically if it exists)::

  python3 scripts/test_sensor.py

Set SMARTAIR_TEST_NO_VENV=1 to force using the current python (no auto venv).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Project root (parent of scripts/)
_ROOT = Path(__file__).resolve().parent.parent
_SCRIPT = Path(__file__).resolve()


def _maybe_reexec_with_venv() -> None:
    """If .venv exists and we're not already using it, re-run under .venv/bin/python3.

    Avoids 'No module named bme680' / 'yaml' when the user types plain ``python3``.

    We must not compare only *resolved* binary paths: the venv's ``python3`` is often
    a symlink to the system interpreter, so resolves match even when ``sys.prefix`` is
    still the **system** prefix (packages would be read from the wrong place)."""
    if (os.environ.get("SMARTAIR_TEST_NO_VENV") or "").lower() in ("1", "true", "yes"):
        return
    venv_dir = _ROOT / ".venv"
    venv_py = venv_dir / "bin" / "python3"
    if not venv_py.is_file():
        return
    try:
        if Path(sys.prefix).resolve() == venv_dir.resolve():
            return
    except OSError:
        return
    # argv[0] for the script must be a path Python can load
    os.execv(str(venv_py), [str(venv_py), str(_SCRIPT), *sys.argv[1:]])


_maybe_reexec_with_venv()

if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

try:
    import yaml  # noqa: F401
except ImportError:  # pragma: no cover
    print(
        "\nError: no module named 'yaml' (PyYAML).\n\n"
        f"  Run:  cd {_ROOT} && ./fix-dependencies.sh\n"
        f"  Then:  {_ROOT / '.venv' / 'bin' / 'python3'} scripts/test_sensor.py\n\n"
        "  Or:  sudo apt install -y python3-yaml\n",
        file=sys.stderr,
    )
    sys.exit(1)


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
    _sub(f"Python: {sys.executable}")
    _venv = _ROOT / ".venv" / "bin" / "python3"
    if _venv.is_file():
        try:
            # Do not use resolve() here — venv’s python3 often symlinks to the same
            # base binary as “system” python, and we only want the true venv path.
            Path(sys.executable).relative_to(_ROOT / ".venv")
            _sub("Using project .venv (same as ./run) — good for imports.")
        except (ValueError, OSError, RuntimeError):
            _sub("Not using .venv — run:  ./fix-dependencies.sh  then")
            _sub("  .venv/bin/python3 scripts/test_sensor.py")
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
        print()
        print("   Fix (run from the project folder):")
        print("     ./fix-dependencies.sh")
        print(f"     {_ROOT / '.venv' / 'bin' / 'python3'} -m pip install 'bme680>=1.0.5,<2.0.0'")
        print("   Then run this test again (prefer: .venv/bin/python3 scripts/test_sensor.py).")
        return 1
    except Exception as e:  # pragma: no cover
        err = str(e).lower()
        print(f"   FAIL loading bme680 library: {e!r}")
        if "smbus" in err:
            print()
            print("   The driver needs I2C access. On Raspberry Pi OS:")
            print("     sudo apt install -y python3-smbus i2c-tools")
            print("   Then re-run:  ./fix-dependencies.sh  (venv uses --system-site-packages on Pi).")
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
