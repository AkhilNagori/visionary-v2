"""Live runtime controls without hardware, cloud credentials, or network calls."""

import json
import os
import socket
import stat
import sys
import threading

import pytest


@pytest.fixture
def live(load):
    sys.modules.pop("live_main", None)
    module = load("live_main")
    yield module
    sys.modules.pop("live_main", None)


class FakeClient:
    def __init__(self):
        self.connected = False
        self.paused = False
        self.photos = []
        self.spoken = []
        self.starts = 0
        self.closes = 0

    def start(self):
        self.starts += 1
        self.connected = True

    def close(self):
        self.closes += 1
        self.connected = False

    def pause(self):
        self.paused = True

    def resume(self):
        self.paused = False

    def toggle(self):
        self.paused = not self.paused

    def send_photo(self, jpeg):
        self.photos.append(jpeg)
        return True

    def say(self, text):
        self.spoken.append(text)
        return self.connected and not self.paused

    def status(self):
        return {"connected": self.connected, "paused": self.paused}


def button_harness(live):
    now = [0.0]
    calls = []
    timers = []

    class Timer:
        def __init__(self, delay, callback):
            self.delay = delay
            self.callback = callback
            self.cancelled = False
            timers.append(self)

        def start(self):
            pass

        def cancel(self):
            self.cancelled = True

    button = live.LiveButton(
        lambda: calls.append("photo"),
        lambda: calls.append("toggle"),
        lambda: calls.append("shutdown"),
        clock=lambda: now[0], timer_factory=Timer,
    )
    return button, now, calls, timers


def test_quick_release_takes_one_photo_without_click_burst_delay(live):
    button, now, calls, timers = button_harness(live)
    button.press()
    button.press()  # a repeated driver notification cannot duplicate the press
    now[0] = 0.3
    button.release()
    button.release()

    assert calls == ["photo"]
    assert len(timers) == 1
    assert timers[0].cancelled


@pytest.mark.parametrize("duration", [1.0, 2.0, 4.99])
def test_medium_hold_toggles_only_on_release(live, duration):
    button, now, calls, timers = button_harness(live)
    button.press()
    now[0] = duration
    assert calls == []  # no one-second ask cue and no premature pause
    button.release()

    assert calls == ["toggle"]
    assert timers[0].cancelled


def test_five_second_hold_shuts_down_once_without_photo_or_pause(live):
    button, now, calls, timers = button_harness(live)
    button.press()
    now[0] = 5.0
    timers[0].callback()
    button.release()
    timers[0].callback()

    assert calls == ["shutdown"]


def test_release_at_shutdown_boundary_works_if_timer_has_not_run(live):
    button, now, calls, timers = button_harness(live)
    button.press()
    now[0] = 5.0
    button.release()
    timers[0].callback()

    assert calls == ["shutdown"]


def test_button_close_cancels_pending_shutdown(live):
    button, now, calls, timers = button_harness(live)
    button.press()
    button.close()
    timers[0].callback()
    button.release()
    button.press()

    assert calls == []
    assert timers[0].cancelled


def test_stale_cancelled_timer_cannot_shutdown_a_new_press(live):
    button, now, calls, timers = button_harness(live)
    button.press()
    now[0] = 0.2
    button.release()
    button.press()
    timers[0].callback()  # Timer cancellation may race a dispatched callback.
    now[0] = 0.4
    button.release()

    assert calls == ["photo", "photo"]


def test_voice_starts_even_when_camera_fails(live, monkeypatch):
    client = FakeClient()
    runtime = live.LiveRuntime(client)

    def fail_camera():
        raise RuntimeError("camera unplugged")

    monkeypatch.setattr(live.vision, "init_camera", fail_camera)
    runtime.start()

    assert client.starts == 1
    assert runtime.status()["online"] is True
    assert runtime.status()["camera_available"] is False
    assert runtime.status()["camera_error"] == "camera unplugged"
    assert client.spoken == []  # no second cloud TTS pipeline at boot
    runtime.close()
    runtime.close()
    assert client.closes == 1


def test_photo_capture_is_nonblocking_and_single_in_flight(live, monkeypatch):
    client = FakeClient()
    runtime = live.LiveRuntime(client)
    runtime.start()
    entered = threading.Event()
    finish = threading.Event()

    def capture():
        entered.set()
        assert finish.wait(2)
        return b"jpeg-test"

    monkeypatch.setattr(live.vision, "capture_jpeg", capture)
    try:
        assert runtime.take_photo() == (True, None)
        assert entered.wait(1)
        assert runtime.take_photo() == (False, "busy")
        finish.set()
        runtime._photo_thread.join(timeout=2)
        assert client.photos == [b"jpeg-test"]
        assert runtime.status()["busy"] is False
    finally:
        finish.set()
        runtime.close()


def test_photo_does_not_capture_when_paused_or_disconnected(live, monkeypatch):
    client = FakeClient()
    runtime = live.LiveRuntime(client)
    captured = []
    monkeypatch.setattr(live.vision, "capture_jpeg", lambda: captured.append(True))

    assert runtime.take_photo() == (False, "not_connected")
    client.start()
    client.pause()
    assert runtime.take_photo() == (False, "paused")
    assert captured == []
    runtime.close()


def test_photo_capture_failure_does_not_leave_runtime_busy(live, monkeypatch):
    client = FakeClient()
    runtime = live.LiveRuntime(client)
    runtime.start()

    def broken_camera():
        raise RuntimeError("capture failed")

    monkeypatch.setattr(live.vision, "capture_jpeg", broken_camera)
    assert runtime.take_photo() == (True, None)
    runtime._photo_thread.join(timeout=1)

    assert client.photos == []
    assert runtime.status()["busy"] is False
    assert runtime.status()["camera_available"] is False
    runtime.close()


def test_legacy_mic_modes_are_rejected_and_control_uses_same_client(live):
    client = FakeClient()
    runtime = live.LiveRuntime(client)
    runtime.start()

    for request in ({"cmd": "listen"}, {"cmd": "capture", "mode": "recorder"},
                    {"cmd": "modes"}, {"cmd": "timers"}):
        assert runtime.handle(request) == {
            "ok": False, "error": "unsupported_in_live"}
    assert runtime.handle({"cmd": "live_control", "action": "pause"})["paused"]
    assert not runtime.handle({"cmd": "live_control", "action": "resume"})["paused"]
    assert runtime.handle({"cmd": "speak", "text": "Hello"}) == {"ok": True}
    assert client.spoken == ["Hello"]
    assert runtime.handle({"cmd": "status"})["runtime"] == "live"
    runtime.close()


def test_photo_aliases_are_compatible_with_existing_app(live, monkeypatch):
    runtime = live.LiveRuntime(FakeClient())
    requests = []
    monkeypatch.setattr(runtime, "take_photo", lambda: requests.append(True) or (True, None))

    for mode in ("photo", "read", "describe"):
        assert runtime.handle({"cmd": "capture", "mode": mode}) == {"ok": True}
    assert len(requests) == 3


def test_default_entrypoint_dispatches_live_without_legacy_boot(live, load, monkeypatch):
    legacy_main = load("main")
    calls = []
    monkeypatch.delenv("VISIONARY_RUNTIME", raising=False)
    monkeypatch.setattr(live, "main", lambda: calls.append("live"))

    def legacy_boot(_dispatcher):
        pytest.fail("Legacy boot must not run for the default Live runtime")

    monkeypatch.setattr(legacy_main, "boot", legacy_boot)
    legacy_main.main()
    assert calls == ["live"]


def test_sim_runtime_starts_without_api_key(live, monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    runtime = live.LiveRuntime(sim=True)
    runtime.start()
    assert isinstance(runtime.client, live.SimLiveClient)
    assert runtime.status()["online"] is True
    runtime.close()


def test_uds_status_permissions_and_bounded_requests(live):
    runtime = live.LiveRuntime(FakeClient())
    runtime.start()
    server = live.LiveCommandServer(runtime)
    server.start()
    try:
        assert stat.S_IMODE(os.stat(server.path).st_mode) == 0o600
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(2)
            client.connect(server.path)
            client.sendall(b'{"cmd":"status"}\n')
            with client.makefile("rb") as response:
                status = json.loads(response.readline())
                assert status["runtime"] == "live"
                assert status["online"] is True
                client.sendall(b"x" * (live.MAX_COMMAND_BYTES + 1))
                rejected = json.loads(response.readline())
                assert rejected["error"] == "request_too_large"
    finally:
        server.close()
        runtime.close()
    assert not os.path.exists(server.path)


def test_uds_refuses_to_replace_an_existing_regular_file(live):
    runtime = live.LiveRuntime(FakeClient())
    path = os.path.join(live.state.HOME, "visionary.sock")
    with open(path, "w") as existing:
        existing.write("keep me")
    server = live.LiveCommandServer(runtime)

    with pytest.raises(RuntimeError, match="non-socket"):
        server.start()
    server.close()
    with open(path) as existing:
        assert existing.read() == "keep me"
