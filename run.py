"""Start the air-quality web app.

From the project folder, use one of these (a bare ``run.sh`` or ``run.py`` will not work)::

  ./run
  python3 run.py
  ./run.sh

The page URL is shown when the app starts (default port 5001; set SMARTAIR_PORT to change it).
"""

from app import run

if __name__ == "__main__":
    run()
