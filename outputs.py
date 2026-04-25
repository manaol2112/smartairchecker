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
BuzzerPattern = Literal["pulsed", "continuous", "siren"]


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


def buzzer_effective_pwm_duty(bz_cfg: dict) -> float:
    """Final PWM *duty* for a passive piezo (used for every alarm: siren / continuous / pulsed).

    1) Base duty from ``volume`` (0..1) → ~0.05..0.5. 2) Multiply by ``gain`` (default 3).
    3) Cap with ``max_pwm_duty`` so we never approach 1.0 (DC → silent on piezos).

    The Pi cannot output 3× *voltage*; this is the strongest *software* drive most modules tolerate.
    """
    max_cap = float(bz_cfg.get("max_pwm_duty", 0.68))
    max_cap = max(0.05, min(0.75, max_cap))
    gain = float(bz_cfg.get("gain", 3.0))
    gain = max(0.3, min(5.0, gain))
    v = max(0.0, min(1.0, float(bz_cfg.get("volume", 1.0))))
    if bz_cfg.get("pwm_duty") is not None:
        d = float(bz_cfg["pwm_duty"])
        raw = d * gain
    else:
        base = 0.05 + 0.45 * v
        raw = base * gain
    return max(0.05, min(max_cap, raw))


def _buzzer_start_tone(
    bz: object,
    is_passive: bool,
    freq: float,
    *,
    pwm_duty: float = 0.5,
) -> None:
    """Set tone; for passive, apply *pwm_duty* (typically 0.5 = loudest clean square wave on Pi)."""
    if is_passive:
        dev: Any = cast(Any, bz)
        dev.play(float(freq))
        pd = getattr(dev, "pwm_device", None)
        if pd is not None:
            d = max(0.05, min(0.75, float(pwm_duty)))
            pd.value = d
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
        if pat in (
            "siren",
            "alarm",
            "yelp",
            "audience",
            "hilo",
            "hi-lo",
        ):
            self._buzz_pattern: BuzzerPattern = "siren"
        elif pat == "continuous":
            self._buzz_pattern = "continuous"
        else:
            self._buzz_pattern = "pulsed"
        # Two-tone siren: alternating Hz (classroom / attention; passive piezo only for dual tone)
        self._siren_f_lo = float(
            bz_cfg.get("siren_freq_low", bz_cfg.get("siren_low_hz", 2000.0))
        )
        self._siren_f_hi = float(
            bz_cfg.get("siren_freq_high", bz_cfg.get("siren_high_hz", 4200.0))
        )
        self._siren_step = float(
            bz_cfg.get("siren_step_seconds", bz_cfg.get("siren_step", 0.1))
        )
        self._siren_step = max(0.04, min(0.5, self._siren_step))
        self._beep_on = float(bz_cfg.get("beep_on", 0.4))
        self._beep_off = float(bz_cfg.get("beep_off", 0.2))
        self._beep_period = float(bz_cfg.get("repeat_every", 2.0))
        self._buzzer_is_passive = self._buzzer_kind == "passive"
        self._buzzer_pwm_duty = (
            buzzer_effective_pwm_duty(bz_cfg) if self._buzzer_is_passive else 1.0
        )

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
        vol = self._buzzer_pwm_duty

        if self._buzz_pattern == "siren":
            if isinstance(bz, _Mock):
                return
            if is_p:
                # Alternating two tones (hi/lo) — more noticeable than one steady beep
                f_lo = min(self._siren_f_lo, self._siren_f_hi)
                f_hi = max(self._siren_f_lo, self._siren_f_hi)
                freqs: list[float] = [f_lo, f_hi]
                i = 0
                while not self._stop_buzzer.is_set():
                    _buzzer_start_tone(bz, True, freqs[i & 1], pwm_duty=vol)
                    t_end = time.time() + self._siren_step
                    while time.time() < t_end and not self._stop_buzzer.is_set():
                        time.sleep(0.02)
                    i += 1
            else:
                # Active buzzer: one pitch only — stutter the DC on/off like a fire bell
                st_on = 0.08
                st_off = 0.08
                while not self._stop_buzzer.is_set():
                    bz.on()
                    t_end = time.time() + st_on
                    while time.time() < t_end and not self._stop_buzzer.is_set():
                        time.sleep(0.02)
                    bz.off()
                    t_end = time.time() + st_off
                    while time.time() < t_end and not self._stop_buzzer.is_set():
                        time.sleep(0.02)
            if not isinstance(bz, _Mock):
                try:
                    _buzzer_stop(bz, is_p)
                except OSError:
                    pass
            return

        if self._buzz_pattern == "continuous":
            if isinstance(bz, _Mock):
                return
            _buzzer_start_tone(
                bz, is_p, self._buzzer_freq, pwm_duty=self._buzzer_pwm_duty
            )
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
                _buzzer_start_tone(
                    bz, is_p, self._buzzer_freq, pwm_duty=self._buzzer_pwm_duty
                )
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


__all__ = ["AirQualityIndicator", "buzzer_effective_pwm_duty"]
