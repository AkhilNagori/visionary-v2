"""memory.py (Tier-3 visual memory) contract: FTS5 search offline, cosine
ranking when embeddings are available, and reindex_pending accounting.

The seam under test is embed(): monkeypatched to None models "offline" (search
must still work via FTS5), and monkeypatched to deterministic orthogonal
vectors models "online" (search ranks by cosine similarity). No network."""

import pytest


def _force_online(monkeypatch, brain, memory):
    monkeypatch.setenv("OPENAI_API_KEY", "o")
    # Cover both wiring styles (memory calling brain.is_online, or importing it).
    monkeypatch.setattr(brain, "is_online", lambda force=False: True, raising=False)
    monkeypatch.setattr(memory, "is_online", lambda *a, **k: True, raising=False)


def test_index_and_search_offline_uses_fts5(load, monkeypatch):
    state = load("state")
    memory = load("memory")
    monkeypatch.setattr(memory, "embed", lambda texts: None)  # offline: no vectors

    hist = state.get_history()
    door = hist.add("read", "The door said room 204 in the east hall.")
    menu = hist.add("read", "Cafeteria lunch menu: pizza and salad.")
    memory.index_entry(door, "The door said room 204 in the east hall.")
    memory.index_entry(menu, "Cafeteria lunch menu: pizza and salad.")

    results = memory.search("room 204", k=5)
    assert results, "FTS5 search returned nothing offline"
    top = results[0]
    assert top["id"] == door
    assert "score" in top
    assert top["kind"] == "read"          # a full history entry dict...
    assert "room 204" in top["text"]      # ...not just an id
    assert menu not in [r["id"] for r in results]  # unrelated entry excluded


def test_search_never_requires_network(load, monkeypatch):
    # embed() raising would mean a network attempt; search must not call it in a
    # way that propagates. Model the offline contract: embed returns None.
    state = load("state")
    memory = load("memory")
    monkeypatch.setattr(memory, "embed", lambda texts: None)
    hist = state.get_history()
    eid = hist.add("read", "blue umbrella by the front office window")
    memory.index_entry(eid, "blue umbrella by the front office window")
    results = memory.search("umbrella office")
    assert any(r["id"] == eid for r in results)


def test_search_ranks_by_cosine_when_embedded(load, monkeypatch):
    pytest.importorskip("numpy")
    state = load("state")
    brain = load("brain")
    memory = load("memory")
    _force_online(monkeypatch, brain, memory)

    vectors = {
        "apple pie recipe card": [1.0, 0.0, 0.0],
        "blue door room number": [0.0, 1.0, 0.0],
    }

    def fake_embed(texts):
        return [vectors.get(t, [0.0, 0.0, 1.0]) for t in texts]

    monkeypatch.setattr(memory, "embed", fake_embed)

    hist = state.get_history()
    a = hist.add("read", "apple pie recipe card")
    b = hist.add("read", "blue door room number")
    memory.index_entry(a, "apple pie recipe card")
    memory.index_entry(b, "blue door room number")
    memory.reindex_pending()  # guarantee vectors are stored regardless of gating

    results = memory.search("apple pie recipe card", k=2)
    assert results[0]["id"] == a                       # aligned vector wins
    assert results[0]["score"] >= results[-1]["score"]  # sorted best-first


def test_reindex_pending_counts_then_drains(load, monkeypatch):
    pytest.importorskip("numpy")
    state = load("state")
    brain = load("brain")
    memory = load("memory")

    hist = state.get_history()
    ids = [hist.add("read", "note %d about apples" % i) for i in range(3)]

    # Indexed offline -> FTS5 rows exist but no embeddings (pending).
    monkeypatch.setattr(memory, "embed", lambda texts: None)
    for eid in ids:
        memory.index_entry(eid, "note about apples")

    # Now online with embeddings available.
    _force_online(monkeypatch, brain, memory)
    monkeypatch.setattr(memory, "embed", lambda texts: [[1.0, 0.0] for _ in texts])

    assert memory.reindex_pending() == 3
    assert memory.reindex_pending() == 0  # nothing pending on the second pass
