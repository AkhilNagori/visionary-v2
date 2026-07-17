"""Triple press: magic recorder — record, transcribe, summarize, keep."""

import os
import shutil
import threading
import time

import audio
import brain
import state
from metrics import StageTimer
from modes import index_memory

_rec = audio.Recorder()
_lock = threading.Lock()


def is_recording():
    # type: () -> bool
    return _rec.recording


def toggle():
    # type: () -> None
    try:
        with _lock:
            if _rec.recording:
                _stop()
            else:
                audio.beep("rec_start")
                _rec.start()
    except Exception:
        try:
            audio.beep("err")
            audio.speak("Sorry, the recorder failed.")
        except Exception:
            pass


def _stop():
    # type: () -> None
    audio.beep("rec_stop")
    wav = _rec.stop()
    # Spoken before transcription: long recordings can take a while to process.
    audio.speak("Processing recording.")
    timer = StageTimer()

    rec_dir = os.path.join(state.HOME, "recordings")
    os.makedirs(rec_dir, exist_ok=True)
    dest = os.path.join(rec_dir, time.strftime("%Y%m%d-%H%M%S") + ".wav")
    shutil.move(wav, dest)

    history = state.get_history()
    try:
        transcript = brain.transcribe(dest).strip()
    except brain.BrainOffline:
        audio.beep("offline")
        audio.speak("Recording saved. I need internet to transcribe it.")
        history.add("recording", "", audio_path=dest)
        timer.log("recording")
        return
    except Exception:
        audio.beep("err")
        audio.speak("Recording saved, but transcription failed.")
        history.add("recording", "", audio_path=dest)
        timer.log("recording")
        return
    timer.mark("stt")

    if not transcript:
        audio.speak("Recording saved, but I couldn't hear any speech in it.")
        history.add("recording", "", audio_path=dest)
        timer.log("recording")
        return

    try:
        summary = brain.chat(
            [{"role": "user", "content": transcript}],
            system=brain.SUMMARY_PROMPT,
        ).strip()
    except (brain.BrainOffline, RuntimeError):
        audio.beep("offline")
        audio.speak("Recording transcribed, but I couldn't make a summary without internet.")
        entry_id = history.add("recording", transcript, audio_path=dest)
        index_memory(entry_id, transcript)
        timer.log("recording")
        return
    timer.mark("summary")

    audio.speak(summary if summary else "Recording saved.")
    entry_id = history.add(
        "recording", transcript, extra={"summary": summary}, audio_path=dest)
    index_memory(entry_id, transcript + "\n" + summary)
    timer.log("recording")
