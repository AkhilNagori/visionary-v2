"""Visionary SDK — three functions, infinite hacks.

The whole platform boils down to a camera, a speaker, and a mic. This module is
that surface, nothing more: grab a still, say something, hear a reply. Everything
else (a mode, a party trick, a copilot) is those three composed with a prompt.

    capture() -> bytes     # a JPEG of whatever you're facing
    speak(text)            # say it out loud (Piper TTS)
    listen(max_s=15) -> str # record until you stop talking, transcribed to text

Example — a three-line "what am I looking at?" hack::

    import sdk, brain

    sdk.speak("Ask me anything.")
    question = sdk.listen()               # blocks until you finish speaking
    photo = sdk.capture()                 # grab a still
    answer = brain.see(photo, question)   # any prompt you want
    sdk.speak(answer)

Runs unchanged in SIM mode (VISIONARY_SIM=1) on a laptop: capture() returns a
generated test image, speak() prints, and listen() returns "" without a
transcription backend. listen() beeps and returns "" rather than raising, so a
hack loop keeps going when the wearer is offline.
"""

import os
from typing import Optional

import audio
import brain
import vision


def capture() -> bytes:
    """A full-resolution JPEG of the current view."""
    return vision.capture_jpeg()


def speak(text: str) -> None:
    """Say ``text`` out loud (no-op on empty text)."""
    audio.speak(text)


def listen(max_s: float = 15.0) -> str:
    """Record until the wearer stops talking (or ``max_s``) and transcribe it.

    Returns "" when nothing was said or transcription is unavailable — and beeps
    so the wearer knows it was heard-but-not-understood rather than ignored.
    """
    wav = audio.record_until_silence(max_s=float(max_s))  # type: Optional[str]
    if not wav:
        return ""
    try:
        text = brain.transcribe(wav)
    except brain.BrainOffline:
        audio.beep("offline")
        return ""
    except Exception:
        audio.beep("err")
        return ""
    finally:
        try:
            if wav and os.path.exists(wav):
                os.remove(wav)
        except OSError:
            pass
    return (text or "").strip()
