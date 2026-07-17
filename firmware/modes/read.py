"""Single press: read the text in front of the wearer aloud."""

import audio
import brain
import state
import vision
from metrics import StageTimer
from modes import index_memory, stream_see


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
            entry_id = state.get_history().add(
                "read", text, extra=extra, image_path=image_path)
            index_memory(entry_id, text)
            timer.log("read")
            return

    # AI inference is intentionally cloud-only. The local earcon still tells the
    # wearer what happened when Wi-Fi or the API is unavailable.
    audio.beep("offline")
    timer.log("read")
