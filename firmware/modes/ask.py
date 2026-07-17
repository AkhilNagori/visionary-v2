"""Hold-to-ask: record a question while held, answer about the current view.

Also the voice assistant. A photo is always attached to the current question,
and the last 6 exchanges live in an in-RAM deque sent as text-only prior turns
(cleared on shutdown, never persisted).

Tier 3 agent wiring: the model may call two tools while answering —
search_memory (over the on-device visual-memory index) and phone_action (queue
a calendar event or reminder for the paired phone to execute).
"""

import os
import time
from collections import deque
from typing import List

import audio
import brain
import memory
import state
import vision
from metrics import StageTimer
from modes import index_memory, stream_see

_memory = deque(maxlen=6)  # (question, answer) text-only exchange history
_rec = audio.Recorder()


def ask_begin():
    # type: () -> None
    try:
        if _rec.recording:
            return
        audio.beep("rec_start")
        _rec.start()
    except Exception:
        _fail("Sorry, I couldn't start listening.")


def ask_end(cancelled=False):
    # type: (bool) -> None
    try:
        if not _rec.recording:
            return
        wav = _rec.stop()
        if cancelled:
            _discard(wav)
            return
        audio.beep("rec_stop")
        _answer(wav)
    except Exception:
        _fail("Sorry, that question failed. Please try again.")


def ask_from_wake():
    # type: () -> None
    """Wake-word entry: listen until silence instead of a held button."""
    try:
        audio.beep("rec_start")
        wav = audio.record_until_silence()
        if wav is None:
            audio.speak("I didn't catch that.")
            return
        _answer(wav)
    except Exception:
        _fail("Sorry, that question failed. Please try again.")


def reset_memory():
    # type: () -> None
    _memory.clear()


def _answer(wav):
    # type: (str) -> None
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
        audio.speak("I didn't catch that. Ask again.")
        return

    jpeg = vision.capture_jpeg()
    image_path = vision.save_capture(jpeg)
    timer.mark("capture")

    # brain.see has no system parameter, so ASK_SYSTEM rides in the turn text.
    prompt = brain.ASK_SYSTEM + "\n\nQuestion: " + question
    try:
        answer = stream_see(
            jpeg, prompt, timer,
            history_msgs=_history_msgs(),
            tools=[brain.TOOL_SEARCH_MEMORY, brain.TOOL_PHONE_ACTION],
            tool_handlers={
                "search_memory": _tool_search_memory,
                "phone_action": _tool_phone_action,
            },
        )
    except brain.BrainOffline:
        _answer_offline(question)
        return
    except RuntimeError:
        audio.beep("err")
        audio.speak("Sorry, I couldn't get an answer. Try again.")
        return

    if answer.strip():
        _memory.append((question, answer))
    entry_id = state.get_history().add(
        "ask", answer, extra={"question": question}, image_path=image_path)
    index_memory(entry_id, question + "\n" + answer)
    timer.log("ask")


def _answer_offline(question):
    # type: (str) -> None
    audio.beep("offline")
    hits = memory.search(question, k=1)  # FTS5 works without a network
    if hits and (hits[0].get("text") or "").strip():
        audio.speak(hits[0]["text"].strip())
    else:
        audio.speak("I need internet to answer questions.")


# ---------------- tool handlers ----------------

def _tool_search_memory(tool_input):
    # type: (dict) -> str
    query = (tool_input.get("query") or "").strip()
    if not query:
        return "No search query was given."
    try:
        k = int(tool_input.get("k") or 5)
    except (TypeError, ValueError):
        k = 5
    hits = memory.search(query, max(1, k))
    if not hits:
        return "No matching memories found."
    lines = []
    for hit in hits:
        text = " ".join((hit.get("text") or "").split())
        if len(text) > 200:
            text = text[:200].rstrip() + "..."
        lines.append("%s: %s" % (_relative_time(hit.get("ts")), text))
    return "\n".join(lines)


def _tool_phone_action(tool_input):
    # type: (dict) -> str
    action_type = tool_input.get("type")
    if action_type not in ("calendar_event", "reminder"):
        return "I can only add calendar events or reminders."
    title = (tool_input.get("title") or "").strip()
    if not title:
        return "That action needs a title."
    payload = {"title": title}
    notes = (tool_input.get("notes") or "").strip()
    if notes:
        payload["notes"] = notes
    if action_type == "calendar_event":
        date = (tool_input.get("date") or "").strip()
        if not date:
            return "A calendar event needs a date."
        payload["date"] = date
    state.get_actions().add(action_type, payload)
    return "Queued for your phone."


def _relative_time(ts):
    # type: (object) -> str
    if not ts:
        return "recently"
    delta = time.time() - float(ts)
    if delta < 90:
        return "just now"
    minutes = delta / 60.0
    if minutes < 60:
        n = int(round(minutes))
        return "%d minute%s ago" % (n, "" if n == 1 else "s")
    hours = minutes / 60.0
    if hours < 24:
        n = int(round(hours))
        return "%d hour%s ago" % (n, "" if n == 1 else "s")
    days = int(round(hours / 24.0))
    if days == 1:
        return "yesterday"
    return "%d days ago" % days


def _history_msgs():
    # type: () -> List[dict]
    msgs = []
    for question, answer in _memory:
        msgs.append({"role": "user", "content": question})
        msgs.append({"role": "assistant", "content": answer})
    return msgs


def _fail(sentence):
    # type: (str) -> None
    try:
        audio.beep("err")
        audio.speak(sentence)
    except Exception:
        pass


def _discard(path):
    # type: (str) -> None
    try:
        if path and os.path.exists(path):
            os.remove(path)
    except OSError:
        pass
