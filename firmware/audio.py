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
from collections import deque
from typing import Optional

import requests

import state

SIM = os.environ.get("VISIONARY_SIM") == "1"

CAPTURE_RATE = 48000
CAPTURE_CHANNELS = 2
CAPTURE_WIDTH = 4  # bytes/sample, S32_LE
TARGET_RATE = 16000

# The ICS-43434 is wired SEL -> GND, so its samples occupy the left (first)
# I2S slot.  Bench measurements on the glasses were approximately -51 dBFS
# speech / -57 dBFS room tone at the active slot.  Select that slot instead of
# averaging it with the empty right slot, then make the 16-bit STT WAV use its
# available range.  Each value remains an environment override for other mics.
_MIC_CHANNEL = 1          # one-based ALSA/SoX channel number
_MIC_GAIN_DB = 24.0       # fixed digital gain; SoX limits unexpected peaks
_MIC_HIGHPASS_HZ = 100.0  # remove frame/handling rumble, not speech

# Adaptive VAD works on 100 ms RMS readings from the selected raw I2S slot.  It
# only decides when a deliberately started capture is finished; it never gates
# or removes samples.  The margins are deliberately small because measured
# speech is only ~5.6 dB above room tone on the current frame.
_VAD_CALIBRATION_CHUNKS = 5
_VAD_EXPECTED_QUIET_DB = -55.0
_VAD_ONSET_MARGIN_DB = 3.0
_VAD_OFFSET_MARGIN_DB = 1.5
_VAD_AMBIGUOUS_MARGIN_DB = 2.0
_VAD_ONSET_CHUNKS = 3
_VAD_AMBIGUOUS_ONSET_CHUNKS = 5
_VAD_LOUD_CALIBRATION_MARGIN_DB = 0.0
_VAD_CALIBRATION_DROP_DB = 3.0
_VAD_CALIBRATION_DROP_CHUNKS = 2
_VAD_NO_SPEECH_S = 5.0

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


def _env_float(name: str, default: float, low: float, high: float) -> float:
    try:
        value = float(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        value = default
    return min(high, max(low, value))


def _mic_channel() -> int:
    try:
        value = int(os.environ.get("VISIONARY_MIC_CHANNEL", str(_MIC_CHANNEL)))
    except (TypeError, ValueError):
        value = _MIC_CHANNEL
    return min(CAPTURE_CHANNELS, max(1, value))


def _mic_gain_db() -> float:
    return _env_float("VISIONARY_MIC_GAIN_DB", _MIC_GAIN_DB, 0.0, 36.0)


def _mic_highpass_hz() -> float:
    return _env_float(
        "VISIONARY_MIC_HIGHPASS_HZ", _MIC_HIGHPASS_HZ, 0.0, 500.0)


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


def beep(name: str, wait: bool = False) -> None:
    # name in: capture | ok | err | offline | rec_start | rec_stop
    if SIM:
        print("[beep " + name + "]")
        return
    path = os.path.join(state.HOME, "sounds", name + ".wav")
    if os.path.exists(path):
        play(path, wait=wait)


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
    """Normalized RMS of only the configured live I2S channel."""
    full_scale = float(1 << (CAPTURE_WIDTH * 8 - 1))
    try:
        import numpy as np
    except ImportError:
        import audioop
        if CAPTURE_CHANNELS == 2:
            weights = ((1.0, 0.0) if _mic_channel() == 1 else (0.0, 1.0))
            data = audioop.tomono(data, CAPTURE_WIDTH, *weights)
        return audioop.rms(data, CAPTURE_WIDTH) / full_scale
    samples = np.frombuffer(data, dtype="<i4")
    usable = samples.size - (samples.size % CAPTURE_CHANNELS)
    samples = samples[:usable]
    if samples.size == 0:
        return 0.0
    samples = samples.reshape(-1, CAPTURE_CHANNELS)[:, _mic_channel() - 1]
    samples = samples.astype(np.float64)
    return float(np.sqrt(np.mean(samples * samples))) / full_scale


class _VadLevelMeter:
    """RMS meter for VAD after channel selection and the 100 Hz high-pass.

    The high-pass carries state between capture chunks.  Digital gain is not
    applied here because it shifts voice and noise by the same amount; the VAD
    works from their separation while the exported WAV receives the full gain.
    """

    def __init__(self) -> None:
        self._previous_x = 0.0
        self._previous_y = 0.0

    def level(self, data: bytes) -> float:
        import numpy as np

        samples = np.frombuffer(data, dtype="<i4")
        usable = samples.size - (samples.size % CAPTURE_CHANNELS)
        if usable == 0:
            return 0.0
        mono = samples[:usable].reshape(
            -1, CAPTURE_CHANNELS)[:, _mic_channel() - 1].astype(np.float64)
        mono /= float(1 << (CAPTURE_WIDTH * 8 - 1))

        # The I2S capture rate is an integer multiple of the transcription rate.
        # Averaging each group also reduces ultrasonic energy before decimation.
        decimation = CAPTURE_RATE // TARGET_RATE
        output_samples = (mono.size // decimation) * decimation
        if output_samples == 0:
            return 0.0
        mono = mono[:output_samples].reshape(-1, decimation).mean(axis=1)

        cutoff = _mic_highpass_hz()
        if cutoff > 0.0:
            alpha = 1.0 / (
                1.0 + (2.0 * 3.141592653589793 * cutoff / TARGET_RATE))
            filtered = np.empty_like(mono)
            previous_x = self._previous_x
            previous_y = self._previous_y
            for index, current_x in enumerate(mono):
                current_y = alpha * (previous_y + current_x - previous_x)
                filtered[index] = current_y
                previous_x = current_x
                previous_y = current_y
            self._previous_x = previous_x
            self._previous_y = previous_y
            mono = filtered

        if mono.size == 0:
            return 0.0
        return float(np.sqrt(np.mean(mono * mono)))


def _convert_raw(raw_path: str, wav_path: str) -> bool:
    """Process S32_LE/48k/stereo raw into an STT-ready mono 16k WAV."""
    command = [
        "sox", "-t", "raw", "-L", "-r", str(CAPTURE_RATE),
        "-e", "signed-integer",
        "-b", str(CAPTURE_WIDTH * 8), "-c", str(CAPTURE_CHANNELS), raw_path,
        "-r", str(TARGET_RATE), "-c", "1", "-b", "16", wav_path,
        "remix", str(_mic_channel()),
    ]
    cutoff = _mic_highpass_hz()
    if cutoff > 0.0:
        command.extend(["highpass", "%g" % cutoff])
    # Make the resampler explicit so peak limiting happens last.  The output
    # `-r` option above then describes the header instead of silently appending
    # another rate effect after the limiter.
    command.extend(["rate", "-v", str(TARGET_RATE)])
    command.extend(["gain", "-l", "%g" % _mic_gain_db()])
    # Leave a little final headroom for 16-bit quantization/dither after the
    # limiter.  The configured pre-limiter boost remains approximately +24 dB.
    command.extend(["gain", "-1"])
    try:
        res = subprocess.run(
            command,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if (res.returncode == 0 and os.path.exists(wav_path)
                and os.path.getsize(wav_path) > 0):
            return True
        detail = res.stderr or b""
        if isinstance(detail, bytes):
            detail = detail.decode("utf-8", "replace")
        detail = str(detail).strip()
        print(
            "audio: SoX conversion failed%s"
            % ((": " + detail[:300]) if detail else ""),
            file=sys.stderr,
        )
    except OSError as exc:
        print("audio: SoX conversion unavailable: %s" % exc, file=sys.stderr)
    return False


def _dbfs(level: float) -> float:
    if level <= 0.0:
        return -120.0
    # Avoid importing math in the hot capture module for one small operation.
    import math
    return max(-120.0, 20.0 * math.log10(level))


class _AdaptiveVad:
    """Noise-calibrated voice activity used only to end explicit captures.

    No samples are removed.  Calibration audio and ambiguous low-level audio
    remain in the WAV sent to transcription, which is safer for a marginal mic
    than an aggressive gate.
    """

    def __init__(self, chunk_s: float = 0.1, trailing_s: float = 1.5) -> None:
        self.chunk_s = chunk_s
        self.calibration = []
        self.noise_db = None  # type: Optional[float]
        self.peak_db = -120.0
        self.heard = False
        self.possible_speech = False
        self._onset_run = 0
        self._ambiguous_run = 0
        self._noise_history = deque(maxlen=20)
        self._loud_calibration = False
        self._calibration_baseline_db = -120.0
        self._calibration_drop_run = 0
        self._calibration_drop_levels = []
        self._chunks_seen = 0
        self._last_activity_chunk = None  # type: Optional[int]
        trailing_chunks = max(3, int(round(trailing_s / chunk_s)))
        self._trailing = deque(maxlen=trailing_chunks)
        self._trailing_quiet_needed = max(2, int(trailing_chunks * 0.8 + 0.5))

    @property
    def calibrated(self) -> bool:
        return self.noise_db is not None

    @property
    def onset_db(self) -> float:
        base = (self.noise_db if self.noise_db is not None
                else _VAD_EXPECTED_QUIET_DB)
        return base + _VAD_ONSET_MARGIN_DB

    @property
    def offset_db(self) -> float:
        base = (self.noise_db if self.noise_db is not None
                else _VAD_EXPECTED_QUIET_DB)
        return base + _VAD_OFFSET_MARGIN_DB

    @property
    def awaiting_calibration_drop(self) -> bool:
        """True while an initially loud baseline may be immediate speech.

        In this state the normal five-second no-speech timeout must not truncate
        the utterance.  A later drop back toward quiet confirms that the loud
        calibration was speech. At max_s, continuous callers discard a steady
        unresolved room while deliberate one-shot callers may preserve it.
        """
        return self._loud_calibration and not self.heard

    def no_speech_timed_out(self, captured_s: float, max_s: float) -> bool:
        """Whether a clearly quiet capture can end before its hard deadline."""
        recent_activity = (
            self._last_activity_chunk is not None
            and (self._chunks_seen - self._last_activity_chunk)
            < self._trailing.maxlen
        )
        return (
            self.calibrated
            and not self.heard
            and not self.awaiting_calibration_drop
            and not recent_activity
            and captured_s >= min(max_s, _VAD_NO_SPEECH_S)
        )

    def update(self, level: float):
        """Return `(speech_confirmed, trailing_silence_complete)`."""
        self._chunks_seen += 1
        level_db = _dbfs(level)
        self.peak_db = max(self.peak_db, level_db)

        if not self.calibrated:
            self.calibration.append(level_db)
            if len(self.calibration) < _VAD_CALIBRATION_CHUNKS:
                return False, False
            return self._finish_calibration(), False

        confirmed = self._classify(level_db)
        if not self.heard:
            return confirmed, False
        if self._loud_calibration:
            # The initial floor may itself be speech. Until a lower floor is
            # observed, never call that same level trailing silence and cut it.
            return confirmed, False

        onset = self.onset_db
        self._trailing.append((level_db < self.offset_db, level_db >= onset))
        if len(self._trailing) < self._trailing.maxlen:
            return confirmed, False
        quiet_count = sum(1 for quiet, _ in self._trailing if quiet)
        onset_flags = [above for _, above in self._trailing]
        sustained_voice = any(
            onset_flags[index - 1] and onset_flags[index]
            for index in range(1, len(onset_flags)))
        should_stop = (
            quiet_count >= self._trailing_quiet_needed and not sustained_voice)
        return confirmed, should_stop

    def finish(self, preserve_unresolved: bool = False) -> bool:
        """Finish calibration and report whether the whole capture is usable.

        Deliberate one-shot callers may preserve an unresolved loud calibration
        at the hard deadline. Continuous modes leave that false, preventing a
        steady loud room from becoming repeated cloud transcription requests.
        """
        if not self.calibrated and self.calibration:
            self._finish_calibration()
        return (
            self.heard
            or self.possible_speech
            or (preserve_unresolved and self.awaiting_calibration_drop)
        )

    def _finish_calibration(self) -> bool:
        quietest = sorted(self.calibration)[:min(3, len(self.calibration))]
        estimated = quietest[len(quietest) // 2]
        self.noise_db = estimated
        self._calibration_baseline_db = estimated
        self._noise_history.extend(quietest)
        loud_calibration = (
            estimated >= (_VAD_EXPECTED_QUIET_DB
                          + _VAD_LOUD_CALIBRATION_MARGIN_DB))
        confirmed = False
        for calibration_db in self.calibration:
            confirmed = self._classify(calibration_db) or confirmed
        # Set this after replaying calibration so low chunks within the initial
        # window cannot themselves look like the post-utterance drop.
        self._loud_calibration = loud_calibration
        return confirmed

    def _classify(self, level_db: float) -> bool:
        if self._loud_calibration:
            if level_db <= (
                    self._calibration_baseline_db - _VAD_CALIBRATION_DROP_DB):
                self._calibration_drop_run += 1
                self._calibration_drop_levels.append(level_db)
            else:
                self._calibration_drop_run = 0
                self._calibration_drop_levels = []
            if self._calibration_drop_run >= _VAD_CALIBRATION_DROP_CHUNKS:
                # Establish the real quiet floor from the drop. If speech began
                # during calibration, confirm it retroactively; every opening
                # sample is already retained in the raw capture.
                ordered = sorted(self._calibration_drop_levels)
                self.noise_db = ordered[len(ordered) // 2]
                self._noise_history.clear()
                self._noise_history.extend(ordered)
                if not self.heard:
                    self.heard = True
                    self.possible_speech = True
                self._loud_calibration = False
                return True

        onset = self.onset_db
        ambiguous = (self.noise_db if self.noise_db is not None
                     else _VAD_EXPECTED_QUIET_DB) + _VAD_AMBIGUOUS_MARGIN_DB
        if level_db >= ambiguous:
            self.possible_speech = True
            self._last_activity_chunk = self._chunks_seen

        if self.heard:
            return True

        self._onset_run = self._onset_run + 1 if level_db >= onset else 0
        self._ambiguous_run = (
            self._ambiguous_run + 1 if level_db >= ambiguous else 0)
        if (self._onset_run >= _VAD_ONSET_CHUNKS
                or self._ambiguous_run >= _VAD_AMBIGUOUS_ONSET_CHUNKS):
            self.heard = True
            return True

        # Adapt only before confirmed speech.  A rolling median rejects a
        # single dropout/handling gap, while the asymmetric step limits keep
        # quiet syllables from rapidly teaching the detector they are noise.
        if level_db < ambiguous and self.noise_db is not None:
            self._noise_history.append(level_db)
            ordered = sorted(self._noise_history)
            candidate = ordered[len(ordered) // 2]
            change = candidate - self.noise_db
            change = max(-0.5, min(0.1, change))
            self.noise_db += change
        return False


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
        # Acquire before opening so no other capture can bind the single-opener
        # I2S device (record_until_silence uses the same ownership lock).
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


def record_until_silence(
        max_s: float = 15.0, silence_s: float = 1.5,
        preserve_ambiguous: bool = True) -> Optional[str]:
    if SIM:
        return _sim_wav()
    chunk_s = 0.1
    chunk_bytes = int(_FRAME_BYTES * CAPTURE_RATE * chunk_s)
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
    vad = _AdaptiveVad(chunk_s=chunk_s, trailing_s=silence_s)
    level_meter = _VadLevelMeter()
    captured_s = 0.0
    deadline = time.monotonic() + max_s
    stop_reason = "deadline"
    try:
        while time.monotonic() < deadline:
            data = proc.stdout.read(chunk_bytes)
            if not data:
                stop_reason = "eof"
                break
            chunks.append(data)
            captured_s += len(data) / float(_FRAME_BYTES * CAPTURE_RATE)
            _, should_stop = vad.update(level_meter.level(data))
            if should_stop:
                stop_reason = "trailing-silence"
                break
            if vad.no_speech_timed_out(captured_s, max_s):
                stop_reason = "quiet-timeout"
                break
    finally:
        _stop_proc(proc)
        _release_capture()
    keep_capture = vad.finish(
        preserve_unresolved=(preserve_ambiguous and stop_reason == "deadline"))
    noise = vad.noise_db if vad.noise_db is not None else -120.0
    print(
        "audio: VAD noise=%.1f onset=%.1f peak=%.1f heard=%s ambiguous=%s"
        % (noise, vad.onset_db, vad.peak_db, vad.heard, vad.possible_speech),
        file=sys.stderr,
    )
    if not keep_capture:
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
