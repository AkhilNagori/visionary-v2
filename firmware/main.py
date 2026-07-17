#!/usr/bin/env python3
"""Visionary firmware entrypoint: gesture engine, action dispatcher, UDS
command server, boot sequence, and the Tier 3 background lifecycle.

Hardware mode drives a GPIO button; SIM mode (VISIONARY_SIM=1) drives
everything from a stdin REPL. A slow config watcher keeps the background
threads (two-way interpreter, navigation assist, wake-word listener) in
sync with config.json and opportunistically reindexes visual memory."""

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
import events
import memory
import packs
import state
import vision
import wakeword
from modes import ask, describe, navigate, read, recorder, session, translate

SIM = os.environ.get("VISIONARY_SIM") == "1"
BUTTON_PIN = 17
CONFIG_POLL_S = 5.0
REINDEX_INTERVAL_S = 60.0
_BOOT_TS = time.monotonic()
_server = None  # type: Optional["CommandServer"]
_dispatcher = None  # type: Optional["Dispatcher"]


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


class LoopManager:
    """A config-gated background loop: two-way translate or navigation assist.

    The loop runs on a daemon thread while its config section's `enabled` flag
    is set. reconcile() starts/stops it to match config. stop() is the single-
    press stop: it signals the loop AND persists the flag off so the watcher
    won't respawn it, with immediate audible feedback. shutdown() only signals
    the loop (process teardown, no config write, no speech).
    """

    def __init__(self, config_key: str,
                 target: Callable[[threading.Event], None],
                 off_message: str, error_message: str) -> None:
        self._key = config_key
        self._target = target
        self._off_message = off_message
        self._error_message = error_message
        self._lock = threading.Lock()
        self._thread = None  # type: Optional[threading.Thread]
        self._stop = None  # type: Optional[threading.Event]
        self._shutdown = False  # process teardown: suppress auto-restart

    def _enabled(self) -> bool:
        return bool((state.load_config().get(self._key) or {}).get("enabled"))

    def reconcile(self) -> None:
        enabled = self._enabled()
        with self._lock:
            alive = self._thread is not None and self._thread.is_alive()
            if enabled and not alive:
                stop = threading.Event()
                self._stop = stop
                self._thread = threading.Thread(
                    target=self._run, args=(stop,), daemon=True)
                self._thread.start()
            elif not enabled and alive and self._stop is not None:
                self._stop.set()

    def active(self) -> bool:
        with self._lock:
            return (self._thread is not None and self._thread.is_alive()
                    and self._stop is not None and not self._stop.is_set())

    def stop(self) -> None:
        with self._lock:
            if self._stop is not None:
                self._stop.set()
        # persist, or the watcher would respawn the loop within ~5s
        self._persist_disable()
        audio.beep("ok")
        audio.speak(self._off_message)

    def _persist_disable(self) -> None:
        cfg = state.load_config()
        section = cfg.get(self._key) or {}
        if section.get("enabled"):
            section["enabled"] = False
            cfg[self._key] = section
            state.save_config(cfg)

    def shutdown(self) -> None:
        with self._lock:
            self._shutdown = True
            if self._stop is not None:
                self._stop.set()

    def _run(self, stop: threading.Event) -> None:
        try:
            self._target(stop)
        except brain.BrainOffline:
            # the loop hit a hard offline wall and already spoke; clear the config
            # flag so the ~5s watcher won't immediately respawn it into a thrash.
            self._persist_disable()
        except Exception:
            # daemon-thread top level: a crash must never be silent
            audio.beep("err")
            audio.speak(self._error_message)
        finally:
            restart = False
            with self._lock:
                if self._thread is threading.current_thread():
                    self._thread = None
                    self._stop = None
                    # a fast off->on toggle can re-enable us while we were still
                    # draining; come straight back up rather than stranding config
                    # enabled with no live thread until the next watcher poll.
                    restart = not self._shutdown and self._enabled()
            if restart:
                self.reconcile()


class ActiveModeManager:
    """Owns the background thread for an `active_mode` whose pipeline is `loop`
    or `session`.

    see/ask/listen active modes run inline from a single press (packs.run_mode);
    the two background pipelines need a stop_event and single-press stopping just
    like the two-way interpreter and navigation assist, so main.py owns them
    here, reconciled against config `active_mode`. A single press stops a running
    background mode and clears active_mode. On a hard offline wall the mode
    raises brain.BrainOffline; when a session ends on its own (stop word / turn
    cap) or a loop exits, we clear active_mode so the watcher won't respawn it —
    the device returns to classic read (same convention as translate/navigate)."""

    _BG_PIPELINES = ("loop", "session")

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._thread = None  # type: Optional[threading.Thread]
        self._stop = None  # type: Optional[threading.Event]
        self._mode_id = None  # type: Optional[str]
        self._shutdown = False

    def _desired(self) -> Optional[dict]:
        mode_id = state.load_config().get("active_mode")
        if not mode_id:
            return None  # common case (classic read): never touches the pack files
        try:
            mode = packs.load_modes().get(mode_id)
        except Exception:
            return None
        if mode and mode.get("pipeline") in self._BG_PIPELINES:
            return mode
        return None

    def reconcile(self) -> None:
        mode = self._desired()
        with self._lock:
            alive = self._thread is not None and self._thread.is_alive()
            if mode is None:
                if alive and self._stop is not None:
                    self._stop.set()
                return
            if alive and self._mode_id == mode["id"]:
                return  # the right background mode is already running
            if alive:
                # active_mode switched to a different background mode; stop the
                # old thread now, the next reconcile brings up the new one.
                if self._stop is not None:
                    self._stop.set()
                return
            stop = threading.Event()
            self._stop = stop
            self._mode_id = mode["id"]
            self._thread = threading.Thread(
                target=self._run, args=(stop, mode), daemon=True)
            self._thread.start()

    def active(self) -> bool:
        with self._lock:
            return (self._thread is not None and self._thread.is_alive()
                    and self._stop is not None and not self._stop.is_set())

    def stop(self) -> None:
        with self._lock:
            if self._stop is not None:
                self._stop.set()
            mode_id = self._mode_id
        # persist active_mode off, or the watcher would respawn it within ~5s
        self._clear_active_mode(mode_id)
        audio.beep("ok")

    def shutdown(self) -> None:
        with self._lock:
            self._shutdown = True
            if self._stop is not None:
                self._stop.set()

    def _clear_active_mode(self, mode_id: Optional[str]) -> None:
        cfg = state.load_config()
        # only clear if it still points at the mode we were running (a concurrent
        # API activation of a different mode must not be stomped)
        if cfg.get("active_mode") is not None and (
                mode_id is None or cfg.get("active_mode") == mode_id):
            cfg["active_mode"] = None
            state.save_config(cfg)

    def _run(self, stop: threading.Event, mode: dict) -> None:
        try:
            if mode.get("pipeline") == "session":
                session.run_session(mode, stop)
            else:
                packs.run_loop(mode, stop)
        except brain.BrainOffline:
            pass  # the mode already spoke its offline reason; cleared below
        except Exception:
            audio.beep("err")
            audio.speak("That mode stopped after an error.")
        finally:
            with self._lock:
                current = self._thread is threading.current_thread()
                shutting = self._shutdown
            # clear BEFORE nulling the thread so a watcher tick in this window
            # sees active_mode gone and won't respawn the mode we just finished
            if current and not shutting:
                self._clear_active_mode(mode.get("id"))
            with self._lock:
                if self._thread is threading.current_thread():
                    self._thread = None
                    self._stop = None
                    self._mode_id = None


class WakeWordManager:
    """Reconciles the openWakeWord listener with config wake_word.enabled."""

    def __init__(self, on_wake: Callable[[], None]) -> None:
        self._on_wake = on_wake
        self._lock = threading.Lock()
        self._started = False

    def reconcile(self) -> None:
        enabled = bool((state.load_config().get("wake_word") or {}).get("enabled"))
        with self._lock:
            if enabled and not self._started:
                self._started = wakeword.start(self._on_wake)
            elif not enabled and self._started:
                wakeword.stop()
                self._started = False

    def stop(self) -> None:
        with self._lock:
            if self._started:
                wakeword.stop()
                self._started = False


class Dispatcher:
    """Routes gestures and UDS captures to mode actions on daemon threads and
    owns the Tier 3 background lifecycle (loops, wake word, memory reindex)."""

    def __init__(self) -> None:
        self.busy = threading.Lock()
        self._hold_active = False
        self._translate = LoopManager(
            "two_way", translate.run_two_way,
            "Interpreter off.", "The interpreter stopped.")
        self._navigate = LoopManager(
            "navigation", navigate.run_navigation,
            "Navigation assist off.", "Navigation assist stopped.")
        self._active_mode = ActiveModeManager()
        # every config-reconciled background activity; single-press stops any of
        # them and each is torn down on shutdown
        self._managers = [self._translate, self._navigate, self._active_mode]
        self._wake = WakeWordManager(self._on_wake)
        self._watch_stop = threading.Event()
        self._watch_thread = None  # type: Optional[threading.Thread]
        self._last_reindex = 0.0

    # -- gesture entry points -------------------------------------------

    def gesture(self, kind: str) -> None:
        active_before = self._any_loop_active()
        self.reconcile()
        active_after = self._any_loop_active()

        cfg = state.load_config()
        mode = (cfg.get("gestures") or {}).get(kind)

        # recorder-stop is honored even while an action holds the busy lock
        if recorder.is_recording():
            if mode == "recorder":
                self._spawn(recorder.toggle, blocking=True)
            return

        # a single press stops an active background loop/session instead of reading
        if kind == "single" and active_before and active_after:
            self.stop_active_loops()
            return

        if self.busy.locked():
            return

        feats = cfg.get("features") or {}
        # v3: an explicit "mode:<id>" gesture mapping runs that mode pack
        if isinstance(mode, str) and mode.startswith("mode:"):
            self._dispatch_mode(mode[len("mode:"):])
            return
        # v3: a single press runs the configured active_mode instead of classic read
        active_mode = cfg.get("active_mode")
        if kind == "single" and active_mode:
            self._dispatch_mode(active_mode)
            return
        if not mode:
            return
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
        self.reconcile()
        if recorder.is_recording() or self._any_loop_active():
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
        self.reconcile()
        if mode == "recorder" and recorder.is_recording():
            self._spawn(recorder.toggle, blocking=True)
            return True, None
        if (recorder.is_recording() or self._any_loop_active()
                or self.busy.locked()):
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

    def listen(self, max_s: float) -> dict:
        """Synchronous record-until-silence + transcribe for POST /listen.

        Holds the busy lock across the capture so it can't race a gesture
        action; refuses (like capture) whenever the mic is already in use."""
        self.reconcile()
        if (recorder.is_recording() or self._any_loop_active()
                or audio.capture_in_use() or not self.busy.acquire(False)):
            return {"ok": False, "error": "busy"}
        wav = None
        try:
            wav = audio.record_until_silence(max_s=float(max_s))
            text = brain.transcribe(wav) if wav else ""
            return {"ok": True, "text": text}
        except brain.BrainOffline:
            audio.beep("err")
            audio.speak("I can't understand speech right now.")
            return {"ok": False, "error": "offline"}
        except Exception as e:
            audio.beep("err")
            audio.speak("Something went wrong.")
            return {"ok": False, "error": str(e) or "listen failed"}
        finally:
            if wav is not None and os.path.exists(wav):
                try:
                    os.remove(wav)
                except OSError:
                    pass
            self.busy.release()

    def status(self) -> dict:
        return {
            "ok": True,
            "online": brain.is_online(),
            "busy": self.busy.locked(),
            "uptime": round(time.monotonic() - _BOOT_TS, 1),
            "recording": recorder.is_recording(),
        }

    # -- Tier 3 background lifecycle -------------------------------------

    def reconcile(self) -> None:
        """Bring background threads in line with config. Idempotent; called on
        every dispatch and by the ~5s watcher."""
        for manager in self._managers:
            manager.reconcile()
        self._wake.reconcile()

    def start_watcher(self) -> None:
        self._watch_thread = threading.Thread(target=self._watch, daemon=True)
        self._watch_thread.start()

    def cleanup(self) -> None:
        self._watch_stop.set()
        self._wake.stop()
        for manager in self._managers:
            manager.shutdown()

    def stop_active_loops(self) -> None:
        for manager in self._managers:
            if manager.active():
                manager.stop()

    def _any_loop_active(self) -> bool:
        return any(manager.active() for manager in self._managers)

    def _watch(self) -> None:
        while not self._watch_stop.wait(CONFIG_POLL_S):
            try:
                self.reconcile()
            except Exception as e:
                print("config watch error: %s" % e, file=sys.stderr)
            self._maybe_reindex()

    def _maybe_reindex(self) -> None:
        now = time.monotonic()
        if now - self._last_reindex < REINDEX_INTERVAL_S:
            return
        try:
            if brain.is_online():
                memory.reindex_pending()
                self._last_reindex = now
        except Exception:
            pass

    def _on_wake(self) -> None:
        # busy-respecting wrapper: run the wake-triggered ask only when idle
        if not self.busy.acquire(False):
            return
        try:
            ask.ask_from_wake()
        except Exception:
            audio.beep("err")
            audio.speak("Something went wrong.")
        finally:
            self.busy.release()

    # -- v3 mode dispatch -------------------------------------------------

    def _dispatch_mode(self, mode_id: str) -> None:
        """Run a mode pack by id on a busy-locked worker. see/ask/listen run
        inline (packs.run_mode); loop/session raise ModeNeeds* and become a
        reconciled background activity owned by ActiveModeManager."""
        def worker() -> None:
            if not self.busy.acquire(False):
                return
            try:
                packs.run_mode(mode_id)
            except (packs.ModeNeedsLoop, packs.ModeNeedsSession) as need:
                self._activate_background(need.mode)
            except Exception:
                audio.beep("err")
                audio.speak("Something went wrong.")
            finally:
                self.busy.release()

        threading.Thread(target=worker, daemon=True).start()

    def _activate_background(self, mode: dict) -> None:
        # loop/session modes run as a config-reconciled background activity keyed
        # on active_mode (single-press stop + offline clearing live in the
        # ActiveModeManager). Persist it if a gesture launched it, then reconcile.
        cfg = state.load_config()
        if cfg.get("active_mode") != mode.get("id"):
            cfg["active_mode"] = mode["id"]
            state.save_config(cfg)
        self._active_mode.reconcile()

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
        if cmd == "listen":
            return self.dispatcher.listen(req.get("max_s", 15.0))
        if cmd == "events":
            seq, evs = events.get_since(req.get("since", 0))
            return {"ok": True, "seq": seq, "events": evs}
        if cmd == "timers":
            # timers are in-RAM threading.Timers that fire in THIS (main) process;
            # the api process reaches them only over UDS (like listen/events).
            import timers
            return {"ok": True, "timers": timers.list_timers()}
        return {"ok": False, "error": "unknown command"}


def boot(dispatcher: Dispatcher) -> CommandServer:
    state.ensure_dirs()
    first_boot = not os.path.exists(os.path.join(state.HOME, "token"))
    token = state.get_token()
    if first_boot:
        # comma-join spells the six digits out one at a time
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
    dispatcher.reconcile()
    dispatcher.start_watcher()
    audio.speak("Visionary ready."
                + ("" if brain.is_online() else " Offline mode."), wait=True)
    return server


def safe_shutdown() -> None:
    audio.speak("Shutting down. Goodbye.", wait=True)
    _cleanup()
    if SIM:
        print("[sim] sudo shutdown -h now")
    else:
        subprocess.run(["sudo", "shutdown", "-h", "now"], check=False)


def _cleanup() -> None:
    if _dispatcher is not None:
        _dispatcher.cleanup()
    if _server is not None:
        _server.close()


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
    global _server, _dispatcher
    dispatcher = Dispatcher()
    _dispatcher = dispatcher
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
        _cleanup()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _on_sigterm)
    try:
        if SIM:
            run_sim(dispatcher)
        else:
            run_hardware(engine)
    finally:
        _cleanup()


if __name__ == "__main__":
    main()
