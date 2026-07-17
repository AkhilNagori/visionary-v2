"""Shared pytest setup for the Visionary firmware + dashboard.

Every test runs in SIM mode against a throwaway ``VISIONARY_HOME`` so nothing
touches real hardware or a shared data dir. The two rules that make this work:

1. ``VISIONARY_SIM`` and ``VISIONARY_HOME`` are set **before** any firmware
   module is imported, and firmware is only ever imported lazily (inside a test
   or fixture) through the ``load`` fixture below.
2. Firmware modules read ``VISIONARY_HOME`` into module-level constants at
   import time and keep singletons (history DB handle, is_online cache, ...) in
   module globals, so between tests we purge them from ``sys.modules`` and let
   each test re-import fresh against its own HOME.
"""

import base64
import importlib
import json
import os
import shutil
import socket
import sys
import tempfile
import threading

import pytest

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_TESTS_DIR)

# firmware modules import each other as top-level modules; the dashboard app is
# a sibling package. Both dirs go on sys.path exactly like the real services run.
for _sub in ("firmware", "dashboard"):
    _p = os.path.join(_ROOT, _sub)
    if _p not in sys.path:
        sys.path.insert(0, _p)

# Local (repo) modules whose module-level state depends on VISIONARY_HOME/SIM.
_FIRMWARE_MODULES = frozenset(
    ("state", "audio", "brain", "vision", "metrics", "main", "memory",
     "wakeword", "api", "app")
)


def _purge_firmware_modules():
    for name in list(sys.modules):
        if name in _FIRMWARE_MODULES or name == "modes" or name.startswith("modes."):
            del sys.modules[name]


@pytest.fixture(autouse=True)
def visionary_env(monkeypatch):
    """Per-test SIM env + isolated HOME, with a clean firmware import graph."""
    # HOME/visionary.sock must fit AF_UNIX's sun_path cap (104 chars on macOS,
    # 108 on Linux). pytest's tmp_path can exceed that under a deep session dir,
    # so anchor HOME at a short base instead.
    home = tempfile.mkdtemp(dir="/tmp", prefix="vh")
    monkeypatch.setenv("VISIONARY_SIM", "1")
    monkeypatch.setenv("VISIONARY_HOME", home)
    # Tests opt in to keys/fixtures explicitly; never inherit the dev shell's.
    for var in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY",
                "VISIONARY_SIM_IMAGE", "VISIONARY_SIM_WAV",
                "VISIONARY_MODEL", "VISIONARY_ALSA_CAPTURE"):
        monkeypatch.delenv(var, raising=False)
    _purge_firmware_modules()
    yield home
    _purge_firmware_modules()
    shutil.rmtree(home, ignore_errors=True)


@pytest.fixture
def load():
    """Import a firmware/dashboard module fresh against the current HOME."""
    def _load(name):
        return importlib.import_module(name)
    return _load


class FakeUDS:
    """Stand-in for main.py's UDS command server: speaks the same JSON-lines
    protocol so api.py's ``uds_call`` can be exercised without the firmware
    service running. Toggle ``busy`` / ``online`` to drive response branches."""

    def __init__(self, path):
        self.path = path
        self.busy = False
        self.online = True
        self.recording = False
        self.uptime = 12.3
        self.speak_calls = []
        self.capture_calls = []
        self._closing = False
        if os.path.exists(path):
            os.unlink(path)
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.bind(path)
        self._sock.listen(8)
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()

    def _accept_loop(self):
        while not self._closing:
            try:
                conn, _ = self._sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn):
        f = conn.makefile("rwb")
        try:
            for raw in f:
                line = raw.strip()
                if not line:
                    continue
                try:
                    req = json.loads(line.decode("utf-8"))
                except ValueError:
                    resp = {"ok": False, "error": "bad request"}
                else:
                    resp = self._handle(req)
                f.write((json.dumps(resp) + "\n").encode("utf-8"))
                f.flush()
        except OSError:
            pass
        finally:
            try:
                f.close()
                conn.close()
            except OSError:
                pass

    def _handle(self, req):
        cmd = req.get("cmd")
        if cmd == "status":
            return {"ok": True, "online": self.online, "busy": self.busy,
                    "uptime": self.uptime, "recording": self.recording}
        if cmd == "capture":
            self.capture_calls.append(req.get("mode"))
            if self.busy:
                return {"ok": False, "error": "busy"}
            return {"ok": True}
        if cmd == "speak":
            self.speak_calls.append(req.get("text"))
            return {"ok": True}
        if cmd == "frame":
            return {"ok": True,
                    "jpeg_b64": base64.b64encode(b"\xff\xd8\xff\xe0jpg").decode("ascii")}
        return {"ok": False, "error": "unknown command"}

    def close(self):
        self._closing = True
        try:
            self._sock.close()
        except OSError:
            pass
        try:
            if os.path.exists(self.path):
                os.unlink(self.path)
        except OSError:
            pass


@pytest.fixture
def fake_uds():
    """A live fake UDS server bound at the test HOME's visionary.sock."""
    path = os.path.join(os.environ["VISIONARY_HOME"], "visionary.sock")
    server = FakeUDS(path)
    yield server
    server.close()
