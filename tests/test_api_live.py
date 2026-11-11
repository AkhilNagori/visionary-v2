"""Live API controls never silently invoke the archived cloud pipelines."""

import pytest

pytest.importorskip("fastapi")
pytest.importorskip("httpx")


@pytest.fixture
def ctx(load, monkeypatch):
    monkeypatch.setenv("VISIONARY_RUNTIME", "live")
    api = load("api")
    from fastapi.testclient import TestClient

    calls = []

    def command(payload, timeout=5.0):
        calls.append(payload)
        return {"ok": True}

    monkeypatch.setattr(api, "uds_call", command)
    monkeypatch.setattr(api, "_wifi_ssid", lambda: "test-wifi")
    return TestClient(api.app), api, {
        "Authorization": "Bearer " + api.state.get_token()
    }, calls


def test_status_preserves_live_fields(ctx, monkeypatch):
    client, api, auth, _ = ctx
    status = {
        "ok": True, "runtime": "live", "online": True, "connected": True,
        "paused": False, "state": "listening", "last_error": None,
        "echo_guard": True, "camera_available": False,
        "camera_error": "camera unavailable", "listening": True,
        "session_id": "session-test", "usage_seconds": 12, "usage_finalized": False,
        "uptime": 14.3, "busy": False, "recording": False,
    }
    monkeypatch.setattr(api, "uds_call", lambda payload: status)
    result = client.get("/status", headers=auth)
    assert result.status_code == 200
    body = result.json()
    for key, value in status.items():
        if key != "ok":
            assert body[key] == value
    assert body["wifi"] == "test-wifi"


@pytest.mark.parametrize("mode", ["photo", "read", "describe"])
def test_photo_and_compatibility_aliases(ctx, mode):
    client, _, auth, calls = ctx
    response = client.post("/capture", headers=auth, json={"mode": mode})
    assert response.status_code == 200
    assert calls == [{"cmd": "capture", "mode": mode}]


@pytest.mark.parametrize("action", ["pause", "resume", "toggle"])
def test_conversation_control(ctx, action):
    client, _, auth, calls = ctx
    response = client.post("/conversation", headers=auth, json={"action": action})
    assert response.status_code == 200
    assert calls == [{"cmd": "live_control", "action": action}]


def test_conversation_validation_and_authentication(ctx):
    client, _, auth, calls = ctx
    assert client.post("/conversation", json={"action": "pause"}).status_code == 401
    assert client.post("/conversation", headers=auth,
                       json={"action": "delete"}).status_code == 422
    assert calls == []


def test_conversation_not_available_in_legacy(ctx, monkeypatch):
    client, _, auth, calls = ctx
    monkeypatch.setenv("VISIONARY_RUNTIME", "legacy")
    result = client.post("/conversation", headers=auth, json={"action": "resume"})
    assert result.status_code == 409
    assert calls == []


@pytest.mark.parametrize("method,path,payload", [
    ("put", "/config", {"rate": 1.5}),
    ("post", "/capture", {"mode": "recorder"}),
    ("post", "/listen", {"max_s": 5}),
    ("post", "/modes/active", {"id": "skim"}),
    ("post", "/packs/install", {"url": "https://example.invalid/pack.json"}),
    ("delete", "/packs/test-pack", None),
    ("post", "/flashcards/generate", {"n": 5}),
    ("get", "/memory/search?q=page", None),
])
def test_legacy_cloud_and_mode_controls_are_rejected(ctx, method, path, payload):
    client, api, auth, calls = ctx
    before = api.state.load_config()
    kwargs = {"headers": auth}
    if payload is not None:
        kwargs["json"] = payload
    response = client.request(method, path, **kwargs)
    assert response.status_code == 409
    assert "inactive in GPT-Live mode" in response.json()["detail"]
    assert calls == []
    assert api.state.load_config() == before


def test_live_is_default_without_environment_override(ctx, monkeypatch):
    client, _, auth, calls = ctx
    monkeypatch.delenv("VISIONARY_RUNTIME")
    assert client.post("/listen", headers=auth).status_code == 409
    assert calls == []


def test_live_modes_are_empty_and_history_is_retained(ctx):
    client, api, auth, _ = ctx
    entry_id = api.state.get_history().add("read", "Earlier saved page")
    assert client.get("/modes", headers=auth).json() == {
        "modes": {}, "active_mode": None, "runtime": "live",
    }
    entries = client.get("/history", headers=auth).json()["entries"]
    assert entries[0]["id"] == entry_id
    assert client.get("/config", headers=auth).status_code == 200


@pytest.mark.parametrize("error,expected", [
    ("busy", 409), ("paused", 409), ("not_connected", 409),
    ("not_connected_or_paused", 409), ("unsupported_in_live", 409),
    ("invalid_text", 422), ("transport_failed", 503),
])
def test_runtime_errors_are_not_internal_server_errors(ctx, monkeypatch, error, expected):
    client, api, auth, _ = ctx
    monkeypatch.setattr(api, "uds_call", lambda payload: {"ok": False, "error": error})
    response = client.post("/speak", headers=auth, json={"text": "Hello"})
    assert response.status_code == expected
    assert response.json()["detail"] == error


def test_speak_routes_through_live_command(ctx):
    client, _, auth, calls = ctx
    response = client.post("/speak", headers=auth, json={"text": "Hello"})
    assert response.status_code == 200
    assert calls == [{"cmd": "speak", "text": "Hello"}]
