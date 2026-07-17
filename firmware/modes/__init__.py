"""Visionary action modes: read, describe, ask, recorder, translate.

stream_see() is the shared online-vision pipeline: it feeds Claude's
streamed chunks into a SentenceSpeaker so the first sentence is audible
while the model is still generating — the perceived-latency win the
whole product is pitched on.
"""

from typing import List, Optional

import audio
import brain
from metrics import StageTimer


def stream_see(jpeg, prompt, timer, history_msgs=None):
    # type: (bytes, str, StageTimer, Optional[List[dict]]) -> str
    """Stream brain.see() into a SentenceSpeaker; marks tts_first and model.

    Raises whatever brain.see raises. The speaker is always drained, so any
    sentences already queued finish speaking even when the stream fails.
    """
    speaker = audio.SentenceSpeaker()
    marked = [False]

    def on_chunk(chunk):
        speaker.feed(chunk)
        if not marked[0] and speaker.first_audio_ts is not None:
            marked[0] = True
            timer.mark("tts_first")

    try:
        text = brain.see(jpeg, prompt, on_text=on_chunk, history_msgs=history_msgs)
    except Exception:
        speaker.close()
        raise
    if not marked[0] and speaker.first_audio_ts is not None:
        timer.mark("tts_first")
    timer.mark("model")
    speaker.close()
    return text
