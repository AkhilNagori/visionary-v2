"""api.py contract via FastAPI's TestClient, with the firmware service faked by
the conftest FakeUDS server. Skipped where fastapi/httpx aren't installed."""

import json
import sys

import pytest

pytest.importorskip("fastapi")
pytest.importorskip("httpx")  # required by starlette's TestClient

# v3 sibling modules the api imports lazily per request (packs/flashcards/
# timers). They are outside conftest's HOME-reset set, so purge them per test to
# keep each api test bound to its own throwaway VISIONARY_HOME and event/timer
# state (same rationale as the shared firmware modules conftest already purges).
_V3_MODULES = ("packs", "events", "flashcards", "timers", "sdk")


@pytest.fixture(autouse=True)
def _purge_v3():
    def purge():
        for name in _V3_MODULES:
            sys.modules.pop(name, None)
    purge()
    yield
    purge()


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


# --- v3: mode-pack platform, flashcards, events, timers --------------------

def test_modes_list_and_active_default(ctx):
    client, _api, token, _ = ctx
    h = _auth(token)
    body = client.get("/modes", headers=h).json()
    assert "skim" in body["modes"]          # a builtin mode id from the contract
    assert body["active_mode"] is None       # default: classic read


def test_activate_then_clear_mode(ctx):
    client, _api, token, _ = ctx
    h = _auth(token)

    on = client.post("/modes/active", headers=h, json={"id": "skim"})
    assert on.status_code == 200
    assert on.json()["active_mode"] == "skim"
    assert client.get("/modes", headers=h).json()["active_mode"] == "skim"

    bad = client.post("/modes/active", headers=h, json={"id": "not_a_real_mode"})
    assert bad.status_code == 422  # unknown mode id rejected

    off = client.post("/modes/active", headers=h, json={"id": None})
    assert off.status_code == 200
    assert off.json()["active_mode"] is None  # back to classic read


def _deck_json():
    return json.dumps([
        {"question": "What is the capital of France?", "answer": "Paris."},
        {"question": "What is 7 times 8?", "answer": "56."},
        {"question": "Who wrote Hamlet?", "answer": "William Shakespeare."},
        {"question": "What is the powerhouse of the cell?",
         "answer": "The mitochondria."},
    ])


def test_flashcards_generate_due_review_flow(ctx, monkeypatch):
    client, api, token, _ = ctx
    h = _auth(token)
    import brain
    monkeypatch.setattr(brain, "chat",
                        lambda messages, system=None, on_text=None: _deck_json())
    monkeypatch.setattr(brain, "is_online", lambda force=False: True,
                        raising=False)
    api.state.get_history().add("read", "The mitochondria is the cell's powerhouse.")

    gen = client.post("/flashcards/generate", headers=h, json={"n": 10})
    assert gen.status_code == 200
    assert len(gen.json()["cards"]) == 4

    due = client.get("/flashcards/due", headers=h).json()["cards"]
    assert len(due) == 4  # freshly generated cards are all due
    card_id = due[0]["id"]

    rev = client.post("/flashcards/%d/review" % card_id, headers=h,
                      json={"grade": 2})
    assert rev.status_code == 200
    assert rev.json()["ok"] is True

    bad_grade = client.post("/flashcards/%d/review" % card_id, headers=h,
                            json={"grade": 9})
    assert bad_grade.status_code == 422  # grade out of 0..3

    unknown = client.post("/flashcards/999999/review", headers=h,
                          json={"grade": 2})
    assert unknown.status_code == 404  # unknown card id


def test_events_sse_first_chunk_smoke(ctx, monkeypatch):
    client, _api, token, uds = ctx
    h = _auth(token)
    # Extend the fake UDS command server to answer the v3 "events" command.
    # api primes with since=0 (call 0 -> empty head); the first poll (call 1)
    # delivers one event; the next poll reports the service gone (ok=False) so
    # the SSE generator returns and the response body is finite (no hang on an
    # endless stream). One event must surface as an SSE frame in that body.
    calls = {"n": 0}
    orig = uds._handle
    event = {"seq": 1, "kind": "caption", "data": "hello world"}

    def handle(req):
        if req.get("cmd") == "events":
            i = calls["n"]
            calls["n"] += 1
            if i == 0:
                return {"ok": True, "seq": 0, "events": []}
            if i == 1:
                return {"ok": True, "seq": 1, "events": [event]}
            return {"ok": False}  # end the stream so the response terminates
        return orig(req)

    monkeypatch.setattr(uds, "_handle", handle)

    resp = client.get("/events", headers=h)
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/event-stream")
    body = resp.text
    assert "event: caption" in body      # SSE event line carries the kind
    assert "hello world" in body         # ...and the data frame the payload


def test_events_sse_unavailable_when_service_down(load, monkeypatch):
    # No fake UDS bound -> uds_call raises -> prime fails before headers flush.
    api = load("api")
    from fastapi.testclient import TestClient
    client = TestClient(api.app)
    r = client.get("/events", headers=_auth(api.state.get_token()))
    assert r.status_code == 503


def test_timers_listing(ctx):
    client, _api, token, _ = ctx
    h = _auth(token)
    assert client.get("/timers", headers=h).json()["timers"] == []

    import timers
    timers.set_timer("pasta", 30)  # long timer: listed, won't fire during the test
    try:
        listing = client.get("/timers", headers=h).json()["timers"]
        names = [t["name"] if isinstance(t, dict) else t for t in listing]
        assert "pasta" in names
    finally:
        timers.cancel_timer("pasta")
