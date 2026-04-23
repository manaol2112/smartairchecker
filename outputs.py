from __future__ import annotations

import logging
import sys
import threading
import time
from typing import Literal

from settings import is_dry_run, load_config

logger = logging.getLogger(__name__)

QualityLabel = Literal["good", "moderate", "bad"]


class _Mock:
    def on(self) -> None:
        pass

    def off(self) -> None:
        pass

    def close(self) -> None:
        pass


def _gpio_ok() -> bool:
    if is_dry_run():
        return False
    # No Raspberry Pi-style GPIO on normal Mac/Windows; skip gpiozero so there are
    # no "pin factory" errors or long warning messages.
    if sys.platform in ("darwin", "win32"):
        return False
    try:
        import gpiozero  # noqa: F401
    except (ImportError, OSError, NotImplementedError):
        return False
    return True


def _init_gpiozero_leds(
    pr: int, pg: int, pb: int, bz: int, active_high: bool
) -> tuple[object, object, object, object] | None:
    """Create real LED / buzzer devices, or return None on laptop / no GPIO."""
    try:
        from gpiozero import LED
        from gpiozero.exc import BadPinFactory

        r = LED(pr, active_high=active_high)
        g = LED(pg, active_high=active_high)
        b = LED(pb, active_high=active_high)
        bz_ = LED(bz)
        return (r, g, b, bz_)
    except (BadPinFactory, OSError, NotImplementedError) as e:
        logger.warning("GPIO not available; LED and buzzer are off (ok on a normal computer): %s", e)
        return None
    except Exception as e:  # noqa: BLE001 - any pin / permission issue
        logger.warning("Could not use GPIO: %s", e)
        return None


class AirQualityIndicator:
    """RGB LED (three separate GPIO lines) and active buzzer."""

    def __init__(self) -> None:
        self._cfg = load_config()
        g = self._cfg.get("gpio", {})
        pr = g.get("rgb_red", 17)
        pg = g.get("rgb_green", 27)
        pb = g.get("rgb_blue", 22)
        bz = g.get("buzzer", 18)
        self._common_anode = bool(g.get("common_anode", False))
        # Common anode: LED turns on when GPIO is low → active_high False
        active_high = not self._common_anode
        if _gpio_ok():
            leds = _init_gpiozero_leds(pr, pg, pb, bz, active_high)
        else:
            leds = None

        if leds is not None:
            self._r, self._g, self._b, self._buzzer = leds
        else:
            self._r = self._g = self._b = _Mock()
            self._buzzer = _Mock()

        bz_cfg = self._cfg.get("buzzer", {})
        self._beep_on = float(bz_cfg.get("beep_on", 0.4))
        self._beep_off = float(bz_cfg.get("beep_off", 0.2))
        self._beep_period = float(bz_cfg.get("repeat_every", 2.0))

        self._stop_buzzer = threading.Event()
        self._buzz_thread: threading.Thread | None = None
        self._lock = threading.Lock()

    def set_quality(self, label: QualityLabel) -> None:
        with self._lock:
            self._r.off()
            self._g.off()
            self._b.off()

            if label == "good":
                self._g.on()
            elif label == "moderate":
                self._r.on()
                self._g.on()
            else:
                self._r.on()

        if label == "bad":
            self._start_buzz_loop()
        else:
            self._stop_buzz_loop()

    def _start_buzz_loop(self) -> None:
        with self._lock:
            if self._buzz_thread and self._buzz_thread.is_alive():
                return
            self._stop_buzzer.clear()
            self._buzz_thread = threading.Thread(
                target=self._buzz_worker, name="buzzer", daemon=True
            )
            self._buzz_thread.start()

    def _stop_buzz_loop(self) -> None:
        self._stop_buzzer.set()
        self._buzzer.off()
        t = self._buzz_thread
        if t and t.is_alive() and t is not threading.current_thread():
            t.join(timeout=0.2)

    def _buzz_worker(self) -> None:
        while not self._stop_buzzer.is_set():
            t0 = time.time()
            while time.time() - t0 < self._beep_period and not self._stop_buzzer.is_set():
                self._buzzer.on()
                time.sleep(self._beep_on)
                self._buzzer.off()
                time.sleep(self._beep_off)
        self._buzzer.off()

    def close(self) -> None:
        self._stop_buzz_loop()
        for p in (self._r, self._g, self._b, self._buzzer):
            try:
                p.close()
            except OSError:
                pass


__all__ = ["AirQualityIndicator"]
