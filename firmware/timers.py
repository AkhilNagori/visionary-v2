"""Multiple named kitchen/work timers — "pasta 8 minutes, sauce 20".

Each timer is a threading.Timer in a name-keyed registry; when one fires it
speaks "<name> timer is done" and publishes a "timer" event (so the phone can
surface it too). Setting a timer with a name that already exists replaces it.
Everything is thread-safe: set/cancel/list run from dispatch and API threads
while timers fire on their own threads.
"""

import threading
import time
from typing import List

import audio
import events

_lock = threading.Lock()
_timers = {}  # type: dict


def set_timer(name: str, seconds: float) -> dict:
    """Start (or replace) a named timer. Returns its info dict.

    Raises ValueError for a non-positive or non-numeric duration so the caller
    can beep/speak the problem.
    """
    try:
        seconds = float(seconds)
    except (TypeError, ValueError):
        raise ValueError("seconds must be a number")
    if seconds <= 0:
        raise ValueError("timer duration must be positive")
    name = (str(name).strip() if name is not None else "") or "Timer"
    fire_at = time.time() + seconds
    with _lock:
        old = _timers.pop(name, None)
        if old is not None:
            old["timer"].cancel()
        timer = threading.Timer(seconds, _fire, args=(name,))
        timer.daemon = True
        _timers[name] = {"name": name, "seconds": seconds,
                         "fire_at": fire_at, "timer": timer}
        timer.start()
    return {"name": name, "seconds": seconds,
            "fire_at": fire_at, "remaining": seconds}


def list_timers() -> List[dict]:
    """Active timers, soonest to fire first, with seconds remaining."""
    now = time.time()
    with _lock:
        infos = list(_timers.values())
    out = [
        {"name": i["name"], "seconds": i["seconds"], "fire_at": i["fire_at"],
         "remaining": max(0.0, i["fire_at"] - now)}
        for i in infos
    ]
    out.sort(key=lambda t: t["fire_at"])
    return out


def cancel_timer(name: str) -> bool:
    """Cancel a named timer. False if no such timer is active."""
    name = str(name).strip() if name is not None else ""
    with _lock:
        info = _timers.pop(name, None)
    if info is None:
        return False
    info["timer"].cancel()
    return True


def cancel_all() -> None:
    """Cancel every active timer (shutdown / test cleanup)."""
    with _lock:
        infos = list(_timers.values())
        _timers.clear()
    for info in infos:
        info["timer"].cancel()


def _fire(name: str) -> None:
    with _lock:
        info = _timers.pop(name, None)
    if info is None:  # cancelled or replaced between firing and acquiring the lock
        return
    try:
        events.publish("timer", {"name": name, "seconds": info["seconds"]})
    except Exception:
        pass
    try:
        audio.speak("%s timer is done" % name)
    except Exception:
        try:
            audio.beep("err")
        except Exception:
            pass
