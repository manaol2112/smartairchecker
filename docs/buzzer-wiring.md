# Passive 5V buzzer module ↔ Raspberry Pi

The app turns the alarm **on** when the dashboard air quality is **bad**, and **off** as soon as it is **no longer bad** (moderate or good) — the same rules as the red LED and the “Bad” chip on the page.

- Software: `outputs.py` → `AirQualityIndicator` (uses `gpiozero` — **TonalBuzzer** for a **passive** piezo, **LED** for an **active** buzzer).
- **Passive** = piezoelectric disc that only makes sound when the GPIO **toggles a frequency** (PWM / tone). **Active** = has a small circuit inside: GPIO **high** = one fixed beep, no `frequency_hz` needed.
- This guide matches common **3-pin** “passive buzzer module” / **5V piezo for Arduino and Raspberry Pi** boards on Amazon. Your board’s silkscreen may say **+ / - / S** or **VCC / GND / I/O** (or **IN** / **S** / **Signal**).

## Wiring (typical module)

| Board marking | Connect to | Notes |
|---------------|------------|--------|
| **VCC** or **+** | Pi **5V** (e.g. physical pins **2** or **4**) | Most driver boards are meant for 5V supply. |
| **GND** or **-**  | **GND** (e.g. **6**, **9**, **14**…) | **Common ground** with the Pi and the BME680. |
| **I/O** / **S** / **IN** / **SIG** | A **GPIO** (default **BCM 18** = physical **12** in `config.yaml` → `gpio.buzzer`) | 3.3V logic is usually enough for the transistor on the board; the Pi **must not** output 5V on this pin. |

**Do not** connect the **signal** wire to 5V. It is a **3.3V GPIO output** from the Pi. Power can still be **5V** on **VCC** if your module is labeled 5V.

**Which GPIO?** The default is **BCM 18** because it can use **hardware PWM** on many Raspberry Pi models (good for a steady tone). You can use another free GPIO in `config.yaml` (`gpio: buzzer: <BCM number>`), but for passive buzzers, pins with hardware PWM (often **12** or **13** in BCM terms on some docs — on the 40-pin header, **BCM 18 = phys 12**) are a good first choice. If the tone is choppy, try the default 18 or see the [Raspberry Pi PWM](https://www.raspberrypi.com/documentation/) notes for your model.

**BCM 18 = physical header pin 12** (not “GPIO 12” in wiring-Pi old numbering — the project and `config.yaml` use **BCM** only).

## `config.yaml` (buzzer section)

The repo default is set up for a **passive** piezo and a **continuous** alarm while air is bad:

```yaml
buzzer:
  enabled: true
  kind: passive
  frequency_hz: 2500
  volume: 1.0
  gain: 3.0
  max_pwm_duty: 0.68
  pattern: siren
  siren_freq_low: 2000
  siren_freq_high: 4200
  siren_step_seconds: 0.1
  beep_on: 0.4
  beep_off: 0.2
  repeat_every: 2.0
```

| Key | Meaning |
|-----|--------|
| `enabled` | `false` = never drive the buzzer (LED only). |
| `kind` | `passive` = play a tone with `TonalBuzzer` + `frequency_hz`. `active` = simple on/off, no `frequency_hz`. |
| `volume` | **Passive only:** **0–1** input; combined with `gain` (see below). `active` buzzers ignore this. |
| `gain` | **Passive only:** multiplier on the base duty (default **3.0**). This is the “~3× louder” control in software, before `max_pwm_duty`. The live alarm, siren, and `./test_buzzer` all use the same formula. |
| `max_pwm_duty` | **Passive only:** hard ceiling (default **0.68**) so drive never hits ~1.0 DC. Lower (e.g. 0.55) if the buzzer distorts. |
| `pwm_duty` | **Passive, expert:** if set, **replaces** the volume-based base, then `gain` still applies, then `max_pwm_duty` caps. |
| `frequency_hz` | Tone for a passive buzzer (roughly 2–4 kHz is a typical sharp alarm). |
| `pattern` | **`siren`** (default) = two **alternating** tones (hi/lo) on passive piezo — sounds like a small alarm, good for audiences. Aliases: `alarm`, `audience`, `yelp`. **`continuous`** = one steady tone until “bad” clears. **`pulsed`** = beep bursts; uses `beep_on` / `beep_off` / `repeat_every`. |
| `siren_freq_low` / `siren_freq_high` | **Siren only** (passive): two frequencies in Hz (defaults 2000 / 4200). |
| `siren_step_seconds` | **Siren only:** how long each tone plays before switching (default 0.1 s). Shorter = more “urgent”. |

If the sound is too harsh or quiet, try **2000**–**4000** Hz, or set `pattern: pulsed` for a gentler, intermittent warning.

**Louder in software (Pi GPIO only):** use **`pattern: siren`**, keep **`volume: 1.0`**, and ensure you are not asking for `pwm_duty` **above ~0.5** on a passive piezo (see table above). Use **5V on the module’s VCC** and higher **siren** frequencies (repo defaults are in the *high* kHz range) so the tone carries in a room.

**If you need “very loud” in a big room or fair hall** — a tiny GPIO piezo is **not** a PA system. The Pi only has **3.3 V, low current** on the signal pin. You will need **hardware** such as: a **5 V or 12 V siren** with its own transducer and a **transistor/relay** driven by the GPIO; a **powered speaker** or **amplifier** + speaker; or a **commercial 85 dB+ active buzzer** on a **driver board** (still limited by 3.3 V control). The software cannot exceed the **acoustic and electrical limits** of the part you wire up.

**“tone is out of the device's range”** (from `gpiozero`): the old default was a **narrow** musical range (~220–880 Hz). The app now uses `TonalBuzzer(..., octaves=4)` so **2–4 kHz** alarm tones from `frequency_hz` work. Update the repo or set the same in your copy of `outputs.py` / `scripts/test_buzzer.py` if you still see this.

**GPIO pin number** is under `gpio.buzzer` (not inside `buzzer:`).

## Quick self-test (on the Pi)

From the project folder, with `gpio` permissions or `sudo`::

  ./test_buzzer
  # same as:  .venv/bin/python3 scripts/test_buzzer.py

If the shell says **“Permission denied”**, the script is not marked executable. After `git pull`, run: `chmod +x test_buzzer scripts/test_buzzer.py` (or the files were updated in the repo to be `+x`).

You should get three short beeps, then a longer tone if `kind: passive` is set. If nothing is heard, re-check VCC, GND, the signal wire on `gpio.buzzer` (default BCM 18), and `buzzer.enabled` / `buzzer.kind` in `config.yaml`.

## How it lines up with the “score”

**Loudness / alarm drive:** The values `volume`, `gain`, and `max_pwm_duty` are read once at startup and applied to **every** kind of **bad-air** sound (siren, continuous, or pulsed) — the same as `./test_buzzer` (which uses the same helper from `outputs.py`).

The buzzer is driven only by the same **quality band** as the UI: **good**, **moderate**, **bad** (from the BME680 gas reading and the `air_quality` thresholds in `config.yaml`), not a separate 0–100 rule. It starts when the band is **bad** and stops when the reading moves to **moderate** or **good** — no extra wiring.

## Dependencies

- `gpiozero` (in `requirements.txt`) — for `TonalBuzzer` on a passive device.
- User in the **`gpio` group** if you get permission errors: `sudo usermod -aG gpio $USER` and log in again.

## If there is no sound

1. `kind: passive` with a **passive** piezo. If you actually have an **active** (self-oscillating) module, set `kind: active` and do not expect `frequency_hz` to matter.
2. `enabled: true` and `./run` on the real Pi (not a laptop with `SENSORS_DRY_RUN=1` only — GPIO may still be skipped on non-Linux; check logs for “GPIO not available”).
3. **GND** shared with the Pi; **VCC** to 5V if the board asks for 5V.
4. `gpio.buzzer` matches the **BCM** number of the wire on **I/O / S** — not the physical pin number unless you also changed the table above.

## See also

- `docs/rgb-led-wiring.md` — LED colors for the same good / moderate / bad states.
