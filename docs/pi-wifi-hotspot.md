# Raspberry Pi as a Wi-Fi hotspot (offline class demo)

Use this to turn a Pi into its own small Wi-Fi network. Kids connect their phones, then open your Smart Air Checker page in the browser. **Data stays on the Pi** (or whatever you have configured in `config.yaml`); the Pi does not need the internet for the pages to work.

## What you *can* and *can’t* do with one QR code

- **A Wi-Fi QR** (WIFI:…) lets many phones start joining your hotspot (Android: Camera; iPhone: recent iOS can read Wi-Fi QRs in Camera or Control Center). It does **not** open a website.
- **A second QR (or a printed URL)** is needed to open `http://<pi-ip>:<port>/` in the browser **after** they are on your Wi-Fi.

You cannot have **one** QR that both auto-connects *and* opens your site in a reliable, universal way. Use **two** QRs (this repo generates both PNGs for you) or a poster with: “1) join Wi-Fi  2) open this link.”

## What the scripts do

| Script | Purpose |
|--------|--------|
| `scripts/hotspot.env.example` | Copy to `.hotspot.env` in the project root, set `SMARTAIR_AP_SSID` and `SMARTAIR_AP_PASS` (8+ characters). |
| `scripts/setup-wifi-ap.sh` | On the Pi, installs/configures a hotspot. Prefers **NetworkManager** + `nmcli` when available (typical on Raspberry Pi OS **Bookworm desktop**). Otherwise uses **hostapd + dnsmasq** and static `192.168.4.1/24` (typical on **Lite** or if NM is off). |
| `scripts/generate-demo-qrs.sh` | Creates `docs/generated/demo-wifi-join.png` and `docs/generated/demo-project-url.png` plus a small text file with the URL. |

## Quick start (on the Pi)

1. **Copy and edit** environment file:

   ```bash
   cd /path/to/smartairchecker
   cp scripts/hotspot.env.example .hotspot.env
   nano .hotspot.env
   ```

   Set at least `SMARTAIR_AP_SSID`, `SMARTAIR_AP_PASS` (8+ characters), and `WIFI_COUNTRY` (e.g. `US`).

2. **Run the hotspot setup** (needs root):

   ```bash
   sudo -E ./scripts/setup-wifi-ap.sh
   ```

   - If the script used **NetworkManager**, the access point often gets something like `10.42.0.1` on `wlan0`.
   - If it used **hostapd**, the Pi is usually `192.168.4.1`.

3. **Start your project** bound to all interfaces (default in `app.py` is `0.0.0.0`):

   ```bash
   export SMARTAIR_PORT=5001
   ./run
   ```

   (Or the same `SMARTAIR_PORT` as in `.hotspot.env`.)

4. **Generate the two QR images** (after the hotspot is up so `--detect` can read the IP):

   ```bash
   ./scripts/generate-demo-qrs.sh --detect
   ```

   Or set the IP by hand: `AP_IP=10.42.0.1 ./scripts/generate-demo-qrs.sh`

5. **Print** `docs/generated/demo-wifi-join.png` and `docs/generated/demo-project-url.png` (or show them on a monitor next to the Pi). Put **Wi-Fi** first, **URL** second on the handout.

## If `nmcli` is not used (hostapd path)

- The script **stops** `NetworkManager` and `wpa_supplicant` only for that session to free `wlan0`. It does **not** permanently disable NetworkManager. To get desktop/guest Wi-Fi back: `sudo systemctl start NetworkManager` (or reboot).
- You need a **country code** in hostapd; set `WIFI_COUNTRY` in `.hotspot.env` before running.
- If `dhcpcd` is not your distro’s network manager, the static-IP block may not apply. Prefer the **NetworkManager** path (desktop Pi OS) for fewer surprises, or set `HOTSPOT_USE_CLASSIC=0` and ensure NM is started.

## Force the classic (hostapd) stack

```bash
sudo HOTSPOT_USE_CLASSIC=1 -E ./scripts/setup-wifi-ap.sh
```

(Use this only if you know you need it—NM is usually easier on Bookworm desktop.)

## Dependencies

- `qrencode` for QR PNGs: `sudo apt install qrencode`
- Hotspot: `hostapd` and `dnsmasq` (the setup script tries to `apt install` them)

## Security note

The demo network uses a **shared password** (often printed on a poster). Treat it as **open house**-level access, not private data. Use a long random password if you are worried about neighbors joining.

## See also

- `config.yaml` → `server.host` and `server.port` (and env `SMARTAIR_PORT` overrides port).
- `app.py` prints the local URL on startup.
