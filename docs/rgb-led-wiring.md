# DIYables RGB LED module ↔ Raspberry Pi

The Smart Air Checker app **already** drives a 3-channel RGB (via `gpiozero`) from the same **air quality** band as the web page: **green** = good, **amber** (red + green) = moderate, **red** = bad. It updates a few times per second while `./run` is running.

- Code: `outputs.py` → `AirQualityIndicator.set_quality`
- Pin numbers: `config.yaml` → `gpio` (use **BCM** numbers, not physical pin count)

## Before you connect

- Use **3.3 V logic** and **one of the Pi’s GND pins** — the same ground as the BME680 and the Pi itself.
- DIYables’ module has **common cathode** and **built-in resistors**: you normally **do not** add extra resistors on the signal lines. Keep using **3.3 V** from the Pi header, not 5 V, unless your board’s documentation explicitly says to use 5 V for a specific pin.
- If your LED is **common anode** (unusual for the DIYables module), set `gpio.common_anode: true` in `config.yaml` so the software drives the GPIO polarity correctly.

## What to wire (default pins in `config.yaml`)

| Module pin (silkscreen) | Connect to | BCM GPIO (for config) | Default `config.yaml` name |
|-------------------------|------------|------------------------|----------------------------|
| **R** (red channel)     | A GPIO     | 17 | `rgb_red`  |
| **G** (green channel)   | A GPIO     | 27 | `rgb_green` |
| **B** (blue channel)    | A GPIO     | 22 | `rgb_blue` |
| **−** / **GND** (common cathode) | **GND**    | — | (ground) |

**Blue** is wired for future use; the app only turns on **R** and/or **G** (never blue for the three “traffic light” states).

**Always double-check the PCB labels** — some modules order pins R–G–B–GND, others B–G–R–GND. Match **each color pin** to the GPIO in `config.yaml`, not a guess from wire color alone.

## Physical header on a 40‑pin Pi (examples)

- **3.3 V** — physical pins **1** or **17** (e.g. for module “+” only if the module needs a supply pin; many modules only have R, G, B, GND and take power through the channels — follow your board’s label).
- **GND** — e.g. physical **6, 9, 14, 20, 25, 30, 34, 39** (any ground is fine).
- **BCM 17** — physical **11**
- **BCM 27** — physical **13**
- **BCM 22** — physical **15**

A convenient layout is to share **one GND** with the BME680 GND and the LED **GND** on the breadboard’s ground bus.

| BCM | Name   | Physical (40‑pin) |
|-----|--------|-------------------|
| 17  | GPIO17 | 11 |
| 27  | GPIO27 | 13 |
| 22  | GPIO22 | 15 |
| 2   | SDA1   | 3  (BME680) |
| 3   | SCL1   | 5  (BME680) |

## Quick self-test (on the Pi)

From the project folder::

  ./test_rgb_led
  # same as:  .venv/bin/python3 scripts/test_rgb_led.py

If you see **“Permission denied”**, run `chmod +x test_rgb_led scripts/test_rgb_led.py` (or `git pull` the version that has execute bits on those files).

This cycles through red, green, blue, then **good** (green), **moderate** (amber), **bad** (red) like the live app. If a channel is wrong, swap the matching `rgb_red` / `rgb_green` / `rgb_blue` BCM values in `config.yaml` to match the module’s **R / G / B** labels. Use `sudo -E` if you get a GPIO permission error.

## Software setup

1. **Enable GPIO** (usually already on Pi OS) and, if you see permission errors, add your user to the `gpio` group and log in again:
   ```bash
   sudo usermod -aG gpio "$USER"
   ```
2. Install dependencies: `gpiozero` is in `requirements.txt` (`pip install -r requirements.txt` or your `./pi-bootstrap` flow).
3. Edit **`config.yaml`** if you use different pins; values are **BCM** numbers.
4. Run the app: `./run` (or your usual command). The LED tracks **live** sensor **quality** (`good` / `moderate` / `bad`) from the BME680 gas reading — same rules as the dashboard score chip.

## Optional buzzer (when air is bad)

The same `outputs` module can drive a buzzer on **`gpio.buzzer`** (default **BCM 18** = physical **12**) while quality is **bad** — it stops as soon as the air is **no longer** bad. Full wiring and options (**passive** piezo vs **active**, `pattern: continuous` vs **pulsed**, `buzzer.enabled`) are in **`docs/buzzer-wiring.md`**.

## Tutorials and troubleshooting

- [DIYables — product overview](https://diyables.io/products/rgb-led-module) (common cathode, 3.3 V–5 V, on-board resistors)
- Third-party step-by-step: [Raspberry Pi — RGB LED module](https://newbiely.com/tutorials/raspberry-pi/raspberry-pi-led-rgb) (pin mapping may differ — always match your board silkscreen to `config.yaml`)
- If nothing lights: run with `SENSORS_DRY_RUN=0`, confirm `./run` has no “GPIO not available” warning, and verify GND is common. If the LED is **dim or wrong color**, you likely swapped **R** and **G** to the wrong GPIOs.

## How “real time” works

A background thread in `app.py` reads the latest snapshot from the BME680 loop every **0.2 s** and calls `set_quality`. When the **quality band** (good / moderate / bad) changes, the color updates immediately. The **0–100 score** can still move within one band; the **color** stays the same until the band changes — that matches “green / orange / red” and the same **thresholds** as `air_quality` in `config.yaml`.

To change *when* the UI (and the LED) switch between green, amber, and red, adjust **`air_quality`** (`good_min`, `moderate_min`, and the score scaling fields) in `config.yaml`, not the GPIO section.
