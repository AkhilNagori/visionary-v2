"""Session pipeline: multi-turn spoken conversation anchored on one photo.

Session modes (recipe, quiz, socratic, ikea, i_spy, escape_room, ...) open by
capturing what the wearer is looking at, speaking an opening move through the
mode's crafted prompt, then holding a back-and-forth: the wearer talks, the
model answers, until they say "stop"/"exit", a single press stops the loop
(main.py sets stop_event), or the 20-turn cap is reached.

The photo rides on the FIRST user turn and stays in the conversation, so the
model can keep referring back to what was captured on every later turn (recipe
step 2 still "sees" the recipe). Every turn goes through brain.chat with the
mode prompt as the system prompt.
"""

import base64
import os
import re

import audio
import brain
import state
import vision
from metrics import StageTimer

MAX_TURNS = 20
_KICKOFF = "Begin."
_WORD = re.compile(r"[a-z0-9]+")
# The whole utterance must BE the exit command, not merely contain "stop"/"exit"
# somewhere. Session modes are exactly where those words occur mid-task ("should
# I stop stirring?", "stop the heat", "the diagram says stop at step 4"), so a
# substring match would kill the session and discard the photo-anchored context.
_EXIT_PHRASES = frozenset((
    "stop", "exit", "quit", "done",
    "stop session", "exit session", "end session", "quit session",
    "stop the session", "end the session", "close the session",
    "please stop", "stop please",
    "all done", "i am done", "i m done", "im done",
    "we are done", "we re done",
))


def run_session(mode, stop_event):
    # type: (dict, "threading.Event") -> None
    try:
        _loop(mode, stop_event)
    except brain.BrainOffline:
        raise  # loop manager clears active_mode so the watcher won't respawn offline
    except Exception:
        try:
            audio.beep("err")
            audio.speak("The session stopped after an error.")
        except Exception:
            pass


def _loop(mode, stop_event):
    # type: (dict, "threading.Event") -> None
    prompt = (mode.get("prompt") or "").strip()
    name = (mode.get("name") or "Session").strip()

    audio.beep("capture")
    timer = StageTimer()
    try:
        jpeg = vision.capture_jpeg()
    except Exception:
        audio.beep("err")
        audio.speak("I couldn't take a photo to start the session.")
        return
    timer.mark("capture")

    if stop_event.is_set():
        return

    # Turn 0: photo + a neutral kickoff; the mode prompt decides the opening move.
    messages = [{
        "role": "user",
        "content": [_image_block(jpeg), {"type": "text", "text": _KICKOFF}],
    }]
    try:
        opening = _say(messages, prompt, timer)
    except brain.BrainOffline:
        audio.beep("offline")
        audio.speak("%s needs an internet connection." % name)
        raise
    except RuntimeError:
        audio.beep("err")
        audio.speak("I couldn't start the session. Try again.")
        return
    timer.log("session")
    if not opening.strip():
        audio.speak("I'm ready. Tell me when to go.")
    # Never seed an empty assistant turn: the API rejects empty content on the
    # next call.
    messages.append({"role": "assistant", "content": opening.strip() or "Ready."})

    turns = 0
    while not stop_event.is_set() and turns < MAX_TURNS:
        wav = audio.record_until_silence(preserve_ambiguous=False)
        if stop_event.is_set():
            _discard(wav)
            break
        if wav is None:
            continue

        turn_timer = StageTimer()
        try:
            said = brain.transcribe(wav).strip()
        except brain.BrainOffline:
            audio.beep("offline")
            audio.speak("I can't hear you without speech recognition. Ending the session.")
            break
        except Exception:
            audio.beep("err")
            continue
        finally:
            _discard(wav)
        turn_timer.mark("stt")

        if stop_event.is_set():
            break
        if not said:
            continue
        if _is_exit(said):
            audio.speak("Okay, ending the session.")
            break

        turns += 1
        messages.append({"role": "user", "content": said})
        try:
            reply = _say(messages, prompt, turn_timer)
        except brain.BrainOffline:
            audio.beep("offline")
            audio.speak("I lost the connection. Ending the session.")
            break
        except RuntimeError:
            audio.beep("err")
            audio.speak("Sorry, I didn't get that. Try again.")
            messages.pop()  # drop the unanswered user turn so context stays clean
            turns -= 1
            continue
        turn_timer.log("session")
        if not reply.strip():
            audio.speak("I don't have anything to add. Say stop to finish.")
        messages.append({"role": "assistant", "content": reply.strip() or "Okay."})

    if turns >= MAX_TURNS:
        audio.speak("That's the end of this session.")


def _say(messages, prompt, timer):
    # type: (list, str, StageTimer) -> str
    """Stream a brain.chat reply through a SentenceSpeaker so the first
    sentence is audible while the model is still generating."""
    speaker = audio.SentenceSpeaker()
    marked = [False]

    def on_chunk(chunk):
        speaker.feed(chunk)
        if not marked[0] and speaker.first_audio_ts is not None:
            marked[0] = True
            timer.mark("tts_first")

    try:
        text = brain.chat(messages, system=prompt or None, on_text=on_chunk)
    except Exception:
        speaker.close()
        raise
    timer.mark("model")
    speaker.close()
    return text


def _image_block(jpeg):
    # type: (bytes) -> dict
    if jpeg[:8] == b"\x89PNG\r\n\x1a\n":
        media = "image/png"
    else:
        media = "image/jpeg"
    return {
        "type": "image",
        "source": {
            "type": "base64",
            "media_type": media,
            "data": base64.b64encode(jpeg).decode(),
        },
    }


def _is_exit(text):
    # type: (str) -> bool
    words = _WORD.findall(text.lower())
    if not words:
        return False
    return " ".join(words) in _EXIT_PHRASES


def _discard(path):
    # type: (str) -> None
    try:
        if path and os.path.exists(path):
            os.remove(path)
    except OSError:
        pass
