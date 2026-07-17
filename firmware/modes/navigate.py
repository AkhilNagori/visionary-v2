"""Tier 3 navigation assist, active while config navigation.enabled.

Periodic low-res captures become short spoken callouts about hazards, signage,
and doorways. This is assistive information, not a certified safety device —
that framing lives in the prompt, in the spoken disclaimer below, in the app,
and in the docs. Captures are sent to the vision API only while the wearer has
navigation explicitly enabled, and are never stored to history.
"""

import audio
import brain
import state
import vision
from metrics import StageTimer

_DISCLAIMER = "Navigation assist gives information, not safety guarantees."


def run_navigation(stop_event):
    # type: ("threading.Event") -> None
    try:
        _loop(stop_event)
    except brain.BrainOffline:
        raise  # loop manager clears config so the watcher won't respawn us offline
    except Exception:
        try:
            audio.beep("err")
            audio.speak("Navigation assist stopped after an error.")
        except Exception:
            pass


def _loop(stop_event):
    audio.speak(_DISCLAIMER)
    last_callout = ""
    while not stop_event.is_set():
        cfg = state.load_config()
        interval = float((cfg.get("navigation") or {}).get("interval_s") or 3.0)

        timer = StageTimer()
        try:
            jpeg = vision.capture_preview_jpeg()
        except Exception:
            audio.beep("err")
            _sleep(stop_event, interval)
            continue
        timer.mark("capture")

        if stop_event.is_set():
            break

        prompt = brain.NAVIGATE_PROMPT
        if last_callout:
            prompt += (
                "\n\nYour previous callout was: \"%s\". Only speak if something "
                "changed or there is something new worth saying; otherwise reply "
                "with the single token NONE." % last_callout
            )

        try:
            reply = brain.see(jpeg, prompt).strip()
        except brain.BrainOffline:
            audio.beep("offline")
            audio.speak("Navigation assist needs internet.")
            raise  # loop manager disables config so we don't respawn every ~5s
        except RuntimeError:
            audio.beep("err")
            _sleep(stop_event, interval)
            continue
        timer.mark("model")

        if stop_event.is_set():
            break
        if reply and reply.upper() != "NONE" and reply != last_callout:
            audio.speak(reply, wait=True)
            last_callout = reply
        timer.log("navigate")

        _sleep(stop_event, interval)


def _sleep(stop_event, seconds):
    # type: ("threading.Event", float) -> None
    stop_event.wait(max(0.0, seconds))
