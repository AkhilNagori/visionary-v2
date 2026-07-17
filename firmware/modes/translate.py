"""Two-way interpreter loop, active while config two_way.enabled.

Direction heuristic — documented simplification: v1 does no local language
identification. Each utterance goes to the model with both configured
languages, and the model is asked to detect which of the two it is in and
translate it into the other, returning ONLY the translation. This costs
nothing extra (one round-trip per utterance either way), avoids shipping a
langid model on a 512MB Pi, and handles code-switching for free. The
trade-off: both directions come out of the same speaker — v1 cannot route
"their" language in-ear and "yours" out loud.
"""

import os

import audio
import brain
import state
from metrics import StageTimer

_SYSTEM = (
    "You are a strict two-way interpreter between two languages given by "
    "their codes: '{theirs}' and '{yours}'. The user message is one "
    "transcribed utterance. Decide which of the two languages it is in, "
    "then translate it into the other. Reply with ONLY the translation - "
    "no labels, no quotes, no commentary. If the utterance is in neither "
    "language, translate it into '{yours}'."
)


def run_two_way(stop_event):
    # type: ("threading.Event") -> None
    try:
        _loop(stop_event)
    except Exception:
        try:
            audio.beep("err")
            audio.speak("Two-way translation stopped after an error.")
        except Exception:
            pass


def _loop(stop_event):
    audio.speak("Two-way translation on.")
    while not stop_event.is_set():
        cfg = state.load_config()
        two_way = cfg.get("two_way") or {}
        system = _SYSTEM.format(
            theirs=two_way.get("theirs", "es"),
            yours=two_way.get("yours", "en"),
        )

        wav = audio.record_until_silence()
        if stop_event.is_set():
            _discard(wav)
            break
        if wav is None:
            continue

        timer = StageTimer()
        try:
            heard = brain.transcribe(wav).strip()
        except brain.BrainOffline:
            audio.beep("offline")
            audio.speak("Two-way translation needs internet. Stopping.")
            return
        except Exception:
            audio.beep("err")
            continue
        finally:
            _discard(wav)
        timer.mark("stt")

        if stop_event.is_set():
            break
        if not heard:
            continue

        try:
            translation = brain.chat(
                [{"role": "user", "content": heard}], system=system
            ).strip()
        except brain.BrainOffline:
            audio.beep("offline")
            audio.speak("Two-way translation needs internet. Stopping.")
            return
        except Exception:
            audio.beep("err")
            continue
        timer.mark("model")

        if stop_event.is_set():
            break
        if translation:
            audio.speak(translation, wait=True)
            state.get_history().add("translate", translation, extra={"heard": heard})
            timer.log("translate")
    audio.speak("Translation off.")


def _discard(path):
    # type: (str) -> None
    try:
        if path and os.path.exists(path):
            os.remove(path)
    except OSError:
        pass
