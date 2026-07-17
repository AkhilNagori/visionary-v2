"""firmware/packs.py — modes as data (the v3 mode-pack platform).

Most v3 features are the same five pipelines with a different prompt, so a
"mode" is just data:

    {"id", "name", "category", "description", "pipeline", "prompt", "options"}

This module loads modes (the shipped builtin pack plus any community packs
installed under HOME/packs/), installs/removes packs by URL, and dispatches a
mode by its pipeline.

Pipelines:
    see      capture a photo, run the prompt over it, speak the result   (inline)
    ask      record a spoken question, attach a photo, answer it          (inline)
    listen   record the wearer, transcribe, run the prompt, speak         (inline)
    loop     background periodic see, e.g. language immersion            (main.py)
    session  multi-turn spoken conversation about the view               (main.py)

run_mode() runs see/ask/listen inline. loop/session are owned by main.py's
background lifecycle (they need a stop_event and single-press stopping like the
two-way interpreter and navigation assist), so run_mode does NOT run them: it
raises ModeNeedsLoop(mode) or ModeNeedsSession(mode) and hands control back to
main, which starts a background thread:

    ModeNeedsLoop(mode)    -> packs.run_loop(mode, stop_event)
    ModeNeedsSession(mode) -> modes.session.run_session(mode, stop_event)

Both honor stop_event and, on a hard offline wall, speak once and raise
brain.BrainOffline so the manager clears active_mode instead of respawning them
every few seconds (same convention as translate.py / navigate.py / session.py).

Failure contract: every user-facing failure path in run_mode / run_loop beeps
and speaks — a mode never fails silently. install_pack / remove_pack are
API-driven config operations, so they raise PackError instead (api.py turns
that into an HTTP error); load_modes / list_packs skip a corrupt installed pack
file rather than taking the whole mode system down with it.
"""

import glob
import json
import os
import re
import sys
import urllib.error
import urllib.request
from typing import Dict, List, Optional, Tuple

import audio
import brain
import state
import vision
from metrics import StageTimer
from modes import index_memory, stream_see

VALID_PIPELINES = ("see", "ask", "listen", "loop", "session")
_REQUIRED_STR_FIELDS = ("id", "name", "category", "description", "pipeline", "prompt")
_ID_RE = re.compile(r"^[a-z0-9_]{1,64}$")
_PACK_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_RESERVED_PACK_NAMES = ("builtin",)
_DEFAULT_LOOP_INTERVAL_S = 4.0


class PackError(Exception):
    """A pack or mode failed strict schema validation, or a pack could not be
    fetched. Raised by install_pack (and the internal validators)."""


class ModeNeedsLoop(Exception):
    """run_mode() signals that this mode is a background `loop` pipeline that
    main.py must own. Carries the validated mode dict; run it via
    packs.run_loop(mode, stop_event) on a background thread."""

    def __init__(self, mode):
        # type: (dict) -> None
        self.mode = mode
        super(ModeNeedsLoop, self).__init__(mode.get("id", ""))


class ModeNeedsSession(Exception):
    """run_mode() signals that this mode is a `session` pipeline that main.py
    must own. Carries the validated mode dict; run it via
    modes.session.run_session(mode, stop_event) on a background thread."""

    def __init__(self, mode):
        # type: (dict) -> None
        self.mode = mode
        super(ModeNeedsSession, self).__init__(mode.get("id", ""))


# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------

def load_modes():
    # type: () -> Dict[str, dict]
    """All available modes keyed by id: the builtin pack first, then every
    validated HOME/packs/*.json. Builtin ids win on collision; a corrupt or
    invalid installed pack file is skipped (logged), never fatal."""
    modes = {}  # type: Dict[str, dict]
    for mode in _load_builtin()["modes"]:
        modes[mode["id"]] = mode
    for path in _installed_pack_paths():
        try:
            pack = _load_pack_file(path)
        except PackError as exc:
            print("packs: skipping %s: %s" % (path, exc), file=sys.stderr)
            continue
        for mode in pack["modes"]:
            if mode["id"] in modes:
                # builtin (or an earlier pack) owns this id; don't let a later
                # community pack shadow it.
                continue
            modes[mode["id"]] = mode
    return modes


def install_pack(url):
    # type: (str) -> List[str]
    """Fetch a pack JSON ({"name", "modes":[...]}) from url (http, https, or a
    local file:// URL used for QR/side-loading), validate it strictly, and save
    it to HOME/packs/<name>.json. Returns the installed mode ids. Raises
    PackError on any fetch or validation failure."""
    pack = _validate_pack(_fetch_pack_json(url))
    _ensure_packs_dir()
    dest = os.path.join(_packs_dir(), pack["name"] + ".json")
    tmp = dest + ".tmp"
    with open(tmp, "w") as f:
        json.dump(pack, f, indent=2)
        f.write("\n")
    os.replace(tmp, dest)
    return [mode["id"] for mode in pack["modes"]]


def remove_pack(name):
    # type: (str) -> bool
    """Delete an installed pack by name. Returns False for the builtin pack,
    an unsafe name, or a name that isn't installed (nothing to delete)."""
    if name in _RESERVED_PACK_NAMES or not _PACK_NAME_RE.match(name or ""):
        return False
    path = os.path.join(_packs_dir(), name + ".json")
    try:
        os.remove(path)
        return True
    except OSError:
        return False


def list_packs():
    # type: () -> List[dict]
    """[{"name", "builtin": bool, "modes": [ids]}], builtin first. A corrupt
    installed pack file is skipped rather than breaking the listing."""
    packs = [{
        "name": "builtin",
        "builtin": True,
        "modes": [mode["id"] for mode in _load_builtin()["modes"]],
    }]
    for path in _installed_pack_paths():
        try:
            pack = _load_pack_file(path)
        except PackError as exc:
            print("packs: skipping %s: %s" % (path, exc), file=sys.stderr)
            continue
        packs.append({
            "name": pack["name"],
            "builtin": False,
            "modes": [mode["id"] for mode in pack["modes"]],
        })
    return packs


def run_mode(mode_id):
    # type: (str) -> None
    """Dispatch a mode by its pipeline. see/ask/listen run inline here;
    loop/session raise ModeNeedsLoop/ModeNeedsSession for main.py to own (see
    the module docstring). Every inline failure path beeps and speaks."""
    try:
        modes = load_modes()
    except Exception:
        audio.beep("err")
        audio.speak("I couldn't load the mode data.")
        return

    mode = modes.get(mode_id)
    if mode is None:
        audio.beep("err")
        audio.speak("That mode is not installed.")
        return

    pipeline = mode["pipeline"]
    if pipeline == "loop":
        raise ModeNeedsLoop(mode)
    if pipeline == "session":
        raise ModeNeedsSession(mode)

    try:
        if pipeline == "see":
            _run_see(mode)
        elif pipeline == "ask":
            _run_ask(mode)
        elif pipeline == "listen":
            _run_listen(mode)
        else:  # unreachable while VALID_PIPELINES stays in sync, but never silent
            audio.beep("err")
            audio.speak("That mode is not supported on the glasses.")
    except (ModeNeedsLoop, ModeNeedsSession):
        raise
    except Exception:
        audio.beep("err")
        audio.speak("Sorry, that mode failed. Please try again.")


def run_loop(mode, stop_event):
    # type: (dict, "threading.Event") -> None
    """Background body for a `loop` pipeline mode (main.py runs this on a
    stop-event thread, like navigation assist). Every options["interval_s"]
    seconds: grab a preview frame, run the prompt with the previous callout for
    continuity, and speak only genuinely new callouts (the model returns the
    literal token NONE when nothing changed). Speaks once and raises
    brain.BrainOffline on a hard offline wall so the manager clears active_mode
    instead of respawning us."""
    name = mode.get("name") or "This mode"
    interval = _loop_interval(mode)
    base_prompt = mode.get("prompt") or ""
    previous = "nothing yet"

    audio.speak("%s on." % name)
    while not stop_event.is_set():
        prompt = (base_prompt
                  + "\n\nYour previous callout was: \"" + previous + "\". "
                  + "Reply with only the word NONE if nothing has meaningfully "
                  + "changed or there is nothing worth saying.")
        try:
            jpeg = vision.capture_preview_jpeg()
            callout = brain.see(jpeg, prompt).strip()
        except brain.BrainOffline:
            audio.beep("offline")
            audio.speak("%s needs an internet connection. Stopping." % name)
            raise
        except Exception:
            if stop_event.wait(interval):
                break
            continue

        if stop_event.is_set():
            break
        if callout and callout.strip().upper() != "NONE":
            audio.speak(callout, wait=True)
            previous = callout
            _save_mode_entry(mode, callout)
        if stop_event.wait(interval):
            break
    audio.speak("%s off." % name)


# --------------------------------------------------------------------------
# Inline pipelines
# --------------------------------------------------------------------------

def _run_see(mode):
    # type: (dict) -> None
    timer = StageTimer()
    if not brain.is_online():
        _speak_needs_net(mode)
        return

    audio.beep("capture")
    jpeg = vision.capture_jpeg()
    image_path = vision.save_capture(jpeg)
    timer.mark("capture")

    tools, handlers = _mode_tools(mode)
    try:
        text = stream_see(jpeg, mode["prompt"], timer,
                          tools=tools, tool_handlers=handlers)
    except (brain.BrainOffline, RuntimeError):
        audio.beep("err")
        audio.speak("Sorry, that didn't work. Please try again.")
        timer.log("mode")
        return

    if text.strip():
        entry_id = state.get_history().add(
            "mode", text, extra=_mode_extra(mode), image_path=image_path)
        index_memory(entry_id, text)
    timer.log("mode")


def _run_ask(mode):
    # type: (dict) -> None
    """`ask` pipeline: the mode's prompt is a system persona for a spoken
    question about the current view (photo + question -> answer)."""
    timer = StageTimer()
    if not brain.is_online():
        _speak_needs_net(mode)
        return

    audio.beep("rec_start")
    wav = audio.record_until_silence()
    if wav is None:
        audio.beep("err")
        audio.speak("I didn't catch a question.")
        return
    audio.beep("rec_stop")

    try:
        question = brain.transcribe(wav).strip()
    except brain.BrainOffline:
        audio.beep("offline")
        audio.speak("I couldn't understand you without an internet connection.")
        return
    except Exception:
        audio.beep("err")
        audio.speak("Sorry, I couldn't hear the question.")
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

    prompt = mode["prompt"] + "\n\nThe wearer asks: " + question
    tools, handlers = _mode_tools(mode)
    try:
        answer = stream_see(jpeg, prompt, timer,
                           tools=tools, tool_handlers=handlers)
    except (brain.BrainOffline, RuntimeError):
        audio.beep("err")
        audio.speak("Sorry, I couldn't answer that. Try again.")
        timer.log("mode")
        return

    if answer.strip():
        extra = _mode_extra(mode)
        extra["question"] = question
        entry_id = state.get_history().add(
            "mode", answer, extra=extra, image_path=image_path)
        index_memory(entry_id, question + "\n" + answer)
    timer.log("mode")


def _run_listen(mode):
    # type: (dict) -> None
    """`listen` pipeline: record the wearer, transcribe, run the prompt over
    the transcript (no photo), speak the result."""
    timer = StageTimer()
    if not brain.is_online():
        _speak_needs_net(mode)
        return

    audio.beep("rec_start")
    wav = audio.record_until_silence()
    if wav is None:
        audio.beep("err")
        audio.speak("I didn't catch anything.")
        return
    audio.beep("rec_stop")

    try:
        heard = brain.transcribe(wav).strip()
    except brain.BrainOffline:
        audio.beep("offline")
        audio.speak("I couldn't understand you without an internet connection.")
        return
    except Exception:
        audio.beep("err")
        audio.speak("Sorry, I couldn't process that.")
        return
    finally:
        _discard(wav)
    timer.mark("stt")

    if not heard:
        audio.beep("err")
        audio.speak("I didn't catch that. Try again.")
        return

    speaker = audio.SentenceSpeaker()
    try:
        answer = brain.chat(
            [{"role": "user", "content": heard}],
            system=mode["prompt"], on_text=speaker.feed)
    except brain.BrainOffline:
        speaker.close()
        audio.beep("offline")
        audio.speak("I lost the connection before I could answer.")
        return
    except RuntimeError:
        speaker.close()
        audio.beep("err")
        audio.speak("Sorry, I couldn't get a response. Try again.")
        return
    timer.mark("model")
    speaker.close()

    if answer.strip():
        extra = _mode_extra(mode)
        extra["heard"] = heard
        entry_id = state.get_history().add("mode", answer, extra=extra)
        index_memory(entry_id, heard + "\n" + answer)
    timer.log("mode")


# --------------------------------------------------------------------------
# Mode tool-use (phone actions)
# --------------------------------------------------------------------------

# A mode opts into phone actions with options["phone_action"] truthy (e.g.
# whiteboard_email -> "email_draft"). The core ask-flow tool in brain.py only
# covers calendar_event/reminder; modes need the v3 send_text/email_draft/note
# action types too, so packs carries its own phone_action schema + handler and
# queues via state.get_actions() (which stores any action type verbatim).
_PHONE_ACTION_TOOL = {
    "type": "function",
    "function": {
        "name": "phone_action",
        "description": (
            "Queue an action on the wearer's paired phone: an email draft, a text "
            "message, a note, a calendar event, or a reminder. Use this to hand "
            "off structured output the wearer asked for, then briefly confirm out "
            "loud that it is queued. Do not read the full contents back to them."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "type": {
                    "type": "string",
                    "enum": ["email_draft", "send_text", "note",
                             "calendar_event", "reminder"],
                    "description": "Which kind of action to queue.",
                },
                "to": {
                    "type": "string",
                    "description": "Recipient, for email_draft or send_text.",
                },
                "subject": {
                    "type": "string",
                    "description": "Subject line, for email_draft.",
                },
                "body": {
                    "type": "string",
                    "description": "Body text of the email, message, or note.",
                },
                "title": {
                    "type": "string",
                    "description": "Title, for note, calendar_event, or reminder.",
                },
                "date": {
                    "type": "string",
                    "description": "ISO 8601 date or datetime, for a calendar_event.",
                },
                "notes": {
                    "type": "string",
                    "description": "Extra details, for calendar_event or reminder.",
                },
            },
            "required": ["type"],
        },
    },
}


def _mode_tools(mode):
    # type: (dict) -> Tuple[Optional[List[dict]], Optional[Dict[str, object]]]
    options = mode.get("options") or {}
    if options.get("phone_action"):
        return [_PHONE_ACTION_TOOL], {"phone_action": _tool_phone_action}
    return None, None


def _tool_phone_action(tool_input):
    # type: (dict) -> str
    action_type = tool_input.get("type")
    body = (tool_input.get("body") or "").strip()
    title = (tool_input.get("title") or "").strip()
    to = (tool_input.get("to") or "").strip()
    notes = (tool_input.get("notes") or "").strip()

    if action_type == "email_draft":
        if not body:
            return "I need the note contents before I can draft the email."
        payload = {"subject": (tool_input.get("subject") or "").strip(), "body": body}
        if to:
            payload["to"] = to
    elif action_type == "send_text":
        if not body:
            return "I need the message text first."
        payload = {"body": body}
        if to:
            payload["to"] = to
    elif action_type == "note":
        if not body:
            return "I need something to write in the note."
        payload = {"title": title or "Note", "body": body}
    elif action_type == "calendar_event":
        if not title:
            return "That event needs a title."
        date = (tool_input.get("date") or "").strip()
        if not date:
            return "That event needs a date."
        payload = {"title": title, "date": date}
        if notes:
            payload["notes"] = notes
    elif action_type == "reminder":
        if not title:
            return "That reminder needs a title."
        payload = {"title": title}
        if notes:
            payload["notes"] = notes
    else:
        return "I can't queue that kind of action."

    state.get_actions().add(action_type, payload)
    return "Queued for your phone."


# --------------------------------------------------------------------------
# Loading + validation
# --------------------------------------------------------------------------

def _fetch_pack_json(url):
    # type: (str) -> object
    """GET the pack body from url and parse it as JSON. urlopen covers http,
    https, and file:// (side-loading a pack the phone downloaded from a QR
    code); an HTTP error status raises URLError, so it is handled here too."""
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            raw = resp.read()
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise PackError("could not fetch pack: %s" % exc)
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise PackError("pack URL did not return valid JSON")


def _builtin_path():
    # type: () -> str
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "packs", "builtin.json")


def _packs_dir():
    # type: () -> str
    return os.path.join(state.HOME, "packs")


def _ensure_packs_dir():
    # type: () -> None
    os.makedirs(_packs_dir(), exist_ok=True)


def _installed_pack_paths():
    # type: () -> List[str]
    return sorted(glob.glob(os.path.join(_packs_dir(), "*.json")))


def _load_builtin():
    # type: () -> dict
    """The shipped builtin pack. It is packaged and pre-validated, so a failure
    here is a build error, not a runtime condition — surface it loudly."""
    try:
        with open(_builtin_path(), "r") as f:
            data = json.load(f)
    except (OSError, ValueError) as exc:
        raise PackError("builtin pack is unreadable: %s" % exc)
    pack = _validate_pack(data, reserved_ok=True)
    return pack


def _load_pack_file(path):
    # type: (str) -> dict
    try:
        with open(path, "r") as f:
            data = json.load(f)
    except (OSError, ValueError) as exc:
        raise PackError("%s is not valid JSON: %s" % (os.path.basename(path), exc))
    return _validate_pack(data)


def _validate_pack(data, reserved_ok=False):
    # type: (object, bool) -> dict
    """Strictly validate a pack ({"name", "modes":[mode...]}) and return a
    normalized copy. Raises PackError on any violation."""
    if not isinstance(data, dict):
        raise PackError("pack must be a JSON object")
    name = data.get("name")
    if not isinstance(name, str) or not _PACK_NAME_RE.match(name):
        raise PackError(
            "pack name must be lowercase letters, digits, '-' or '_'")
    if name in _RESERVED_PACK_NAMES and not reserved_ok:
        raise PackError("pack name '%s' is reserved" % name)

    raw_modes = data.get("modes")
    if not isinstance(raw_modes, list) or not raw_modes:
        raise PackError("pack '%s' must have a non-empty modes list" % name)

    modes = []
    seen = set()
    for raw in raw_modes:
        mode = _validate_mode(raw)
        if mode["id"] in seen:
            raise PackError("pack '%s' has duplicate mode id '%s'"
                            % (name, mode["id"]))
        seen.add(mode["id"])
        modes.append(mode)
    return {"name": name, "modes": modes}


def _validate_mode(raw):
    # type: (object) -> dict
    if not isinstance(raw, dict):
        raise PackError("each mode must be a JSON object")
    for field in _REQUIRED_STR_FIELDS:
        value = raw.get(field)
        if not isinstance(value, str) or not value.strip():
            raise PackError("mode field '%s' must be a non-empty string" % field)
    mode_id = raw["id"]
    if not _ID_RE.match(mode_id):
        raise PackError(
            "mode id '%s' must be lowercase letters, digits, or underscore"
            % mode_id)
    pipeline = raw["pipeline"]
    if pipeline not in VALID_PIPELINES:
        raise PackError("mode '%s' has unknown pipeline '%s'"
                        % (mode_id, pipeline))
    options = raw.get("options", {})
    if options is None:
        options = {}
    if not isinstance(options, dict):
        raise PackError("mode '%s' options must be a JSON object" % mode_id)
    return {
        "id": mode_id,
        "name": raw["name"],
        "category": raw["category"],
        "description": raw["description"],
        "pipeline": pipeline,
        "prompt": raw["prompt"],
        "options": options,
    }


# --------------------------------------------------------------------------
# Small shared helpers
# --------------------------------------------------------------------------

def _mode_extra(mode):
    # type: (dict) -> Dict[str, str]
    return {"mode": mode["id"], "name": mode["name"]}


def _save_mode_entry(mode, text):
    # type: (dict, str) -> None
    try:
        entry_id = state.get_history().add("mode", text, extra=_mode_extra(mode))
        index_memory(entry_id, text)
    except Exception as exc:  # a history write must never crash a live loop
        print("packs: history write failed: %s" % exc, file=sys.stderr)


def _speak_needs_net(mode):
    # type: (dict) -> None
    audio.beep("offline")
    audio.speak("%s needs an internet connection." % (mode.get("name") or "This mode"))


def _loop_interval(mode):
    # type: (dict) -> float
    try:
        return float((mode.get("options") or {}).get(
            "interval_s", _DEFAULT_LOOP_INTERVAL_S))
    except (TypeError, ValueError):
        return _DEFAULT_LOOP_INTERVAL_S


def _discard(path):
    # type: (str) -> None
    try:
        if path and os.path.exists(path):
            os.remove(path)
    except OSError:
        pass
