"""Audio out (OpenAI TTS + ALSA), beeps, and ALSA microphone capture."""

import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import wave
from typing import Optional

import requests

import state

SIM = os.environ.get("VISIONARY_SIM") == "1"

CAPTURE_RATE = 48000
CAPTURE_CHANNELS = 2
CAPTURE_WIDTH = 4  # bytes/sample, S32_LE
TARGET_RATE = 16000
SILENCE_THRESHOLD = 0.01  # RMS as fraction of full scale (~-40 dBFS)

_TTS_URL = "https://api.openai.com/v1/audio/speech"
_TTS_MODEL = "gpt-4o-mini-tts-2025-12-15"
_TTS_VOICE = "marin"
# Stay below both the endpoint's 4096-character cap and the model's 2000-token
# input window, including for languages that tokenize more densely than English.
_TTS_MAX_CHARS = 1800
_OPENAI_VOICES = frozenset((
    "alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx",
    "sage", "shimmer", "verse", "marin", "cedar",
))

_FRAME_BYTES = CAPTURE_CHANNELS * CAPTURE_WIDTH
_SENTENCE = re.compile(r"[^.!?\n]*[.!?\n]")
_WORD = re.compile(r"\w")


def _capture_device() -> str:
    return os.environ.get("VISIONARY_ALSA_CAPTURE", "plughw:0,0")


# ---------------- mic ownership ----------------
# The I2S capture device is single-opener (plughw, no dsnoop), so Recorder and
# short utterance capture serialize their arecord processes under this lock.
_capture_lock = threading.Lock()
_capture_users = 0
_capture_open = False
_capture_released = threading.Condition(_capture_lock)
_speech_lock = threading.Lock()


def _acquire_capture() -> None:
    global _capture_users, _capture_open
    with _capture_lock:
        _capture_users += 1
        while _capture_open:
            _capture_released.wait()
        _capture_open = True


def _release_capture() -> None:
    global _capture_users, _capture_open
    with _capture_lock:
        if _capture_users > 0:
            _capture_users -= 1
        _capture_open = False
        _capture_released.notify_all()


def capture_in_use() -> bool:
    with _capture_lock:
        return _capture_users > 0


# ---------------- playback ----------------

def play(path: str, wait: bool = False) -> None:
    if SIM:
        print("[play] " + path)
        return
    cmd = ["aplay", "-q", path]
    try:
        if wait:
            subprocess.run(cmd, check=False)
        else:
            subprocess.Popen(cmd)
    except OSError as exc:
        print("audio: aplay failed: %s" % exc, file=sys.stderr)


def beep(name: str) -> None:
    # name in: capture | ok | err | offline | rec_start | rec_stop
    if SIM:
        print("[beep " + name + "]")
        return
    path = os.path.join(state.HOME, "sounds", name + ".wav")
    if os.path.exists(path):
        play(path)


def _tts_chunks(text: str):
    """Split direct /speak calls below the Audio API's input limit."""
    rest = text.strip()
    while rest:
        if len(rest) <= _TTS_MAX_CHARS:
            yield rest
            return
        cut = rest.rfind(" ", 0, _TTS_MAX_CHARS + 1)
        if cut < _TTS_MAX_CHARS // 2:
            cut = _TTS_MAX_CHARS
        yield rest[:cut].strip()
        rest = rest[cut:].strip()


def _response_error(resp) -> str:
    try:
        return resp.json()["error"]["message"]
    except Exception:
        return (getattr(resp, "text", "") or "").strip()[:300]


def _speak_openai(text: str, rate: float, voice: str) -> None:
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key or key == "PUT_YOUR_KEY_HERE":
        raise RuntimeError("OPENAI_API_KEY is not configured")

    model = os.environ.get("VISIONARY_TTS_MODEL", _TTS_MODEL).strip() or _TTS_MODEL
    configured_voice = os.environ.get("VISIONARY_TTS_VOICE", "").strip() or voice
    if configured_voice not in _OPENAI_VOICES:
        configured_voice = _TTS_VOICE  # migrate unsupported legacy voice ids

    for chunk in _tts_chunks(text):
        try:
            resp = requests.post(
                _TTS_URL,
                headers={
                    "Authorization": "Bearer " + key,
                    "Content-Type": "application/json",
                },
                json={
                    "model": model,
                    "voice": configured_voice,
                    "input": chunk,
                    "response_format": "wav",
                    "speed": rate,
                },
                timeout=(5, 30),
            )
        except requests.exceptions.RequestException as exc:
            raise RuntimeError("OpenAI speech request failed: %s" % exc)
        if resp.status_code != 200:
            raise RuntimeError(
                "OpenAI speech API error %s: %s"
                % (resp.status_code, _response_error(resp))
            )
        try:
            played = subprocess.run(
                ["aplay", "-q", "-"], input=resp.content, check=False)
        except OSError as exc:
            raise RuntimeError("aplay failed: %s" % exc)
        if played.returncode != 0:
            raise RuntimeError("aplay exited %d" % played.returncode)


def speak(text: str, wait: bool = True) -> None:
    text = text.strip()
    if not text:
        return
    if SIM:
        print("[speak] " + text)
        return
    cfg = state.load_config()
    rate = min(2.0, max(0.5, float(cfg.get("rate") or 1.0)))
    voice = str(cfg.get("voice") or _TTS_VOICE)

    def run() -> None:
        try:
            with _speech_lock:
                _speak_openai(text, rate, voice)
        except Exception as exc:
            # Preserve the old speak() contract: audio failures are audible/logged,
            # but never crash the button dispatcher or boot loop.
            print("audio: speech failed: %s" % exc, file=sys.stderr)
            beep("err")

    if wait:
        run()
    else:
        threading.Thread(target=run, daemon=True).start()


class SentenceSpeaker:
    """Streaming TTS: speaks each completed sentence, in order, off a worker
    thread so speech overlaps with model streaming."""

    def __init__(self) -> None:
        self.first_audio_ts = None  # type: Optional[float]
        self._buf = ""
        self._queue = queue.Queue()  # type: queue.Queue
        self._closed = False
        self._thread = threading.Thread(target=self._worker, daemon=True)
        self._thread.start()

    def feed(self, chunk: str) -> None:
        self._buf += chunk
        while True:
            m = _SENTENCE.match(self._buf)
            if not m:
                break
            self._buf = self._buf[m.end():]
            self._enqueue(m.group(0))

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._enqueue(self._buf)
        self._buf = ""
        self._queue.put(None)
        self._thread.join()

    def _enqueue(self, text: str) -> None:
        text = text.strip()
        if text and _WORD.search(text):  # skip bare punctuation fragments
            self._queue.put(text)

    def _worker(self) -> None:
        while True:
            item = self._queue.get()
            if item is None:
                return
            if self.first_audio_ts is None:
                self.first_audio_ts = time.monotonic()
            try:
                speak(item, wait=True)
            except Exception as exc:  # keep draining; close() must not hang
                print("audio: speak failed: %s" % exc, file=sys.stderr)


# ---------------- capture ----------------

def _write_wav(path: str, frames: bytes, rate: int = TARGET_RATE) -> None:
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(frames)


def _sim_wav() -> str:
    fd, path = tempfile.mkstemp(suffix=".wav", prefix="visionary_sim_")
    os.close(fd)
    fixture = os.environ.get("VISIONARY_SIM_WAV")
    if fixture and os.path.exists(fixture):
        # Copy, never hand back the fixture itself: callers delete/move the wav.
        shutil.copyfile(fixture, path)
    else:
        _write_wav(path, b"\x00\x00" * TARGET_RATE)  # 1s of 16k mono silence
    return path


def _rms_level(data: bytes) -> float:
    full_scale = float(1 << (CAPTURE_WIDTH * 8 - 1))
    try:
        import numpy as np
    except ImportError:
        import audioop
        return audioop.rms(data, CAPTURE_WIDTH) / full_scale
    samples = np.frombuffer(data, dtype="<i4").astype(np.float64)
    if samples.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(samples * samples))) / full_scale


def _numpy_downmix(buf: bytes) -> bytes:
    import numpy as np
    samples = np.frombuffer(buf, dtype="<i4").reshape(-1, CAPTURE_CHANNELS)
    mono = samples.mean(axis=1)
    decim = CAPTURE_RATE // TARGET_RATE
    mono = mono[: (mono.size // decim) * decim].reshape(-1, decim).mean(axis=1)
    return (mono / 65536.0).astype("<i2").tobytes()


def _convert_raw_py(raw_path: str, wav_path: str) -> bool:
    try:
        import audioop
    except ImportError:
        audioop = None
    # Chunked so a long recording never sits in RAM (512MB budget).
    chunk = _FRAME_BYTES * CAPTURE_RATE
    try:
        with open(raw_path, "rb") as src, wave.open(wav_path, "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(TARGET_RATE)
            ratecv_state = None
            pending = b""
            while True:
                buf = src.read(chunk)
                if not buf:
                    break
                buf = pending + buf
                usable = len(buf) - len(buf) % (_FRAME_BYTES * 3)
                pending = buf[usable:]
                buf = buf[:usable]
                if not buf:
                    continue
                if audioop is not None:
                    mono = audioop.tomono(buf, CAPTURE_WIDTH, 0.5, 0.5)
                    mono16 = audioop.lin2lin(mono, CAPTURE_WIDTH, 2)
                    conv, ratecv_state = audioop.ratecv(
                        mono16, 2, 1, CAPTURE_RATE, TARGET_RATE, ratecv_state)
                else:
                    conv = _numpy_downmix(buf)
                out.writeframes(conv)
        return True
    except Exception as exc:
        print("audio: wav conversion failed: %s" % exc, file=sys.stderr)
        return False


def _convert_raw(raw_path: str, wav_path: str) -> bool:
    """S32_LE/48k/stereo raw -> 16k mono 16-bit WAV. sox, then pure python."""
    try:
        res = subprocess.run(
            ["sox", "-t", "raw", "-r", str(CAPTURE_RATE), "-e", "signed",
             "-b", str(CAPTURE_WIDTH * 8), "-c", str(CAPTURE_CHANNELS), raw_path,
             "-r", str(TARGET_RATE), "-c", "1", "-b", "16", wav_path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode == 0 and os.path.exists(wav_path):
            return True
    except OSError:
        pass
    return _convert_raw_py(raw_path, wav_path)


def _stop_proc(proc: "subprocess.Popen") -> None:
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


class Recorder:
    def __init__(self) -> None:
        self.recording = False
        self._proc = None  # type: Optional[subprocess.Popen]
        self._raw_path = None  # type: Optional[str]

    def start(self) -> None:
        if self.recording:
            return
        if SIM:
            self.recording = True
            _acquire_capture()
            return
        rec_dir = os.path.join(state.HOME, "recordings")
        os.makedirs(rec_dir, exist_ok=True)
        # Raw (headerless) so a killed arecord can't leave a broken WAV header;
        # on the SD card, not /tmp, to spare RAM if /tmp is tmpfs.
        raw = os.path.join(rec_dir, ".rec_%d_%d.raw" % (os.getpid(), int(time.time())))
        # Acquire before opening: the wake listener must release the single-opener
        # I2S device before arecord can bind it (record_until_silence does the same).
        _acquire_capture()
        try:
            self._proc = subprocess.Popen(
                ["arecord", "-q", "-D", _capture_device(), "-f", "S32_LE",
                 "-r", str(CAPTURE_RATE), "-c", str(CAPTURE_CHANNELS),
                 "-t", "raw", raw])
        except OSError as exc:
            _release_capture()
            raise RuntimeError("microphone unavailable: %s" % exc)
        self._raw_path = raw
        self.recording = True

    def stop(self) -> str:
        was_recording = self.recording
        self.recording = False
        if SIM:
            if was_recording:
                _release_capture()
            return _sim_wav()
        proc, raw_path = self._proc, self._raw_path
        self._proc = None
        self._raw_path = None
        try:
            if proc is not None:
                _stop_proc(proc)
        finally:
            # Keep ownership until arecord has actually closed the single-opener
            # I2S device; otherwise a waiting capture can race into EBUSY.
            if was_recording:
                _release_capture()
        rec_dir = os.path.join(state.HOME, "recordings")
        os.makedirs(rec_dir, exist_ok=True)
        out = os.path.join(rec_dir, "rec_%d.wav" % int(time.time()))
        try:
            if raw_path is None or not _convert_raw(raw_path, out):
                _write_wav(out, b"")  # valid empty wav; STT failure speaks downstream
        finally:
            if raw_path and os.path.exists(raw_path):
                os.remove(raw_path)
        return out


def record_until_silence(max_s: float = 15.0, silence_s: float = 1.2) -> Optional[str]:
    if SIM:
        return _sim_wav()
    chunk_bytes = _FRAME_BYTES * CAPTURE_RATE // 10  # 100ms
    _acquire_capture()
    try:
        proc = subprocess.Popen(
            ["arecord", "-q", "-D", _capture_device(), "-f", "S32_LE",
             "-r", str(CAPTURE_RATE), "-c", str(CAPTURE_CHANNELS), "-t", "raw"],
            stdout=subprocess.PIPE)
    except OSError as exc:
        print("audio: arecord failed: %s" % exc, file=sys.stderr)
        _release_capture()
        return None
    chunks = []
    heard = False
    quiet_s = 0.0
    deadline = time.monotonic() + max_s
    try:
        while time.monotonic() < deadline:
            data = proc.stdout.read(chunk_bytes)
            if not data:
                break
            chunks.append(data)
            if _rms_level(data) >= SILENCE_THRESHOLD:
                heard = True
                quiet_s = 0.0
            else:
                quiet_s += len(data) / float(_FRAME_BYTES * CAPTURE_RATE)
                if quiet_s >= silence_s:
                    break
    finally:
        _stop_proc(proc)
        _release_capture()
    if not heard:
        return None
    fd, raw_path = tempfile.mkstemp(suffix=".raw", prefix="visionary_utt_")
    with os.fdopen(fd, "wb") as f:
        for c in chunks:
            f.write(c)
    fd, wav_path = tempfile.mkstemp(suffix=".wav", prefix="visionary_utt_")
    os.close(fd)
    ok = _convert_raw(raw_path, wav_path)
    os.remove(raw_path)
    if not ok:
        os.remove(wav_path)
        return None
    return wav_path
