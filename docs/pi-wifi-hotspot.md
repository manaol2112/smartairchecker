# Raspberry Pi as a Wi-Fi hotspot (offline class demo)

Use this to turn a Pi into its own small Wi-Fi network. Kids connect their phones, then open your Smart Air Checker page in the browser. **Data stays on the Pi** (or whatever you have configured in `config.yaml`); the Pi does not need the internet for the pages to work.

## What you *can* and *can’t* do with one QR code

- **A Wi-Fi QR** (WIFI:…) lets many phones start joining your hotspot (Android: Camera; iPhone: recent iOS can read Wi-Fi QRs in Camera or Control Center). It does **not** open a website.
- **A second QR (or a printed URL)** is needed to open `http://<pi-ip>:<port>/` in the browser **after** they are on your Wi-Fi.

You cannot have **one** QR that both auto-connects *and* opens your site in a reliable, universal way. Use **two** QRs (this repo generates both PNGs for you) or a poster with: “1) join Wi-Fi  2) open this link.”

### Open Wi-Fi (no password) and “captive” auto-redirect

For a **public demo** you can set **`SMARTAIR_AP_OPEN=1`** in `.hotspot.env` before `./setuphotspot`. The AP will have **no WPA password** (anyone in range can join). That is convenient for visitors; do not treat the network as private.

To nudge phones toward your dashboard after they connect, set **`HOTSPOT_CAPTIVE=1`** in `.hotspot.env` and run `./setuphotspot` again. The script will use the **hostapd + dnsmasq** path and:

- Point **all DNS lookups** from clients to the Pi’s address (so “am I online?” checks hit your Pi).
- **Redirect TCP port 80** to your Flask port (e.g. 5001), so `http://<pi>/` reaches the app without running Flask as root on :80.
- With **`./run`**, the Flask app registers common **connectivity-check paths** (for example `/generate_204`, `/hotspot-detect.html`) and **302-redirects** them to your project URL.

**Reality check:** different phones and OS versions still behave differently. Some show a **“Sign in to network”** sheet, others open a browser tab, and some only show a notification—**full auto-open of your page is not guaranteed**. A printed **URL QR** or poster text remains the most reliable fallback.

**Rules and venues:** open access points may be restricted or inappropriate in some places; use only where you are allowed to run a dedicated demo network.

### Troubleshooting: phone still asks for a password, or stuck on “Connecting”

**Still asks for a password**

- **`SMARTAIR_AP_OPEN=1` must be in `.hotspot.env` (not only in `hotspot.env.example`)**, with **no** `#` in front, then run **`./setuphotspot` again** from the project folder. The value can also be `yes` or `true` (case does not matter).
- **Forget / remove the saved network on the phone** and scan again. If you used to use WPA, the phone often keeps the old “secured” profile for the same SSID.
- Run on the Pi: `sudo ./scripts/verify-hotspot.sh` and read **“2c) Open vs password”**. If the Pi still has `wpa=2` in `/etc/hostapd/hostapd.conf`, the AP is not open. Use **`HOTSPOT_USE_CLASSIC=1`** in `.hotspot.env` to force the hostapd path, then re-run setup.
- If you are on the **NetworkManager** (`nmcli`) path only, the hotspot is **always** WPA2 with a key — for an open network you need **hostapd** (e.g. `HOTSPOT_USE_CLASSIC=1` and `SMARTAIR_AP_OPEN=1`).

**Stuck on “Connecting” (often before an IP is assigned)**

- Usually **DHCP did not complete**: **`dnsmasq` is not running**, the AP interface has no **`192.168.4.1`**, or **`HOTSPOT_CAPTIVE=1`** is enabled but `dnsmasq` failed to bind (port **53**). **Try `HOTSPOT_CAPTIVE=0`**, re-run **`./setuphotspot`**, then `sudo journalctl -u dnsmasq -n 30`.
- **Password:** must be **at least 8 characters** and match **`.hotspot.env` exactly** (no extra space; avoid weird symbols).
- **Channel:** if one channel is bad in your area, set **`AP_CHANNEL=6` or `11`** in `.hotspot.env` and re-run.
- The Pi’s **on-board Wi-Fi** in AP mode is not always solid; a **USB Wi-Fi dongle** and **`AP_IFACE=wlan1`** often fixes “connecting” loops.

## What the scripts do

| Script | Purpose |
|--------|--------|
| `scripts/hotspot.env.example` | Copy to `.hotspot.env`, set `SMARTAIR_AP_SSID` and `SMARTAIR_AP_PASS` (8+ chars), or `SMARTAIR_AP_OPEN=1` for no password. Optional: `HOTSPOT_CAPTIVE=1` for auto-redirect / captive-style behavior. |
| `scripts/setup-wifi-ap.sh` | On the Pi, installs/configures a hotspot. Prefers **NetworkManager** + `nmcli` when available (typical on Raspberry Pi OS **Bookworm desktop**). If `nmcli` reports success but the interface never reaches real **AP** mode (see `verify-hotspot`), it **automatically falls back** to **hostapd + dnsmasq** and static `192.168.4.1/24`. Otherwise uses hostapd when NM is off or you set `HOTSPOT_USE_CLASSIC=1`. |
| `scripts/generate-demo-qrs.sh` | Creates `docs/generated/demo-wifi-join.png` and `docs/generated/demo-project-url.png` plus a small text file with the URL. |

## One command (on the Pi)

From the project root (clone or copy of this repo on the Pi):

```bash
cd /path/to/smartairchecker
chmod +x setuphotspot
./setuphotspot
```

The first time, this **creates `.hotspot.env`** from `scripts/hotspot.env.example`, **installs** `hostapd`, `dnsmasq`, and `qrencode` (via `apt`), then configures the hotspot. It will **ask for your sudo password** if needed.  
Optionally **edit `.hotspot.env`** first (or after) to set `SMARTAIR_AP_SSID`, `SMARTAIR_AP_PASS` (8+ characters), and `WIFI_COUNTRY` (e.g. `US`).

Same thing without the wrapper:

```bash
sudo -E ./scripts/setup-wifi-ap.sh
```

## What happens to the IP address

- If the script used **NetworkManager**, the access point often gets something like **10.42.0.1** on `wlan0`.
- If it used **hostapd**, the Pi is usually **192.168.4.1**.

## After setup

1. **Start your project** bound to all interfaces (default in `app.py` is `0.0.0.0`):

   ```bash
   export SMARTAIR_PORT=5001
   ./run
   ```

   (Or the same `SMARTAIR_PORT` as in `.hotspot.env`.)

2. **Generate the two QR images** (after the hotspot is up so `--detect` can read the IP):

   ```bash
   ./scripts/generate-demo-qrs.sh --detect
   ```

   Or set the IP by hand: `AP_IP=10.42.0.1 ./scripts/generate-demo-qrs.sh`

3. **Print** `docs/generated/demo-wifi-join.png` and `docs/generated/demo-project-url.png` (or show them on a monitor next to the Pi). Put **Wi-Fi** first, **URL** second on the handout.

## “Done” but my phone does not see the Wi-Fi name

1. On the Pi run:
   ```bash
   sudo ./scripts/verify-hotspot.sh
   ```
   You want **`type AP`** in the `iw dev wlan0 info` line. If the interface is not in **AP** mode, the SSID will not show up in scans.

2. The Raspberry Pi’s **on-board Wi-Fi** is sometimes unreliable in access-point mode (driver / firmware). If verify looks wrong, try a ** USB Wi-Fi dongle** and set in `.hotspot.env`:
   ```text
   AP_IFACE=wlan1
   ```
   (Use `ip -br link` to see the name: often `wlx…` for USB; `wlan1` is common.)

3. We only use **2.4 GHz** (`hw_mode=g`). On the phone, do not filter to **5 GHz only** when looking for the network. Move a little closer; output power is low.

4. If the **SSID is visible** but the phone says **Unable to connect** (or spins then fails), the Wi-Fi layer may be up but **DHCP** is not: the Pi must have **192.168.4.1** (or your `HOTSPOT_STATIC`) on the AP interface, and **`dnsmasq` must be running** so clients get an IP. Run `verify-hotspot` and check **section 2b**. Re-run `./setuphotspot` after the script is updated, and make sure the **Wi-Fi password in the phone matches** `.hotspot.env` (regenerate the Wi-Fi QR with `./scripts/generate-demo-qrs.sh --detect` if you change it).

5. Force the **hostapd** path (skips `nmcli`):
   ```bash
   HOTSPOT_USE_CLASSIC=1 ./setuphotspot
   ```

6. If `hostapd` fails, read the end of: `journalctl -u hostapd -n 40`

## If `nmcli hotspot` fails (common fix)

`nmcli` often fails if **something else is still using the Wi-Fi** (saved home network, an old `Hotspot` profile, or the wrong device name). The `setup` script now:

- turns the radio on and sets the interface to **managed**;
- brings down the active connection, disconnects, and **deletes** saved profiles on that card;
- if hotspot **still** fails, or **`iw` never shows AP mode** after `nmcli`, **falls back to hostapd** (unless you set `HOTSPOT_NM_NO_FALLBACK=1`).
- Optional: `HOTSPOT_NM_STRICT=1` keeps the NetworkManager result even when `iw` does not show AP mode (for debugging only; phones will usually still not see the SSID).

**Manual one-liner** if you need to start over:

```bash
nmcli dev disconnect wlan0
nmcli con delete "SmartAir-AP" 2>/dev/null; sudo ./setuphotspot
```

If your USB Wi-Fi is **`wlan1`**, set in `.hotspot.env`: `AP_IFACE=wlan1`

## If `nmcli` is not used (hostapd path)

- The script **stops** `NetworkManager` and `wpa_supplicant` only for that session to free `wlan0`. It does **not** permanently disable NetworkManager. To get desktop/guest Wi-Fi back: `sudo systemctl start NetworkManager` (or reboot).
- If the script **seemed to freeze** on “Stopping NetworkManager…”, a plain `systemctl stop NetworkManager` can take **a long time** on some systems. The setup script now uses a **non-blocking** stop first, then a time-limited wait, and only then a force kill. If you ever need to unblock by hand, in a second terminal run: `sudo systemctl stop NetworkManager` (or `sudo systemctl kill NetworkManager`).
- You need a **country code** in hostapd; set `WIFI_COUNTRY` in `.hotspot.env` before running.
- If `dhcpcd` is not your distro’s network manager, the static-IP block may not apply. Prefer the **NetworkManager** path (desktop Pi OS) for fewer surprises, or set `HOTSPOT_USE_CLASSIC=0` and ensure NM is started.

## Force the classic (hostapd) stack

```bash
HOTSPOT_USE_CLASSIC=1 ./setuphotspot
# or: sudo HOTSPOT_USE_CLASSIC=1 -E ./scripts/setup-wifi-ap.sh
```

(Use this only if you know you need it—NM is usually easier on Bookworm desktop.)

## Dependencies

- `qrencode` for QR PNGs: `sudo apt install qrencode`
- Hotspot: `hostapd` and `dnsmasq` (the setup script tries to `apt install` them)

## Security note

With **WPA2**, the demo network uses a **shared password** (often printed on a poster). Treat it as **open house**-level access, not private data. Use a long random password if you are worried about neighbors joining.

With **`SMARTAIR_AP_OPEN=1`**, there is **no Wi-Fi encryption** between the phone and the Pi (and anyone in range can join). Use only for **local demos** where that is acceptable.

## See also

- `config.yaml` → `server.host` and `server.port` (and env `SMARTAIR_PORT` overrides port).
- `app.py` prints the local URL on startup.
