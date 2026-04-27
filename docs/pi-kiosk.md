# Raspberry Pi: run on power-on + open the dashboard in a browser

You need **Raspberry Pi OS with desktop** (not **Lite** — there is no local browser on Lite).

## Quick checklist (demo on a monitor)

1. **Flask app on every boot** (systemd):  
   `sudo ./scripts/install-smartair-service.sh`  
   then `sudo systemctl enable --now smartair-web`  
   (or use `./setupclientdemo` if you use the client Wi‑Fi flow).

2. **Browser:**  
   `sudo apt update && sudo apt install -y chromium`

3. **Autostart kiosk** (opens the app in fullscreen after login):  
   `cd /path/to/smartairchecker && sudo ./scripts/install-smartair-kiosk.sh`

4. **Auto-login** so the desktop (and autostart) runs without typing a password:  
   `sudo raspi-config` → **System Options** → **Auto Login** (or **Boot / Auto Login**), choose **Desktop Autologin**, finish, reboot.  
   On some images: **Raspberry Pi Configuration** app → **System** tab → **Auto login**

5. **Reboot** and confirm: the Pi should show Chromium (kiosk) on `http://127.0.0.1:5001/` once the app is responding.

`kiosk-launch.sh` **waits** until the Flask server answers before opening the browser, so you are not stuck on an error page during startup.

---

## 1. App on boot (`./run`)

Use the same flow as the headless client demo.

```bash
cd /path/to/smartairchecker
./setupclientdemo
```

(Or only the service: `sudo ./scripts/install-smartair-service.sh`.)

- **`smartair-web.service`** runs **`./run`**, starting after the network target (about **2 s** after boot, then the process starts; the BME680 begins measuring with its normal loop).  
- **Start now:** `sudo systemctl start smartair-web`  
- **Status:** `systemctl status smartair-web`  
- **Logs:** `journalctl -u smartair-web -f`  
- If the job fails, see **`docs/troubleshooting-smartair-service.md`**

Raspberry Pi **OS Lite** (no desktop): the web UI is only reachable from other devices; there is no local browser. Use a phone, laptop, or QR.

## 2. Fullscreen browser on the Pi (Raspberry Pi OS with desktop)

1. Install Chromium if it is not already:  
   `sudo apt update && sudo apt install -y chromium`  
2. From the project root:  
   `sudo ./scripts/install-smartair-kiosk.sh`  
3. Reboot, or sign out and back in, so the autostart file under  
   `~/.config/autostart/smartair-kiosk.desktop` runs.

`scripts/kiosk-launch.sh` waits until the app answers on `http://127.0.0.1:5001/` (override with `SMARTAIR_PORT` / `SMARTAIR_KIOSK_URL` if you change the port), then starts **Chromium** (or **Firefox** if Chromium is missing) in **kiosk** mode.

- **Port:** set `export SMARTAIR_PORT=8080` in the environment, or in `run`/systemd if you use a non-default port; match `config.yaml` and `kiosk-launch.sh` uses `SMARTAIR_PORT` from the environment. The systemd service does not set it by default — default app port is **5001** (see `config.yaml` and `run.py`).

**Remove the kiosk autostart:**  
`rm -f ~/.config/autostart/smartair-kiosk.desktop`

**Auto login:** to show the browser without a manual login, enable auto-login in **Raspberry Pi configuration** (or your compositor) so the desktop session starts and autostart can run. Without auto-login, you must sign in once after boot.

## 3. Optional: set systemd environment for a custom port

If the app uses `SMARTAIR_PORT=5001` from the environment, create an override:

```bash
sudo systemctl edit smartair-web
# Add in the editor:
# [Service]
# Environment=SMARTAIR_PORT=5001
```

Use the same port in the kiosk (export for the user session or a small `~/.config/environment.d/*.conf` for GUI).
