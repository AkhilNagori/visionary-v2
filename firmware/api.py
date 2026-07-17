"""Visionary local API on :8321.

Runs as a separate process (visionary-api.service) and talks to the main
firmware service only through the JSON-lines UDS protocol at HOME/visionary.sock.
"""

import base64
import hmac
import json
import os
import socket
import subprocess
import threading
import time
from typing import Any, Dict, Iterator, Optional

from fastapi import Body, Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

import state

VERSION = "1.0.0"
SOCK_PATH = os.path.join(state.HOME, "visionary.sock")
APP_DIR = os.path.dirname(os.path.abspath(__file__))
# The running app dir is a flattened copy of firmware/, so it can't be a git tree.
# setup.sh keeps a full checkout here; /update pulls it and re-syncs firmware/ -> app.
REPO_DIR = os.path.join(state.HOME, "src")
FIRMWARE_DIR = os.path.join(REPO_DIR, "firmware")
LIVE_BOUNDARY = "visionaryframe"
CAPTURE_MODES = ("read", "describe", "recorder")


def require_token(request: Request) -> None:
    scheme, _, credential = request.headers.get("authorization", "").partition(" ")
    if scheme.lower() != "bearer" or not hmac.compare_digest(
        credential.strip(), state.get_token()
    ):
        raise HTTPException(status_code=401, detail="invalid or missing token")


app = FastAPI(title="Visionary", version=VERSION, dependencies=[Depends(require_token)])


def uds_call(payload: dict, timeout: float = 5.0) -> dict:
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        try:
            conn.connect(SOCK_PATH)
            conn.sendall((json.dumps(payload) + "\n").encode("utf-8"))
            buf = b""
            while b"\n" not in buf:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
        finally:
            conn.close()
        return json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
    except (OSError, ValueError):
        raise HTTPException(
            status_code=503, detail="Visionary service is not running"
        )


class CaptureBody(BaseModel):
    mode: str


class SpeakBody(BaseModel):
    text: str


class WifiBody(BaseModel):
    ssid: str
    psk: str


class ActionResultBody(BaseModel):
    status: str
    result: str = ""


def _wifi_ssid() -> Optional[str]:
    try:
        out = subprocess.run(
            ["iwgetid", "-r"], capture_output=True, text=True, timeout=3
        )
        if out.returncode != 0:
            return None
        return out.stdout.strip() or None
    except (OSError, subprocess.TimeoutExpired):
        return None


def _deep_merge(base: Dict[str, Any], patch: Dict[str, Any]) -> Dict[str, Any]:
    merged = dict(base)
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


@app.get("/status")
def get_status() -> Dict[str, Any]:
    st = uds_call({"cmd": "status"})
    return {
        "online": bool(st.get("online")),
        "battery": None,
        "wifi": _wifi_ssid(),
        "version": VERSION,
        "uptime": st.get("uptime"),
        "busy": bool(st.get("busy")),
        "recording": bool(st.get("recording")),
    }


@app.get("/config")
def get_config() -> Dict[str, Any]:
    return state.load_config()


@app.put("/config")
def put_config(patch: Dict[str, Any] = Body(...)) -> Dict[str, Any]:
    unknown = sorted(set(patch) - set(state.DEFAULT_CONFIG))
    if unknown:
        raise HTTPException(
            status_code=422, detail="unknown config keys: " + ", ".join(unknown)
        )
    merged = _deep_merge(state.load_config(), patch)
    state.save_config(merged)
    return merged


@app.get("/history")
def get_history(
    page: int = Query(1, ge=1), per_page: int = Query(20, ge=1, le=100)
) -> Dict[str, Any]:
    return state.get_history().list(page=page, per_page=per_page)


def _entry_file(entry_id: int, path_key: str) -> str:
    entry = state.get_history().get(entry_id)
    path = (entry or {}).get(path_key)
    if not path or not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="not found")
    return path


@app.get("/history/{entry_id}/image")
def history_image(entry_id: int) -> FileResponse:
    return FileResponse(_entry_file(entry_id, "image_path"), media_type="image/jpeg")


@app.get("/history/{entry_id}/audio")
def history_audio(entry_id: int) -> FileResponse:
    return FileResponse(_entry_file(entry_id, "audio_path"), media_type="audio/wav")


@app.post("/capture")
def capture(body: CaptureBody) -> Dict[str, Any]:
    if body.mode not in CAPTURE_MODES:
        raise HTTPException(
            status_code=422, detail="mode must be one of: " + ", ".join(CAPTURE_MODES)
        )
    resp = uds_call({"cmd": "capture", "mode": body.mode})
    if not resp.get("ok"):
        if resp.get("error") == "busy":
            raise HTTPException(status_code=409, detail="device is busy")
        raise HTTPException(status_code=500, detail=resp.get("error") or "capture failed")
    return {"ok": True}


def _mjpeg_part(jpeg: bytes) -> bytes:
    return (
        b"--" + LIVE_BOUNDARY.encode("ascii") + b"\r\n"
        b"Content-Type: image/jpeg\r\n"
        b"Content-Length: " + str(len(jpeg)).encode("ascii") + b"\r\n\r\n"
        + jpeg + b"\r\n"
    )


@app.get("/live")
def live() -> StreamingResponse:
    first = uds_call({"cmd": "frame"})
    if not first.get("ok"):
        raise HTTPException(status_code=503, detail="preview unavailable")

    def frames(resp: Dict[str, Any] = first) -> Iterator[bytes]:
        while True:
            try:
                yield _mjpeg_part(base64.b64decode(resp["jpeg_b64"]))
            except (KeyError, ValueError):
                return
            time.sleep(0.25)
            try:
                resp = uds_call({"cmd": "frame"})
            except HTTPException:
                return
            if not resp.get("ok"):
                return

    return StreamingResponse(
        frames(),
        media_type="multipart/x-mixed-replace; boundary=" + LIVE_BOUNDARY,
    )


@app.post("/speak")
def speak(body: SpeakBody) -> Dict[str, Any]:
    text = body.text.strip()
    if not text:
        raise HTTPException(status_code=422, detail="text must not be empty")
    resp = uds_call({"cmd": "speak", "text": text})
    if not resp.get("ok"):
        raise HTTPException(status_code=500, detail=resp.get("error") or "speak failed")
    return {"ok": True}


@app.post("/wifi")
def wifi(body: WifiBody) -> Dict[str, Any]:
    try:
        connect = subprocess.run(
            ["nmcli", "device", "wifi", "connect", body.ssid, "password", body.psk],
            capture_output=True, text=True, timeout=60,
        )
        if connect.returncode == 0:
            return {"ok": True, "detail": connect.stdout.strip()}
        # visible-network connect failed: add a profile so hidden SSIDs work too
        add = subprocess.run(
            [
                "nmcli", "connection", "add", "type", "wifi",
                "con-name", body.ssid, "ssid", body.ssid,
                "802-11-wireless.hidden", "yes",
                "wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", body.psk,
                "connection.autoconnect", "yes",
            ],
            capture_output=True, text=True, timeout=30,
        )
        if add.returncode != 0:
            raise HTTPException(
                status_code=500,
                detail=(connect.stderr.strip() or add.stderr.strip() or "nmcli failed"),
            )
        up = subprocess.run(
            ["nmcli", "connection", "up", body.ssid],
            capture_output=True, text=True, timeout=60,
        )
        if up.returncode != 0:
            raise HTTPException(
                status_code=500, detail=up.stderr.strip() or "could not join network"
            )
        return {"ok": True, "detail": up.stdout.strip()}
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise HTTPException(status_code=500, detail="nmcli unavailable: " + str(exc))


def _restart_services() -> None:
    time.sleep(1.5)  # let the HTTP response flush before systemd kills this process
    subprocess.run(
        ["systemctl", "restart", "visionary", "visionary-api"], check=False
    )


@app.post("/update")
def update() -> Dict[str, Any]:
    if not os.path.isdir(os.path.join(REPO_DIR, ".git")):
        raise HTTPException(
            status_code=500,
            detail="no on-device git checkout at " + REPO_DIR + "; re-run setup.sh",
        )
    try:
        pull = subprocess.run(
            ["git", "pull", "--ff-only"],
            cwd=REPO_DIR, capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise HTTPException(status_code=500, detail="update failed: " + str(exc))
    if pull.returncode != 0:
        raise HTTPException(
            status_code=500, detail=pull.stderr.strip() or "git pull failed"
        )
    try:
        sync = subprocess.run(
            ["rsync", "-a", "--delete", "--exclude", "__pycache__", "--exclude",
             "*.pyc", FIRMWARE_DIR + "/", APP_DIR + "/"],
            capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise HTTPException(status_code=500, detail="update sync failed: " + str(exc))
    if sync.returncode != 0:
        raise HTTPException(
            status_code=500, detail=sync.stderr.strip() or "firmware sync failed"
        )
    threading.Thread(target=_restart_services, daemon=True).start()
    return {"ok": True, "detail": pull.stdout.strip(), "restarting": True}


@app.get("/memory/search")
def memory_search(
    q: str = Query(..., min_length=1), k: int = Query(5, ge=1, le=50)
) -> Dict[str, Any]:
    import memory  # lazy: keeps api importable even where numpy/openai are absent
    return {"results": memory.search(q, k)}


@app.get("/actions")
def list_actions() -> Dict[str, Any]:
    return {"actions": state.get_actions().list_pending()}


@app.post("/actions/{action_id}")
def complete_action(action_id: int, body: ActionResultBody) -> Dict[str, Any]:
    if body.status not in ("done", "failed"):
        raise HTTPException(
            status_code=422, detail='status must be "done" or "failed"'
        )
    if not state.get_actions().complete(action_id, body.status, body.result):
        raise HTTPException(status_code=404, detail="unknown action id")
    return {"ok": True}
