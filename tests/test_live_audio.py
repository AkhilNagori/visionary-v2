"""Streaming audio contracts; no audio hardware or network is used."""

import importlib
import io
import queue
import struct
import subprocess
import threading

import pytest


@pytest.fixture
def live_audio(monkeypatch):
    for name in ("VISIONARY_ALSA_CAPTURE", "VISIONARY_ALSA_PLAYBACK",
                 "VISIONARY_MIC_CHANNEL", "VISIONARY_MIC_GAIN_DB",
                 "VISIONARY_MIC_HIGHPASS_HZ", "VISIONARY_LIVE_ECHO_GUARD"):
        monkeypatch.delenv(name, raising=False)
    return importlib.import_module("live_audio")


def _running(module, clock=lambda: 10.0):
    device = module.LiveAudio(clock=clock)
    device._started = True
    return device


def test_shared_i2s_bus_stays_at_48k_and_network_audio_is_24k(live_audio):
    capture, convert = live_audio.capture_commands()
    playback = live_audio.playback_command()
    assert capture[capture.index("-r") + 1] == "48000"
    assert playback[playback.index("-r") + 1] == "48000"
    assert capture[capture.index("-f") + 1] == "S32_LE"
    assert convert[-12:] == [
        "remix", "1", "highpass", "100", "rate", "-m", "24000",
        "gain", "-l", "24", "gain", "-1",
    ]
    assert "--buffer" in convert


def test_hardware_overrides_are_bounded_and_not_shell_interpolated(live_audio, monkeypatch):
    monkeypatch.setenv("VISIONARY_ALSA_CAPTURE", "plughw:USB,0")
    monkeypatch.setenv("VISIONARY_ALSA_PLAYBACK", "plughw:Other,0")
    monkeypatch.setenv("VISIONARY_MIC_CHANNEL", "2")
    monkeypatch.setenv("VISIONARY_MIC_GAIN_DB", "500")
    monkeypatch.setenv("VISIONARY_MIC_HIGHPASS_HZ", "0")
    capture, convert = live_audio.capture_commands()
    assert "plughw:USB,0" in capture
    assert "plughw:Other,0" in live_audio.playback_command()
    assert convert[convert.index("remix") + 1] == "2"
    assert "highpass" not in convert
    assert convert[-5:] == ["gain", "-l", "36", "gain", "-1"]


def test_nonfinite_gain_uses_safe_default(live_audio, monkeypatch):
    monkeypatch.setenv("VISIONARY_MIC_GAIN_DB", "nan")
    _, convert = live_audio.capture_commands()
    assert convert[-5:] == ["gain", "-l", "24", "gain", "-1"]


def test_silent_output_does_not_gate_microphone(live_audio):
    device = _running(live_audio)
    device.write(bytes(960))
    microphone = b"\x01\x00" * 480
    assert device.input_for_model(microphone) == microphone


def test_audible_output_mutes_only_until_scheduled_playback_and_tail(live_audio):
    now = [10.0]
    device = _running(live_audio, clock=lambda: now[0])
    voice = struct.pack("<h", 1000) * 480
    device.write(voice)
    assert device.input_for_model(voice) == bytes(len(voice))
    now[0] = 10.31  # 80ms device delay + 20ms frame + 200ms echo tail
    assert device.input_for_model(voice) == voice


def test_silence_after_speech_does_not_extend_echo_guard(live_audio):
    now = [10.0]
    device = _running(live_audio, clock=lambda: now[0])
    voice = struct.pack("<h", 1000) * 480
    device.write(voice)
    original_guard = device._guard_until
    device.write(bytes(960 * 20))
    assert device._guard_until == original_guard
    now[0] = original_guard + 0.01
    assert device.input_for_model(voice) == voice


def test_echo_guard_can_be_disabled_for_isolated_audio(live_audio, monkeypatch):
    monkeypatch.setenv("VISIONARY_LIVE_ECHO_GUARD", "0")
    device = _running(live_audio)
    pcm = struct.pack("<h", 1000) * 480
    device.write(pcm)
    assert device.input_for_model(pcm) == pcm


def test_output_keeps_partial_pcm_sample_until_next_event(live_audio):
    device = _running(live_audio)
    device.write(b"\x01")
    assert device._playback_queue.empty()
    device.write(b"\x02\x03\x04\x05")
    assert device._playback_queue.get_nowait() == b"\x01\x02\x03\x04"
    assert device._pending_output == b"\x05"


def test_speaker_backpressure_fails_bounded_instead_of_blocking(live_audio):
    device = _running(live_audio)
    device._playback_queue = queue.Queue(maxsize=1)
    with pytest.raises(RuntimeError, match="overflow"):
        device.write(bytes(960 * 2))
    assert device._playback_queue.empty()


def test_upsampling_is_continuous_across_chunks_and_cannot_wrap(live_audio):
    data = struct.pack("<hhhh", 32767, 32767, -32768, -32768)
    whole = live_audio._Upsampler().convert(data)
    converter = live_audio._Upsampler()
    chunked = converter.convert(data[:4]) + converter.convert(data[4:])
    assert chunked == whole
    assert len(whole) == len(data) * 2
    values = struct.unpack("<8h", whole)
    assert values == (0, 16383, 32767, 32767, 32767, -1, -32768, -32768)


def test_capture_worker_reassembles_short_reads(live_audio):
    device = _running(live_audio)
    chunks = [b"a" * 31, b"b" * 929]

    class ShortReader:
        def read(self, size):
            if chunks:
                return chunks.pop(0)
            device._stop.set()
            return b""

    class Filter:
        stdout = ShortReader()

    device._filter = Filter()
    device._capture_worker()
    assert device.read(timeout=0) == b"a" * 31 + b"b" * 929


def test_delayed_capture_drain_cannot_leak_speaker_echo(live_audio):
    now = [10.0]
    device = _running(live_audio, clock=lambda: now[0])
    voice = struct.pack("<h", 1000) * 480
    device.write(voice)
    chunks = [voice]

    class Reader:
        def read(self, size):
            if chunks:
                return chunks.pop(0)
            device._stop.set()
            return b""

    class Filter:
        stdout = Reader()

    device._filter = Filter()
    device._capture_worker()
    now[0] = 16.0  # the photo upload has finished; speaker guard expired long ago
    assert device.input_for_model(voice) == voice
    assert device.read(timeout=0) == bytes(len(voice))  # already protected at capture


def test_capture_queue_holds_eight_seconds_but_cannot_grow_beyond_it(live_audio):
    device = _running(live_audio)
    assert device._capture_queue.maxsize == 400
    assert device._capture_queue.maxsize * live_audio.CHUNK_BYTES / (24000 * 2) == 8

    class Filter:
        stdout = io.BytesIO(bytes(live_audio.CHUNK_BYTES * 401))

    device._filter = Filter()
    device._capture_worker()
    assert device._capture_queue.qsize() == 400
    with pytest.raises(RuntimeError, match="microphone queue overflow"):
        device.read(timeout=0)


def test_capture_overflow_is_reported(live_audio):
    device = _running(live_audio)
    device._capture_queue = queue.Queue(maxsize=1)

    class Filter:
        stdout = io.BytesIO(bytes(960 * 2))

    device._filter = Filter()
    device._capture_worker()
    with pytest.raises(RuntimeError, match="microphone queue overflow"):
        device.read(timeout=0)


def test_read_short_timeout_and_stalled_capture(live_audio):
    now = [10.0]
    device = _running(live_audio, clock=lambda: now[0])
    assert device.read(timeout=0) is None
    now[0] = 16.0
    with pytest.raises(RuntimeError, match="no audio"):
        device.read(timeout=0)


def test_start_wires_processes_and_close_releases_every_pipe(live_audio, monkeypatch):
    calls = []
    processes = []

    class Process:
        def __init__(self, command, **kwargs):
            calls.append((command, kwargs))
            self.stdin = io.BytesIO() if kwargs.get("stdin") == subprocess.PIPE else None
            self.stdout = io.BytesIO() if kwargs.get("stdout") == subprocess.PIPE else None
            self.returncode = None
            processes.append(self)

        def poll(self):
            return self.returncode

        def terminate(self):
            self.returncode = -15

        def wait(self, timeout=None):
            return self.returncode

    class Thread:
        def __init__(self, **kwargs):
            pass

        def start(self):
            pass

        def join(self, timeout=None):
            pass

    monkeypatch.setattr(live_audio.subprocess, "Popen", Process)
    monkeypatch.setattr(live_audio.threading, "Thread", Thread)
    device = live_audio.LiveAudio()
    device.start()
    assert [command[0] for command, _ in calls] == ["arecord", "sox", "aplay"]
    assert calls[1][1]["stdin"] is processes[0].stdout
    assert processes[0].stdout.closed
    device.close()
    device.close()  # idempotent cleanup
    assert all(proc.returncode == -15 for proc in processes)
    assert processes[1].stdout.closed
    assert processes[2].stdin.closed
    with pytest.raises(RuntimeError, match="not running"):
        device.write(b"\0\0")


def test_partial_start_failure_cleans_capture(live_audio, monkeypatch):
    class Capture:
        stdin = None
        stdout = io.BytesIO()
        returncode = None

        def poll(self):
            return self.returncode

        def terminate(self):
            self.returncode = -15

        def wait(self, timeout=None):
            return self.returncode

    capture = Capture()
    count = [0]

    def popen(command, **kwargs):
        count[0] += 1
        if count[0] == 1:
            return capture
        raise FileNotFoundError("sox")

    monkeypatch.setattr(live_audio.subprocess, "Popen", popen)
    device = live_audio.LiveAudio()
    with pytest.raises(FileNotFoundError):
        device.start()
    assert capture.returncode == -15
    assert capture.stdout.closed


def test_close_during_start_cannot_leak_a_late_created_process(live_audio, monkeypatch):
    entered = threading.Event()
    release = threading.Event()
    closed = threading.Event()
    processes = []

    class Process:
        def __init__(self, command, **kwargs):
            self.stdin = io.BytesIO() if kwargs.get("stdin") == subprocess.PIPE else None
            self.stdout = io.BytesIO() if kwargs.get("stdout") == subprocess.PIPE else None
            self.returncode = None
            processes.append(self)
            if len(processes) == 1:
                entered.set()
                assert release.wait(2)

        def poll(self):
            return self.returncode

        def terminate(self):
            self.returncode = -15

        def wait(self, timeout=None):
            return self.returncode

    monkeypatch.setattr(live_audio.subprocess, "Popen", Process)
    device = live_audio.LiveAudio()
    monkeypatch.setattr(device, "_capture_worker", lambda: None)
    monkeypatch.setattr(device, "_playback_worker", lambda: None)
    starter = threading.Thread(target=device.start)

    def close_device():
        device.close()
        closed.set()

    closer = threading.Thread(target=close_device)
    starter.start()
    assert entered.wait(2)
    closer.start()
    assert not closed.wait(0.02)
    release.set()
    starter.join(timeout=2)
    closer.join(timeout=2)
    assert closed.is_set()
    assert len(processes) == 3
    assert all(proc.returncode == -15 for proc in processes)
    assert all(pipe.closed for proc in processes for pipe in (proc.stdin, proc.stdout)
               if pipe is not None)
