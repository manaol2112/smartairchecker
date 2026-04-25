from __future__ import annotations

import logging
import sys
import threading
import time
from typing import Any, Literal, cast

from settings import is_dry_run, load_config

logger = logging.getLogger(__name__)

QualityLabel = Literal["good", "moderate", "bad"]
BuzzerKind = Literal["active", "passive"]
BuzzerPattern = Literal["pulsed", "continuous"]


class _Mock:
    def on(self) -> None:
        pass

    def off(self) -> None:
        pass

    def play(self, *_a: object, **_k: object) -> None:
        pass

    def stop(self) -> None:
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


def _init_rgb(
    pr: int, pg: int, pb: int, active_high: bool
) -> tuple[object, object, object] | None:
    try:
        from gpiozero import LED
        from gpiozero.exc import BadPinFactory

        r = LED(pr, active_high=active_high)
        g = LED(pg, active_high=active_high)
        b = LED(pb, active_high=active_high)
        return (r, g, b)
    except (BadPinFactory, OSError, NotImplementedError) as e:
        logger.warning("GPIO not available; LED is off (ok on a normal computer): %s", e)
        return None
    except Exception as e:  # noqa: BLE001
        logger.warning("Could not use GPIO for LED: %s", e)
        return None


def _init_buzzer_device(pin: int, kind: BuzzerKind) -> object | None:
    """Active = DC on/off. Passive piezo = needs a tone (PWM) — use TonalBuzzer."""
    try:
        from gpiozero import LED, TonalBuzzer
        from gpiozero.exc import BadPinFactory

        if kind == "passive":
            # Default TonalBuzzer is only A4 ±1 octave (~220–880 Hz); piezo alarms use ~2–4 kHz.
            return TonalBuzzer(pin, octaves=4)
        return LED(pin, active_high=True)
    except (BadPinFactory, OSError, NotImplementedError) as e:
        logger.warning("GPIO not available; buzzer is off: %s", e)
        return None
    except Exception as e:  # noqa: BLE001
        logger.warning("Could not use GPIO for buzzer: %s", e)
        return None


def _buzzer_stop(bz: object, is_passive: bool) -> None:
    if is_passive:
        cast(Any, bz).stop()
    else:
        cast(Any, bz).off()


def _buzzer_start_tone(bz: object, is_passive: bool, freq: float) -> None:
    if is_passive:
        cast(Any, bz).play(float(freq))
    else:
        cast(Any, bz).on()


class AirQualityIndicator:
    """RGB LED (three GPIO lines) and buzzer: active (DC) or passive piezo (PWM tone)."""

    def __init__(self) -> None:
        self._cfg = load_config()
        g = self._cfg.get("gpio", {}) if isinstance(self._cfg.get("gpio"), dict) else {}
        pr = g.get("rgb_red", 17)
        pg = g.get("rgb_green", 27)
        pb = g.get("rgb_blue", 22)
        bz_pin = g.get("buzzer", 18)
        self._common_anode = bool(g.get("common_anode", False))
        active_high = not self._common_anode

        bz_cfg = self._cfg.get("buzzer", {}) if isinstance(self._cfg.get("buzzer"), dict) else {}
        self._buzzer_enabled = bool(bz_cfg.get("enabled", True))
        kind_raw = str(bz_cfg.get("kind", "active")).lower().strip()
        if kind_raw in ("passive", "piezo", "pzm", "5v_piezo"):
            self._buzzer_kind: BuzzerKind = "passive"
        else:
            self._buzzer_kind = "active"
        self._buzzer_freq = float(bz_cfg.get("frequency_hz", 2500.0))
        pat = str(bz_cfg.get("pattern", "pulsed")).lower().strip()
        self._buzz_pattern: BuzzerPattern = "continuous" if pat == "continuous" else "pulsed"
        self._beep_on = float(bz_cfg.get("beep_on", 0.4))
        self._beep_off = float(bz_cfg.get("beep_off", 0.2))
        self._beep_period = float(bz_cfg.get("repeat_every", 2.0))

        self._buzzer_is_passive = self._buzzer_kind == "passive"

        if _gpio_ok():
            rgb = _init_rgb(pr, pg, pb, active_high)
            if rgb is not None:
                self._r, self._g, self._b = rgb
            else:
                self._r = self._g = self._b = _Mock()
            if self._buzzer_enabled:
                bz_dev = _init_buzzer_device(bz_pin, self._buzzer_kind)
                self._buzzer = bz_dev if bz_dev is not None else _Mock()
            else:
                self._buzzer = _Mock()
        else:
            self._r = self._g = self._b = _Mock()
            self._buzzer = _Mock()

        self._stop_buzzer = threading.Event()
        self._buzz_thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self._last_label: QualityLabel | None = None

    def set_quality(self, label: QualityLabel) -> None:
        with self._lock:
            if label == self._last_label:
                return
            self._last_label = label
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

        if not self._buzzer_enabled:
            return

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
        if not isinstance(self._buzzer, _Mock):
            try:
                _buzzer_stop(self._buzzer, self._buzzer_is_passive)
            except (OSError, ValueError) as e:
                logger.debug("buzzer stop: %s", e)
        t = self._buzz_thread
        if t and t.is_alive() and t is not threading.current_thread():
            t.join(timeout=0.2)

    def _buzz_worker(self) -> None:
        bz: Any = self._buzzer
        is_p = self._buzzer_is_passive

        if self._buzz_pattern == "continuous":
            if isinstance(bz, _Mock):
                return
            _buzzer_start_tone(bz, is_p, self._buzzer_freq)
            self._stop_buzzer.wait()
            try:
                _buzzer_stop(bz, is_p)
            except OSError:
                pass
            return

        # pulsed: on/off or tone bursts until air improves
        while not self._stop_buzzer.is_set():
            t0 = time.time()
            while time.time() - t0 < self._beep_period and not self._stop_buzzer.is_set():
                if isinstance(bz, _Mock):
                    time.sleep(self._beep_on + self._beep_off)
                    continue
                _buzzer_start_tone(bz, is_p, self._buzzer_freq)
                time.sleep(self._beep_on)
                _buzzer_stop(bz, is_p)
                time.sleep(self._beep_off)
        if not isinstance(bz, _Mock):
            try:
                _buzzer_stop(bz, is_p)
            except OSError:
                pass

    def close(self) -> None:
        self._last_label = None
        self._stop_buzz_loop()
        for p in (self._r, self._g, self._b, self._buzzer):
            try:
                p.close()  # type: ignore[attr-defined]
            except OSError:
                pass


__all__ = ["AirQualityIndicator"]
