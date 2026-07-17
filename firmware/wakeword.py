"""Tier 3 wake word: openWakeWord listener ("hey Jarvis" by default).

Privacy: all wake-word audio is processed locally on the device. Frames are fed
straight into the openWakeWord model in RAM and discarded; nothing is ever
written to disk, and nothing is ever uploaded. Only after a local trigger does a
downstream action run.

Runtime shape: a daemon thread reads 16 kHz mono PCM from an arecord subprocess
in 80 ms frames and feeds each frame to openWakeWord (~15% CPU on the Zero 2 W).
When the score crosses the threshold it fires on_wake once, then holds a 3 s
refractory period before it can fire again. While another part of the system owns
the microphone (audio.capture_in_use()), inference pauses and the arecord
subprocess is released, then restarted when the mic is free again.
"""

import os
import subprocess
import sys
import threading
import time
from typing import Callable, Optional

import audio
import state

SIM = os.environ.get("VISIONARY_SIM") == "1"

FRAME_SAMPLES = 1280            # 80 ms at 16 kHz, openWakeWord's preferred chunk
_FRAME_BYTES = FRAME_SAMPLES * 2  # S16_LE mono
THRESHOLD = 0.5
REFRACTORY_S = 3.0

# openWakeWord's bundled pretrained trigger phrases (validates config names
# without importing the package just to answer available()).
_PRETRAINED = {"alexa", "hey_mycroft", "hey_jarvis", "hey_rhasspy", "timer", "weather"}

_lock = threading.Lock()
_thread = None       # type: Optional[threading.Thread]
_stop_event = None   # type: Optional[threading.Event]


def available() -> bool:
    if SIM:
        return False
    try:
        import openwakeword  # noqa: F401
    except ImportError:
        return False
    return _resolve_model() is not None


def start(on_wake: Callable[[], None]) -> bool:
    """Spawn the listener thread. False if unavailable (incl. SIM)."""
    if SIM:
        return False
    with _lock:
        global _thread, _stop_event
        if _thread is not None and _thread.is_alive():
            return True
        model = _load_model()
        if model is None:
            return False
        _stop_event = threading.Event()
        _thread = threading.Thread(
            target=_listen, args=(model, on_wake, _stop_event), daemon=True)
        _thread.start()
        return True


def stop() -> None:
    with _lock:
        global _thread, _stop_event
        thread, event = _thread, _stop_event
        _thread, _stop_event = None, None
    if event is not None:
        event.set()
    if thread is not None:
        thread.join(timeout=5)


def _resolve_model() -> Optional[str]:
    cfg = state.load_config()
    name = (cfg.get("wake_word") or {}).get("model") or "hey_jarvis"
    if os.path.exists(name):
        return name
    if name in _PRETRAINED:
        return name
    try:
        import openwakeword
        for path in openwakeword.get_pretrained_model_paths():
            if os.path.splitext(os.path.basename(path))[0] == name:
                return path
    except Exception:
        pass
    return None


def _load_model():
    try:
        from openwakeword.model import Model
    except ImportError:
        return None
    ref = _resolve_model()
    if ref is None:
        return None
    try:
        return Model(wakeword_models=[ref])
    except Exception as exc:
        print("wakeword: model load failed: %s" % exc, file=sys.stderr)
        return None


def _listen(model, on_wake, stop_event):
    try:
        import numpy as np
    except ImportError:
        _fail("Wake word needs numpy.")
        return
    device = os.environ.get("VISIONARY_ALSA_CAPTURE", "plughw:0,0")
    proc = None
    paused = False
    last_fire = None  # monotonic time of the last fire; None = never fired
    try:
        while not stop_event.is_set():
            if audio.capture_in_use():
                # Yield the mic to the active capture; resume once it's free.
                if proc is not None:
                    _stop_proc(proc)
                    proc = None
                    audio.listener_release_mic()
                paused = True
                stop_event.wait(0.2)
                continue
            if proc is None:
                if not audio.listener_acquire_mic():
                    # a capturer took the mic between checks; yield and retry
                    paused = True
                    stop_event.wait(0.2)
                    continue
                proc = _open_arecord(device)
                if proc is None:
                    audio.listener_release_mic()
                    _fail("Wake word microphone unavailable.")
                    return
                if paused:
                    model.reset()  # drop stale buffer from before the pause
                    paused = False
            data = proc.stdout.read(_FRAME_BYTES)
            if not data or len(data) < _FRAME_BYTES:
                _stop_proc(proc)  # arecord ended; restart on the next loop
                proc = None
                audio.listener_release_mic()
                continue
            scores = model.predict(np.frombuffer(data, dtype="<i2"))
            now = time.monotonic()
            if last_fire is not None and now - last_fire < REFRACTORY_S:
                continue
            if _triggered(scores):
                last_fire = now
                model.reset()
                # Release the mic BEFORE the (synchronous) wake action: it opens
                # its own capture on the single-opener I2S device. Reacquire and
                # resume on the next loop, once that capture has finished.
                _stop_proc(proc)
                proc = None
                audio.listener_release_mic()
                paused = True
                try:
                    on_wake()
                except Exception as exc:
                    print("wakeword: on_wake failed: %s" % exc, file=sys.stderr)
    finally:
        if proc is not None:
            _stop_proc(proc)
        audio.listener_release_mic()


def _triggered(scores) -> bool:
    try:
        return any(float(v) >= THRESHOLD for v in scores.values())
    except (AttributeError, TypeError, ValueError):
        return False


def _open_arecord(device):
    try:
        return subprocess.Popen(
            ["arecord", "-q", "-D", device, "-f", "S16_LE", "-r", "16000",
             "-c", "1", "-t", "raw"],
            stdout=subprocess.PIPE)
    except OSError as exc:
        print("wakeword: arecord failed: %s" % exc, file=sys.stderr)
        return None


def _stop_proc(proc) -> None:
    try:
        proc.terminate()
        proc.wait(timeout=2)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def _fail(msg: str) -> None:
    try:
        audio.beep("err")
        audio.speak(msg)
    except Exception:
        pass
