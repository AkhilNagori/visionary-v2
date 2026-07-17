"""flashcards.py (v3 auto-flashcards) contract: generate today's reading into
Q/A cards via brain.chat, expose the due queue, and grade with SM-2-lite.

The model call is the only network seam: brain.chat is monkeypatched to return
a fixed JSON deck, so generation is deterministic and offline. SM-2 transitions
are asserted as invariants read straight from the cards table (schema is fixed
by the contract), not against a specific ease/interval formula.
"""

import json
import sqlite3
import sys

import pytest

_V3_MODULES = ("packs", "events", "flashcards", "timers", "sdk")

# Four distinct cards so the four SM-2 grades can be compared side by side.
_DECK_JSON = json.dumps([
    {"question": "What is the capital of France?", "answer": "Paris."},
    {"question": "What is 7 times 8?", "answer": "56."},
    {"question": "Who wrote Hamlet?", "answer": "William Shakespeare."},
    {"question": "What gas do plants absorb?", "answer": "Carbon dioxide."},
])


@pytest.fixture(autouse=True)
def _purge_v3():
    def purge():
        for name in _V3_MODULES:
            sys.modules.pop(name, None)
    purge()
    yield
    purge()


def _seed_today(state):
    hist = state.get_history()
    hist.add("read", "Photosynthesis converts light into chemical energy.")
    hist.add("read", "The French Revolution began in 1789 in Paris.")


def _generate(load, monkeypatch, deck_json=_DECK_JSON, n=10):
    state = load("state")
    brain = load("brain")
    flashcards = load("flashcards")
    _seed_today(state)
    # brain.chat is the sole model call; return the fixed deck instead of a
    # network request. is_online is forced True in case generation gates on it.
    monkeypatch.setattr(brain, "chat",
                        lambda messages, system=None, on_text=None: deck_json)
    monkeypatch.setattr(brain, "is_online", lambda force=False: True,
                        raising=False)
    cards = flashcards.generate_from_today(n)
    return state, flashcards, cards


def _card_stats(state, card_id):
    conn = sqlite3.connect(state.DB_PATH)
    conn.execute("PRAGMA busy_timeout = 5000")
    try:
        row = conn.execute(
            "SELECT interval_d, ease FROM cards WHERE id = ?", (card_id,)
        ).fetchone()
    finally:
        conn.close()
    assert row is not None, "card %d missing from the cards table" % card_id
    return {"interval_d": row[0], "ease": row[1]}


def test_generate_from_today_creates_cards(load, monkeypatch):
    _state, flashcards, cards = _generate(load, monkeypatch)
    assert len(cards) == 4  # one per deck entry

    due = flashcards.due_cards()
    assert len(due) == 4  # freshly generated cards are all due immediately
    questions = {c["question"] for c in due}
    assert "What is the capital of France?" in questions
    for card in due:
        assert isinstance(card["id"], int)
        assert card["question"] and card["answer"]


def test_generate_offline_yields_no_cards(load, monkeypatch):
    # Generation is best-effort: a model failure (offline or API error) produces
    # an empty deck, never an exception, so callers own the spoken feedback.
    state = load("state")
    brain = load("brain")
    flashcards = load("flashcards")
    _seed_today(state)

    def offline(*_a, **_k):
        raise brain.BrainOffline("no network")

    monkeypatch.setattr(brain, "chat", offline)
    monkeypatch.setattr(brain, "is_online", lambda force=False: False,
                        raising=False)
    assert flashcards.generate_from_today(10) == []
    assert flashcards.due_cards() == []  # nothing was written


def test_sm2_grade_transitions_are_monotonic(load, monkeypatch):
    state, flashcards, _cards = _generate(load, monkeypatch)
    ids = sorted(c["id"] for c in flashcards.due_cards())
    assert len(ids) == 4

    # Fresh, identical cards graded again/hard/good/easy (0..3). Later intervals
    # must never be shorter than earlier ones, and easy must beat again.
    intervals, eases = {}, {}
    for card_id, grade in zip(ids, (0, 1, 2, 3)):
        result = flashcards.review(card_id, grade)
        assert result  # truthy: updated card (dict) or ok flag, never None/False
        stats = _card_stats(state, card_id)
        intervals[grade] = stats["interval_d"]
        eases[grade] = stats["ease"]

    assert intervals[0] <= intervals[1] <= intervals[2] <= intervals[3]
    assert intervals[3] > intervals[0]          # easy schedules further than again
    assert eases[0] <= eases[3]                 # again never eases more than easy
    assert all(e > 0 for e in eases.values())   # ease stays a positive multiplier


def test_good_review_drops_card_from_due_queue(load, monkeypatch):
    _state, flashcards, _cards = _generate(load, monkeypatch)
    due_before = flashcards.due_cards()
    target = due_before[0]["id"]

    flashcards.review(target, 3)  # easy: pushes the next review into the future

    remaining = [c["id"] for c in flashcards.due_cards()]
    assert target not in remaining
    assert len(remaining) == len(due_before) - 1  # exactly one card left the queue


def test_review_unknown_card_returns_falsy(load, monkeypatch):
    _state, flashcards, _cards = _generate(load, monkeypatch)
    assert not flashcards.review(999999, 2)  # 404 signal for the API layer
