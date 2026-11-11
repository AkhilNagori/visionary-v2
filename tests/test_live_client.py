"""Protocol/lifecycle tests: all sockets and audio devices are fake."""

import base64
import json
import queue
import threading
import time

import pytest


class FakeAudio:
    def __init__(self):
        self.started = False
        self.closed = False
        self.played = []
        self.reads = queue.Queue()

    def start(self):
        self.started = True

    def read(self, timeout=0.2):
        if self.closed:
            raise RuntimeError("closed")
        try:
            return self.reads.get(timeout=0.01)
        except queue.Empty:
            return None

    def input_for_model(self, pcm):
        return pcm

    def write(self, pcm):
        if self.closed:
            raise RuntimeError("audio already closed")
        self.played.append(pcm)

    def close(self):
        self.closed = True


class FakeSocket:
    def __init__(self, started=True):
        self.sent = []
        self.incoming = queue.Queue()
        self.closed = False
        self.autostart = started

    def settimeout(self, timeout):
        self.timeout = timeout

    def send(self, value):
        event = json.loads(value)
        self.sent.append(event)
        if event["type"] == "session.start" and self.autostart:
            self.emit({"type": "session.started", "session": {"id": "live_test"}})
        elif event["type"] == "session.close":
            self.emit({"type": "session.closed", "reason": "close_requested",
                       "usage": {"seconds": 7}})

    def emit(self, event):
        self.incoming.put(json.dumps(event))

    def recv(self):
        try:
            return self.incoming.get(timeout=0.01)
        except queue.Empty:
            raise TimeoutError

    def close(self):
        self.closed = True


def wait_for(predicate, timeout=2):
    end = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < end, "condition timed out"
        threading.Event().wait(0.005)


def test_session_uses_live_protocol_and_vision_backend(load):
    live = load("live_client")
    event = live.session_start()
    session = event["session"]
    assert event["type"] == "session.start"
    assert session["model"] == "gpt-live-1"
    assert session["audio"]["format"] == {"type": "audio/pcm", "rate": 24000}
    assert session["delegation"]["responses"]["model"] == "gpt-6-luna"
    assert session["store"] is False
    assert "<|SpawnThinking|>" in session["instructions"]
    assert "turn_detection" not in session


def test_photo_is_sent_to_backend_then_response_is_created(load):
    live = load("live_client")
    jpeg = b"\xff\xd8test-image"
    batch = live.photo_events(jpeg)
    assert [event["type"] for event in batch] == ["response.item.create", "response.create"]
    image = batch[0]["item"]["content"][1]
    assert image["type"] == "input_image"
    assert base64.b64decode(image["image_url"].split(",", 1)[1]) == jpeg
    with pytest.raises(ValueError):
        live.photo_events(b"not a jpeg")
    with pytest.raises(ValueError):
        live.photo_events(b"\xff\xd8" + bytes(live.MAX_PHOTO_BYTES))


def test_no_audio_or_photo_before_session_started(load):
    live = load("live_client")
    ws, audio = FakeSocket(started=False), FakeAudio()
    client = live.LiveClient(lambda: ws, lambda: audio)
    client.start()
    try:
        wait_for(lambda: ws.sent)
        assert client.send_photo(b"\xff\xd8photo") is False
        assert audio.started is False
        assert [item["type"] for item in ws.sent] == ["session.start"]
        ws.emit({"type": "session.started", "session": {"id": "live_test"}})
        wait_for(lambda: client.status()["connected"])
        assert audio.started is True
    finally:
        client.close()
    assert audio.closed and ws.closed


def test_stream_audio_photo_and_close_finalize_usage(load):
    live = load("live_client")
    ws, audio = FakeSocket(), FakeAudio()
    client = live.LiveClient(lambda: ws, lambda: audio)
    client.start()
    try:
        wait_for(lambda: client.status()["connected"])
        audio.reads.put(b"\x01")
        audio.reads.put(b"\x02\x03\x04")
        wait_for(lambda: any(x["type"] == "session.input_audio.append" for x in ws.sent))
        sent_audio = [x for x in ws.sent if x["type"] == "session.input_audio.append"]
        assert base64.b64decode(sent_audio[0]["audio"]) == b"\x01\x02\x03\x04"
        ws.emit({"type": "session.output_audio.delta", "delta": base64.b64encode(b"\x05\x06").decode()})
        wait_for(lambda: audio.played)
        assert audio.played == [b"\x05\x06"]
        assert client.send_photo(b"\xff\xd8photo") is True
        wait_for(lambda: any(x["type"] == "response.create" for x in ws.sent))
        types = [x["type"] for x in ws.sent]
        at = types.index("response.item.create")
        assert types[at + 1] == "response.create"
        ws.emit({"type": "session.usage.updated", "usage": {"seconds": 4}})
        ws.emit({"type": "session.usage.updated", "usage": {"seconds": 6}})
        wait_for(lambda: client.status()["usage_seconds"] == 6)
    finally:
        client.close()
    assert client.status()["usage_seconds"] == 7
    assert client.status()["usage_finalized"] is True
    assert ws.sent[-1]["type"] == "session.close"
    assert audio.closed and ws.closed


def test_pause_stops_mic_and_resume_starts_fresh_session(load):
    live = load("live_client")
    sockets, audios = [], []

    def new_socket():
        ws = FakeSocket()
        sockets.append(ws)
        return ws

    def new_audio():
        audio = FakeAudio()
        audios.append(audio)
        return audio

    client = live.LiveClient(new_socket, new_audio)
    client.start()
    try:
        wait_for(lambda: client.status()["connected"])
        client.pause()
        assert audios[0].closed
        assert client.send_photo(b"\xff\xd8photo") is False
        wait_for(lambda: sockets[0].closed)
        assert client.status()["paused"]
        client.resume()
        wait_for(lambda: len(audios) == 2 and client.status()["connected"])
        assert len(sockets) == 2
        assert sockets[1].sent[0]["type"] == "session.start"
        assert not any(x["type"] == "response.item.create" for x in sockets[1].sent)
    finally:
        client.close()


def test_backend_configuration_error_pauses_instead_of_looping(load):
    live = load("live_client")
    ws, audio = FakeSocket(), FakeAudio()
    client = live.LiveClient(lambda: ws, lambda: audio)
    client.start()
    try:
        wait_for(lambda: client.status()["connected"])
        ws.emit({"type": "error", "error": {"code": "responses_validation_failed",
                "message": "backend model unavailable"}})
        wait_for(lambda: ws.closed)
        assert client.status()["paused"]
        assert "backend model unavailable" in client.status()["last_error"]
        assert audio.closed
    finally:
        client.close()


def test_photo_queue_bounded_and_cleared_when_disconnected(load):
    live = load("live_client")
    client = live.LiveClient()
    client._connected = True
    assert client.say("one") is True
    assert client.say("two") is True
    assert client.say("three") is False
    client.pause()
    assert client.say("four") is False


def test_transcripts_are_bounded_and_key_is_redacted(load, monkeypatch, caplog):
    live = load("live_client")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-secret-test")
    client = live.LiveClient()
    for index in range(40):
        client._record_transcript("user" if index % 2 else "assistant", {"delta": "word " * 1000})
    history = client._saved_history()
    assert len(history) == 12
    assert all(len(item["content"][0]["text"]) <= 256 for item in history)
    client._error("bad key sk-secret-test")
    assert "sk-secret-test" not in caplog.text
    assert "sk-secret-test" not in client.status()["last_error"]


def test_content_termination_does_not_auto_reconnect(load):
    live = load("live_client")
    ws, audio = FakeSocket(), FakeAudio()
    client = live.LiveClient(lambda: ws, lambda: audio)
    client.start()
    try:
        wait_for(lambda: client.status()["connected"])
        ws.emit({"type": "session.closed", "reason": "content", "usage": {"seconds": 3}})
        wait_for(lambda: ws.closed)
        assert client.status()["paused"]
        assert client.status()["usage_finalized"]
    finally:
        client.close()


@pytest.mark.parametrize("during_startup", [False, True])
def test_pause_during_recv_does_not_play_or_start_audio(load, during_startup):
    live = load("live_client")
    blocked, release = threading.Event(), threading.Event()

    class BlockingSocket(FakeSocket):
        def recv(self):
            if not blocked.is_set() and (during_startup or audio.started):
                blocked.set()
                assert release.wait(2)
                if during_startup:
                    return json.dumps({"type": "session.started", "session": {"id": "live_test"}})
                return json.dumps({"type": "session.output_audio.delta", "delta": "AAA="})
            return super().recv()

    ws, audio = BlockingSocket(started=not during_startup), FakeAudio()
    client = live.LiveClient(lambda: ws, lambda: audio)
    client.start()
    try:
        assert blocked.wait(2)
        client.pause()
        release.set()
        wait_for(lambda: ws.closed)
        assert audio.played == []
        if during_startup:
            assert not audio.started
        assert any(event["type"] == "session.close" for event in ws.sent)
        assert client.status()["usage_finalized"]
        assert client.status()["last_error"] is None
    finally:
        release.set()
        client.close()
