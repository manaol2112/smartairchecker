"""
Optional captive-style redirects so phones on the SmartAir hotspot can open the dashboard.

Set ``HOTSPOT_CAPTIVE=1`` in ``.hotspot.env`` (or ``SMARTAIR_CAPTIVE=1``), or
``server.captive_portal: true`` in ``config.yaml``.

Requires the hotspot to be set up with ``HOTSPOT_CAPTIVE=1`` in
``./setuphotspot`` (DNS on the AP + iptables :80 → Flask). See
``docs/pi-wifi-hotspot.md``.
"""
from __future__ import annotations

import os
from pathlib import Path

from flask import Flask, redirect

# Paths used by Android / iOS / Windows for connectivity checks
_CAPTIVE_PATHS: tuple[str, ...] = (
    "/generate_204",
    "/gen_204",
    "/hotspot-detect.html",
    "/connecttest.txt",
    "/redirect",
    "/canonical.html",
    "/ncsi.txt",
    "/success.txt",
    "/connectivity-check.html",
    "/kindle-wifi/wifiredirect.html",
    "/check_network_status.txt",
    "/captive-portal/ok",
)

_ROOT = Path(__file__).resolve().parent
_captive_routes_done = False


def _captive_url() -> str:
    p = (os.environ.get("SMARTAIR_CAPTIVE_URL") or "").strip()
    if p:
        return p
    st_path = os.environ.get("SMARTAIR_AP_STATE", str(_ROOT / ".hotspot.state"))
    st = Path(st_path)
    if st.is_file():
        ap_ip: str | None = None
        url: str | None = None
        for line in st.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("AP_IP="):
                ap_ip = line.split("=", 1)[1].strip()
            if line.startswith("SMARTAIR_URL="):
                url = line.split("=", 1)[1].strip()
        if url:
            return url
        if ap_ip:
            port = int(os.environ.get("SMARTAIR_PORT", "5001"))
            return f"http://{ap_ip}:{port}/"
    ap = os.environ.get("SMARTAIR_AP_IP", "192.168.4.1")
    port = int(os.environ.get("SMARTAIR_PORT", "5001"))
    return f"http://{ap}:{port}/"


def _captive_enabled() -> bool:
    for key in ("HOTSPOT_CAPTIVE", "SMARTAIR_CAPTIVE"):
        if (os.environ.get(key) or "").lower() in ("1", "true", "yes"):
            return True
    try:
        from settings import load_config

        s = load_config().get("server", {})
        if isinstance(s, dict) and s.get("captive_portal"):
            return True
    except OSError:
        pass
    return False


def register_captive_routes(app: Flask) -> None:
    global _captive_routes_done
    if not _captive_enabled():
        return
    if _captive_routes_done:
        return
    _captive_routes_done = True
    target = _captive_url()

    def _go():
        return redirect(target, 302)

    for i, path in enumerate(_CAPTIVE_PATHS):
        app.add_url_rule(path, f"_captive_{i}", _go, methods=["GET", "HEAD"])

    print(f"  Captive-style redirects: enabled → {target} (OS connectivity probes)")


__all__ = ["register_captive_routes", "_captive_url"]
