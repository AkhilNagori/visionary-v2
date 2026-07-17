"""Single press: read the text in front of the wearer aloud."""

import audio
import brain
import state
import vision
from metrics import StageTimer
from modes import stream_see


def run_read():
    # type: () -> None
    try:
        _read()
    except Exception:
        try:
            audio.beep("err")
            audio.speak("Sorry, reading failed. Please try again.")
        except Exception:
            pass


def _read():
    # type: () -> None
    cfg = state.load_config()
    lang = cfg.get("language")
    timer = StageTimer()

    audio.beep("capture")
    jpeg = vision.capture_jpeg()
    image_path = vision.save_capture(jpeg)
    timer.mark("capture")

    if brain.is_online():
        try:
            text = stream_see(jpeg, brain.read_prompt(lang), timer)
        except (brain.BrainOffline, RuntimeError):
            text = ""
        if text:
            extra = {"language": lang} if lang else None
            state.get_history().add("read", text, extra=extra, image_path=image_path)
            timer.log("read")
            return

    audio.beep("offline")
    try:
        ocr_text = brain.ocr(jpeg).strip()
    except Exception:
        audio.beep("err")
        audio.speak("I can't read right now. There is no internet and no offline reader.")
        timer.log("read")
        return
    timer.mark("ocr")
    audio.speak(ocr_text if ocr_text else "I couldn't find any text.")
    state.get_history().add("read", ocr_text, image_path=image_path)
    timer.log("read")
