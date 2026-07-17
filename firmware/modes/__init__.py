"""Visionary action modes: read, describe, ask, recorder, translate, navigate.

stream_see() is the shared online-vision pipeline: it feeds the model's streamed
chunks into a SentenceSpeaker so the first sentence is audible while the model
is still generating — the perceived-latency win the whole product is pitched on.

index_memory() is the shared best-effort hook that makes each saved history
entry searchable (Tier 3 visual memory) without ever letting an indexing
failure turn an already-spoken action into a spoken error.
"""

import sys
from typing import Callable, Dict, List, Optional

import audio
import brain
import memory
from metrics import StageTimer


def stream_see(jpeg, prompt, timer, history_msgs=None, tools=None, tool_handlers=None):
    # type: (bytes, str, StageTimer, Optional[List[dict]], Optional[List[dict]], Optional[Dict[str, Callable[[dict], str]]]) -> str
    """Stream brain.see() into a SentenceSpeaker; marks tts_first and model.

    Raises whatever brain.see raises. The speaker is always drained, so any
    sentences already queued finish speaking even when the stream fails. With
    tools supplied, brain.see runs its non-streaming tool loop and delivers the
    final answer to on_text once — still spoken, just without the token-by-token
    overlap that Tier 1 reading gets.
    """
    speaker = audio.SentenceSpeaker()
    marked = [False]

    def on_chunk(chunk):
        speaker.feed(chunk)
        if not marked[0] and speaker.first_audio_ts is not None:
            marked[0] = True
            timer.mark("tts_first")

    kwargs = {"on_text": on_chunk, "history_msgs": history_msgs}
    if tools is not None:
        # Only forward tool args when actually using tools, so the Tier 1 read
        # path never depends on the tool-use signature being wired up yet.
        kwargs["tools"] = tools
        kwargs["tool_handlers"] = tool_handlers

    try:
        text = brain.see(jpeg, prompt, **kwargs)
    except Exception:
        speaker.close()
        raise
    if not marked[0] and speaker.first_audio_ts is not None:
        timer.mark("tts_first")
    timer.mark("model")
    speaker.close()
    return text


def index_memory(entry_id, text):
    # type: (int, str) -> None
    """Make a saved entry searchable. Best-effort: an indexing failure must
    never convert a completed, already-spoken action into a spoken error
    (same philosophy as metrics)."""
    try:
        memory.index_entry(entry_id, text)
    except Exception as exc:
        print("modes: memory index failed: %s" % exc, file=sys.stderr)
