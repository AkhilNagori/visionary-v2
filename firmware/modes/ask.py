"""Hold-to-ask: record a question while held, answer about the current view.

Also serves as the voice assistant — a photo is always attached to the
current question, and the last 6 exchanges live in an in-RAM deque that is
sent as text-only prior turns (cleared on shutdown, never persisted).
"""

import os
from collections import deque
from typing import List

import audio
import brain
import state
import vision
from metrics import StageTimer
from modes import stream_see

_memory = deque(maxlen=6)  # (question, answer)
_rec = audio.Recorder()


def ask_begin():
    # type: () -> None
    try:
        if _rec.recording:
            return
        audio.beep("rec_start")
        _rec.start()
    except Exception:
        try:
            audio.beep("err")
            audio.speak("Sorry, I couldn't start listening.")
        except Exception:
            pass


def ask_end(cancelled=False):
    # type: (bool) -> None
    try:
        _ask_end(cancelled)
    except Exception:
        try:
            audio.beep("err")
            audio.speak("Sorry, that question failed. Please try again.")
        except Exception:
            pass


def reset_memory():
    # type: () -> None
    _memory.clear()


def _history_msgs():
    # type: () -> List[dict]
    msgs = []
    for question, answer in _memory:
        msgs.append({"role": "user", "content": question})
        msgs.append({"role": "assistant", "content": answer})
    return msgs


def _ask_end(cancelled):
    # type: (bool) -> None
    if not _rec.recording:
        return
    wav = _rec.stop()
    if cancelled:
        _discard(wav)
        return
    audio.beep("rec_stop")
    timer = StageTimer()

    try:
        question = brain.transcribe(wav).strip()
    except brain.BrainOffline:
        audio.beep("offline")
        audio.speak("I can't understand speech right now. No internet and no offline listener.")
        return
    except Exception:
        audio.beep("err")
        audio.speak("Sorry, I couldn't process your question.")
        return
    finally:
        _discard(wav)
    timer.mark("stt")

    if not question:
        audio.beep("err")
        audio.speak("I didn't catch that. Hold the button and ask again.")
        return

    jpeg = vision.capture_jpeg()
    image_path = vision.save_capture(jpeg)
    timer.mark("capture")

    # brain.see has no system parameter, so ASK_SYSTEM rides in the turn text.
    prompt = brain.ASK_SYSTEM + "\n\nQuestion: " + question
    try:
        answer = stream_see(jpeg, prompt, timer, history_msgs=_history_msgs())
    except brain.BrainOffline:
        audio.beep("offline")
        audio.speak("I need internet to answer questions.")
        return
    except RuntimeError:
        audio.beep("err")
        audio.speak("Sorry, I couldn't get an answer. Try again.")
        return

    _memory.append((question, answer))
    state.get_history().add("ask", answer, extra={"question": question}, image_path=image_path)
    timer.log("ask")


def _discard(path):
    # type: (str) -> None
    try:
        if path and os.path.exists(path):
            os.remove(path)
    except OSError:
        pass
