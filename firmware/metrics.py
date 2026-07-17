"""Per-stage latency logging (see ARCHITECTURE.md, firmware/metrics.py)."""

import os
import sys
import time
from typing import List, Tuple

PRIMARY_LOG = "/var/log/visionary/metrics.log"


def _log_path() -> str:
    # Resolved per call so an unwritable /var/log (dev machines, SIM) falls
    # back to $VISIONARY_HOME without caching a bad decision at import time.
    try:
        os.makedirs(os.path.dirname(PRIMARY_LOG), exist_ok=True)
        with open(PRIMARY_LOG, "a"):
            return PRIMARY_LOG
    except OSError:
        home = os.environ.get("VISIONARY_HOME", "/opt/visionary")
        return os.path.join(home, "metrics.log")


class StageTimer:
    def __init__(self) -> None:
        self._start = time.monotonic()
        self._last = self._start
        self._stages = []  # type: List[Tuple[str, int]]

    def mark(self, stage: str) -> None:
        now = time.monotonic()
        self._stages.append((stage, int(round((now - self._last) * 1000))))
        self._last = now

    def log(self, event: str) -> None:
        total_ms = int(round((time.monotonic() - self._start) * 1000))
        parts = ["ts=%d" % int(time.time()), "event=%s" % event]
        parts.extend("%s_ms=%d" % (name, ms) for name, ms in self._stages)
        parts.append("total_ms=%d" % total_ms)
        line = " ".join(parts)
        path = _log_path()
        try:
            parent = os.path.dirname(path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(path, "a") as f:
                f.write(line + "\n")
        except OSError as exc:
            # Metrics must never break a user-facing pipeline.
            print("metrics: %s: %s" % (exc, line), file=sys.stderr)
