"""
Optional captive-style redirects so phones on the SmartAir hotspot can open the dashboard.

Set ``HOTSPOT_CAPTIVE=1`` in ``.hotspot.env`` and re-run ``./setuphotspot`` (DNS on AP + :80
→ Flask). Or set ``server.captive_portal: true`` in ``config.yaml`` if you are sure the
network layer is in captive mode. See ``docs/pi-wifi-hotspot.md``.

Full automatic browser open is not guaranteed: many phones use **HTTPS** checks that the Pi
cannot answer without a certificate, or the OS only shows a “Sign in to network” notification.
"""
from __future__ import annotations

import os
from html import escape
from pathlib import Path

from flask import Flask, Response, make_response, redirect, request

# OS connectivity probes; DNS is hijacked to the Pi, requests hit this app on :80 → SMARTAIR_PORT
_CAPTIVE_PATHS: tuple[str, ...] = (
    "/generate_204",
    "/gen_204",
    "/connectivitycheck/generate_204",  # some builds
    "/hotspot-detect.html",  # iOS/legacy — also handled with HTML for CNA
    "/connecttest.txt",  # Windows
    "/redirect",
    "/canonical.html",
    "/ncsi.txt",
    "/ncsi/ncsi.txt",  # Windows variants
    "/success.txt",
    "/connectivity-check.html",
    "/kindle-wifi/wifiredirect.html",
    "/check_network_status.txt",
    "/captive-portal/ok",
    "/library/test/success.html",  # some Apple / embedded checks
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


def _captive_in_state_file() -> bool:
    p = _ROOT / ".hotspot.state"
    if not p.is_file():
        return False
    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        s = line.strip()
        if s.startswith("HOTSPOT_CAPTIVE="):
            v = s.split("=", 1)[1].strip().lower()
            return v in ("1", "true", "yes", "on")
    return False


def _captive_enabled() -> bool:
    for key in ("HOTSPOT_CAPTIVE", "SMARTAIR_CAPTIVE"):
        if (os.environ.get(key) or "").lower() in ("1", "true", "yes"):
            return True
    if _captive_in_state_file():
        return True
    try:
        from settings import load_config

        s = load_config().get("server", {})
        if isinstance(s, dict) and s.get("captive_portal"):
            return True
    except OSError:
        pass
    return False


def _apple_portal_page(target: str) -> Response:
    """iOS Captive Network Assistant often follows 302, but HTML+meta refresh is more reliable."""
    tq = escape(target, quote=True)
    body = f"""<!doctype html>
<html><head>
<meta http-equiv="refresh" content="0;url={tq}">
<meta name="viewport" content="width=device-width">
<title>Network login</title>
</head><body>
<p>Redirecting to the project page…</p>
<p><a href="{tq}">Open Smart Air</a> if you are not redirected.</p>
</body></html>"""
    r = make_response(body, 200)
    r.headers["Content-Type"] = "text/html; charset=utf-8"
    r.headers["X-WISPr-Location-URL"] = target  # some stacks look for WISPr
    r.headers["Cache-Control"] = "no-store"
    return r


def register_captive_routes(app: Flask) -> None:
    global _captive_routes_done
    if not _captive_enabled():
        return
    if _captive_routes_done:
        return
    _captive_routes_done = True
    target = _captive_url()

    def _go():
        p = request.path or "/"
        # Apple: avoid matching “Success” body that iOS uses to mean “has internet”
        if p.rstrip("/") in ("/hotspot-detect.html",) or p.endswith("hotspot-detect.html"):
            return _apple_portal_page(target)
        r = redirect(target, 302)
        r.headers["X-WISPr-Location-URL"] = target
        return r

    for i, path in enumerate(_CAPTIVE_PATHS):
        app.add_url_rule(path, f"_captive_{i}", _go, methods=["GET", "HEAD"])

    print(
        f"  Captive-style redirects: enabled → {target}  "
        f"(add HOTSPOT_CAPTIVE=1 + re-run setuphotspot for DNS+ :80; HTTPS checks may not auto-open a browser)\n"
    )


__all__ = ["register_captive_routes", "_captive_url"]
