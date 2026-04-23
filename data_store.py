from __future__ import annotations

import csv
import datetime
import os
import sqlite3
import threading
import time
from collections import defaultdict
from pathlib import Path
from typing import Any

from settings import load_config


def _db_path() -> str:
    p = load_config().get("data", {}).get("sqlite_path", "data/readings.db")
    root = Path(__file__).resolve().parent
    return str(root / p) if not os.path.isabs(p) else p


def _csv_path() -> str:
    p = load_config().get("data", {}).get("csv_path", "data/readings_log.csv")
    root = Path(__file__).resolve().parent
    return str(root / p) if not os.path.isabs(p) else p


_init_lock = threading.Lock()
_initialized = False


def _ensure_db() -> None:
    global _initialized
    with _init_lock:
        if _initialized:
            return
        Path(_db_path()).parent.mkdir(parents=True, exist_ok=True)
        Path(_csv_path()).parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(_db_path())
        try:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS reading (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts REAL NOT NULL,
                    room TEXT NOT NULL,
                    temperature_c REAL,
                    humidity_percent REAL,
                    pressure_hpa REAL,
                    gas_ohms REAL,
                    quality TEXT,
                    score INTEGER
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS room_summary (
                    room TEXT PRIMARY KEY,
                    sample_count INTEGER NOT NULL,
                    sum_score REAL NOT NULL,
                    last_ts REAL
                )
                """
            )
            conn.commit()
        finally:
            conn.close()
        _initialized = True


def insert_reading(
    room: str,
    temperature_c: float,
    humidity_percent: float,
    pressure_hpa: float,
    gas_ohms: float,
    quality: str,
    score: int,
) -> None:
    _ensure_db()
    ts = time.time()
    conn = sqlite3.connect(_db_path())
    try:
        conn.execute(
            """
            INSERT INTO reading
            (ts, room, temperature_c, humidity_percent, pressure_hpa, gas_ohms, quality, score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (ts, room, temperature_c, humidity_percent, pressure_hpa, gas_ohms, quality, score),
        )
        row = conn.execute(
            "SELECT sample_count, sum_score FROM room_summary WHERE room = ?", (room,)
        ).fetchone()
        if row:
            c, s = int(row[0]), float(row[1])
            conn.execute(
                "UPDATE room_summary SET sample_count = ?, sum_score = ?, last_ts = ? WHERE room = ?",
                (c + 1, s + score, ts, room),
            )
        else:
            conn.execute(
                "INSERT INTO room_summary (room, sample_count, sum_score, last_ts) VALUES (?, 1, ?, ?)",
                (room, float(score), ts),
            )
        conn.commit()
    finally:
        conn.close()

    _append_csv(
        {
            "ts": ts,
            "room": room,
            "temperature_c": temperature_c,
            "humidity_percent": humidity_percent,
            "pressure_hpa": pressure_hpa,
            "gas_ohms": gas_ohms,
            "quality": quality,
            "score": score,
        }
    )


def _append_csv(row: dict[str, Any]) -> None:
    path = _csv_path()
    new_file = not Path(path).exists()
    with open(path, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(
            f,
            fieldnames=[
                "ts",
                "room",
                "temperature_c",
                "humidity_percent",
                "pressure_hpa",
                "gas_ohms",
                "quality",
                "score",
            ],
        )
        if new_file:
            w.writeheader()
        w.writerow(row)


def _local_date_iso(ts: float) -> str:
    return datetime.datetime.fromtimestamp(float(ts)).date().isoformat()


def get_distinct_reading_dates() -> list[str]:
    """All calendar days (local Pi clock) that have at least one stored reading, newest first."""
    _ensure_db()
    conn = sqlite3.connect(_db_path())
    try:
        cur = conn.execute("SELECT ts FROM reading")
        days: set[str] = set()
        for (ts,) in cur.fetchall():
            days.add(_local_date_iso(float(ts)))
    finally:
        conn.close()
    return sorted(days, reverse=True)


def get_room_time_period_chart(filter_date: str | None) -> dict[str, Any]:
    """
    Average score (0-100) per room per time period.
    * filter_date: YYYY-MM-DD (local time) = only that day's samples
    * filter_date None: combine all days (overall average for each slot)
    """
    from time_periods import chart_period_display_meta, classify_time_period_for_timestamp

    _ensure_db()
    cfg = load_config()
    room_list = [str(r) for r in cfg.get("rooms", [])]
    room_set = set(room_list)
    display_labels, period_keys = chart_period_display_meta()

    sum_score: dict[tuple[str, str], float] = defaultdict(float)
    count: dict[tuple[str, str], int] = defaultdict(int)

    conn = sqlite3.connect(_db_path())
    try:
        cur = conn.execute("SELECT ts, room, score FROM reading")
        for ts, room, sc in cur.fetchall():
            tsf = float(ts)
            if filter_date and _local_date_iso(tsf) != filter_date:
                continue
            key = classify_time_period_for_timestamp(tsf)
            if key is None:
                continue
            r = str(room)
            if r not in room_set:
                continue
            sum_score[(r, key)] += int(sc)
            count[(r, key)] += 1
    finally:
        conn.close()

    series: list[dict[str, Any]] = []
    for r in room_list:
        values: list[float | None] = []
        sample_counts: list[int] = []
        for pk in period_keys:
            c = int(count.get((r, pk), 0))
            if c > 0:
                v = sum_score[(r, pk)] / c
                values.append(round(v, 1))
                sample_counts.append(c)
            else:
                values.append(None)
                sample_counts.append(0)
        series.append(
            {
                "room": r,
                "values": values,
                "sample_counts": sample_counts,
            }
        )

    return {
        "periods": display_labels,
        "period_keys": period_keys,
        "series": series,
        "filter_date": filter_date,
        "available_dates": get_distinct_reading_dates(),
    }


__all__ = [
    "insert_reading",
    "get_room_time_period_chart",
    "ensure_db",
]


def ensure_db() -> None:
    _ensure_db()
