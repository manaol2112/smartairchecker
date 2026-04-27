# `smartair-web.service` failed to start

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

## 6. Network wait (unusual)

The unit uses `After=network-online.target`. A broken network configuration should not block forever, but if boot hangs, ask on your OS forums. You can test without waiting by temporarily editing the service (advanced) or by running `./run` manually.
