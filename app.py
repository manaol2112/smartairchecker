from __future__ import annotations

import os
import threading
import time
from typing import Any

from flask import Flask, jsonify, render_template, request

from data_store import ensure_db, get_room_time_period_chart, insert_reading
from outputs import AirQualityIndicator
from sensor_bme680 import BME680Monitor
import state
from settings import load_config

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


def _logging_loop() -> None:
    while True:
        time.sleep(2.0)
        snap = _get_monitor().get_snapshot()
        if not snap or "quality" not in snap:
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


def _follow_hardware_loop() -> None:
    last: str | None = None
    while True:
        time.sleep(0.2)
        snap = _get_monitor().get_snapshot()
        q = snap.get("quality")
        if not q:
            continue
        if q == last:
            continue
        last = str(q)
        _get_outputs().set_quality(q)  # type: ignore[arg-type]


def create_app() -> Flask:
    return app


@app.route("/")
def index() -> str:
    cfg = load_config()
    return render_template("index.html", rooms=cfg.get("rooms", []))


@app.get("/api/status")
def api_status() -> Any:
    snap = _get_monitor().get_snapshot()
    return jsonify(
        {
            "sensor": snap,
            "room": state.get_current_room(),
            "rooms": load_config().get("rooms", []),
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

    cfg = load_config()
    s = cfg.get("server", {})
    host = s.get("host", "0.0.0.0")
    default_port = int(s.get("port", 5001))
    port = int(os.environ.get("SMARTAIR_PORT", str(default_port)))
    print(
        f"\n  Air project page → http://127.0.0.1:{port}   (on your Pi, use the Pi’s IP and this port)\n"
    )
    app.run(host=host, port=port, debug=False, threaded=True)
