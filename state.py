import threading
from settings import load_config

_lock = threading.Lock()
_room: str = ""


def init_default_room() -> None:
    global _room
    rooms = load_config().get("rooms", ["Living Room"])
    _room = str(rooms[0]) if rooms else "Unknown"


def get_current_room() -> str:
    with _lock:
        return _room or "Unknown"


def set_current_room(name: str) -> None:
    global _room
    with _lock:
        _room = name
