"""brain.py contract with all network mocked: is_online caching, see()'s SSE
streaming + error contract, the Tier-3 tool-use loop, transcribe routing, and
prompt helpers. No test here ever touches a real socket or HTTP endpoint."""

import json
import wave

import pytest


# --- fake streamed (SSE) and non-streamed HTTP responses --------------------

def _sse_lines(deltas):
    """A realistic Anthropic message stream carrying the given text deltas."""
    lines = []

    def event(etype, obj):
        lines.append("event: " + etype)
        lines.append("data: " + json.dumps(obj))
        lines.append("")

    event("message_start",
          {"type": "message_start",
           "message": {"id": "msg_1", "role": "assistant", "content": []}})
    event("content_block_start",
          {"type": "content_block_start", "index": 0,
           "content_block": {"type": "text", "text": ""}})
    for d in deltas:
        event("content_block_delta",
              {"type": "content_block_delta", "index": 0,
               "delta": {"type": "text_delta", "text": d}})
    event("content_block_stop", {"type": "content_block_stop", "index": 0})
    event("message_delta",
          {"type": "message_delta", "delta": {"stop_reason": "end_turn"}})
    event("message_stop", {"type": "message_stop"})
    return lines


class FakeSSE:
    status_code = 200
    text = ""

    def __init__(self, lines):
        self._lines = lines

    def iter_lines(self, decode_unicode=False):
        for ln in self._lines:
            yield ln

    def json(self):
        return {}

    def close(self):
        pass


class FakeJSON:
    """A non-streaming JSON response (used by the tool loop and Whisper)."""
    text = ""

    def __init__(self, payload, status_code=200):
        self._payload = payload
        self.status_code = status_code

    def json(self):
        return self._payload

    def iter_lines(self, decode_unicode=False):
        return iter(())

    def close(self):
        pass


# --- is_online caching ------------------------------------------------------

def test_is_online_caches_within_window(load, monkeypatch):
    brain = load("brain")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "k")
    calls = {"n": 0}

    class Conn:
        def close(self):
            pass

    def ok_conn(addr, timeout=None):
        calls["n"] += 1
        return Conn()

    monkeypatch.setattr(brain.socket, "create_connection", ok_conn)
    assert brain.is_online(force=True) is True
    assert calls["n"] == 1
    assert brain.is_online() is True   # served from cache
    assert calls["n"] == 1

    def dropped(addr, timeout=None):
        calls["n"] += 1
        raise OSError("network down")

    monkeypatch.setattr(brain.socket, "create_connection", dropped)
    assert brain.is_online() is True   # cache still valid, no reconnect
    assert calls["n"] == 1
    assert brain.is_online(force=True) is False  # forced recompute sees the drop
    assert calls["n"] == 2


def test_is_online_false_without_key(load, monkeypatch):
    brain = load("brain")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

    def boom(*a, **k):
        raise AssertionError("must not connect without an API key")

    monkeypatch.setattr(brain.socket, "create_connection", boom)
    assert brain.is_online(force=True) is False


# --- see(): streaming, error contract, tool loop ----------------------------

def test_see_streams_deltas_in_order(load, monkeypatch):
    brain = load("brain")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "k")
    deltas = ["Hello, ", "this is ", "the answer."]
    monkeypatch.setattr(brain.requests, "post",
                        lambda *a, **k: FakeSSE(_sse_lines(deltas)))
    chunks = []
    text = brain.see(b"\xff\xd8\xffjpeg", "read this", on_text=chunks.append)
    assert text == "Hello, this is the answer."
    assert chunks == deltas


def test_chat_streams(load, monkeypatch):
    brain = load("brain")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "k")
    monkeypatch.setattr(brain.requests, "post",
                        lambda *a, **k: FakeSSE(_sse_lines(["Sure. ", "Done."])))
    assert brain.chat([{"role": "user", "content": "hi"}]) == "Sure. Done."


def test_see_offline_without_key_raises_brainoffline(load, monkeypatch):
    brain = load("brain")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    with pytest.raises(brain.BrainOffline):
        brain.see(b"jpeg", "prompt")


def test_see_network_failure_raises_brainoffline(load, monkeypatch):
    brain = load("brain")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "k")

    def boom(*a, **k):
        raise brain.requests.exceptions.RequestException("no route to host")

    monkeypatch.setattr(brain.requests, "post", boom)
    with pytest.raises(brain.BrainOffline):
        brain.see(b"jpeg", "prompt")


def test_see_api_error_raises_runtimeerror(load, monkeypatch):
    brain = load("brain")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "k")
    monkeypatch.setattr(
        brain.requests, "post",
        lambda *a, **k: FakeJSON({"error": {"message": "overloaded"}}, status_code=529))
    with pytest.raises(RuntimeError):
        brain.see(b"jpeg", "prompt")


def test_tool_schemas_present(load):
    brain = load("brain")
    for tool in (brain.TOOL_SEARCH_MEMORY, brain.TOOL_PHONE_ACTION):
        assert isinstance(tool, dict)
        assert "name" in tool and "input_schema" in tool
    assert brain.TOOL_SEARCH_MEMORY["name"] == "search_memory"
    assert brain.TOOL_PHONE_ACTION["name"] == "phone_action"


def test_see_runs_tool_loop(load, monkeypatch):
    brain = load("brain")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "k")
    responses = [
        {"role": "assistant", "stop_reason": "tool_use",
         "content": [
             {"type": "text", "text": ""},
             {"type": "tool_use", "id": "toolu_1", "name": "search_memory",
              "input": {"query": "room number"}},
         ]},
        {"role": "assistant", "stop_reason": "end_turn",
         "content": [{"type": "text", "text": "The room number was 204."}]},
    ]
    seq = iter(responses)
    monkeypatch.setattr(brain.requests, "post", lambda *a, **k: FakeJSON(next(seq)))

    handler_inputs = []

    def search_memory(inp):
        handler_inputs.append(inp)
        return "Room 204 was on the blue door."

    chunks = []
    text = brain.see(
        b"jpeg", "which room was that?",
        on_text=chunks.append,
        tools=[brain.TOOL_SEARCH_MEMORY],
        tool_handlers={"search_memory": search_memory},
    )
    assert handler_inputs == [{"query": "room number"}]
    assert text == "The room number was 204."
    assert chunks == ["The room number was 204."]  # final answer spoken once


# --- transcribe routing -----------------------------------------------------

def _write_wav(path):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\x00\x00" * 1600)


def test_transcribe_uses_openai_when_online(load, monkeypatch, tmp_path):
    brain = load("brain")
    monkeypatch.setenv("OPENAI_API_KEY", "o")
    monkeypatch.setattr(brain, "is_online", lambda force=False: True)
    wav = tmp_path / "utt.wav"
    _write_wav(wav)

    def fake_post(url, headers=None, data=None, files=None, timeout=None, **kw):
        assert "openai" in url
        return FakeJSON({"text": "hello there"})

    monkeypatch.setattr(brain.requests, "post", fake_post)
    assert brain.transcribe(str(wav)) == "hello there"


def test_transcribe_offline_without_backend_raises(load, monkeypatch, tmp_path):
    brain = load("brain")
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setattr(brain, "is_online", lambda force=False: False)
    wav = tmp_path / "utt.wav"
    _write_wav(wav)
    # No whisper.cpp installed under HOME/whisper -> no backend at all.
    with pytest.raises(brain.BrainOffline):
        brain.transcribe(str(wav))


# --- prompt helpers ---------------------------------------------------------

def test_read_prompt_translation_suffix(load):
    brain = load("brain")
    assert brain.read_prompt(None) == brain.READ_PROMPT
    translated = brain.read_prompt("Spanish")
    assert translated.startswith(brain.READ_PROMPT)
    assert "Spanish" in translated
