"""Shared I2C / SMBus handle for the BME680 (library defaults to bus 1 only)."""
from __future__ import annotations

from typing import Any, Mapping

__all__ = ["i2c_bus_from_cfg", "open_smbus"]


def i2c_bus_from_cfg(cfg: Mapping[str, Any]) -> int:
    """I2C bus number for the 40‑pin SDA/SCL (often 1 on Pi 3/4/5; try 0 in config if open fails)."""
    n = int(cfg.get("sensors", {}).get("i2c_bus", 1))
    if n < 0 or n > 40:
        raise ValueError("sensors.i2c_bus must be a small non-negative integer (typically 0 or 1).")
    return n


def open_smbus(bus: int) -> Any:
    """Open Linux SMBus. Prefer ``smbus`` (apt: ``python3-smbus``); else ``smbus2`` from pip."""
    try:
        import smbus  # from python3-smbus

        return smbus.SMBus(bus)
    except ImportError:  # pragma: no cover
        import smbus2

        return smbus2.SMBus(bus)
