"""Spoken news briefing: fetch the wearer's RSS/Atom feeds and read a summary.

"Read me my feeds." Pulls config "feeds" (a list of RSS/Atom URLs), collects
the latest headlines with xml.etree, and has the brain condense them into a
short spoken briefing. Exposed both as a mode and as the TOOL_GET_BRIEFING tool
wired into ask.py, so the wearer can also just ask for it out loud.

Offline-degradable: if the summariser can't be reached the raw headlines are
read straight out; if the feeds themselves can't be reached the wearer is told.
"""

import re
import xml.etree.ElementTree as ET

import requests

import audio
import brain
import state
from metrics import StageTimer

_PER_FEED = 5
_MAX_ITEMS = 10
_FETCH_TIMEOUT = 8.0
_UA = {"User-Agent": "Visionary/1.0 (+https://visionary.local)"}

_BRIEFING_PROMPT = (
    "You are the voice of assistive smart glasses giving a spoken news "
    "briefing. Below are recent headlines and blurbs from the wearer's feeds. "
    "Summarise them into a short briefing to be read aloud by text-to-speech: "
    "group related stories, lead with what matters most, and keep it to about "
    "five or six short sentences of plain words. No markdown, no lists, no "
    "headings, no preamble like 'here is your briefing'."
)


def run_briefing():
    # type: () -> None
    try:
        _briefing()
    except Exception:
        try:
            audio.beep("err")
            audio.speak("Sorry, the briefing failed.")
        except Exception:
            pass


def _briefing():
    # type: () -> None
    cfg = state.load_config()
    feeds = [u for u in (cfg.get("feeds") or []) if isinstance(u, str) and u.strip()]
    if not feeds:
        audio.speak("You don't have any feeds set up yet.")
        return

    audio.speak("Getting your briefing.")
    timer = StageTimer()
    items = []
    for url in feeds:
        items.extend(_fetch_feed(url.strip()))
        if len(items) >= _MAX_ITEMS:
            break
    items = items[:_MAX_ITEMS]
    timer.mark("fetch")

    if not items:
        audio.beep("offline")
        audio.speak("I couldn't reach your feeds right now.")
        return

    blob = "\n".join("- %s%s" % (t, (": " + d) if d else "") for t, d in items)
    try:
        _speak_stream([{"role": "user", "content": blob}], _BRIEFING_PROMPT, timer)
    except (brain.BrainOffline, RuntimeError):
        # The reasoning call failed; try the raw headlines if TTS is reachable.
        audio.beep("offline")
        audio.speak("I couldn't summarise, so here are your headlines.")
        audio.speak(". ".join(t for t, _ in items[:5]) + ".")
        timer.log("briefing")
        return
    timer.log("briefing")


def _fetch_feed(url):
    # type: (str) -> list
    try:
        resp = requests.get(url, headers=_UA, timeout=_FETCH_TIMEOUT)
        if resp.status_code != 200:
            return []
        root = ET.fromstring(resp.content)
    except (requests.exceptions.RequestException, ET.ParseError, ValueError):
        return []

    out = []
    for elem in root.iter():
        if _local(elem.tag) not in ("item", "entry"):
            continue
        title = _child_text(elem, ("title",))
        desc = _child_text(elem, ("description", "summary", "content"))
        if title:
            out.append((title, desc))
        if len(out) >= _PER_FEED:
            break
    return out


def _child_text(elem, names):
    # type: ("ET.Element", tuple) -> str
    for child in elem:
        if _local(child.tag) in names:
            return _clean(child.text or "".join(child.itertext()))
    return ""


def _local(tag):
    # type: (str) -> str
    # Strip the "{namespace}" prefix ElementTree puts on namespaced tags.
    if isinstance(tag, str) and "}" in tag:
        return tag.rsplit("}", 1)[1].lower()
    return tag.lower() if isinstance(tag, str) else ""


def _clean(text):
    # type: (str) -> str
    text = re.sub(r"<[^>]+>", " ", text or "")  # strip embedded HTML for TTS
    text = " ".join(text.split())
    if len(text) > 300:
        text = text[:300].rstrip() + "..."
    return text


def _speak_stream(messages, system, timer):
    # type: (list, str, StageTimer) -> None
    """Stream a brain.chat reply through a SentenceSpeaker so the first
    sentence is audible while the model is still generating."""
    speaker = audio.SentenceSpeaker()
    try:
        brain.chat(messages, system=system, on_text=speaker.feed)
    except Exception:
        speaker.close()
        raise
    timer.mark("model")
    speaker.close()
