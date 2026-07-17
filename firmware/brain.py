"""Cloud brain: Claude vision/chat (streaming SSE + tool-use), Whisper STT,
Tesseract OCR, connectivity check, and the shared prompt bank.

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

MODEL = os.environ.get("VISIONARY_MODEL", "claude-haiku-4-5")
MAX_TOKENS = 1024
_API_URL = "https://api.anthropic.com/v1/messages"
_API_HOST = "api.anthropic.com"
_ANTHROPIC_VERSION = "2023-06-01"
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
# brain.py only defines the Anthropic schemas and drives the tool loop.
TOOL_SEARCH_MEMORY = {
    "name": "search_memory",
    "description": (
        "Search the wearer's own past captures, readings, and recordings — "
        "everything Visionary has read or heard for them before. Use this "
        "when they ask about something seen or heard earlier, like 'what "
        "room number was on that door?' or 'what did the flyer say?'."
    ),
    "input_schema": {
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
}

TOOL_PHONE_ACTION = {
    "name": "phone_action",
    "description": (
        "Queue an action on the wearer's paired phone, such as adding a "
        "calendar event or a reminder. Use this when the wearer asks to "
        "remember, schedule, or be reminded of something — for example "
        "'add this flyer's date to my calendar'. Briefly confirm out loud "
        "after queuing it."
    ),
    "input_schema": {
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
    with _online_lock:
        now = time.monotonic()
        if (not force and _online_cache["ts"] is not None
                and now - _online_cache["ts"] < _ONLINE_CACHE_S):
            return _online_cache["value"]
        value = False
        if os.environ.get("ANTHROPIC_API_KEY"):
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
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not key:
        raise BrainOffline("ANTHROPIC_API_KEY not set")
    headers = {
        "x-api-key": key,
        "anthropic-version": _ANTHROPIC_VERSION,
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
        raise RuntimeError("Claude API error %s: %s" % (resp.status_code, msg))
    return resp


def _stream(messages: List[dict], system: Optional[str] = None,
            on_text: Optional[Callable[[str], None]] = None) -> str:
    payload = {
        "model": MODEL,
        "max_tokens": MAX_TOKENS,
        "stream": True,
        "messages": messages,
    }
    if system:
        payload["system"] = system
    resp = _post(payload, stream=True)
    parts = []
    try:
        for raw in resp.iter_lines(decode_unicode=True):
            if not raw or not raw.startswith("data:"):
                continue
            data = raw[5:].strip()
            if not data:
                continue
            try:
                event = json.loads(data)
            except ValueError:
                continue
            etype = event.get("type")
            if etype == "content_block_delta":
                delta = event.get("delta", {})
                if delta.get("type") == "text_delta":
                    text = delta.get("text", "")
                    if text:
                        parts.append(text)
                        if on_text is not None:
                            on_text(text)
            elif etype == "error":
                err = event.get("error", {})
                raise RuntimeError("Claude API error: %s"
                                   % err.get("message", "stream error"))
    except requests.exceptions.RequestException as e:
        raise BrainOffline(str(e))
    finally:
        resp.close()
    return "".join(parts)


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
        blocks = data.get("content", []) or []
        convo.append({"role": "assistant", "content": blocks})
        if data.get("stop_reason") == "tool_use" and rounds < _MAX_TOOL_ROUNDS:
            rounds += 1
            results = []
            for block in blocks:
                if block.get("type") != "tool_use":
                    continue
                name = block.get("name", "")
                handler = handlers.get(name)
                if handler is None:
                    result = "No handler available for tool %s." % name
                else:
                    try:
                        result = handler(block.get("input", {}) or {})
                    except Exception as e:
                        result = "Tool %s failed: %s" % (name, e)
                results.append({
                    "type": "tool_result",
                    "tool_use_id": block.get("id"),
                    "content": result or "",
                })
            convo.append({"role": "user", "content": results})
            continue
        text = "".join(b.get("text", "") for b in blocks
                       if b.get("type") == "text")
        if on_text is not None:
            on_text(text)
        return text


def see(jpeg: bytes, prompt: str, on_text: Optional[Callable[[str], None]] = None,
        history_msgs: Optional[List[dict]] = None,
        tools: Optional[List[dict]] = None,
        tool_handlers: Optional[Dict[str, Callable[[dict], str]]] = None) -> str:
    content = [
        {"type": "image", "source": {
            "type": "base64",
            "media_type": _media_type(jpeg),
            "data": base64.b64encode(jpeg).decode(),
        }},
        {"type": "text", "text": prompt},
    ]
    messages = list(history_msgs or []) + [{"role": "user", "content": content}]
    if tools:
        return _tool_loop(messages, tools, tool_handlers, on_text)
    return _stream(messages, on_text=on_text)


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
