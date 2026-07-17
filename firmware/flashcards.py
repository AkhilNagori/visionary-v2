"""Auto-flashcards: today's reading becomes tonight's spaced-repetition deck.

One table lives alongside the history in state.DB_PATH:

    cards(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, question TEXT,
          answer TEXT, due REAL, interval_d REAL, ease REAL)

``due`` is a unix timestamp (a new card is due immediately); ``interval_d`` is
the current spacing in days; ``ease`` is the SM-2 ease factor (starts 2.5, floors
at 1.3). Scheduling is SM-2-lite over four grades — 0 again / 1 hard / 2 good /
3 easy. Like memory.py, this module owns its own connection + lock into the
shared history DB.
"""

import json
import re
import sqlite3
import threading
import time
from typing import List, Optional, Tuple

import brain
import state

# SM-2-lite constants.
DEFAULT_EASE = 2.5
MIN_EASE = 1.3
_DAY = 86400.0
_RELEARN_S = 600.0  # a lapsed card (grade 0) comes back in ~10 minutes
# Ease adjustment per grade: again drops it hardest, easy lifts it, good holds.
_EASE_DELTA = {0: -0.20, 1: -0.15, 2: 0.0, 3: 0.15}

GENERATE_SYSTEM = (
    "You turn a student's day of readings and notes into study flashcards. Read "
    "the material and write up to %d clear question-and-answer pairs that test "
    "the important facts and ideas. Keep each question and answer to one or two "
    "short sentences. Reply with STRICT JSON only: a JSON array of objects, each "
    'with a "q" field (the question) and an "a" field (the answer). No markdown, '
    "no code fences, and no commentary before or after the JSON array."
)

_conn = None  # type: Optional[sqlite3.Connection]
_lock = threading.Lock()


def _db() -> sqlite3.Connection:
    global _conn
    with _lock:
        if _conn is None:
            state.ensure_dirs()
            conn = sqlite3.connect(state.DB_PATH, check_same_thread=False)
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA busy_timeout=5000")
            conn.execute(
                "CREATE TABLE IF NOT EXISTS cards ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, "
                "question TEXT, answer TEXT, due REAL, interval_d REAL, ease REAL)"
            )
            conn.commit()
            _conn = conn
        return _conn


def generate_from_today(n: int = 20) -> List[dict]:
    """Build up to ``n`` cards from today's history via brain.chat.

    Returns the created card dicts (empty when there is nothing to study today,
    when the model is offline, or when it returns nothing parseable). Callers own
    any spoken/beeped feedback.
    """
    n = max(1, min(100, int(n)))
    material = _todays_material()
    if not material.strip():
        return []
    try:
        reply = brain.chat(
            [{"role": "user", "content": material}],
            system=GENERATE_SYSTEM % n,
        )
    except (brain.BrainOffline, RuntimeError):
        return []
    now = time.time()
    created = []  # type: List[dict]
    for question, answer in _parse_cards(reply, n):
        created.append(_insert_card(question, answer, now))
    return created


def due_cards(now: Optional[float] = None) -> List[dict]:
    """Cards whose ``due`` timestamp has passed, soonest first."""
    now = time.time() if now is None else float(now)
    conn = _db()
    with _lock:
        rows = conn.execute(
            "SELECT id, ts, question, answer, due, interval_d, ease "
            "FROM cards WHERE due <= ? ORDER BY due ASC",
            (now,),
        ).fetchall()
    return [_row_to_card(r) for r in rows]


def review(card_id: int, grade: int) -> Optional[dict]:
    """Apply an SM-2-lite review and return the updated card (None if unknown).

    ``grade``: 0 again, 1 hard, 2 good, 3 easy. Again schedules a short relearn;
    the other grades grow the interval and nudge the ease factor.
    """
    try:
        grade = int(grade)
    except (TypeError, ValueError):
        raise ValueError("grade must be an integer 0..3")
    if grade < 0 or grade > 3:
        raise ValueError("grade must be 0..3")
    card = _get_card(card_id)
    if card is None:
        return None

    ease = max(MIN_EASE, float(card["ease"]) + _EASE_DELTA[grade])
    prev = float(card["interval_d"])
    now = time.time()
    if grade == 0:
        interval = 0.0
        due = now + _RELEARN_S
    else:
        if prev <= 0:
            # First graduation (new or lapsed): good/hard -> 1 day, easy -> 3.
            interval = 3.0 if grade == 3 else 1.0
        else:
            factor = {1: 1.2, 2: ease, 3: ease * 1.3}[grade]
            interval = prev * factor
        due = now + interval * _DAY

    conn = _db()
    with _lock:
        conn.execute(
            "UPDATE cards SET due = ?, interval_d = ?, ease = ? WHERE id = ?",
            (due, interval, ease, int(card_id)),
        )
        conn.commit()
    return _get_card(card_id)


# ---------------- internals ----------------

def _insert_card(question: str, answer: str, ts: Optional[float] = None) -> dict:
    ts = time.time() if ts is None else float(ts)
    conn = _db()
    with _lock:
        cur = conn.execute(
            "INSERT INTO cards (ts, question, answer, due, interval_d, ease) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (ts, question, answer, ts, 0.0, DEFAULT_EASE),
        )
        conn.commit()
        card_id = int(cur.lastrowid)
    return _get_card(card_id)


def _get_card(card_id: int) -> Optional[dict]:
    conn = _db()
    with _lock:
        row = conn.execute(
            "SELECT id, ts, question, answer, due, interval_d, ease "
            "FROM cards WHERE id = ?",
            (int(card_id),),
        ).fetchone()
    return _row_to_card(row) if row else None


def _row_to_card(row) -> dict:
    return {
        "id": int(row[0]),
        "ts": float(row[1]),
        "question": row[2],
        "answer": row[3],
        "due": float(row[4]),
        "interval_d": float(row[5]),
        "ease": float(row[6]),
    }


def _todays_material(max_chars: int = 6000) -> str:
    """Concatenate today's history text, newest first, capped for the prompt."""
    history = state.get_history()
    start = _start_of_today()
    collected = []  # type: List[str]
    total = 0
    page = 1
    per_page = 50
    while True:
        res = history.list(page=page, per_page=per_page)
        entries = res.get("entries") or []
        if not entries:
            break
        reached_yesterday = False
        for entry in entries:
            if float(entry.get("ts") or 0.0) < start:
                reached_yesterday = True
                break
            piece = _entry_text(entry)
            if piece:
                collected.append(piece)
                total += len(piece)
        if (reached_yesterday or total >= max_chars
                or page * per_page >= int(res.get("total") or 0)):
            break
        page += 1
    return "\n\n".join(collected)[:max_chars]


def _entry_text(entry: dict) -> str:
    extra = entry.get("extra") or {}
    parts = []  # type: List[str]
    question = extra.get("question")
    if question:
        parts.append("Asked: " + str(question))
    text = (entry.get("text") or "").strip()
    if text:
        parts.append(text)
    summary = extra.get("summary")
    if summary and summary != text:
        parts.append("Summary: " + str(summary))
    return "\n".join(parts).strip()


def _parse_cards(reply: str, n: int) -> List[Tuple[str, str]]:
    """Defensively pull Q/A pairs out of the model's reply."""
    data = _loads_lenient(reply)
    if not isinstance(data, list):
        return []
    out = []  # type: List[Tuple[str, str]]
    for item in data:
        if not isinstance(item, dict):
            continue
        question = item.get("q", item.get("question"))
        answer = item.get("a", item.get("answer"))
        if not isinstance(question, str) or not isinstance(answer, str):
            continue
        question = question.strip()
        answer = answer.strip()
        if question and answer:
            out.append((question, answer))
        if len(out) >= n:
            break
    return out


def _loads_lenient(text: str):
    """json.loads, but tolerant of code fences and surrounding prose."""
    text = (text or "").strip()
    if not text:
        return None
    if text.startswith("```"):
        text = re.sub(r"^```[A-Za-z0-9]*\s*", "", text)
        text = re.sub(r"\s*```$", "", text).strip()
    try:
        return json.loads(text)
    except ValueError:
        pass
    start = text.find("[")
    end = text.rfind("]")
    if start != -1 and end > start:
        try:
            return json.loads(text[start:end + 1])
        except ValueError:
            return None
    return None


def _start_of_today() -> float:
    lt = time.localtime()
    midnight = time.struct_time(
        (lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0,
         lt.tm_wday, lt.tm_yday, lt.tm_isdst)
    )
    return time.mktime(midnight)
