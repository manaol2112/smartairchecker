"""Start the air-quality web app.

From the project folder::

  ./run
  # On the Pi, first time: ./run  runs  scripts/pi-bootstrap.sh  (apt + venv + pip) if .venv
  # is missing, then starts the app. You can re-run:  bash scripts/pi-bootstrap.sh
  # Manual venv:  bash scripts/pi-bootstrap.sh  then  .venv/bin/python3 run.py

  ./run.sh
  .venv/bin/python3 run.py

The page URL is printed on startup (default port 5001; set SMARTAIR_PORT to change it).

BME680 / I2C check on the Pi::

  python3 scripts/test_sensor.py
"""

from app import run

if __name__ == "__main__":
    run()
