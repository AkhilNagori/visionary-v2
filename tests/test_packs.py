"""packs.py (v3 modes-as-data) contract: the builtin pack loads and every mode
validates, pipelines are a closed set, and install_pack ingests a local pack
(file:// URL) while rejecting anything malformed.

packs/flashcards/timers/events are v3 firmware modules that live outside
conftest's HOME-reset set, so this file carries a small autouse fixture to purge
them between tests (same reason the shared modules are purged): each test must
re-import them fresh against its own throwaway VISIONARY_HOME.
"""

import json
import sys

import pytest

# The five pipelines a mode may declare (ARCHITECTURE v3 "modes as data").
PIPELINES = frozenset(("see", "ask", "listen", "loop", "session"))

# v3 firmware modules whose module-level state (loaded packs, DB handles, event
# ring, timer table) is bound to VISIONARY_HOME at import time.
_V3_MODULES = ("packs", "events", "flashcards", "timers", "sdk")


@pytest.fixture(autouse=True)
def _purge_v3():
    def purge():
        for name in _V3_MODULES:
            sys.modules.pop(name, None)
    purge()
    yield
    purge()


def _mode_fixture(mode_id="warbler", pipeline="see"):
    return {
        "id": mode_id,
        "name": "Warbler ID",
        "category": "nature",
        "description": "Identify the warbler in view.",
        "pipeline": pipeline,
        "prompt": "Name the bird species and one field mark.",
        "options": {},
    }


def test_builtin_pack_loads_and_every_mode_validates(load):
    packs = load("packs")
    modes = packs.load_modes()

    assert isinstance(modes, dict)
    assert len(modes) >= 30  # ARCHITECTURE ships ~35 builtin modes

    for mode_id, mode in modes.items():
        assert mode["id"] == mode_id, "modes keyed by their own id"
        for key in ("name", "category", "description", "prompt"):
            assert isinstance(mode[key], str)
        assert mode["name"] and mode["prompt"]  # non-empty where it matters
        assert mode["pipeline"] in PIPELINES  # pipelines are known values
        assert isinstance(mode.get("options", {}), dict)


def test_builtin_pipelines_are_a_closed_known_set(load):
    packs = load("packs")
    modes = packs.load_modes()

    used = {mode["pipeline"] for mode in modes.values()}
    assert used.issubset(PIPELINES)
    # The contract pins these pipelines to specific builtin modes:
    # whiteboard_email/skim -> see, teleprompter/pronunciation -> listen,
    # recipe/ikea -> session. All three must show up.
    assert {"see", "listen", "session"}.issubset(used)


def test_signature_builtin_modes_present(load):
    packs = load("packs")
    modes = packs.load_modes()
    # A sample of the ★ features the contract names explicitly as builtin ids.
    for expected in ("skim", "math", "pokedex", "recipe", "teleprompter",
                     "roast", "chess"):
        assert expected in modes, "missing builtin mode: " + expected


def test_list_packs_marks_the_builtin_pack(load):
    packs = load("packs")
    listed = packs.list_packs()

    assert isinstance(listed, list)
    builtins = [p for p in listed if p.get("builtin")]
    assert len(builtins) == 1, "exactly one shipped builtin pack"
    assert builtins[0]["modes"], "builtin pack advertises its mode ids"
    for pack in listed:
        assert isinstance(pack["name"], str) and pack["name"]
        assert isinstance(pack["modes"], list)


def test_install_pack_from_local_file_url(load, tmp_path):
    packs = load("packs")
    pack = {"name": "birder", "modes": [_mode_fixture("warbler", "see")]}
    pack_file = tmp_path / "birder.json"
    pack_file.write_text(json.dumps(pack))

    before = set(packs.load_modes())
    ids = packs.install_pack(pack_file.as_uri())  # file:// fetch

    assert "warbler" in ids
    modes = packs.load_modes()
    assert "warbler" in modes
    assert modes["warbler"]["pipeline"] == "see"
    assert set(modes) - before == {"warbler"}  # only the new mode appeared
    assert "birder" in [p["name"] for p in packs.list_packs()]  # persisted


def test_install_pack_rejects_invalid_mode(load, tmp_path):
    packs = load("packs")
    before = set(packs.load_modes())
    # Unknown pipeline + missing required fields: must not validate.
    bad = {"name": "broken", "modes": [{"id": "x", "pipeline": "telepathy"}]}
    bad_file = tmp_path / "broken.json"
    bad_file.write_text(json.dumps(bad))

    with pytest.raises(Exception):
        packs.install_pack(bad_file.as_uri())

    assert set(packs.load_modes()) == before  # nothing leaked into the registry
    assert "broken" not in [p["name"] for p in packs.list_packs()]


def test_install_pack_rejects_malformed_json(load, tmp_path):
    packs = load("packs")
    bad_file = tmp_path / "notjson.json"
    bad_file.write_text("{ this is : not json")
    with pytest.raises(Exception):
        packs.install_pack(bad_file.as_uri())


def test_remove_installed_pack_but_not_builtin(load, tmp_path):
    packs = load("packs")
    pack = {"name": "chesspack", "modes": [_mode_fixture("blitz", "session")]}
    pack_file = tmp_path / "chesspack.json"
    pack_file.write_text(json.dumps(pack))
    packs.install_pack(pack_file.as_uri())
    assert "blitz" in packs.load_modes()

    assert packs.remove_pack("chesspack") is True
    assert "blitz" not in packs.load_modes()
    assert "chesspack" not in [p["name"] for p in packs.list_packs()]

    # The builtin pack is not removable; its name comes from list_packs().
    builtin_name = next(p["name"] for p in packs.list_packs() if p.get("builtin"))
    assert packs.remove_pack(builtin_name) is False
    assert packs.remove_pack("no-such-pack") is False
