"""events.py + timers.py (v3) contract.

events: publish/get_since ordering, a forward cursor, and a 500-entry ring that
drops the oldest on overflow. timers: a short real timer fires in SIM, speaking
"<name> timer is done" (captured via a patched audio.speak) and publishing an
event; plus list/cancel bookkeeping. Timers use real threads even in SIM, so
firing is polled for with a generous cap rather than a fixed sleep.
"""

import sys
import time

import pytest

_V3_MODULES = ("packs", "events", "flashcards", "timers", "sdk")

RING = 500  # events ring-buffer capacity (ARCHITECTURE v3)


@pytest.fixture(autouse=True)
def _purge_v3():
    def purge():
        for name in _V3_MODULES:
            sys.modules.pop(name, None)
    purge()
    yield
    purge()


def _timer_names(listing):
    return [t["name"] if isinstance(t, dict) else t for t in listing]


def _wait_until(predicate, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


# --- events ---------------------------------------------------------------

def test_publish_and_get_since_ordering(load):
    events = load("events")
    events.publish("caption", "one")
    events.publish("caption", "two")
    events.publish("timer", "pasta timer")

    seq, evs = events.get_since(0)
    assert len(evs) == 3
    assert [e["kind"] for e in evs] == ["caption", "caption", "timer"]
    assert [e["data"] for e in evs] == ["one", "two", "pasta timer"]

    # The returned seq is a forward cursor: replaying from it yields nothing.
    _seq2, evs2 = events.get_since(seq)
    assert evs2 == []

    # A later publish is visible only to a poll from the old cursor.
    events.publish("timer", "sauce timer")
    seq3, evs3 = events.get_since(seq)
    assert [e["kind"] for e in evs3] == ["timer"]
    assert evs3[0]["data"] == "sauce timer"
    assert seq3 > seq


def test_get_since_only_returns_newer_than_cursor(load):
    events = load("events")
    for i in range(3):
        events.publish("caption", i)
    cursor, evs = events.get_since(0)
    assert [e["data"] for e in evs] == [0, 1, 2]

    events.publish("caption", 3)
    events.publish("caption", 4)
    _, tail = events.get_since(cursor)
    assert [e["data"] for e in tail] == [3, 4]  # only events past the cursor


def test_ring_buffer_overflow_drops_oldest(load):
    events = load("events")
    for i in range(RING + 100):  # 600 events into a 500 ring
        events.publish("caption", i)

    _seq, evs = events.get_since(0)
    assert len(evs) == RING            # capped at the ring size
    assert evs[-1]["data"] == RING + 99  # newest retained (599)
    assert evs[0]["data"] == 100         # oldest 100 (0..99) were dropped


# --- timers ---------------------------------------------------------------

def test_timer_fires_speaks_and_publishes_event(load, monkeypatch):
    audio = load("audio")
    spoken = []
    # The fire callback resolves audio.speak as a module global at call time.
    monkeypatch.setattr(audio, "speak",
                        lambda text, *a, **k: spoken.append(text))
    events = load("events")
    timers = load("timers")

    timers.set_timer("pasta", 0.05)

    fired = _wait_until(
        lambda: bool(spoken)
        and any(e.get("kind") == "timer" for e in events.get_since(0)[1])
    )
    assert fired, "timer did not fire within the timeout"
    assert any("pasta" in s and "done" in s.lower() for s in spoken)

    _seq, evs = events.get_since(0)
    assert any(e.get("kind") == "timer" for e in evs)


def test_list_and_cancel_timer(load):
    timers = load("timers")
    timers.set_timer("bread", 30)  # long enough not to fire during the test

    assert "bread" in _timer_names(timers.list_timers())
    assert timers.cancel_timer("bread")  # truthy on a real cancel
    assert "bread" not in _timer_names(timers.list_timers())

    assert not timers.cancel_timer("no-such-timer")  # falsy on an unknown name


def test_multiple_named_timers_coexist(load):
    timers = load("timers")
    timers.set_timer("pasta", 30)
    timers.set_timer("sauce", 45)
    names = _timer_names(timers.list_timers())
    assert "pasta" in names and "sauce" in names
    timers.cancel_timer("pasta")
    timers.cancel_timer("sauce")
