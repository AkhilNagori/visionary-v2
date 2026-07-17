"""dashboard/app.py contract: /fleet returns the in-RAM snapshot and / serves
the page — with the device poller kept off the network. Skipped without
fastapi/httpx."""

import pytest

pytest.importorskip("fastapi")
pytest.importorskip("httpx")


def test_fleet_snapshot_and_page(load, monkeypatch, tmp_path):
    # Empty fleet: the poller has nothing to fetch, so no network call can
    # happen regardless of its timing.
    devices = tmp_path / "devices.json"
    devices.write_text("[]")
    monkeypatch.setenv("VISIONARY_FLEET_CONFIG", str(devices))

    app_mod = load("app")

    # Belt and suspenders: if a poll ever fires, it must not reach the network.
    class _NoNetwork:
        def get(self, *a, **k):
            raise AssertionError("dashboard must not make real network calls")

    monkeypatch.setattr(app_mod, "requests", _NoNetwork(), raising=False)

    from fastapi.testclient import TestClient
    client = TestClient(app_mod.app)

    fleet = client.get("/fleet")
    assert fleet.status_code == 200
    snapshot = fleet.json()
    assert isinstance(snapshot, dict)  # {device name: {online, last_seen, ...}}

    page = client.get("/")
    assert page.status_code == 200
    assert "text/html" in page.headers["content-type"]
