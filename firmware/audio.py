"""Audio out (Piper TTS via aplay, beeps) and audio in (ALSA capture)."""

import json
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
import wave
from typing import Optional

import state

SIM = os.environ.get("VISIONARY_SIM") == "1"

CAPTURE_RATE = 48000
CAPTURE_CHANNELS = 2
CAPTURE_WIDTH = 4  # bytes/sample, S32_LE
TARGET_RATE = 16000
SILENCE_THRESHOLD = 0.01  # RMS as fraction of full scale (~-40 dBFS)

_FRAME_BYTES = CAPTURE_CHANNELS * CAPTURE_WIDTH
_SENTENCE = re.compile(r"[^.!?\n]*[.!?\n]")
_WORD = re.compile(r"\w")


def _capture_device() -> str:
    return os.environ.get("VISIONARY_ALSA_CAPTURE", "plughw:0,0")


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


def _voice_sample_rate(model_path: str) -> int:
    # Piper voices ship as <voice>.onnx + <voice>.onnx.json.
    for cand in (model_path + ".json", os.path.splitext(model_path)[0] + ".json"):
        try:
            with open(cand) as f:
                sr = json.load(f).get("audio", {}).get("sample_rate")
            if sr:
                return int(sr)
        except (OSError, ValueError):
            continue
    return 16000


def _espeak(text: str, rate: float) -> None:
    try:
        subprocess.run(["espeak-ng", "-s", str(int(160 * rate)), text], check=False)
    except OSError as exc:
        print("audio: no TTS backend available: %s" % exc, file=sys.stderr)


def speak(text: str, wait: bool = True) -> None:
    text = text.strip()
    if not text:
        return
    if SIM:
        print("[speak] " + text)
        return
    cfg = state.load_config()
    rate = min(2.0, max(0.5, float(cfg.get("rate") or 1.0)))
    voice = cfg.get("voice") or "en_US-lessac-low"
    model = os.path.join(state.HOME, "voices", voice + ".onnx")
    if not os.path.exists(model):
        _espeak(text, rate)
        return
    try:
        piper = subprocess.Popen(
            ["piper", "--model", model, "--output-raw",
             "--length-scale", "%.3f" % (1.0 / rate)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        aplay = subprocess.Popen(
            ["aplay", "-q", "-r", str(_voice_sample_rate(model)),
             "-f", "S16_LE", "-t", "raw", "-"],
            stdin=piper.stdout)
        piper.stdout.close()
        piper.stdin.write(text.encode("utf-8"))
        piper.stdin.close()
    except OSError:
        _espeak(text, rate)
        return
    if wait:
        aplay.wait()
        if piper.wait() != 0 or aplay.returncode != 0:
            _espeak(text, rate)


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
    fixture = os.environ.get("VISIONARY_SIM_WAV")
    if fixture and os.path.exists(fixture):
        return fixture
    fd, path = tempfile.mkstemp(suffix=".wav", prefix="visionary_sim_")
    os.close(fd)
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
            return
        rec_dir = os.path.join(state.HOME, "recordings")
        os.makedirs(rec_dir, exist_ok=True)
        # Raw (headerless) so a killed arecord can't leave a broken WAV header;
        # on the SD card, not /tmp, to spare RAM if /tmp is tmpfs.
        raw = os.path.join(rec_dir, ".rec_%d_%d.raw" % (os.getpid(), int(time.time())))
        try:
            self._proc = subprocess.Popen(
                ["arecord", "-q", "-D", _capture_device(), "-f", "S32_LE",
                 "-r", str(CAPTURE_RATE), "-c", str(CAPTURE_CHANNELS),
                 "-t", "raw", raw])
        except OSError as exc:
            raise RuntimeError("microphone unavailable: %s" % exc)
        self._raw_path = raw
        self.recording = True

    def stop(self) -> str:
        self.recording = False
        if SIM:
            return _sim_wav()
        proc, raw_path = self._proc, self._raw_path
        self._proc = None
        self._raw_path = None
        if proc is not None:
            _stop_proc(proc)
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
    try:
        proc = subprocess.Popen(
            ["arecord", "-q", "-D", _capture_device(), "-f", "S32_LE",
             "-r", str(CAPTURE_RATE), "-c", str(CAPTURE_CHANNELS), "-t", "raw"],
            stdout=subprocess.PIPE)
    except OSError as exc:
        print("audio: arecord failed: %s" % exc, file=sys.stderr)
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
