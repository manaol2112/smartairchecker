from __future__ import annotations

import logging
import random
import threading
import time
from typing import Any, TYPE_CHECKING

if TYPE_CHECKING:
    import bme680

from air_quality import AirQualityResult, evaluate_air_quality
from settings import is_dry_run, load_config

logger = logging.getLogger(__name__)


class BME680Monitor:
    """Background reads BME680; results protected by a lock for thread-safe access."""

    def __init__(self) -> None:
        self._cfg = load_config()
        self._lock = threading.Lock()
        self._last: dict[str, Any] = {}
        self._sensor: Any = None
        self._dry = is_dry_run()
        iq = self._cfg.get("air_quality", {})
        # Used until the gas heater reports a stable reading (avoids a blank live UI for minutes)
        self._last_gas: float = float(iq.get("baseline_ohms", 50_000))

    def _init_sensor(self) -> None:
        if self._dry:
            return
        import bme680 as bme

        addrs: list[int] = [bme.I2C_ADDR_PRIMARY, bme.I2C_ADDR_SECONDARY]
        last_err: Exception | None = None
        s = None
        for addr in addrs:
            try:
                s = bme.BME680(addr)
                logger.info("BME680 opened on I2C 0x%02x (SDA/SCL, 3.3V, GND)", addr)
                break
            except (RuntimeError, OSError) as e:
                last_err = e
                logger.debug("BME680 not at 0x%02x: %s", addr, e)
        if s is None:
            assert last_err is not None
            raise RuntimeError(
                "Could not open BME680 on I2C (tried 0x76 and 0x77). "
                "Enable I2C (sudo raspi-config → Interface Options → I2C), "
                "add user to the i2c group, and check SDA/SCL and 3.3V. "
                "Run:  sudo i2cdetect -y 1  (or bus 0 on older Pis)."
            ) from last_err
        s.set_humidity_oversample(bme.OS_2X)
        s.set_pressure_oversample(bme.OS_4X)
        s.set_temperature_oversample(bme.OS_8X)
        s.set_filter(bme.FILTER_SIZE_3)
        s.set_gas_heater_temperature(320)
        s.set_gas_heater_duration(150)
        self._sensor = s

    def read_loop(self) -> None:
        if not self._dry:
            try:
                self._init_sensor()
            except (RuntimeError, OSError) as e:
                logger.error(
                    "BME680 not available: %s. Using pretend air numbers for the page only (not a real reading).",
                    e,
                )
                self._dry = True
        iq = self._cfg.get("air_quality", {})
        g_min = float(iq.get("good_min", 20_000))
        m_min = float(iq.get("moderate_min", 10_000))
        min_ohms = float(iq.get("min_gas_ohms", 1_000))
        baseline = float(iq.get("baseline_ohms", 50_000))
        use_rel = bool(iq.get("use_relative_score", True))
        t_base = 24.0
        h_base = 50.0
        g_base = 25_000.0

        while True:
            if self._dry:
                # Fake drift for UI testing off-device
                t_base += random.uniform(-0.05, 0.05)
                h_base = max(20, min(70, h_base + random.uniform(-0.2, 0.2)))
                g_base = max(5_000, g_base + random.uniform(-200, 200))
                temp = t_base
                hum = h_base
                pres = 1013.0 + random.uniform(-0.5, 0.5)
                gas_ohms = g_base
            else:
                assert self._sensor is not None
                s = self._sensor
                if not s.get_sensor_data():
                    time.sleep(0.1)
                    continue
                d = s.data
                temp = d.temperature
                hum = d.humidity
                pres = d.pressure
                # Gas resistance is only reliable once the hot plate has stabilized. If we
                # waited only for that, the web UI would stay empty for a long time.
                heat_ok = bool(getattr(d, "heat_stable", True))
                gr = getattr(d, "gas_resistance", None)
                if heat_ok and gr is not None and float(gr) > 0:
                    self._last_gas = float(gr)
                gas_ohms = max(float(self._last_gas), min_ohms)
                # True once the gas heater reports a new valid resistance (not just T/H/P).
                gas_stabilized = heat_ok

            result: AirQualityResult = evaluate_air_quality(
                gas_ohms=gas_ohms,
                good_min=g_min,
                moderate_min=m_min,
                min_gas_ohms=min_ohms,
                baseline_ohms=baseline,
                use_relative_score=use_rel,
            )
            snap: dict[str, Any] = {
                "temperature_c": round(temp, 2),
                "humidity_percent": round(hum, 2),
                "pressure_hpa": round(pres, 2),
                "gas_ohms": round(gas_ohms, 1),
                "quality": result.label,
                "score": result.score_0_100,
                "ts": time.time(),
            }
            if not self._dry:
                snap["gas_stabilized"] = gas_stabilized
            with self._lock:
                self._last = snap
            time.sleep(1.0)

    def uses_synthetic(self) -> bool:
        """True if we are not reading a real I2C sensor (config, env, or hardware failure)."""
        return bool(self._dry)

    def get_snapshot(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._last) if self._last else {}


__all__ = ["BME680Monitor"]
