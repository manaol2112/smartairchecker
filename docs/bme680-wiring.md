# BME680 ↔ Raspberry Pi — wiring validation

Your connections match the **standard I2C1** mapping on a **40‑pin** Pi:

| Your wire | Pi **physical** pin | Pi function   | OK? |
|----------|---------------------|---------------|-----|
| VCC      | **1**               | **3.3V**      | Yes — BME680 breakouts are almost always **3.3 V**; use this, **not 5V** unless the board’s docs say a regulator allows 5V in. |
| SDA      | **3**               | **SDA1** (I2C data)  | Yes |
| SCL      | **5**               | **SCL1** (I2C clock) | Yes — often written “SCL” (you had “slc” — same thing). |
| GND      | **6**               | GND           | Yes |

Pin numbers are counted from the **corner with the square pad**; pin 1 is next to the SD card on most Pis.

## 1) Software checks (do these first)

```bash
# I2C on?
ls -l /dev/i2c-*

# On **bus 1** (default; use -y 0 for bus 0)
sudo i2cdetect -y 1
```

- You should see **76** or **77** in the grid (hex addresses: `0x76` / `0x77`), **not** `--` everywhere in two rows of addresses.
- If the chip only appears on bus **0**, set in `config.yaml`: `sensors.i2c_bus: 0`.
- If **nothing** appears: wiring, power, or a damaged sensor — keep reading.

## 2) Power with a multimeter (Pi **off** for continuity, **on** for voltage)

- **Continuity (Pi off, unplug BME680 power if you use a switch):**
  - Pi **GND (pin 6)** ↔ breakout **GND**
  - Pi **SDA (pin 3)** ↔ breakout **SDA** (or **SDI** on some boards)
  - Pi **SCL (pin 5)** ↔ breakout **SCL** (or **SCK** as clock for I2C on some PCBs)
- **Voltage (Pi on):**
  - Breakout **VCC / 3.3V** to board GND should read **~3.3 V** (not 0 V, not 5 V unless your board is designed for 5 V in).

**Wrong or swapped SDA/SCL** usually still shows a device in `i2cdetect` (sometimes a ghost address) — if you see **nothing**, recheck GND and 3.3V first.

## 3) “ADDR” and “CS” not connected

- **CS** (chip select) is for **SPI**. On most **I2C‑only** breakouts, CS is not used; many boards tie it internally. **Leaving CS open is often fine** (see your board’s vendor guide).
- **I2C address** on Bosch BME680 is **not a separate “ADDR” pin** on the chip. On **breakouts**, the address is set by the **SDO** pin (sometimes labeled **ADD** on cheap boards):
  - Tied to **GND** → often **0x76**
  - Tied to **VCC/3.3V** → often **0x77**
- If **SDO/ADDR is left floating** on a cheap board, the address can be **unreliable** or the chip can **fail to respond** → try soldering or wiring **SDO to GND (0x76)** or to **3.3V (0x77)** *only if your board’s PDF says to do that*.

## 4) Other common issues

- **5 V on VCC** on a 3.3 V‑only board → can destroy or brown out the sensor.
- **Loose breadboard** — wiggle and reseat; I2C is fast edges; bad contacts = no 76/77.
- **Permissions:** user in `i2c` group, or use `sudo i2cdetect` once to test.
- **I2C disabled:** `sudo raspi-config` → **Interface Options** → **I2C** → **Enable** → **reboot**.

## 5) Match the silkscreen on *your* board

Different vendors use different labels:

- **Pimoroni / Adafruit:** VCC, GND, SDA, SCL (clear).
- **Some AliExpress boards:** `SDA` = `SDI`, `SCL` = `SCK` in I2C mode; sometimes `ADDR` = `SDO`.

When in doubt, use the **PDF/schematic** for your exact breakout.

## 6) After wiring looks good

```bash
cd /path/to/smartairchecker
.venv/bin/python3 scripts/test_sensor.py
```

If `i2cdetect` shows **76** or **77** but Python still errors, set `sensors.i2c_bus` in `config.yaml` to the bus where that line appears (`0` or `1`).
