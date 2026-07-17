"""api.py contract via FastAPI's TestClient, with the firmware service faked by
the conftest FakeUDS server. Skipped where fastapi/httpx aren't installed."""

import pytest

pytest.importorskip("fastapi")
pytest.importorskip("httpx")  # required by starlette's TestClient


@pytest.fixture
def ctx(load, fake_uds):
    api = load("api")
    from fastapi.testclient import TestClient
    token = api.state.get_token()
    return TestClient(api.app), api, token, fake_uds


def _auth(token):
    return {"Authorization": "Bearer " + token}


def test_requires_bearer_token(ctx):
    client, _api, token, _ = ctx
    assert client.get("/config").status_code == 401              # missing
    assert client.get("/config",
                      headers={"Authorization": "Bearer nope"}).status_code == 401
    assert client.get("/config", headers=_auth(token)).status_code == 200


def test_config_roundtrip_and_unknown_key_422(ctx):
    client, api, token, _ = ctx
    h = _auth(token)
    got = client.get("/config", headers=h)
    assert got.status_code == 200
    assert got.json()["voice"] == api.state.DEFAULT_CONFIG["voice"]

    put = client.put("/config", headers=h, json={"rate": 1.5})
    assert put.status_code == 200
    assert put.json()["rate"] == 1.5
    assert client.get("/config", headers=h).json()["rate"] == 1.5

    bad = client.put("/config", headers=h, json={"bogus_key": 1})
    assert bad.status_code == 422


def test_history_pagination_newest_first(ctx):
    client, api, token, _ = ctx
    h = _auth(token)
    ids = [api.state.get_history().add("read", "entry %d" % i) for i in range(5)]
    body = client.get("/history?page=1&per_page=2", headers=h).json()
    assert body["total"] == 5
    assert body["page"] == 1 and body["per_page"] == 2
    assert len(body["entries"]) == 2
    assert body["entries"][0]["id"] == ids[-1]  # newest first
    page3 = client.get("/history?page=3&per_page=2", headers=h).json()
    assert [e["id"] for e in page3["entries"]] == [ids[0]]


def test_history_image_404(ctx):
    client, api, token, _ = ctx
    h = _auth(token)
    eid = api.state.get_history().add("read", "text only, no photo")
    assert client.get("/history/%d/image" % eid, headers=h).status_code == 404
    assert client.get("/history/999999/image", headers=h).status_code == 404


def test_capture_ok_then_busy_409(ctx):
    client, _api, token, uds = ctx
    h = _auth(token)
    ok = client.post("/capture", headers=h, json={"mode": "read"})
    assert ok.status_code == 200 and ok.json()["ok"] is True
    assert uds.capture_calls == ["read"]
    uds.busy = True
    busy = client.post("/capture", headers=h, json={"mode": "read"})
    assert busy.status_code == 409


def test_speak(ctx):
    client, _api, token, uds = ctx
    h = _auth(token)
    r = client.post("/speak", headers=h, json={"text": "hello there"})
    assert r.status_code == 200
    assert uds.speak_calls == ["hello there"]


def test_memory_search_offline_fts5(ctx, monkeypatch):
    client, api, token, _ = ctx
    h = _auth(token)
    import memory
    monkeypatch.setattr(memory, "embed", lambda texts: None)  # no network
    eid = api.state.get_history().add("read", "the fire exit sign near stairwell B")
    memory.index_entry(eid, "the fire exit sign near stairwell B")
    r = client.get("/memory/search", headers=h, params={"q": "fire exit", "k": 5})
    assert r.status_code == 200
    results = r.json()["results"]
    assert any(item["id"] == eid for item in results)


def test_actions_queue_lifecycle(ctx):
    client, api, token, _ = ctx
    h = _auth(token)
    assert client.get("/actions", headers=h).json()["actions"] == []

    aid = api.state.get_actions().add(
        "calendar_event", {"title": "Science Fair", "date": "2026-07-18"})
    listing = client.get("/actions", headers=h).json()["actions"]
    assert len(listing) == 1
    assert listing[0]["id"] == aid
    assert listing[0]["type"] == "calendar_event"
    assert listing[0]["payload"] == {"title": "Science Fair", "date": "2026-07-18"}
    assert listing[0]["status"] == "pending"

    done = client.post("/actions/%d" % aid, headers=h,
                       json={"status": "done", "result": "created"})
    assert done.status_code == 200
    assert client.get("/actions", headers=h).json()["actions"] == []  # gone

    assert client.post("/actions/424242", headers=h,
                       json={"status": "done"}).status_code == 404  # unknown id
    assert client.post("/actions/%d" % aid, headers=h,
                       json={"status": "weird"}).status_code == 422  # bad status
