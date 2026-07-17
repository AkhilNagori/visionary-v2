#!/usr/bin/env python3
"""Visionary firmware entrypoint: gesture engine, action dispatcher, UDS
command server, and boot sequence. Hardware mode drives a GPIO button;
SIM mode (VISIONARY_SIM=1) drives everything from a stdin REPL."""

import base64
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from typing import Callable, Optional, Tuple

import audio
import brain
import state
import vision
from modes import ask, describe, read, recorder, translate

SIM = os.environ.get("VISIONARY_SIM") == "1"
BUTTON_PIN = 17
TWO_WAY_POLL_S = 5.0
_BOOT_TS = time.monotonic()
_server = None


class GestureEngine:
    """Pure gesture logic, no GPIO. Debounce belongs to the button driver.

    Presses shorter than hold_time join a click burst; the burst resolves
    multi_window after the last release into single/double/triple. A press
    held >= hold_time fires on_hold_start while still held; releasing before
    shutdown_time fires on_hold_end(cancelled=False); reaching shutdown_time
    fires on_hold_end(cancelled=True) then on_shutdown.
    """

    def __init__(self,
                 on_single: Callable[[], None],
                 on_double: Callable[[], None],
                 on_triple: Callable[[], None],
                 on_hold_start: Callable[[], None],
                 on_hold_end: Callable[..., None],
                 on_shutdown: Callable[[], None],
                 multi_window: float = 0.45,
                 hold_time: float = 1.0,
                 shutdown_time: float = 5.0,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self.on_single = on_single
        self.on_double = on_double
        self.on_triple = on_triple
        self.on_hold_start = on_hold_start
        self.on_hold_end = on_hold_end
        self.on_shutdown = on_shutdown
        self.multi_window = multi_window
        self.hold_time = hold_time
        self.shutdown_time = shutdown_time
        self._clock = clock
        self._lock = threading.Lock()
        self._state = "idle"  # idle | pressed | holding | burst
        self._clicks = 0
        self._press_ts = 0.0
        self._last_release = 0.0
        self._shutdown_done = False
        self._hold_timer = None  # type: Optional[threading.Timer]
        self._burst_timer = None  # type: Optional[threading.Timer]
        self._shutdown_timer = None  # type: Optional[threading.Timer]

    def press(self) -> None:
        fire = None
        with self._lock:
            now = self._clock()
            if self._state in ("pressed", "holding"):
                return
            if self._state == "burst":
                self._cancel(self._burst_timer)
                # burst logically expired (fake clocks outrun real timers):
                # resolve it before starting the new gesture
                if self._clicks and now - self._last_release >= self.multi_window:
                    fire = self._resolve(self._clicks)
                    self._clicks = 0
            self._state = "pressed"
            self._press_ts = now
            self._shutdown_done = False
            self._hold_timer = self._start_timer(self.hold_time, self._hold_fired)
        if fire is not None:
            fire()

    def release(self) -> None:
        fires = []
        with self._lock:
            now = self._clock()
            if self._state == "pressed":
                self._cancel(self._hold_timer)
                dur = now - self._press_ts
                if dur >= self.shutdown_time:
                    # hold timers never fired (injected clock): synthesize the
                    # full hold lifecycle in contract order
                    self._state = "idle"
                    self._clicks = 0
                    self._shutdown_done = True
                    fires = [self.on_hold_start,
                             lambda: self.on_hold_end(cancelled=True),
                             self.on_shutdown]
                elif dur >= self.hold_time:
                    self._state = "idle"
                    self._clicks = 0
                    fires = [self.on_hold_start,
                             lambda: self.on_hold_end(cancelled=False)]
                else:
                    self._clicks += 1
                    self._last_release = now
                    self._state = "burst"
                    self._burst_timer = self._start_timer(self.multi_window,
                                                          self._burst_fired)
            elif self._state == "holding":
                self._cancel(self._shutdown_timer)
                self._state = "idle"
                if not self._shutdown_done:
                    if now - self._press_ts >= self.shutdown_time:
                        self._shutdown_done = True
                        fires = [lambda: self.on_hold_end(cancelled=True),
                                 self.on_shutdown]
                    else:
                        fires = [lambda: self.on_hold_end(cancelled=False)]
        for f in fires:
            f()

    def _hold_fired(self) -> None:
        with self._lock:
            if self._state != "pressed":
                return
            self._state = "holding"
            self._clicks = 0  # a hold absorbs any pending click burst
            delay = max(0.0, self.shutdown_time - self.hold_time)
            self._shutdown_timer = self._start_timer(delay, self._shutdown_fired)
        self.on_hold_start()

    def _shutdown_fired(self) -> None:
        with self._lock:
            if self._state != "holding" or self._shutdown_done:
                return
            self._shutdown_done = True
            self._state = "idle"
        self.on_hold_end(cancelled=True)
        self.on_shutdown()

    def _burst_fired(self) -> None:
        with self._lock:
            if self._state != "burst":
                return
            fire = self._resolve(self._clicks)
            self._clicks = 0
            self._state = "idle"
        if fire is not None:
            fire()

    def _resolve(self, clicks: int) -> Optional[Callable[[], None]]:
        if clicks == 1:
            return self.on_single
        if clicks == 2:
            return self.on_double
        if clicks >= 3:
            return self.on_triple
        return None

    def _start_timer(self, delay: float, fn: Callable[[], None]) -> threading.Timer:
        t = threading.Timer(delay, fn)
        t.daemon = True
        t.start()
        return t

    @staticmethod
    def _cancel(t: Optional[threading.Timer]) -> None:
        if t is not None:
            t.cancel()


class Dispatcher:
    """Routes gestures and UDS captures to mode actions on daemon threads."""

    def __init__(self) -> None:
        self.busy = threading.Lock()
        self._hold_active = False
        self._two_way_lock = threading.Lock()
        self._two_way_thread = None  # type: Optional[threading.Thread]
        self._two_way_stop = None  # type: Optional[threading.Event]

    # -- gesture entry points -------------------------------------------

    def gesture(self, kind: str) -> None:
        two_way_was_active = self._two_way_active()
        self.sync_two_way()
        cfg = state.load_config()
        mode = (cfg.get("gestures") or {}).get(kind)
        if recorder.is_recording():
            if mode == "recorder":
                self._spawn(recorder.toggle, blocking=True)
            return
        if two_way_was_active and self._two_way_active():
            if kind == "single":
                self.stop_two_way()
            return
        if self.busy.locked() or not mode:
            return
        feats = cfg.get("features") or {}
        if mode == "read":
            self._spawn(read.run_read)
        elif mode == "describe":
            self._spawn(describe.run_describe)
        elif mode == "recorder":
            if feats.get("recorder", True):
                self._spawn(recorder.toggle)
            else:
                audio.beep("err")
                audio.speak("The recorder is turned off.")
        else:
            audio.beep("err")
            audio.speak("That gesture is not set up.")

    def hold_start(self) -> None:
        self.sync_two_way()
        if recorder.is_recording() or self._two_way_active():
            return
        cfg = state.load_config()
        if not (cfg.get("features") or {}).get("ask", True):
            audio.beep("err")
            audio.speak("Ask is turned off.")
            return
        if not self.busy.acquire(False):
            return
        self._hold_active = True
        try:
            ask.ask_begin()
        except Exception:
            self._hold_active = False
            self.busy.release()
            audio.beep("err")
            audio.speak("Something went wrong.")

    def hold_end(self, cancelled: bool = False) -> None:
        if not self._hold_active:
            return
        self._hold_active = False
        if cancelled:
            # shutdown follows immediately; abandon the ask
            self.busy.release()
            return

        def worker() -> None:
            try:
                ask.ask_end()
            except Exception:
                audio.beep("err")
                audio.speak("Something went wrong.")
            finally:
                self.busy.release()

        threading.Thread(target=worker, daemon=True).start()

    # -- UDS capture entry point ----------------------------------------

    def capture(self, mode: str) -> Tuple[bool, Optional[str]]:
        self.sync_two_way()
        if mode == "recorder" and recorder.is_recording():
            self._spawn(recorder.toggle, blocking=True)
            return True, None
        if recorder.is_recording() or self._two_way_active() or self.busy.locked():
            return False, "busy"
        feats = state.load_config().get("features") or {}
        if mode == "recorder":
            if not feats.get("recorder", True):
                return False, "disabled"
            self._spawn(recorder.toggle)
        elif mode == "read":
            self._spawn(read.run_read)
        else:
            self._spawn(describe.run_describe)
        return True, None

    def status(self) -> dict:
        return {
            "ok": True,
            "online": brain.is_online(),
            "busy": self.busy.locked(),
            "uptime": round(time.monotonic() - _BOOT_TS, 1),
            "recording": recorder.is_recording(),
        }

    # -- two-way translate lifecycle -------------------------------------

    def sync_two_way(self) -> None:
        enabled = bool((state.load_config().get("two_way") or {}).get("enabled"))
        with self._two_way_lock:
            alive = self._two_way_thread is not None and self._two_way_thread.is_alive()
            if enabled and not alive:
                stop = threading.Event()
                self._two_way_stop = stop
                self._two_way_thread = threading.Thread(
                    target=self._two_way_worker, args=(stop,), daemon=True)
                self._two_way_thread.start()
            elif not enabled and alive and self._two_way_stop is not None:
                self._two_way_stop.set()

    def stop_two_way(self) -> None:
        with self._two_way_lock:
            if self._two_way_stop is not None:
                self._two_way_stop.set()
        # persist, or the poll would respawn the loop within ~5s
        cfg = state.load_config()
        if (cfg.get("two_way") or {}).get("enabled"):
            cfg["two_way"]["enabled"] = False
            state.save_config(cfg)
        audio.beep("ok")
        audio.speak("Interpreter off.")

    def _two_way_active(self) -> bool:
        with self._two_way_lock:
            return (self._two_way_thread is not None
                    and self._two_way_thread.is_alive()
                    and self._two_way_stop is not None
                    and not self._two_way_stop.is_set())

    def _two_way_worker(self, stop: threading.Event) -> None:
        try:
            translate.run_two_way(stop)
        except Exception:
            audio.beep("err")
            audio.speak("The interpreter stopped.")

    # -- internals --------------------------------------------------------

    def _spawn(self, fn: Callable[[], None], blocking: bool = False) -> None:
        def worker() -> None:
            if not self.busy.acquire(blocking):
                return
            try:
                fn()
            except Exception:
                audio.beep("err")
                audio.speak("Something went wrong.")
            finally:
                self.busy.release()

        threading.Thread(target=worker, daemon=True).start()


class CommandServer:
    """JSON-lines command server on a unix socket at HOME/visionary.sock."""

    def __init__(self, dispatcher: Dispatcher) -> None:
        self.dispatcher = dispatcher
        self.path = os.path.join(state.HOME, "visionary.sock")
        self._closing = False
        self._sock = None  # type: Optional[socket.socket]

    def start(self) -> None:
        if os.path.exists(self.path):
            os.unlink(self.path)
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.bind(self.path)
        self._sock.listen(4)
        threading.Thread(target=self._accept_loop, daemon=True).start()

    def close(self) -> None:
        self._closing = True
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
        try:
            if os.path.exists(self.path):
                os.unlink(self.path)
        except OSError:
            pass

    def _accept_loop(self) -> None:
        while not self._closing:
            try:
                conn, _ = self._sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn: socket.socket) -> None:
        f = conn.makefile("rwb")
        try:
            for raw in f:
                line = raw.strip()
                if not line:
                    continue
                try:
                    req = json.loads(line.decode("utf-8"))
                    if not isinstance(req, dict):
                        raise ValueError("not an object")
                except (ValueError, UnicodeDecodeError):
                    resp = {"ok": False, "error": "bad request"}
                else:
                    try:
                        resp = self._handle(req)
                    except Exception as e:
                        resp = {"ok": False, "error": str(e) or e.__class__.__name__}
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

    def _handle(self, req: dict) -> dict:
        cmd = req.get("cmd")
        if cmd == "capture":
            mode = req.get("mode")
            if mode not in ("read", "describe", "recorder"):
                return {"ok": False, "error": "bad mode"}
            ok, err = self.dispatcher.capture(mode)
            if ok:
                return {"ok": True}
            return {"ok": False, "error": err}
        if cmd == "speak":
            text = str(req.get("text", ""))
            threading.Thread(target=audio.speak, args=(text,), daemon=True).start()
            return {"ok": True}
        if cmd == "frame":
            jpeg = vision.capture_preview_jpeg()
            return {"ok": True, "jpeg_b64": base64.b64encode(jpeg).decode("ascii")}
        if cmd == "status":
            return self.dispatcher.status()
        return {"ok": False, "error": "unknown command"}


def boot(dispatcher: Dispatcher) -> CommandServer:
    state.ensure_dirs()
    first_boot = not os.path.exists(os.path.join(state.HOME, "token"))
    token = state.get_token()
    if first_boot:
        audio.speak("Welcome to Visionary. Your pairing code is %s."
                    % ", ".join(token), wait=True)
    try:
        vision.init_camera()
    except Exception:
        audio.beep("err")
        audio.speak("The camera failed to start.")
        raise
    server = CommandServer(dispatcher)
    server.start()
    dispatcher.sync_two_way()
    threading.Thread(target=_two_way_poll, args=(dispatcher,), daemon=True).start()
    audio.speak("Visionary ready."
                + ("" if brain.is_online() else " Offline mode."), wait=True)
    return server


def _two_way_poll(dispatcher: Dispatcher) -> None:
    while True:
        time.sleep(TWO_WAY_POLL_S)
        try:
            dispatcher.sync_two_way()
        except Exception as e:
            print("two-way poll error: %s" % e, file=sys.stderr)


def safe_shutdown() -> None:
    audio.speak("Shutting down. Goodbye.", wait=True)
    if _server is not None:
        _server.close()
    if SIM:
        print("[sim] sudo shutdown -h now")
    else:
        subprocess.run(["sudo", "shutdown", "-h", "now"], check=False)


def run_hardware(engine: GestureEngine) -> None:
    from gpiozero import Button
    btn = Button(BUTTON_PIN, pull_up=True, bounce_time=0.05)
    btn.when_pressed = engine.press
    btn.when_released = engine.release
    threading.Event().wait()


def run_sim(dispatcher: Dispatcher) -> None:
    print("Visionary SIM — 1/2/3 = clicks, a = hold start, "
          "r = hold release, s = status, q = quit")
    while True:
        try:
            line = input("> ")
        except (EOFError, KeyboardInterrupt):
            print()
            return
        cmd = line.strip().lower()
        if cmd == "1":
            dispatcher.gesture("single")
        elif cmd == "2":
            dispatcher.gesture("double")
        elif cmd == "3":
            dispatcher.gesture("triple")
        elif cmd == "a":
            dispatcher.hold_start()
        elif cmd == "r":
            dispatcher.hold_end()
        elif cmd == "s":
            print(json.dumps(dispatcher.status()))
        elif cmd == "q":
            return
        elif cmd:
            print("unknown command: %s" % cmd)


def main() -> None:
    global _server
    dispatcher = Dispatcher()
    engine = GestureEngine(
        on_single=lambda: dispatcher.gesture("single"),
        on_double=lambda: dispatcher.gesture("double"),
        on_triple=lambda: dispatcher.gesture("triple"),
        on_hold_start=dispatcher.hold_start,
        on_hold_end=dispatcher.hold_end,
        on_shutdown=safe_shutdown,
    )
    _server = boot(dispatcher)

    def _on_sigterm(signum, frame):
        if _server is not None:
            _server.close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _on_sigterm)
    try:
        if SIM:
            run_sim(dispatcher)
        else:
            run_hardware(engine)
    finally:
        _server.close()


if __name__ == "__main__":
    main()
