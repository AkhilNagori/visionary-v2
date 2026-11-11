#!/usr/bin/env python3
"""Live glasses runtime: continuous conversation and one-click camera context.

The old recorder, TTS, mode watchers, and local VAD are intentionally absent
from this runtime. One LiveClient owns microphone capture and reply playback.
"""

import base64
import json
import logging
import os
import signal
import socket
import stat
import subprocess
import threading
import time
from typing import Callable, Optional, Tuple

import events
import state
import vision

LOG = logging.getLogger("visionary.live")
BUTTON_PIN = 17
MAX_COMMAND_BYTES = 65536


class LiveButton:
    """Short release takes a photo; medium release pauses; 5s hold shuts down."""

    def __init__(
            self, on_photo: Callable, on_toggle: Callable, on_shutdown: Callable,
            clock: Callable = time.monotonic, timer_factory=threading.Timer,
            pause_time: float = 1.0, shutdown_time: float = 5.0) -> None:
        self.on_photo = on_photo
        self.on_toggle = on_toggle
        self.on_shutdown = on_shutdown
        self.clock = clock
        self.timer_factory = timer_factory
        self.pause_time = pause_time
        self.shutdown_time = shutdown_time
        self._lock = threading.Lock()
        self._pressed = False
        self._started = 0.0
        self._press_id = 0
        self._timer = None
        self._closed = False

    def press(self) -> None:
        with self._lock:
            if self._closed or self._pressed:
                return
            self._pressed = True
            self._started = self.clock()
            self._press_id += 1
            press_id = self._press_id
            self._timer = self.timer_factory(
                self.shutdown_time, lambda: self._held(press_id))
            self._timer.daemon = True
            self._timer.start()

    def release(self) -> None:
        with self._lock:
            if self._closed or not self._pressed:
                return
            elapsed = self.clock() - self._started
            self._pressed = False
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None
            if elapsed >= self.shutdown_time:
                callback = self.on_shutdown
            elif elapsed >= self.pause_time:
                callback = self.on_toggle
            else:
                callback = self.on_photo
        callback()

    def _held(self, press_id: int) -> None:
        with self._lock:
            if (self._closed or not self._pressed
                    or press_id != self._press_id):
                return
            self._pressed = False
            self._timer = None
        self.on_shutdown()

    def close(self) -> None:
        with self._lock:
            self._closed = True
            self._pressed = False
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None


class SimLiveClient:
    """Offline control-path simulation; never reads keys or opens a network."""

    def __init__(self) -> None:
        self.connected = False
        self.paused = False

    def start(self) -> None:
        self.connected = True
        LOG.info("SIM Live ready: no microphone, speaker, or network opened")

    def close(self) -> None:
        self.connected = False

    def pause(self) -> None:
        self.paused = True

    def resume(self) -> None:
        self.paused = False

    def toggle(self) -> None:
        self.paused = not self.paused

    def send_photo(self, jpeg: bytes) -> bool:
        if not self.connected or self.paused:
            return False
        LOG.info("SIM shared photo: %d bytes", len(jpeg))
        return True

    def say(self, text: str) -> bool:
        if not self.connected or self.paused:
            return False
        LOG.info("SIM say: %s", text)
        return True

    def status(self) -> dict:
        return {
            "connected": self.connected,
            "paused": self.paused,
            "state": "paused" if self.paused else "connected",
            "listening": self.connected and not self.paused,
        }


class LiveRuntime:
    def __init__(self, client=None, sim: Optional[bool] = None) -> None:
        self.sim = os.environ.get("VISIONARY_SIM") == "1" if sim is None else sim
        if client is None:
            if self.sim:
                client = SimLiveClient()
            else:
                from live_client import LiveClient
                client = LiveClient()
        self.client = client
        self.stop_requested = threading.Event()
        self.shutdown_requested = False
        self._photo_lock = threading.Lock()
        self._close_lock = threading.Lock()
        self._closed = False
        self._photo_thread = None
        self._boot_ts = time.monotonic()
        self.camera_available = False
        self.camera_error = None

    def start(self) -> None:
        state.ensure_dirs()
        state.get_token()  # Preserve companion pairing without a separate TTS call.
        try:
            vision.init_camera()
            self.camera_available = True
        except Exception as exc:
            self.camera_error = str(exc)
            LOG.error("Camera unavailable; voice conversation can still run: %s", exc)
        self.client.start()

    def close(self) -> None:
        self.stop_requested.set()
        with self._close_lock:
            if self._closed:
                return
            self._closed = True
        self.client.close()
        worker = self._photo_thread
        if worker is not None and worker is not threading.current_thread():
            worker.join(timeout=2.0)

    def status(self) -> dict:
        details = dict(self.client.status())
        connected = bool(details.get("connected", details.get("online", False)))
        details.update({
            "ok": True,
            "runtime": "live",
            "online": connected,
            "busy": self._photo_lock.locked(),
            "recording": False,
            "uptime": round(time.monotonic() - self._boot_ts, 1),
            "camera_available": self.camera_available,
            "camera_error": self.camera_error,
        })
        return details

    def take_photo(self) -> Tuple[bool, Optional[str]]:
        if self.stop_requested.is_set():
            return False, "closing"
        current = self.client.status()
        if current.get("paused"):
            return False, "paused"
        if not current.get("connected", current.get("online", False)):
            return False, "not_connected"
        if not self._photo_lock.acquire(False):
            return False, "busy"

        def capture() -> None:
            try:
                jpeg = vision.capture_jpeg()
                self.camera_available = True
                self.camera_error = None
                if self.stop_requested.is_set():
                    return
                if self.client.send_photo(jpeg):
                    LOG.info("Photo shared with the Live conversation (%d bytes)", len(jpeg))
                    events.publish("live_photo", {"bytes": len(jpeg)})
                else:
                    LOG.warning("Photo not shared: Live session is unavailable or paused")
            except Exception as exc:
                self.camera_available = False
                self.camera_error = str(exc)
                LOG.error("Photo capture failed: %s", exc)
            finally:
                self._photo_lock.release()

        self._photo_thread = threading.Thread(target=capture, daemon=True)
        try:
            self._photo_thread.start()
        except Exception:
            self._photo_lock.release()
            raise
        return True, None

    def toggle(self) -> None:
        if not self.stop_requested.is_set():
            self.client.toggle()
            LOG.info("Live pause toggled: %s", self.client.status().get("paused"))

    def request_shutdown(self) -> None:
        self.shutdown_requested = True
        self.stop_requested.set()

    def handle(self, request: dict) -> dict:
        command = request.get("cmd")
        if command == "status":
            return self.status()
        if command == "capture":
            if request.get("mode", "photo") not in ("photo", "read", "describe"):
                return {"ok": False, "error": "unsupported_in_live"}
            ok, error = self.take_photo()
            return {"ok": ok, **({"error": error} if error else {})}
        if command == "frame":
            jpeg = vision.capture_preview_jpeg()
            return {"ok": True, "jpeg_b64": base64.b64encode(jpeg).decode("ascii")}
        if command == "speak":
            text = request.get("text")
            if not isinstance(text, str) or not text.strip() or len(text) > 4000:
                return {"ok": False, "error": "invalid_text"}
            ok = self.client.say(text.strip())
            return {"ok": ok, **({"error": "not_connected_or_paused"} if not ok else {})}
        if command == "live_control":
            action = request.get("action")
            if action not in ("pause", "resume", "toggle"):
                return {"ok": False, "error": "invalid_action"}
            getattr(self.client, action)()
            return self.status()
        if command == "events":
            seq, items = events.get_since(request.get("since", 0))
            return {"ok": True, "seq": seq, "events": items}
        if command in ("listen", "recorder", "modes", "timers", "mode"):
            return {"ok": False, "error": "unsupported_in_live"}
        return {"ok": False, "error": "unknown_command"}


class LiveCommandServer:
    """Bounded, local-only JSON-lines adapter for the existing companion API."""

    def __init__(self, runtime: LiveRuntime, path: Optional[str] = None) -> None:
        self.runtime = runtime
        self.path = path or os.path.join(state.HOME, "visionary.sock")
        self._socket = None
        self._thread = None
        self._closed = threading.Event()
        self._slots = threading.BoundedSemaphore(8)
        self._connections = set()
        self._lock = threading.Lock()
        self._inode = None

    def start(self) -> None:
        if os.path.lexists(self.path):
            if not stat.S_ISSOCK(os.lstat(self.path).st_mode):
                raise RuntimeError("Refusing to replace a non-socket command path")
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.settimeout(1.0)
            try:
                probe.connect(self.path)
            except ConnectionRefusedError:
                os.unlink(self.path)
            except FileNotFoundError:
                pass
            else:
                raise RuntimeError("Another Visionary command server is running")
            finally:
                probe.close()
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.bind(self.path)
            os.chmod(self.path, 0o600)
            self._inode = os.lstat(self.path).st_ino
            sock.listen(8)
            sock.settimeout(0.5)
        except Exception:
            sock.close()
            raise
        self._socket = sock
        self._thread = threading.Thread(target=self._accept, daemon=True)
        self._thread.start()

    def _accept(self) -> None:
        while not self._closed.is_set():
            try:
                connection, _ = self._socket.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            if not self._slots.acquire(False):
                connection.close()
                continue
            connection.settimeout(5.0)
            with self._lock:
                if self._closed.is_set():
                    connection.close()
                    self._slots.release()
                    return
                self._connections.add(connection)
            threading.Thread(target=self._serve, args=(connection,), daemon=True).start()

    def _serve(self, connection: socket.socket) -> None:
        try:
            with connection.makefile("rwb") as stream:
                while not self._closed.is_set():
                    raw = stream.readline(MAX_COMMAND_BYTES + 1)
                    if not raw:
                        return
                    if len(raw) > MAX_COMMAND_BYTES or not raw.endswith(b"\n"):
                        stream.write(b'{"ok":false,"error":"request_too_large"}\n')
                        stream.flush()
                        return
                    try:
                        request = json.loads(raw.decode("utf-8"))
                        if not isinstance(request, dict):
                            raise ValueError("Expected an object")
                    except (ValueError, UnicodeDecodeError):
                        response = {"ok": False, "error": "bad_request"}
                    else:
                        try:
                            response = self.runtime.handle(request)
                        except Exception as exc:
                            LOG.error("Command %r failed: %s", request.get("cmd"), exc)
                            response = {"ok": False, "error": "command_failed"}
                    stream.write((json.dumps(response) + "\n").encode("utf-8"))
                    stream.flush()
        except OSError:
            pass
        finally:
            connection.close()
            with self._lock:
                self._connections.discard(connection)
            self._slots.release()

    def close(self) -> None:
        self._closed.set()
        if self._socket is not None:
            self._socket.close()
        with self._lock:
            for connection in self._connections:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                connection.close()
        if self._thread is not None:
            self._thread.join(timeout=1.0)
        try:
            if self._inode is not None and os.lstat(self.path).st_ino == self._inode:
                os.unlink(self.path)
        except FileNotFoundError:
            pass


def run_hardware(runtime: LiveRuntime) -> None:
    from gpiozero import Button

    engine = LiveButton(runtime.take_photo, runtime.toggle, runtime.request_shutdown)
    button = Button(BUTTON_PIN, pull_up=True, bounce_time=0.05)
    button.when_pressed = engine.press
    button.when_released = engine.release
    try:
        runtime.stop_requested.wait()
    finally:
        engine.close()
        button.close()


def run_sim(runtime: LiveRuntime) -> None:
    print("Visionary Live SIM: p=photo, m=pause/resume, s=status, q=quit")
    while not runtime.stop_requested.is_set():
        try:
            command = input("> ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            return
        if command in ("p", "1"):
            print(runtime.take_photo())
        elif command == "m":
            runtime.toggle()
        elif command == "s":
            print(json.dumps(runtime.status()))
        elif command == "q":
            return


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    runtime = LiveRuntime()
    server = LiveCommandServer(runtime)

    def request_stop(_signal, _frame) -> None:
        runtime.stop_requested.set()
        if runtime.sim:
            raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    try:
        runtime.start()
        server.start()
        if runtime.sim:
            run_sim(runtime)
        else:
            run_hardware(runtime)
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
        runtime.close()
    if runtime.shutdown_requested:
        if runtime.sim:
            LOG.info("SIM safe shutdown requested")
        else:
            subprocess.run(["shutdown", "-h", "now"], check=False)


if __name__ == "__main__":
    main()
