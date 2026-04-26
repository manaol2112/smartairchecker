# Headless client demo: phone hotspot, static IP, auto-start

Use this when the **Raspberry Pi is a Wi‑Fi client** to your **phone’s hotspot** (e.g. “Sophia Science Project”), not when the Pi is the access point (that flow is in `pi-wifi-hotspot.md` and `./setuphotspot`).

**Android hotspot (common case):** the examples use **`192.168.43.x/24`**, gateway **`192.168.43.1`**, and **WPA2** — set **`CLIENT_DEMO_PSK`** to the password the phone shows for the hotspot. The defaults in `client-demo.env.example` match a typical **Android** tether. **iPhone** uses a different subnet (see below); this doc’s paths assume Android unless you change **`.client-demo.env`**.

Only leave **`CLIENT_DEMO_PSK`** empty if the network is **truly open** (no password), which is uncommon on phone hotspots.

**Goal:** after power-on, the Pi joins your hotspot, gets a **fixed IPv4**, runs **`./run`**, and you can print a **QR** with a **stable** URL (same IP every time).

## 1) Find the subnet your phone uses (once)

With the **phone hotspot on** and the Pi **not** on static config yet, join the network using the desktop, or a temporary **DHCP** profile. Then on the Pi:

```bash
ip -4 route | grep default
ip -4 addr show dev wlan0
```

- **Android** Personal Hotspot / Wi‑Fi hotspot: often gateway **`192.168.43.1`**, **`192.168.43.0/24`**. A static like **`192.168.43.100/24`** is a good first try (the repo defaults). Pick an address your phone is unlikely to assign to another device (e.g. high `.100`–`.150` is usually fine in `/24`).

- **iPhone / iPad** (if you ever switch): almost always **`172.20.10.0/28`**, **not** `192.168.43.x`. See **`ip -4 a show`** after a DHCP join and adjust **`.client-demo.env`**.

**If the page does not load** from your phone, on the Pi run **`./scripts/verify-client-demo.sh`**. Common causes: **wrong static** (mismatch to what `ip route` actually shows on DHCP), static not applied (re-run **`sudo ./scripts/setup-client-wifi.sh`**, it cycles the link), **ufw** blocking the port, or the app not running.

## 2) Create `.client-demo.env`

From the project root:

1. Run **`./setupclientdemo`** once — it creates **`.client-demo.env`** from `scripts/client-demo.env.example`.
2. Edit **`.client-demo.env`** and set at least:
   - **`CLIENT_DEMO_SSID`** — exact SSID, e.g. `Sophia Science Project`
   - **`CLIENT_DEMO_PSK`** — hotspot password (**required** for iPhone and most Android; same as on the phone). Alias: **`CLIENT_DEMO_PASSWORD`**
   - **`CLIENT_DEMO_IPV4`** — e.g. `192.168.43.100/24` or `172.20.10.2/28`
   - **`CLIENT_DEMO_GW`** — the hotspot gateway (often same as the phone’s client-side IP in `ip route`)
   - **`CLIENT_DEMO_USER`** — usually `pi`

3. Run **`./setupclientdemo`** again (not as `sudo` directly on the file; the script uses `sudo` for the right steps). This:
   - Joins the Wi‑Fi with **`nmcli device wifi connect`** (open or WPA2), then applies **static IPv4** and autoconnect
   - Installs and enables **`smartair-web.service`**: runs **`./run`** after boot (with a short delay and restart on failure)

4. **Start the service now (optional test):**  
   `sudo systemctl start smartair-web`  
   `journalctl -u smartair-web -f`

5. On your laptop/phone, open **`http://<STATIC_IP>:5001/`** (or your `config.yaml` `server.port`).

## 3) Static URL for the QR

Default app port is **5001** (see `config.yaml`). Your URL is:

`http://<the IPv4 you set in CLIENT_DEMO_IPV4 (host only)>:5001/`

Example: `http://192.168.43.100:5001/`

Generate PNGs (install **`qrencode`** first):

```bash
AP_IP=192.168.43.100 SMARTAIR_PORT=5001 SMARTAIR_AP_SSID="Sophia Science Project" SMARTAIR_AP_OPEN=1 \
  ./scripts/generate-demo-qrs.sh
```

If **`.client-demo.env`** exists and contains **`CLIENT_DEMO_SSID`**, `CLIENT_DEMO_IPV4`, etc., the generator will pick up those values if you add them to the environment or copy them into the command.

## 4) What not to run at the same time

- **Do not** also run **Pi access-point** hot (`./setuphotspot`) on the same interface — a radio cannot be AP and client at once the way these scripts are written.
- If you previously used setuphotspot, use **`./scripts/restore-client-wifi.sh`**, then run **client** setup; see `pi-wifi-hotspot.md`.

## 5) Disable autostart of the app

```bash
sudo systemctl disable --now smartair-web
```

## 6) Remove the static Wi‑Fi profile (optional)

```bash
nmcli con delete smartair-client
# or whatever you set in CLIENT_DEMO_CONN_NAME
```

Rely on the **NetworkManager** and **systemd** versions shipped on Raspberry Pi OS **Bookworm**; **NetworkManager** is required for `scripts/setup-client-wifi.sh`.
