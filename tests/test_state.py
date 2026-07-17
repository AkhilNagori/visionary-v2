"""state.py contract: config defaults + deep-merge + atomic save, History
CRUD/pagination, pairing token stability, and the Tier-3 Actions queue."""

import json
import os

import pytest


def test_default_config_has_contract_schema(load):
    state = load("state")
    cfg = state.DEFAULT_CONFIG
    # Every top-level key the API validates against and the iOS app edits.
    for key in ("voice", "rate", "language", "two_way", "gestures",
                "features", "wake_word", "navigation"):
        assert key in cfg, "DEFAULT_CONFIG missing %r" % key
    assert cfg["voice"] == "en_US-lessac-low"
    assert cfg["rate"] == 1.0
    assert cfg["language"] is None
    assert cfg["gestures"] == {"single": "read", "double": "describe",
                               "triple": "recorder"}
    assert cfg["two_way"] == {"enabled": False, "theirs": "es", "yours": "en"}


def test_load_config_returns_defaults_without_file(load):
    state = load("state")
    cfg = state.load_config()
    assert cfg["voice"] == state.DEFAULT_CONFIG["voice"]
    assert cfg["gestures"]["single"] == "read"


def test_load_config_deep_merges_file_over_defaults(load):
    state = load("state")
    # A partial config on disk: override a scalar and one nested key only.
    partial = {"rate": 1.5, "two_way": {"enabled": True}}
    with open(state.CONFIG_PATH, "w") as f:
        json.dump(partial, f)
    cfg = state.load_config()
    assert cfg["rate"] == 1.5                     # scalar overridden
    assert cfg["two_way"]["enabled"] is True      # nested key overridden
    assert cfg["two_way"]["theirs"] == "es"       # sibling preserved from default
    assert cfg["voice"] == state.DEFAULT_CONFIG["voice"]  # untouched default


def test_save_config_is_atomic_and_roundtrips(load):
    state = load("state")
    cfg = state.load_config()
    cfg["rate"] = 0.75
    cfg["gestures"]["single"] = "describe"
    state.save_config(cfg)
    assert os.path.exists(state.CONFIG_PATH)
    assert not os.path.exists(state.CONFIG_PATH + ".tmp")  # temp swapped away
    reread = state.load_config()
    assert reread["rate"] == 0.75
    assert reread["gestures"]["single"] == "describe"


def test_history_add_get_and_extra_roundtrip(load):
    state = load("state")
    hist = state.get_history()
    eid = hist.add("ask", "the answer", extra={"question": "what?"},
                   image_path="/x/img.jpg")
    assert isinstance(eid, int)
    entry = hist.get(eid)
    assert entry["id"] == eid
    assert entry["kind"] == "ask"
    assert entry["text"] == "the answer"
    assert entry["extra"] == {"question": "what?"}
    assert entry["image_path"] == "/x/img.jpg"
    assert entry["audio_path"] is None
    assert isinstance(entry["ts"], float)
    assert hist.get(999999) is None


def test_history_list_pagination_newest_first(load):
    state = load("state")
    hist = state.get_history()
    ids = [hist.add("read", "entry %d" % i) for i in range(5)]
    page1 = hist.list(page=1, per_page=2)
    assert page1["total"] == 5
    assert page1["page"] == 1
    assert page1["per_page"] == 2
    assert len(page1["entries"]) == 2
    # newest first
    assert page1["entries"][0]["id"] == ids[-1]
    assert page1["entries"][1]["id"] == ids[-2]
    page3 = hist.list(page=3, per_page=2)
    assert len(page3["entries"]) == 1
    assert page3["entries"][0]["id"] == ids[0]


def test_get_history_is_singleton(load):
    state = load("state")
    assert state.get_history() is state.get_history()


def test_token_is_six_digits_and_stable(load):
    state = load("state")
    token = state.get_token()
    assert token.isdigit() and len(token) == 6
    assert state.get_token() == token  # stable across calls
    # persisted to disk with private perms
    assert os.path.exists(state.TOKEN_PATH)
    mode = os.stat(state.TOKEN_PATH).st_mode & 0o777
    assert mode == 0o600


def test_pairing_payload_shape(load):
    state = load("state")
    payload = state.pairing_payload()
    assert set(payload) == {"url", "token"}
    assert payload["url"].startswith("http://")
    assert payload["url"].endswith(":8321")
    assert payload["token"] == state.get_token()


def test_actions_queue_lifecycle(load):
    state = load("state")
    actions = state.get_actions()
    assert actions.list_pending() == []
    aid = actions.add("reminder", {"title": "call home", "notes": "after class"})
    assert isinstance(aid, int)
    pending = actions.list_pending()
    assert len(pending) == 1
    act = pending[0]
    assert act["id"] == aid
    assert act["type"] == "reminder"
    assert act["payload"] == {"title": "call home", "notes": "after class"}
    assert act["status"] == "pending"
    assert isinstance(act["ts"], float)
    # complete moves it out of pending
    assert actions.complete(aid, "done", "created") is True
    assert actions.list_pending() == []
    # unknown id -> False
    assert actions.complete(123456, "done") is False


def test_get_actions_is_singleton(load):
    state = load("state")
    assert state.get_actions() is state.get_actions()
