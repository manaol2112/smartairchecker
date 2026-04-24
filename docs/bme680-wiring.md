# BME680 ↔ Raspberry Pi — wiring validation

Your connections match the **standard I2C1** mapping on a **40‑pin** Pi:

| Your wire | Pi **physical** pin | Pi function   | OK? |
|----------|---------------------|---------------|-----|
| VCC      | **1**               | **3.3V**      | Yes — BME680 breakouts are almost always **3.3 V**; use this, **not 5V** unless the board’s docs say a regulator allows 5V in. |
| SDA      | **3**               | **SDA1** (I2C data)  | Yes |
| SCL      | **5**               | **SCL1** (I2C clock) | Yes — often written “SCL” (you had “slc” — same thing). |
| GND      | **6**               | GND           | Yes |

Pin numbers are counted from the **corner with the square pad**; pin 1 is next to the SD card on most Pis.

## How to use your breadboard (columns **1–17**, **letters a–e** and **f–j**)

This matches a **typical 400/830 style** block: a **number** (1 through 17) is one **column**. **a–e** are the **top** group of 5 holes in that column, **f–j** are the **bottom** group. The **colored plastic** (blocks or stripes) is only layout — it is **not** 3.3 V or GND by itself. What matters is the **hidden metal** under each group of five.

### All‑black or faint text — and **a1, a2, a3** vs **1a, 1b, 1c**

On a **blank/black** board, the column numbers are sometimes **stamped in white** in the **margin**; use a phone light. If you still cannot read labels, use a **multimeter in continuity (beep) mode, Pi and sensor unplugged** to find which holes are **one metal strip**: touch one pin in a hole, then hunt — **only four more holes** in that same 5 should beep (sometimes **5** on boards with 5‑hole strips only).

**How names are read (vendors differ):** the **five holes that are wired together** are always **in one “column” of five** on **one** side of the **center slot** in the main grid.

- You might see the five printed as **1a, 1b, 1c, 1d, 1e** (number = column, letters = the five in that column), **or** the same set written **a1, b1, c1, d1, e1** (number = same column, letters first). In both cases, **that block of five is one power/signal** — we call it **“column 1, top group (a–e)”** in this doc.
- **Not** the same: a line like **a1, a2, a3, a4, a5** (same letter **a**, number goes **1, 2, 3…**). That is **different columns** on **one row**; those jumpers are **not** all connected. The group you want for **+3.3 V** is **one** column’s **fivesome**: e.g. **1a+1b+1c+1d+1e** (or **a1+b1+c1+d1+e1** if that is how your print runs).

**Quick rule:** for **+3.3 V** you need **five holes that all touch the same bus**; pick the column you want, then use **all five letter positions a–e in that same column (top block)**. Same for GND in **another** column. **SCL** and **SDA** each use **a different column**’s fivesome so they stay separate.

- **(5a) (5b) (5c) (5d) (5e)** = **five holes shorted together** (same as each other) — you can use **any** of them to share one signal.
- **(5f) (5g) (5h) (5i) (5j)** = a **separate** group of five, shorted with each other.
- **(5e)** and **(5f)** are **not** connected to each other (there is a **center gap**). To join top and bottom block, add a **jumper** between e and f in that column (only if you need to).

**No red/blue “power strip”?** That is **normal** on many mini breadboards. You do not need separate rails: use **one full column of five holes (a–e)** for all **+3.3 V** and **another** column of five (a–e) for all **GND** — see the table below. *(Some large boards *do* have long side rails, often red/blue. If you have those, you can use them the same way: all 3.3 V into any hole in the + strip, all GND into the – strip.)*

### Copy‑this plan (no power rails, **0x77** = **SDO/ADDR to 3.3 V**)

| What | Raspberry Pi **physical** pin | Put it on the breadboard (example columns) |
|------|------------------------------|--------------------------------|
| 3.3 V to whole “power row” | **Pin 1** (or **Pin 17** — also 3.3 V) | **Column 1, top group:** **1a** (all **1a–1e** are the same node) |
| BME VCC, CS, SDO/ADDR | (not GPIO — same as 3.3 V) | **1b, 1c, 1d** — *same* **1a–1e** group as above |
| GND to whole “ground row” | **Pin 6** | **Column 2, top group:** **2a** (all **2a–2e** = GND) |
| BME GND | (not a GPIO) | **2b** (same **2a–2e** as Pin 6) |
| SDA | **Pin 3** | **4a**; BME **SDA** in **4b** (any **4a–4e**; **one** column, Pi + BME) |
| SCL | **Pin 5** | **5a**; BME **SCL** in **5b** (any **5a–5e**; **other** column than SDA) |

**You do *not* use a GPIO for CS or SDO** — they go to the **same 1a–1e 3.3 V** group as VCC. **SDA and SCL use two different column numbers (e.g. 4 and 5)** so the two I2C wires do not meet in one 5‑hole group.

**If you only have two letter rows** (not a–e / f–j), any **5 holes in a straight line** that the datasheet or silkscreen show as **one connected strip** works the same way: one strip = 3.3 V, next strip = GND, two more strips = SDA and SCL.

## 0) Correct `i2cdetect` command (a very common typo)

**Wrong** (missing spaces / wrong bus argument):

```bash
sudo i2cdetect y-1    # not valid — you may get only a header line or a confusing result
```

**Right** (there are **spaces** after `i2cdetect` and after `-y`):

```bash
sudo i2cdetect -y 1
```

- `-y` = non-interactive (no “are you sure?” prompt).
- `1` = **I2C bus number 1** (this is the usual bus for the 40‑pin **SDA / SCL** on Pi 2/3/4/5).

**See which bus devices you actually have:**

```bash
ls -l /dev/i2c-*
# optional:
i2cdetect -l
```

## 1) Why bus **0** often errors (`/dev/i2c-0: No such file or directory`)

On most Raspberry Pi models, the I2C you use for the BME680 on the **main GPIO** is **bus 1** → `/dev/i2c-1`. There is often **no** `/dev/i2c-0` exposed. So:

- **`sudo i2cdetect -y 0` failing** is **normal** on many Pis — you can ignore it.
- Use **`sudo i2cdetect -y 1`** and keep `sensors.i2c_bus: 1` in `config.yaml`.

(Only a few old / special layouts use bus 0 for your wiring; if `ls /dev` shows `i2c-0` and your sensor appears only there, you could set `i2c_bus: 0`.)

## 2) What you should see on bus 1

```bash
ls -l /dev/i2c-1
sudo i2cdetect -y 1
```

- You should see **76** or **77** in the grid (chips’ hex addresses on I2C), not only `--` cells.
- If the grid is all `--` and no 76/77: wiring, 3.3 V, GND, or the module — go to the multimeter section below.
- If the chip only appears on another bus, set `sensors.i2c_bus` in `config.yaml` to that number.

## 3) Power with a multimeter (Pi **off** for continuity, **on** for voltage)

- **Continuity (Pi off, unplug BME680 power if you use a switch):**
  - Pi **GND (pin 6)** ↔ breakout **GND**
  - Pi **SDA (pin 3)** ↔ breakout **SDA** (or **SDI** on some boards)
  - Pi **SCL (pin 5)** ↔ breakout **SCL** (or **SCK** as clock for I2C on some PCBs)
- **Voltage (Pi on):**
  - Breakout **VCC / 3.3V** to board GND should read **~3.3 V** (not 0 V, not 5 V unless your board is designed for 5 V in).

**Wrong or swapped SDA/SCL** usually still shows a device in `i2cdetect` (sometimes a ghost address) — if you see **nothing**, recheck GND and 3.3V first.

## 4) “ADDR” and “CS” not connected

- **CS** (chip select) is for **SPI**. On most **I2C‑only** breakouts, CS is not used; many boards tie it internally. **Leaving CS open is often fine** (see your board’s vendor guide).
- **I2C address** on Bosch BME680 is **not a separate “ADDR” pin** on the chip. On **breakouts**, the address is set by the **SDO** pin (sometimes labeled **ADD** on cheap boards):
  - Tied to **GND** → often **0x76**
  - Tied to **VCC/3.3V** → often **0x77**
- If **SDO/ADDR is left floating** on a cheap board, the address can be **unreliable** or the chip can **fail to respond** → try soldering or wiring **SDO to GND (0x76)** or to **3.3V (0x77)** *only if your board’s PDF says to do that*.

## 5) Other common issues

- **5 V on VCC** on a 3.3 V‑only board → can destroy or brown out the sensor.
- **Loose breadboard** — wiggle and reseat; I2C is fast edges; bad contacts = no 76/77.
- **Permissions:** user in `i2c` group, or use `sudo i2cdetect` once to test.
- **I2C disabled:** `sudo raspi-config` → **Interface Options** → **I2C** → **Enable** → **reboot**.

## 6) Match the silkscreen on *your* board

Different vendors use different labels:

- **Pimoroni / Adafruit:** VCC, GND, SDA, SCL (clear).
- **Some AliExpress boards:** `SDA` = `SDI`, `SCL` = `SCK` in I2C mode; sometimes `ADDR` = `SDO`.

When in doubt, use the **PDF/schematic** for your exact breakout.

## 7) After wiring looks good

```bash
cd /path/to/smartairchecker
.venv/bin/python3 scripts/test_sensor.py
```

If `i2cdetect` shows **76** or **77** but Python still errors, set `sensors.i2c_bus` in `config.yaml` to the bus where that line appears (`0` or `1`).

## 8) “Blow on the sensor” / audience demo

The BME680 is **very good** at showing a live reaction to breath **via humidity and (often) temperature**: exhaled air is warm and very moist, so you should see **%RH jump** and sometimes **°C** tick up if the air reaches the little package.

- **If %RH / °C barely move:** the app used to set the BME680 **IIR filter** to “size 3,” which **smooths** readings and **hides** short blips like a breath. In `config.yaml` set **`sensors.iir_filter_size: 0`** (default in the project now) and **restart the app** so T/H can react quickly. Use **`3`** if you want **smoother** (but slower) numbers for long charts.
- **Faster on-screen updates:** set `sensors.read_interval_seconds` (e.g. `0.4`) and `server.live_poll_ms` (e.g. `400`) and restart. Aim breath at the **metal sensor can**, a few centimetres away.
- **Air quality (gas / score):** still slower and messier on breath than **humidity**; use **%RH** for the “instant” demo.

**Tip:** point breath toward the **sensor** package, not only the board edge; keep the Pi in **open air** so one strong breath is not the only thing in a sealed volume.
