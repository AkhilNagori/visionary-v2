"""GestureEngine contract: single/double/triple burst resolution, hold ->
on_hold_start / on_hold_end(cancelled=False), and a full hold ->
on_hold_end(cancelled=True) + on_shutdown.

Uses tiny real windows and real sleeps rather than an injected clock so the
threading.Timer machinery (the part that actually ships) is exercised end to
end. Windows: multi_window 0.08s, hold 0.15s, shutdown 0.4s.
"""

import time

import pytest

MULTI = 0.08
HOLD = 0.15
SHUTDOWN = 0.4


def _engine(load):
    main = load("main")
    rec = {"single": [], "double": [], "triple": [],
           "hold_start": [], "hold_end": [], "shutdown": []}

    def on_hold_end(cancelled=False):
        rec["hold_end"].append(cancelled)

    engine = main.GestureEngine(
        on_single=lambda: rec["single"].append(1),
        on_double=lambda: rec["double"].append(1),
        on_triple=lambda: rec["triple"].append(1),
        on_hold_start=lambda: rec["hold_start"].append(1),
        on_hold_end=on_hold_end,
        on_shutdown=lambda: rec["shutdown"].append(1),
        multi_window=MULTI, hold_time=HOLD, shutdown_time=SHUTDOWN,
    )
    return engine, rec


def _click(engine):
    engine.press()
    engine.release()


def test_single_press(load):
    engine, rec = _engine(load)
    _click(engine)
    time.sleep(MULTI + 0.15)
    assert rec["single"] == [1]
    assert rec["double"] == [] and rec["triple"] == []
    assert rec["hold_start"] == [] and rec["hold_end"] == []


def test_double_press(load):
    engine, rec = _engine(load)
    _click(engine)
    _click(engine)
    time.sleep(MULTI + 0.15)
    assert rec["double"] == [1]
    assert rec["single"] == [] and rec["triple"] == []


def test_triple_press(load):
    engine, rec = _engine(load)
    _click(engine)
    _click(engine)
    _click(engine)
    time.sleep(MULTI + 0.15)
    assert rec["triple"] == [1]
    assert rec["single"] == [] and rec["double"] == []


def test_hold_then_release_before_shutdown(load):
    engine, rec = _engine(load)
    engine.press()
    time.sleep(HOLD + 0.1)          # past hold_time, before shutdown_time
    assert rec["hold_start"] == [1]  # fires while still held
    engine.release()
    assert rec["hold_end"] == [False]
    assert rec["shutdown"] == []
    assert rec["single"] == []       # a hold is never a click


def test_full_hold_cancels_ask_and_shuts_down(load):
    engine, rec = _engine(load)
    engine.press()
    time.sleep(SHUTDOWN + 0.15)      # never released
    assert rec["hold_start"] == [1]
    assert rec["hold_end"] == [True]  # ask cancelled
    assert rec["shutdown"] == [1]
    # contract order: hold_start before the cancelling hold_end before shutdown
    assert rec["hold_start"] and rec["hold_end"] and rec["shutdown"]
