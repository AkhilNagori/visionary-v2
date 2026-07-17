"""Cloud brain: OpenAI vision/chat (streaming SSE + function-calling), Whisper
STT, Tesseract OCR, connectivity check, and the shared prompt bank.

Error contract: BrainOffline = no connectivity / no usable backend (callers
fall back to the offline path); RuntimeError = a backend answered with an
error (callers beep and speak a short failure sentence).
"""

import base64
import json
import os
import socket
import subprocess
import threading
import time
from typing import Callable, Dict, List, Optional

import requests

import state
import vision

MODEL = os.environ.get("VISIONARY_MODEL", "gpt-4o-mini")
MAX_TOKENS = 1024
_API_URL = "https://api.openai.com/v1/chat/completions"
_API_HOST = "api.openai.com"
_ONLINE_CACHE_S = 10.0
_MAX_TOOL_ROUNDS = 5

READ_PROMPT = (
    "You are the voice of assistive smart glasses for a visually impaired "
    "student. Read ALL printed or handwritten text in this image aloud, in "
    "natural reading order. Output ONLY the text content, cleaned up for "
    "text-to-speech: expand obvious abbreviations and skip page furniture "
    "like page numbers, headers, and watermarks. No commentary, no markdown. "
    "If there is no readable text, say what the object is instead, in one "
    "short sentence."
)

DESCRIBE_PROMPT = (
    "You are the voice of assistive smart glasses. Describe this scene for a "
    "visually impaired person in 2-3 short, concrete sentences: main objects, "
    "people, obstacles, and any visible text. Frame it from their point of "
    "view, for example 'to your left' or 'in front of you'. Be direct."
)

ASK_SYSTEM = (
    "You are Visionary, voice-controlled assistive smart glasses worn by a "
    "visually impaired student. The wearer asks questions out loud; a photo "
    "of what they are facing may be attached. Everything you say is spoken "
    "through a small speaker, so answer in one to three short sentences of "
    "plain words: no markdown, no lists, no preamble. When the answer is in "
    "the photo, describe where things are from the wearer's point of view. "
    "If the photo does not show the answer, say so briefly and answer from "
    "general knowledge when you can. Use your tools when they help: search "
    "the wearer's past captures to answer questions about things they saw "
    "earlier, and queue a phone action when they ask to schedule or be "
    "reminded of something."
)

SUMMARY_PROMPT = (
    "Summarize this transcript of a lecture or conversation so it can be "
    "read aloud by text-to-speech. Give the main topic, the key points, and "
    "anything to remember or do, in at most five short sentences of plain "
    "words: no markdown, no bullet points, no headings."
)

NAVIGATE_PROMPT = (
    "You are the navigation-assist voice of assistive smart glasses for a "
    "person with low vision, giving quick spoken callouts as they move. This "
    "is assistive information to help them notice things, NOT a certified "
    "safety or obstacle-avoidance system, so never tell them it is safe to "
    "proceed. Look at this point-of-view photo and call out only what is "
    "genuinely useful right now: hazards or obstacles ahead, doorways, "
    "stairs, curbs, turns, and signs with their text. Use ONE short spoken "
    "sentence with point-of-view framing like 'ahead of you' or 'on your "
    "right'. You will be told your previous callout; if the scene has not "
    "meaningfully changed, or there is nothing worth mentioning, reply with "
    "the single word NONE and nothing else."
)

# Tier 3 agent tools. Handlers are supplied by the caller (see modes/ask.py);
# brain.py only defines the OpenAI function schemas and drives the tool loop.
# Handlers stay keyed by function name.
TOOL_SEARCH_MEMORY = {
    "type": "function",
    "function": {
        "name": "search_memory",
        "description": (
            "Search the wearer's own past captures, readings, and recordings — "
            "everything Visionary has read or heard for them before. Use this "
            "when they ask about something seen or heard earlier, like 'what "
            "room number was on that door?' or 'what did the flyer say?'."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "What to look for in the wearer's history.",
                },
                "k": {
                    "type": "integer",
                    "description": "How many past items to return (default 5).",
                },
            },
            "required": ["query"],
        },
    },
}

TOOL_PHONE_ACTION = {
    "type": "function",
    "function": {
        "name": "phone_action",
        "description": (
            "Queue an action on the wearer's paired phone, such as adding a "
            "calendar event or a reminder. Use this when the wearer asks to "
            "remember, schedule, or be reminded of something — for example "
            "'add this flyer's date to my calendar'. Briefly confirm out loud "
            "after queuing it."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "type": {
                    "type": "string",
                    "enum": ["calendar_event", "reminder"],
                    "description": "calendar_event needs a date; reminder does not.",
                },
                "title": {
                    "type": "string",
                    "description": "Short title of the event or reminder.",
                },
                "date": {
                    "type": "string",
                    "description": "ISO 8601 date or datetime, for a calendar_event.",
                },
                "notes": {
                    "type": "string",
                    "description": "Optional extra details.",
                },
            },
            "required": ["type", "title"],
        },
    },
}

TOOL_SET_TIMER = {
    "type": "function",
    "function": {
        "name": "set_timer",
        "description": (
            "Start a named countdown timer for the wearer, e.g. 'set a pasta timer "
            "for 8 minutes'. When it finishes the glasses announce it out loud. Use "
            "this whenever the wearer asks to be timed or reminded after a number of "
            "minutes or seconds. Convert minutes to seconds. Briefly confirm out "
            "loud after starting it."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Short label for the timer, like 'pasta' or 'tea'.",
                },
                "seconds": {
                    "type": "number",
                    "description": "Duration in seconds (convert any minutes given).",
                },
            },
            "required": ["seconds"],
        },
    },
}

TOOL_SET_MODE = {
    "type": "function",
    "function": {
        "name": "set_mode",
        "description": (
            "Switch the glasses into one of the wearer's installed modes by its id, "
            "so a single press runs that mode — e.g. 'recipe' or 'pokedex'. Use this "
            "only when the wearer explicitly asks to turn on or switch to a named "
            "mode. Pass an empty id to go back to classic reading."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {
                    "type": "string",
                    "description": "The mode id to activate, or empty to clear it.",
                },
            },
            "required": ["id"],
        },
    },
}

TOOL_GET_BRIEFING = {
    "type": "function",
    "function": {
        "name": "get_briefing",
        "description": (
            "Read the wearer a short spoken news briefing from their configured "
            "feeds. Use this when they ask for their news, headlines, or a briefing. "
            "The briefing is spoken to them directly, so after calling this just "
            "confirm very briefly and do not repeat the contents."
        ),
        "parameters": {"type": "object", "properties": {}},
    },
}


class BrainOffline(Exception):
    pass


def read_prompt(language: Optional[str]) -> str:
    if language:
        return READ_PROMPT + " Translate everything to %s." % language
    return READ_PROMPT


_online_lock = threading.Lock()
_online_cache = {"ts": None, "value": False}


def is_online(force: bool = False) -> bool:
    if state.load_config().get("local_only"):
        return False  # #58: local-only mode keeps everything on-device
    with _online_lock:
        now = time.monotonic()
        if (not force and _online_cache["ts"] is not None
                and now - _online_cache["ts"] < _ONLINE_CACHE_S):
            return _online_cache["value"]
        value = False
        if os.environ.get("OPENAI_API_KEY"):
            try:
                socket.create_connection((_API_HOST, 443), timeout=2.0).close()
                value = True
            except OSError:
                value = False
        _online_cache["value"] = value
        _online_cache["ts"] = time.monotonic()
        return value


def _media_type(image: bytes) -> str:
    # VISIONARY_SIM_IMAGE may point at a PNG
    if image[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    return "image/jpeg"


def _api_error_message(resp) -> str:
    try:
        return resp.json()["error"]["message"]
    except Exception:
        return (resp.text or "").strip()[:300]


def _post(payload: dict, stream: bool):
    key = os.environ.get("OPENAI_API_KEY", "")
    if not key:
        raise BrainOffline("OPENAI_API_KEY not set")
    headers = {
        "Authorization": "Bearer " + key,
        "content-type": "application/json",
    }
    if stream:
        headers["accept"] = "text/event-stream"
    try:
        resp = requests.post(_API_URL, headers=headers, json=payload,
                             stream=stream, timeout=(5, 60))
    except requests.exceptions.RequestException as e:
        raise BrainOffline(str(e))
    if resp.status_code != 200:
        msg = _api_error_message(resp)
        resp.close()
        raise RuntimeError("OpenAI API error %s: %s" % (resp.status_code, msg))
    return resp


def _with_system(messages: List[dict], system: Optional[str]) -> List[dict]:
    if system:
        return [{"role": "system", "content": system}] + list(messages)
    return list(messages)


def _stream(messages: List[dict], system: Optional[str] = None,
            on_text: Optional[Callable[[str], None]] = None) -> str:
    payload = {
        "model": MODEL,
        "max_tokens": MAX_TOKENS,
        "stream": True,
        "messages": _with_system(messages, system),
    }
    resp = _post(payload, stream=True)
    parts = []
    try:
        for raw in resp.iter_lines(decode_unicode=True):
            if not raw or not raw.startswith("data:"):
                continue
            data = raw[5:].strip()
            if not data or data == "[DONE]":
                continue
            try:
                event = json.loads(data)
            except ValueError:
                continue
            if event.get("error"):
                err = event["error"]
                msg = err.get("message") if isinstance(err, dict) else err
                raise RuntimeError("OpenAI API error: %s" % (msg or "stream error"))
            choices = event.get("choices") or []
            if not choices:
                continue
            text = (choices[0].get("delta") or {}).get("content")
            if text:
                parts.append(text)
                if on_text is not None:
                    on_text(text)
    except requests.exceptions.RequestException as e:
        raise BrainOffline(str(e))
    finally:
        resp.close()
    return "".join(parts)


def _message(data: dict) -> dict:
    choices = data.get("choices") or []
    if not choices:
        return {}
    return choices[0].get("message") or {}


def _tool_loop(messages: List[dict], tools: List[dict],
               tool_handlers: Optional[Dict[str, Callable[[dict], str]]],
               on_text: Optional[Callable[[str], None]]) -> str:
    handlers = tool_handlers or {}
    convo = list(messages)
    rounds = 0
    while True:
        payload = {
            "model": MODEL,
            "max_tokens": MAX_TOKENS,
            "messages": convo,
            "tools": tools,
        }
        resp = _post(payload, stream=False)
        try:
            data = resp.json()
        finally:
            resp.close()
        message = _message(data)
        tool_calls = message.get("tool_calls") or []
        # Echo the assistant turn back verbatim; OpenAI requires the message
        # that issued tool_calls to precede the matching tool results.
        convo.append(message)
        if tool_calls and rounds < _MAX_TOOL_ROUNDS:
            rounds += 1
            for call in tool_calls:
                fn = call.get("function") or {}
                name = fn.get("name", "")
                try:
                    args = json.loads(fn.get("arguments") or "{}")
                except ValueError:
                    args = {}
                if not isinstance(args, dict):
                    args = {}
                handler = handlers.get(name)
                if handler is None:
                    result = "No handler available for tool %s." % name
                else:
                    try:
                        result = handler(args)
                    except Exception as e:
                        result = "Tool %s failed: %s" % (name, e)
                convo.append({
                    "role": "tool",
                    "tool_call_id": call.get("id"),
                    "content": result or "",
                })
            continue
        text = message.get("content") or ""
        if on_text is not None:
            on_text(text)
        return text


def see(jpeg: bytes, prompt: str, on_text: Optional[Callable[[str], None]] = None,
        history_msgs: Optional[List[dict]] = None,
        tools: Optional[List[dict]] = None,
        tool_handlers: Optional[Dict[str, Callable[[dict], str]]] = None) -> str:
    data_url = "data:%s;base64,%s" % (
        _media_type(jpeg), base64.b64encode(jpeg).decode())
    content = [
        {"type": "text", "text": prompt},
        {"type": "image_url", "image_url": {"url": data_url}},
    ]
    messages = _to_openai_messages(history_msgs) + [
        {"role": "user", "content": content}]
    if tools:
        return _tool_loop(messages, tools, tool_handlers, on_text)
    return _stream(messages, on_text=on_text)


def _to_openai_messages(history_msgs: Optional[List[dict]]) -> List[dict]:
    """Convert prior text turns to OpenAI messages. Callers pass
    {"role", "content"} turns with plain-string content (see modes/ask.py),
    which pass through unchanged; a list content (older block-style) is
    flattened to its text so history still loads."""
    out = []
    for msg in history_msgs or []:
        content = msg.get("content")
        if isinstance(content, list):
            content = "".join(
                b.get("text", "") for b in content
                if isinstance(b, dict) and b.get("type") == "text")
        out.append({"role": msg.get("role", "user"), "content": content})
    return out


def chat(messages: List[dict], system: Optional[str] = None,
         on_text: Optional[Callable[[str], None]] = None) -> str:
    return _stream(messages, system=system, on_text=on_text)


def transcribe(wav_path: str) -> str:
    api_error = None
    if is_online() and os.environ.get("OPENAI_API_KEY"):
        try:
            return _transcribe_openai(wav_path)
        except requests.exceptions.RequestException as e:
            api_error = BrainOffline(str(e))
        except RuntimeError as e:
            api_error = e
    binary = os.path.join(state.HOME, "whisper", "main")
    model = os.path.join(state.HOME, "whisper", "ggml-tiny.en.bin")
    if os.path.exists(binary) and os.path.exists(model):
        return _transcribe_whisper_cpp(wav_path, binary, model)
    if api_error is not None:
        raise api_error
    raise BrainOffline("no transcription backend available")


def _transcribe_openai(wav_path: str) -> str:
    key = os.environ["OPENAI_API_KEY"]
    with open(wav_path, "rb") as f:
        resp = requests.post(
            "https://api.openai.com/v1/audio/transcriptions",
            headers={"Authorization": "Bearer " + key},
            data={"model": "whisper-1"},
            files={"file": (os.path.basename(wav_path), f, "audio/wav")},
            timeout=60,
        )
    if resp.status_code != 200:
        try:
            msg = resp.json()["error"]["message"]
        except Exception:
            msg = (resp.text or "").strip()[:300]
        raise RuntimeError("Whisper API error %s: %s" % (resp.status_code, msg))
    return resp.json().get("text", "").strip()


def _transcribe_whisper_cpp(wav_path: str, binary: str, model: str) -> str:
    # subprocess that exits: keeps the 512MB RAM budget (contract invariant 4)
    try:
        proc = subprocess.run(
            [binary, "-m", model, "-f", wav_path, "-nt"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError("whisper.cpp failed: %s" % e)
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", errors="replace").strip()[:300]
        raise RuntimeError("whisper.cpp exited %d: %s" % (proc.returncode, detail))
    lines = proc.stdout.decode("utf-8", errors="replace").splitlines()
    return " ".join(ln.strip() for ln in lines if ln.strip())


def ocr(jpeg: bytes) -> str:
    img = vision.preprocess_for_ocr(jpeg)
    try:
        import pytesseract  # optional dep; only the offline path needs it
    except ImportError:
        raise RuntimeError("pytesseract is not installed")
    try:
        return pytesseract.image_to_string(img)
    except Exception as e:  # includes TesseractNotFoundError (binary missing)
        raise RuntimeError("Tesseract OCR failed: %s" % e)
