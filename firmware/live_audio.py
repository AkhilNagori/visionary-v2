"""Bounded, streaming ALSA audio for GPT-Live on the shared 48 kHz I2S bus.

The wire format is 24 kHz mono PCM16. Hardware capture and playback both run at
48 kHz so the MAX98357A and ICS-43434 can share their clock. Echo protection is
deliberately a playback-only microphone mute, not a voice/noise gate or AEC.
Disable it only with acoustic isolation or external echo cancellation.
"""

import math
import os
import queue
import subprocess
import threading
import time
from typing import Optional

import numpy as np


RATE = 24000
HARDWARE_RATE = 48000
CHUNK_BYTES = 960  # 20 ms, mono signed 16-bit little endian
_CAPTURE_QUEUE_CHUNKS = 400  # 8 s: bounded headroom for a <=5 s photo upload
_PLAYBACK_QUEUE_CHUNKS = 100
_ECHO_TAIL_S = 0.20
_PLAYBACK_LATENCY_S = 0.08
_AUDIBLE_RMS = 100.0  # roughly -50 dBFS on the *output*, never the microphone


def _number(name: str, default: float, low: float, high: float) -> float:
    try:
        value = float(os.environ.get(name, default))
    except (TypeError, ValueError):
        value = default
    if not math.isfinite(value):
        value = default
    return max(low, min(high, value))


def capture_commands():
    """Return the two process argument lists; no shell interpolation."""
    channel = int(_number("VISIONARY_MIC_CHANNEL", 1, 1, 2))
    gain = _number("VISIONARY_MIC_GAIN_DB", 24, 0, 36)
    cutoff = _number("VISIONARY_MIC_HIGHPASS_HZ", 100, 0, 500)
    capture = [
        "arecord", "-q", "-D", os.environ.get("VISIONARY_ALSA_CAPTURE", "plughw:0,0"),
        "-t", "raw", "-f", "S32_LE", "-r", str(HARDWARE_RATE), "-c", "2",
        "--buffer-time=80000", "--period-time=20000",
    ]
    convert = [
        "sox", "-q", "--buffer", "2048", "-D",
        "-t", "raw", "-L", "-e", "signed-integer", "-b", "32",
        "-r", str(HARDWARE_RATE), "-c", "2", "-",
        "-t", "raw", "-L", "-e", "signed-integer", "-b", "16",
        "-r", str(RATE), "-c", "1", "-", "remix", str(channel),
    ]
    if cutoff:
        convert.extend(["highpass", "%g" % cutoff])
    convert.extend(["rate", "-m", str(RATE), "gain", "-l", "%g" % gain, "gain", "-1"])
    return capture, convert


def playback_command():
    return [
        "aplay", "-q", "-D", os.environ.get("VISIONARY_ALSA_PLAYBACK", "plughw:0,0"),
        "-t", "raw", "-f", "S16_LE", "-r", str(HARDWARE_RATE), "-c", "1",
        "--buffer-time=80000", "--period-time=20000",
    ]


class _Upsampler:
    """Continuous 2x interpolation with one input-sample delay and no wrap."""

    def __init__(self):
        self.previous = 0

    def convert(self, pcm: bytes) -> bytes:
        samples = np.frombuffer(pcm, dtype="<i2").astype(np.int32)
        if samples.size == 0:
            return b""
        previous = np.empty_like(samples)
        previous[0] = self.previous
        previous[1:] = samples[:-1]
        self.previous = int(samples[-1])
        output = np.empty(samples.size * 2, dtype="<i2")
        output[0::2] = previous
        output[1::2] = (previous + samples) // 2
        return output.tobytes()


class LiveAudio:
    """One owned capture/playback pair; create a new instance after close().

    read() returns None on a short timeout, and raises on EOF or a failed audio
    process. write() only queues data; an overfull queue raises instead of
    blocking the network receiver or growing indefinitely. Both methods raise
    after close. Captured frames are echo-protected before they enter the queue,
    so a delayed network send cannot expose old speaker echo after the guard
    expires. The caller must send returned silence too, to advance GPT-Live's
    audio timeline; it must not apply a second send-time microphone gate.
    """

    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._capture_queue = queue.Queue(maxsize=_CAPTURE_QUEUE_CHUNKS)
        self._playback_queue = queue.Queue(maxsize=_PLAYBACK_QUEUE_CHUNKS)
        self._stop = threading.Event()
        self._started = False
        self._closed = False
        self._error = None  # type: Optional[str]
        self._error_lock = threading.Lock()
        self._lifecycle_lock = threading.RLock()
        self._write_lock = threading.Lock()
        self._echo_lock = threading.Lock()
        self._playback_until = 0.0
        self._guard_until = 0.0
        self._pending_output = b""
        self._last_capture = self._clock()
        self._capture = None
        self._filter = None
        self._player = None
        self._threads = []
        self.echo_guard = os.environ.get("VISIONARY_LIVE_ECHO_GUARD", "1") != "0"

    def start(self):
        with self._lifecycle_lock:
            self._start_locked()

    def _start_locked(self):
        if self._closed:
            raise RuntimeError("live audio is closed")
        if self._started:
            return
        capture, convert = capture_commands()
        try:
            self._capture = subprocess.Popen(capture, stdout=subprocess.PIPE, bufsize=0)
            self._filter = subprocess.Popen(
                convert, stdin=self._capture.stdout, stdout=subprocess.PIPE, bufsize=0)
            # The child owns the capture pipe; retaining this copy prevents EOF
            # and SIGPIPE from propagating correctly when a child fails.
            self._capture.stdout.close()
            self._player = subprocess.Popen(playback_command(), stdin=subprocess.PIPE, bufsize=0)
            self._started = True
            self._last_capture = self._clock()
            for target in (self._capture_worker, self._playback_worker):
                worker = threading.Thread(target=target, daemon=True)
                self._threads.append(worker)
                worker.start()
        except Exception:
            self.close()
            raise

    def _fail(self, message):
        if not self._stop.is_set():
            with self._error_lock:
                if self._error is None:
                    self._error = message

    def _check(self):
        if self._closed or not self._started:
            raise RuntimeError("live audio is not running")
        with self._error_lock:
            if self._error:
                raise RuntimeError(self._error)

    def _capture_worker(self):
        pending = bytearray()
        try:
            while not self._stop.is_set():
                chunk = self._filter.stdout.read(CHUNK_BYTES)
                if not chunk:
                    self._fail("live microphone/SoX stream ended; check ALSA and SoX logs")
                    return
                pending.extend(chunk)
                while len(pending) >= CHUNK_BYTES:
                    frame = self.input_for_model(bytes(pending[:CHUNK_BYTES]))
                    del pending[:CHUNK_BYTES]
                    try:
                        self._capture_queue.put_nowait(frame)
                    except queue.Full:
                        self._fail("live microphone queue overflow; connection is not consuming audio")
                        return
        except (OSError, ValueError) as exc:
            self._fail("live microphone failed: %s" % exc)

    def read(self, timeout=0.2):
        self._check()
        try:
            pcm = self._capture_queue.get(timeout=timeout)
            self._last_capture = self._clock()
            return pcm
        except queue.Empty:
            self._check()
            if self._clock() - self._last_capture > 5.0:
                raise RuntimeError("live microphone produced no audio for five seconds")
            return None

    def _schedule(self, pcm):
        samples = np.frombuffer(pcm, dtype="<i2").astype(np.float64)
        audible = bool(samples.size and np.sqrt(np.mean(samples * samples)) >= _AUDIBLE_RMS)
        with self._echo_lock:
            now = self._clock()
            start = max(self._playback_until, now + _PLAYBACK_LATENCY_S)
            self._playback_until = start + len(pcm) / float(RATE * 2)
            if audible:
                self._guard_until = self._playback_until + _ECHO_TAIL_S

    def write(self, pcm):
        self._check()
        if not isinstance(pcm, bytes):
            raise TypeError("live output must be PCM bytes")
        with self._write_lock:
            data = self._pending_output + pcm
            complete = len(data) - len(data) % 2
            frames = [data[index:min(index + CHUNK_BYTES, complete)]
                      for index in range(0, complete, CHUNK_BYTES)]
            # Preflight the whole event; never queue half a spoken event and
            # silently discard the rest. The caller can reconnect on overflow.
            if len(frames) > self._playback_queue.maxsize - self._playback_queue.qsize():
                self._fail("live speaker queue overflow; playback is too slow")
                raise RuntimeError("live speaker queue overflow; playback is too slow")
            self._pending_output = data[complete:]
            for frame in frames:
                self._schedule(frame)
                self._playback_queue.put_nowait(frame)

    def input_for_model(self, pcm):
        if not self.echo_guard:
            return pcm
        with self._echo_lock:
            mute = self._clock() < self._guard_until
        return bytes(len(pcm)) if mute else pcm

    def _playback_worker(self):
        upsampler = _Upsampler()
        try:
            while not self._stop.is_set():
                try:
                    pcm = self._playback_queue.get(timeout=0.1)
                except queue.Empty:
                    if self._player.poll() is not None:
                        self._fail("live speaker process ended; check ALSA logs")
                        return
                    continue
                output = memoryview(upsampler.convert(pcm))
                while output and not self._stop.is_set():
                    written = self._player.stdin.write(output)
                    if not written:
                        raise OSError("speaker pipe accepted no audio")
                    output = output[written:]
        except (OSError, ValueError) as exc:
            self._fail("live speaker failed: %s" % exc)

    def close(self):
        # Pause can arrive while subprocess creation is in progress. Serialize
        # the complete lifecycle, so it cannot miss a child created afterward.
        with self._lifecycle_lock:
            self._close_locked()

    def _close_locked(self):
        if self._closed:
            return
        self._closed = True
        self._stop.set()
        # Terminate children before closing pipes or joining threads, so blocked
        # reads and writes wake up. Queued audio must not play after pause.
        processes = (self._filter, self._capture, self._player)
        for proc in processes:
            if proc is not None and proc.poll() is None:
                try:
                    proc.terminate()
                except OSError:
                    pass
        for proc in processes:
            if proc is None:
                continue
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=1)
            for pipe in (proc.stdin, proc.stdout):
                if pipe is not None:
                    try:
                        pipe.close()
                    except OSError:
                        pass
        for worker in self._threads:
            if worker is not threading.current_thread():
                worker.join(timeout=1)
        with self._echo_lock:
            self._guard_until = 0.0
            self._playback_until = 0.0
