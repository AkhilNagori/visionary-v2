"""Paths, config load/save, SQLite history, pairing token + QR.

No hardware dependencies — safe to import anywhere, including SIM mode.
"""

import json
import os
import secrets
import socket
import sqlite3
import threading
import time
from typing import Dict, Optional

HOME = os.environ.get("VISIONARY_HOME", "/opt/visionary")

CONFIG_PATH = os.path.join(HOME, "config.json")
DB_PATH = os.path.join(HOME, "history.db")
TOKEN_PATH = os.path.join(HOME, "token")
QR_PATH = os.path.join(HOME, "pairing_qr.png")

DEFAULT_CONFIG = {
    "voice": "en_US-lessac-low",
    "rate": 1.0,
    "language": None,
    "two_way": {"enabled": False, "theirs": "es", "yours": "en"},
    "gestures": {"single": "read", "double": "describe", "triple": "recorder"},
    "features": {"ask": True, "recorder": True},
}


def ensure_dirs() -> None:
    for sub in ("captures", "recordings", "voices", "sounds"):
        os.makedirs(os.path.join(HOME, sub), exist_ok=True)


def _deep_merge(base: dict, override: dict) -> dict:
    merged = dict(base)
    for key, value in override.items():
        if (
            key in merged
            and isinstance(merged[key], dict)
            and isinstance(value, dict)
        ):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def load_config() -> dict:
    try:
        with open(CONFIG_PATH, "r") as f:
            file_cfg = json.load(f)
        if not isinstance(file_cfg, dict):
            raise ValueError("config.json is not a JSON object")
    except (OSError, ValueError):
        # Missing or corrupt: fall back to defaults and rewrite the file.
        cfg = json.loads(json.dumps(DEFAULT_CONFIG))
        save_config(cfg)
        return cfg
    return _deep_merge(DEFAULT_CONFIG, file_cfg)


def save_config(cfg: dict) -> None:
    ensure_dirs()
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.replace(tmp, CONFIG_PATH)


class History:
    def __init__(self, db_path: str = DB_PATH) -> None:
        ensure_dirs()
        self._lock = threading.Lock()
        # One shared connection guarded by the lock; sqlite's own
        # same-thread check would reject use from dispatcher threads.
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS entries ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "ts REAL, kind TEXT, text TEXT, extra TEXT, "
            "image_path TEXT, audio_path TEXT)"
        )
        self._conn.commit()

    def add(
        self,
        kind: str,
        text: str,
        extra: Optional[Dict[str, str]] = None,
        image_path: Optional[str] = None,
        audio_path: Optional[str] = None,
    ) -> int:
        extra_json = None
        if extra is not None:
            extra_json = json.dumps({str(k): str(v) for k, v in extra.items()})
        with self._lock:
            cur = self._conn.execute(
                "INSERT INTO entries (ts, kind, text, extra, image_path, audio_path) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (time.time(), kind, text, extra_json, image_path, audio_path),
            )
            self._conn.commit()
            return int(cur.lastrowid)

    def list(self, page: int = 1, per_page: int = 20) -> dict:
        page = max(1, int(page))
        per_page = max(1, int(per_page))
        with self._lock:
            total = self._conn.execute("SELECT COUNT(*) FROM entries").fetchone()[0]
            rows = self._conn.execute(
                "SELECT id, ts, kind, text, extra, image_path, audio_path "
                "FROM entries ORDER BY id DESC LIMIT ? OFFSET ?",
                (per_page, (page - 1) * per_page),
            ).fetchall()
        return {
            "entries": [self._row_to_entry(r) for r in rows],
            "page": page,
            "per_page": per_page,
            "total": int(total),
        }

    def get(self, entry_id: int) -> Optional[dict]:
        with self._lock:
            row = self._conn.execute(
                "SELECT id, ts, kind, text, extra, image_path, audio_path "
                "FROM entries WHERE id = ?",
                (entry_id,),
            ).fetchone()
        return self._row_to_entry(row) if row else None

    @staticmethod
    def _row_to_entry(row) -> dict:
        extra = None
        if row[4]:
            try:
                extra = json.loads(row[4])
            except ValueError:
                extra = None
        return {
            "id": row[0],
            "ts": row[1],
            "kind": row[2],
            "text": row[3],
            "extra": extra,
            "image_path": row[5],
            "audio_path": row[6],
        }


_history = None  # type: Optional[History]
_history_lock = threading.Lock()


def get_history() -> History:
    global _history
    with _history_lock:
        if _history is None:
            _history = History()
        return _history


def get_token() -> str:
    ensure_dirs()
    token = None
    try:
        with open(TOKEN_PATH, "r") as f:
            token = f.read().strip()
    except OSError:
        pass
    if not (token and token.isdigit() and len(token) == 6):
        token = "{:06d}".format(secrets.randbelow(1000000))
        with open(TOKEN_PATH, "w") as f:
            f.write(token + "\n")
        os.chmod(TOKEN_PATH, 0o600)
        _write_qr(token)
    elif not os.path.exists(QR_PATH):
        # qrcode may have been installed after first boot; retry.
        _write_qr(token)
    return token


def _write_qr(token: str) -> None:
    try:
        import qrcode
        payload = {"url": _device_url(), "token": token}
        qrcode.make(json.dumps(payload)).save(QR_PATH)
    except ImportError:
        pass


def _device_url() -> str:
    hostname = socket.gethostname().split(".")[0]
    return "http://{}.local:8321".format(hostname)


def pairing_payload() -> dict:
    return {"url": _device_url(), "token": get_token()}
