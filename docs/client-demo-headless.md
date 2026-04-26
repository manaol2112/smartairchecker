# Headless client demo: phone hotspot, static IP, auto-start

Use this when the **Raspberry Pi is a Wi‑Fi client** to your **phone’s open hotspot** (e.g. “Sophia Science Project”), not when the Pi is the access point (that flow is in `pi-wifi-hotspot.md` and `./setuphotspot`).

**Goal:** after power-on, the Pi joins your hotspot, gets a **fixed IPv4**, runs **`./run`**, and you can print a **QR** with a **stable** URL (same IP every time).

## 1) Find the subnet your phone uses (once)

With the **phone hotspot on** and the Pi **not** on static config yet, join the network using the desktop, or a temporary **DHCP** profile. Then on the Pi:

```bash
ip -4 route | grep default
ip -4 addr show dev wlan0
```

- **Many Android** hotspots: gateway **`192.168.43.1`**, you can often use a static like **`192.168.43.100/24`**.
- **Many iPhone/iPad** hotspots: **`172.20.10.0/28`**, use something like **`172.20.10.2/28`**, gateway **`172.20.10.1`** (only a few addresses; avoid clashes).

Pick an address the phone is **unlikely** to hand out to another device (e.g. `.100` in a large Android range, or a low number in a tiny iOS pool).

## 2) Create `.client-demo.env`

From the project root:

1. Run **`./setupclientdemo`** once — it creates **`.client-demo.env`** from `scripts/client-demo.env.example`.
2. Edit **`.client-demo.env`** and set at least:
   - **`CLIENT_DEMO_SSID`** — exact SSID, e.g. `Sophia Science Project`
   - **`CLIENT_DEMO_IPV4`** — e.g. `192.168.43.100/24` or `172.20.10.2/28`
   - **`CLIENT_DEMO_GW`** — the hotspot gateway (often same as the phone’s client-side IP in `ip route`)
   - **`CLIENT_DEMO_USER`** — usually `pi`

3. Run **`./setupclientdemo`** again (not as `sudo` directly on the file; the script uses `sudo` for the right steps). This:
   - Writes a **NetworkManager** profile: auto-connect, **open** Wi‑Fi, **static IPv4**
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
