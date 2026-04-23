from __future__ import annotations

import datetime
from typing import Any

from settings import load_config


def _hour_in_range(h: int, start: int, end: int) -> bool:
    """
    [start, end) on 24h clock. If start > end, the interval wraps (night: 20 → 5
    is 20:00–23:59 and 00:00–04:59).
    """
    h = h % 24
    if start < end:
        return start <= h < end
    if start > end:
        return h >= start or h < end
    return False


def classify_time_period_for_timestamp(ts: float) -> str | None:
    """
    Classify a logged sample by the device's local time into a period key
    (e.g. morning, lunch, night) or None if the hour is in a gap between windows.
    """
    cfg = load_config()
    tcfg = cfg.get("time_periods", {})
    order: list[str] = list(
        tcfg.get("order", ["morning", "lunch", "night"])
    )
    h = int(datetime.datetime.fromtimestamp(ts).hour)

    for key in order:
        block = tcfg.get(key)
        if not isinstance(block, dict):
            continue
        start = int(block.get("from_hour", 0))
        end = int(block.get("to_hour", 24))
        if _hour_in_range(h, start, end):
            return str(key)
    return None


def chart_period_display_meta() -> tuple[list[str], list[str]]:
    """
    (labels for X axis, same order as time_periods.order),
    (keys in same order).
    """
    cfg = load_config()
    tcfg = cfg.get("time_periods", {})
    order: list[str] = list(
        tcfg.get("order", ["morning", "lunch", "night"])
    )
    labels_map = tcfg.get("labels", {})
    keys: list[str] = []
    labels: list[str] = []
    for k in order:
        keys.append(k)
        raw = labels_map.get(k, k)
        if isinstance(raw, str) and raw:
            labels.append(raw)
        else:
            labels.append(k.replace("_", " ").title())
    return labels, keys


__all__ = [
    "classify_time_period_for_timestamp",
    "chart_period_display_meta",
]
