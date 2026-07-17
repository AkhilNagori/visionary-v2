"""Live captions: transcribe nearby speech and publish it as events.

Built for deaf and hard-of-hearing wearers (one device, a second disability
served). VAD-chunked utterances are transcribed and pushed onto the event bus
so the paired app's Captions view can render them near-real-time. Normal
captions are NEVER spoken back — that would defeat the purpose and leak the
conversation out loud.

Two opt-in watchwords ride in config "captions":
  - listen_name: a word/phrase to be alerted about (your name, "gate change").
    A hit speaks a short alert and fires an event badge.
  - help_phrase: an emergency phrase. A hit speaks an alert, fires an event,
    AND queues a send_text phone action to the configured emergency_contact.

Alerts are debounced so a repeated phrase can't spam the wearer or, worse,
fire a burst of emergency texts.
"""

import os
import sys
import time

import audio
import brain
import events
import state
from metrics import StageTimer

_ALERT_COOLDOWN_S = 12.0     # min gap between spoken alerts for the same watchword
_HELP_TEXT_COOLDOWN_S = 60.0  # min gap between emergency texts
_last_fire = {}  # type: dict


def run_captions(stop_event):
    # type: ("threading.Event") -> None
    try:
        _loop(stop_event)
    except Exception:
        try:
            audio.beep("err")
            audio.speak("Live captions stopped after an error.")
        except Exception:
            pass


def _loop(stop_event):
    # type: ("threading.Event") -> None
    _last_fire.clear()
    audio.beep("ok")  # audible "captions on"; no speech, per the caption contract
    while not stop_event.is_set():
        wav = audio.record_until_silence()
        if stop_event.is_set():
            _discard(wav)
            break
        if wav is None:
            continue

        timer = StageTimer()
        try:
            text = brain.transcribe(wav).strip()
        except brain.BrainOffline:
            audio.beep("offline")
            audio.speak("Live captions need speech recognition, which isn't available offline.")
            break
        except Exception:
            audio.beep("err")
            continue
        finally:
            _discard(wav)
        timer.mark("stt")

        if stop_event.is_set():
            break
        if not text:
            continue

        _publish("caption", text)
        _check_watchwords(text)
        timer.log("captions")


def _check_watchwords(text):
    # type: (str) -> None
    cfg = state.load_config()
    captions = cfg.get("captions") or {}
    lower = text.lower()

    name = (captions.get("listen_name") or "").strip()
    if name and name.lower() in lower and _should_fire("name", _ALERT_COOLDOWN_S):
        _publish("caption_alert", text)
        audio.speak("Heads up. I heard %s." % name)

    phrase = (captions.get("help_phrase") or "").strip()
    if phrase and phrase.lower() in lower:
        # Safety-critical: never assert we messaged the contact unless we
        # actually queued the text this time. The text is on a longer cooldown
        # than the spoken alert, so decide the queue FIRST, then word the alert
        # to match what really happened.
        queued = False
        if _should_fire("help_text", _HELP_TEXT_COOLDOWN_S):
            _queue_help_text(cfg, text)
            queued = True
        if _should_fire("help", _ALERT_COOLDOWN_S):
            _publish("caption_alert", text)
            if queued:
                audio.speak("Emergency phrase heard. Messaging your emergency contact.")
            else:
                audio.speak("Emergency phrase heard.")


def _queue_help_text(cfg, text):
    # type: (dict, str) -> None
    payload = {"body": "Help requested. I heard: %s" % text}
    contact = (cfg.get("emergency_contact") or "").strip()
    if contact:
        payload["to"] = contact
    try:
        state.get_actions().add("send_text", payload)
    except Exception as exc:  # queuing must not crash the caption loop
        print("captions: could not queue help text: %s" % exc, file=sys.stderr)


def _should_fire(key, cooldown):
    # type: (str, float) -> bool
    now = time.monotonic()
    last = _last_fire.get(key)
    if last is not None and now - last < cooldown:
        return False
    _last_fire[key] = now
    return True


def _publish(kind, text):
    # type: (str, str) -> None
    try:
        events.publish(kind, text)
    except Exception as exc:  # a dead event bus must not stop captioning
        print("captions: event publish failed: %s" % exc, file=sys.stderr)


def _discard(path):
    # type: (str) -> None
    try:
        if path and os.path.exists(path):
            os.remove(path)
    except OSError:
        pass
