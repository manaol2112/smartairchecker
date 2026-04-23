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

    def _init_sensor(self) -> None:
        if self._dry:
            return
        import bme680 as bme

        try:
            s = bme.BME680(bme.I2C_ADDR_PRIMARY)
        except (RuntimeError, OSError) as e:
            raise RuntimeError(
                "Could not open BME680 on I2C. Run: sudo raspi-config → Interface Options → I2C → Enable, "
                "and check wiring (SDA/SCL) and 3.3V."
            ) from e
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
                if s.get_sensor_data() and s.data.heat_stable:
                    temp = s.data.temperature
                    hum = s.data.humidity
                    pres = s.data.pressure
                    gas_ohms = s.data.gas_resistance
                else:
                    time.sleep(0.1)
                    continue

            result: AirQualityResult = evaluate_air_quality(
                gas_ohms=gas_ohms,
                good_min=g_min,
                moderate_min=m_min,
                min_gas_ohms=min_ohms,
                baseline_ohms=baseline,
                use_relative_score=use_rel,
            )
            with self._lock:
                self._last = {
                    "temperature_c": round(temp, 2),
                    "humidity_percent": round(hum, 2),
                    "pressure_hpa": round(pres, 2),
                    "gas_ohms": round(gas_ohms, 1),
                    "quality": result.label,
                    "score": result.score_0_100,
                    "ts": time.time(),
                }
            time.sleep(1.0)

    def uses_synthetic(self) -> bool:
        """True if we are not reading a real I2C sensor (config, env, or hardware failure)."""
        return bool(self._dry)

    def get_snapshot(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._last) if self._last else {}


__all__ = ["BME680Monitor"]
