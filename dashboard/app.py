"""Visionary classroom fleet dashboard.

Teacher-run FastAPI web app that runs on the teacher's laptop on the same LAN as
the glasses (NOT on the glasses themselves). A background thread polls each
configured device's local API every 15s and keeps an in-RAM snapshot of
TEXT-ONLY reading activity.

Privacy: this app only ever calls each device's /status and /history endpoints.
It NEVER requests /history/{id}/image or /history/{id}/audio, so no picture or
sound ever leaves a student's device. Reading text is truncated to a single
short line per entry: summaries, not surveillance.
"""

import json
import os
import sys
import threading
import time
from typing import Any, Dict, List, Optional

import requests
from fastapi import FastAPI
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse

HERE = os.path.dirname(os.path.abspath(__file__))
INDEX_HTML = os.path.join(HERE, "static", "index.html")

CONFIG_PATH = os.environ.get("VISIONARY_FLEET_CONFIG", "./devices.json")
POLL_INTERVAL_S = 15.0
HTTP_TIMEOUT_S = 5.0
HISTORY_PER_PAGE = 20
RECENT_LIMIT = 6
TEXT_MAX = 120

_snapshot: Dict[str, Dict[str, Any]] = {}
_lock = threading.Lock()
_poller_started = False


def load_devices() -> List[Dict[str, str]]:
    """Read devices.json -> [{name, url, token}]. Missing/invalid config yields []
    so the app boots into its instructions state instead of crashing."""
    if not os.path.isfile(CONFIG_PATH):
        return []
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError) as exc:
        print("[fleet] could not read %s: %s" % (CONFIG_PATH, exc), file=sys.stderr)
        return []
    if not isinstance(raw, list):
        print("[fleet] %s must be a JSON array of devices" % CONFIG_PATH, file=sys.stderr)
        return []
    devices: List[Dict[str, str]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name", "")).strip()
        url = str(item.get("url", "")).strip().rstrip("/")
        token = str(item.get("token", "")).strip()
        if not name or not url or not token:
            print("[fleet] skipping incomplete device entry (name=%r): missing name/url/token" % (name or None,), file=sys.stderr)
            continue
        devices.append({"name": name, "url": url, "token": token})
    return devices


def _start_of_today() -> float:
    lt = time.localtime()
    midnight = time.struct_time(
        (lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, lt.tm_wday, lt.tm_yday, -1)
    )
    return time.mktime(midnight)


def _first_line(text: Optional[str]) -> str:
    line = (text or "").strip().split("\n", 1)[0].strip()
    if len(line) > TEXT_MAX:
        line = line[: TEXT_MAX - 1].rstrip() + "…"
    return line


def poll_device(device: Dict[str, str]) -> Dict[str, Any]:
    """Poll one device's /status + /history and return its snapshot entry.

    Raises on any failure (unreachable, bad token, malformed response) so the
    caller can mark the station offline and keep its last-known snapshot. Only
    /status and /history are ever requested -- never image or audio endpoints.
    """
    headers = {"Authorization": "Bearer " + device["token"]}
    base = device["url"]

    status = requests.get(base + "/status", headers=headers, timeout=HTTP_TIMEOUT_S)
    status.raise_for_status()

    hist = requests.get(
        base + "/history",
        params={"page": 1, "per_page": HISTORY_PER_PAGE},
        headers=headers,
        timeout=HTTP_TIMEOUT_S,
    )
    hist.raise_for_status()
    entries = hist.json().get("entries", []) or []

    start_of_day = _start_of_today()
    reads_today = sum(1 for e in entries if float(e.get("ts") or 0) >= start_of_day)
    recent = [
        {"ts": e.get("ts"), "kind": e.get("kind"), "text": _first_line(e.get("text"))}
        for e in entries[:RECENT_LIMIT]
    ]
    return {
        "online": True,
        "last_seen": time.time(),
        "reads_today": reads_today,
        "recent": recent,
    }


def poll_all() -> None:
    """One poll cycle across all configured devices. Unreachable devices keep
    their last snapshot but are marked offline; devices dropped from the config
    are pruned."""
    devices = load_devices()
    with _lock:
        prev = dict(_snapshot)
    fresh: Dict[str, Dict[str, Any]] = {}
    for device in devices:
        name = device["name"]
        try:
            fresh[name] = poll_device(device)
        except Exception as exc:  # noqa: BLE001 - any failure means "offline, keep last"
            print("[fleet] %s unreachable: %s" % (name, exc), file=sys.stderr)
            last = prev.get(name)
            if last is not None:
                fresh[name] = dict(last)
                fresh[name]["online"] = False
            else:
                fresh[name] = {
                    "online": False,
                    "last_seen": None,
                    "reads_today": 0,
                    "recent": [],
                }
    with _lock:
        _snapshot.clear()
        _snapshot.update(fresh)


def _poll_loop() -> None:
    while True:
        try:
            poll_all()
        except Exception as exc:  # noqa: BLE001 - the poller must never die
            print("[fleet] poll cycle failed: %s" % exc, file=sys.stderr)
        time.sleep(POLL_INTERVAL_S)


def get_snapshot() -> Dict[str, Dict[str, Any]]:
    with _lock:
        return json.loads(json.dumps(_snapshot))


app = FastAPI(title="Visionary Fleet")


@app.on_event("startup")
def _start_poller() -> None:
    global _poller_started
    if _poller_started:
        return
    _poller_started = True
    threading.Thread(target=_poll_loop, name="fleet-poller", daemon=True).start()


@app.get("/")
def index() -> Any:
    if os.path.isfile(INDEX_HTML):
        return FileResponse(INDEX_HTML, media_type="text/html")
    return HTMLResponse("<h1>Visionary Fleet</h1><p>static/index.html is missing.</p>")


@app.get("/fleet")
def fleet() -> JSONResponse:
    return JSONResponse(get_snapshot())
