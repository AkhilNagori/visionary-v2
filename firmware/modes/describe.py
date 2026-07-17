"""Double press: describe the scene for the wearer."""

import audio
import brain
import state
import vision
from metrics import StageTimer
from modes import index_memory, stream_see


def run_describe():
    # type: () -> None
    try:
        _describe()
    except Exception:
        try:
            audio.beep("err")
            audio.speak("Sorry, describing failed. Please try again.")
        except Exception:
            pass


def _describe():
    # type: () -> None
    state.load_config()
    timer = StageTimer()

    audio.beep("capture")
    jpeg = vision.capture_jpeg()
    image_path = vision.save_capture(jpeg)
    timer.mark("capture")

    if brain.is_online():
        try:
            text = stream_see(jpeg, brain.DESCRIBE_PROMPT, timer)
        except (brain.BrainOffline, RuntimeError):
            text = ""
        if text:
            entry_id = state.get_history().add(
                "describe", text, image_path=image_path)
            index_memory(entry_id, text)
            timer.log("describe")
            return

    audio.beep("offline")
    audio.speak("Scene description needs internet. Reading any text instead.")
    try:
        ocr_text = brain.ocr(jpeg).strip()
    except Exception:
        audio.beep("err")
        audio.speak("I couldn't read any text either.")
        timer.log("describe")
        return
    timer.mark("ocr")
    audio.speak(ocr_text if ocr_text else "No text found.")
    entry_id = state.get_history().add("describe", ocr_text, image_path=image_path)
    index_memory(entry_id, ocr_text)
    timer.log("describe")
