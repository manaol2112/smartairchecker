from __future__ import annotations

import os
import threading
import time
from pathlib import Path
from typing import Any

from flask import Flask, jsonify, render_template, request

from data_store import ensure_db, get_room_time_period_chart, insert_reading
from outputs import AirQualityIndicator
from sensor_bme680 import BME680Monitor
import state
from settings import load_config

from captive_portal import register_captive_routes

app = Flask(__name__)
# Without this, the server can keep a cached Jinja2 template in memory; edits to
# index.html will not show until the process is restarted. Allow reload on every request.
app.config["TEMPLATES_AUTO_RELOAD"] = True
app.jinja_env.auto_reload = True


@app.after_request
def _no_cache(res):
    res.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    res.headers["Pragma"] = "no-cache"
    return res
_monitor: BME680Monitor | None = None
_outputs: AirQualityIndicator | None = None


def _get_monitor() -> BME680Monitor:
    assert _monitor is not None
    return _monitor


def _get_outputs() -> AirQualityIndicator:
    assert _outputs is not None
    return _outputs


def _data_log_interval_sec() -> float:
    d = load_config().get("data", {})
    if not isinstance(d, dict):
        return 30 * 60.0
    v = d.get("log_interval_seconds", 30 * 60)
    return max(1.0, float(v))


def _logging_loop() -> None:
    """Append one row to SQLite + CSV on each tick; default tick is every 30 minutes."""
    while True:
        snap = _get_monitor().get_snapshot()
        if not snap or "quality" not in snap:
            time.sleep(2.0)
            continue
        # After a room change, only log once the BME680 has completed a read *after* the switch
        # (snapshot ts is newer than the change) so rows match the room’s air.
        ch = state.get_room_change_ts()
        if ch > 0.0 and float(snap.get("ts", 0.0)) <= ch:
            time.sleep(0.3)
            continue
        try:
            insert_reading(
                room=state.get_current_room(),
                temperature_c=float(snap.get("temperature_c", 0)),
                humidity_percent=float(snap.get("humidity_percent", 0)),
                pressure_hpa=float(snap.get("pressure_hpa", 0)),
                gas_ohms=float(snap.get("gas_ohms", 0)),
                quality=str(snap.get("quality", "")),
                score=int(snap.get("score", 0)),
            )
        except OSError as e:
            app.logger.error("data insert failed: %s", e)
        time.sleep(_data_log_interval_sec())


def _follow_hardware_loop() -> None:
    """Push live quality to RGB + buzzer; outputs.set_quality no-ops if label unchanged."""
    while True:
        time.sleep(0.2)
        snap = _get_monitor().get_snapshot()
        q = snap.get("quality")
        if not q:
            continue
        _get_outputs().set_quality(q)  # type: ignore[arg-type]


def create_app() -> Flask:
    return app


def _load_captive_from_hotspot_files() -> None:
    """Apply HOTSPOT_CAPTIVE from .hotspot.state / .hotspot.env so ./run matches ./setuphotspot."""
    if (os.environ.get("HOTSPOT_CAPTIVE") or "").lower() in ("1", "true", "yes"):
        return
    if (os.environ.get("SMARTAIR_CAPTIVE") or "").lower() in ("1", "true", "yes"):
        return
    # Last setup wins in .hotspot.state; read that before .hotspot.env
    root = Path(__file__).resolve().parent
    for name in (".hotspot.state", ".hotspot.env"):
        p = root / name
        if not p.is_file():
            continue
        for raw in p.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line.startswith("HOTSPOT_CAPTIVE="):
                continue
            v = line.split("=", 1)[1].strip().strip('"').strip("'")
            if v.lower() in ("1", "true", "yes"):
                os.environ["HOTSPOT_CAPTIVE"] = "1"
                os.environ["SMARTAIR_CAPTIVE"] = "1"
                return
            # explicit 0 / false: keep scanning the other file


def _live_poll_ms() -> int:
    s = load_config().get("server", {})
    if not isinstance(s, dict):
        return 1000
    ms = int(s.get("live_poll_ms", 1000))
    return max(200, min(10_000, ms))


@app.route("/")
def index() -> str:
    cfg = load_config()
    return render_template(
        "index.html",
        rooms=cfg.get("rooms", []),
        live_poll_ms=_live_poll_ms(),
    )


@app.get("/api/status")
def api_status() -> Any:
    snap = _get_monitor().get_snapshot()
    return jsonify(
        {
            "sensor": snap,
            "room": state.get_current_room(),
            "rooms": load_config().get("rooms", []),
            "live_poll_ms": _live_poll_ms(),
            # "live" only when a real BME680 is in use; otherwise pretend numbers for the UI
            "data_source": "simulated"
            if _get_monitor().uses_synthetic()
            else "live",
        }
    )


@app.get("/api/room_time_chart")
def api_room_time_chart() -> Any:
    raw = (request.args.get("date") or "").strip()
    if not raw or raw.lower() == "all":
        return jsonify(get_room_time_period_chart(None))
    if len(raw) == 10 and raw[4] == "-" and raw[7] == "-":
        return jsonify(get_room_time_period_chart(raw))
    return jsonify({"error": "date must be YYYY-MM-DD or all"}), 400


@app.post("/api/room")
def api_set_room() -> Any:
    data = request.get_json(silent=True) or {}
    name = (data.get("room") or "").strip()
    allowed = set(load_config().get("rooms", []))
    if name not in allowed:
        return jsonify({"ok": False, "error": "Invalid room name"}), 400
    state.set_current_room(name)
    return jsonify({"ok": True, "room": name})


def run() -> None:
    global _monitor, _outputs
    state.init_default_room()
    ensure_db()
    db_path = load_config().get("data", {}).get("sqlite_path", "data/readings.db")
    log_iv = _data_log_interval_sec()
    print(
        f"  Data log: SQLite + CSV every {log_iv/60.0:.1f} min  (set data.log_interval_seconds in config.yaml; DB: {db_path})"
    )

    _monitor = BME680Monitor()
    _outputs = AirQualityIndicator()
    t_sensor = threading.Thread(target=_monitor.read_loop, name="bme680", daemon=True)
    t_sensor.start()
    t_log = threading.Thread(target=_logging_loop, name="logger", daemon=True)
    t_log.start()
    t_hw = threading.Thread(target=_follow_hardware_loop, name="hardware", daemon=True)
    t_hw.start()

    # Wait briefly for first reading before opening hardware output (optional)
    for _ in range(50):
        if _monitor.get_snapshot().get("quality"):
            _outputs.set_quality(_monitor.get_snapshot()["quality"])  # type: ignore[arg-type]
            break
        time.sleep(0.1)

    _load_captive_from_hotspot_files()
    register_captive_routes(app)
    cfg = load_config()
    s = cfg.get("server", {})
    host = s.get("host", "0.0.0.0")
    default_port = int(s.get("port", 5001))
    port = int(os.environ.get("SMARTAIR_PORT", str(default_port)))
    print(
        f"\n  Air project page → http://127.0.0.1:{port}   (on your Pi, use the Pi’s IP and this port)\n"
    )
    app.run(host=host, port=port, debug=False, threaded=True)
