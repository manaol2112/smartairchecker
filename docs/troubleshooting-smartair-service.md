# `smartair-web.service` failed to start

## 0) Journal says **Failed with result 'exit-code'**

That means the **main process** (usually `python3 …/run.py`) **exited with a non-zero status** — almost always a **Python error** (missing package, bad `config.yaml`, I2C permission, **port 5001 already in use**, etc.).

1. **Show the real message** (scroll up a few lines for a **Traceback**):

   ```bash
   sudo journalctl -u smartair-web -b -n 100 --no-pager
   ```

   Grep for errors:

   ```bash
   sudo journalctl -u smartair-web -b --no-pager | grep -E 'Error|error|Traceback|Exception|No such file|Address already|Permission'
   ```

2. **Re-run the app in a terminal** (same as systemd, so you see the error immediately):

   ```bash
   cd /path/to/smartairchecker
   ./scripts/diagnose-smartair.sh
   ```

   (Run as the **same user** the service uses — e.g. `raspberry` / `pi` — not `root`. If the service runs as `pi`: `sudo -u pi -H ./scripts/diagnose-smartair.sh` from the project directory.)

3. **Typical fixes** after you read the error: section **2** (venv), **4** (port in use: `ss -tlnp | grep 5001`), and **1** in this file (full journal).

## 0.5) Stuck in **activating** (never becomes **active**)

The start job is **still running or waiting** — often on **ordering** (another target not reached yet) or a **hung** `ExecStart` (very rare for Python).

1. **Install the current unit** (local disk only, **no** `network-online` or `network.target` wait):

   ```bash
   cd /path/to/smartairchecker
   git pull
   sudo ./scripts/install-smartair-service.sh
   sudo systemctl daemon-reload
   sudo systemctl reset-failed smartair-web
   sudo systemctl start smartair-web
   ```

2. **Confirm the file on disk** (must show **`After=local-fs.target`**, not `network-online`):

   ```bash
   grep -E '^(After=|Wants=|ExecStart=)' /etc/systemd/system/smartair-web.service
   ```

3. **See if another job is blocking:**

   ```bash
   sudo systemctl list-jobs
   ```

4. **See what the unit is ordered after:**

   ```bash
   systemctl list-dependencies smartair-web.service
   ```

5. If it still never turns **active** within a few seconds, it may be a **Python crash / restart** that looks like flapping: run `sudo journalctl -u smartair-web -b -n 80` and `cd ... && ./scripts/diagnose-smartair.sh` (same user as the service).

## 0) Journal shows `ExecStartPre=/bin/sleep` and “activating / exit”

**That is normal** if you still have an old unit with a **sleep** in it: the sleep process exits in a few seconds with **status 0**. That is **not** the failure. The part that **crashes** is almost always the **`python3` / `run.py` line a moment later** — scroll down in the log or use:

```bash
sudo journalctl -u smartair-web -b -e --no-pager
```

Look for a **Python traceback** or `ModuleNotFoundError`, `Permission denied`, or `Address already in use`.

**If the service is stuck “activating”** or you see *start request repeated too quickly*:

```bash
sudo systemctl reset-failed smartair-web
```

Then pull the latest `install-smartair-service.sh` (sleep was removed) and: `sudo ./scripts/install-smartair-service.sh && sudo systemctl daemon-reload && sudo systemctl restart smartair-web`.

## 1. See the real error (always do this on the Pi)

```bash
sudo systemctl status smartair-web
sudo journalctl -u smartair-web -b -n 80 --no-pager
```

The last lines show the Python or shell error (missing module, bad path, I2C, `config.yaml`, etc.).

## 2. No virtualenv (very common on first install)

`./run` expects **`./.venv/`** to exist. If it is missing, the service can exit immediately or fail in odd ways.

**As the same Linux user that owns the project** (e.g. `raspberry`, `pi`):

```bash
cd /path/to/smartairchecker
./pi-bootstrap.sh
```

If that is not an option:

```bash
sudo -u YOUR_USER -H bash -lc 'cd /path/to/smartairchecker && ./pi-bootstrap.sh'
```

Then **reinstall** the unit and start:

```bash
sudo ./scripts/install-smartair-service.sh
sudo systemctl daemon-reload
sudo systemctl restart smartair-web
```

## 3. Run manually to reproduce

```bash
cd /path/to/smartairchecker
./run
```

If this fails, fix the error before relying on systemd (missing `pip` deps, `config.yaml`, I2C, etc.).

## 4. Wrong user or home directory

The service runs as the user the installer picked (from `.client-demo.env` `CLIENT_DEMO_USER`, or `SUDO_USER`, or uid 1000). The project files must be readable and the project must live where the unit says (re-run the installer if you moved the repo).

## 5. Port already in use

If something else is on port 5001 (or `server.port` / `SMARTAIR_PORT`), the app will exit. Check:

```bash
ss -tlnp | grep 5001
sudo lsof -i :5001
```

## 6. Network (not required for the service)

The installed unit uses **`After=local-fs.target` only** — the app does **not** wait for WiFi or `network-online`. If you still have an old unit with `network-online`, re-run `sudo ./scripts/install-smartair-service.sh` and `sudo systemctl daemon-reload` (see section 0.5).
