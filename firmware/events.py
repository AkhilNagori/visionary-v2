"""In-process event bus: a bounded ring buffer that live features publish into
and the UDS/SSE layer polls out of.

Captions, timers, and any mode that wants to surface something to the phone call
publish(kind, data). main.py's UDS server answers {"cmd":"events","since":n} by
calling get_since(n); api.py's GET /events streams those out as Server-Sent
Events, polling every ~0.5s. The buffer keeps only the most recent RING events,
so a subscriber that falls further behind than that silently skips the gap and
resumes from the latest sequence number.

Sequence numbers are monotonic and never reset for the life of the process, so a
poller can hold a cursor across reconnects. Everything here is thread-safe: any
firmware thread may publish, and the UDS thread reads concurrently.
"""

import threading
import time
from collections import deque
from typing import Any, Deque, List, Optional, Tuple

RING = 500

_lock = threading.Lock()
_events = deque(maxlen=RING)  # type: Deque[dict]
_seq = 0


def publish(kind: str, data: Any = None) -> int:
    """Append an event and return its sequence number.

    ``data`` must be JSON-serializable (it is sent verbatim over UDS/SSE): a
    string for captions, a small dict for timers, etc.
    """
    global _seq
    with _lock:
        _seq += 1
        _events.append({"seq": _seq, "ts": time.time(), "kind": kind, "data": data})
        return _seq


def get_since(seq: Optional[int] = 0) -> Tuple[int, List[dict]]:
    """Return (latest_seq, events strictly newer than ``seq``).

    ``latest_seq`` is the current head even when no new events exist, so a poller
    can advance its cursor without missing the next event. Event dicts are copied
    so callers can serialize them without holding the lock.
    """
    try:
        since = int(seq)
    except (TypeError, ValueError):
        since = 0
    with _lock:
        latest = _seq
        fresh = [dict(e) for e in _events if e["seq"] > since]
    return latest, fresh


def clear() -> None:
    """Drop buffered events; the sequence counter keeps advancing.

    Used when a live session restarts (so stale captions don't replay) and by
    tests that want a clean buffer.
    """
    with _lock:
        _events.clear()
