import threading
import time
from settings import load_config

_lock = threading.Lock()
_room: str = ""
# 0.0 = no gating; after set_current_room, only readings with ts _after_ this are logged.
_room_change_at: float = 0.0


def init_default_room() -> None:
    global _room, _room_change_at
    rooms = load_config().get("rooms", ["Living Room"])
    _room = str(rooms[0]) if rooms else "Unknown"
    _room_change_at = 0.0


def get_current_room() -> str:
    with _lock:
        return _room or "Unknown"


def get_room_change_ts() -> float:
    """UNIX time when the user last selected a room. Used to skip logging stale air."""
    with _lock:
        return _room_change_at


def set_current_room(name: str) -> None:
    global _room, _room_change_at
    with _lock:
        if name == _room:
            return
        _room = name
        _room_change_at = time.time()
