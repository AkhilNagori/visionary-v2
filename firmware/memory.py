"""Tier 3 visual memory: embeddings + FTS5 search over history.

Every history entry becomes searchable ("what room number was on that door?").
Two tables live alongside the history in state.DB_PATH:

    memory(entry_id INTEGER PRIMARY KEY, embedding BLOB, model TEXT)   -- float32 bytes
    memory_fts USING fts5(entry_id UNINDEXED, text)

Search uses cosine similarity over the stored float32 vectors when a query
embedding is available (online + OPENAI_API_KEY + numpy), and FTS5 full-text
matching otherwise. It NEVER requires the network: offline it degrades to FTS5,
and if numpy is missing it degrades to FTS5 too. Vectors are embedded
opportunistically when online; entries indexed offline stay pending until
reindex_pending() picks them up.
"""

import math
import os
import re
import sqlite3
import threading
from array import array
from typing import List, Optional

import requests

import state

EMBED_MODEL = "text-embedding-3-small"
_EMBED_URL = "https://api.openai.com/v1/embeddings"

# Word tokens for FTS5: \w never contains a double quote, so each token can be
# wrapped in quotes and treated as a literal phrase with no escaping needed.
_TOKEN = re.compile(r"\w+", re.UNICODE)

_conn = None  # type: Optional[sqlite3.Connection]
_lock = threading.Lock()


def _db() -> sqlite3.Connection:
    global _conn
    with _lock:
        if _conn is None:
            state.ensure_dirs()
            conn = sqlite3.connect(state.DB_PATH, check_same_thread=False)
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute(
                "CREATE TABLE IF NOT EXISTS memory ("
                "entry_id INTEGER PRIMARY KEY, embedding BLOB, model TEXT)"
            )
            conn.execute(
                "CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts "
                "USING fts5(entry_id UNINDEXED, text)"
            )
            conn.commit()
            _conn = conn
        return _conn


def embed(texts: List[str]) -> Optional[List[List[float]]]:
    """OpenAI text-embedding-3-small. None when offline or no key."""
    if not texts:
        return []
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        return None
    try:
        resp = requests.post(
            _EMBED_URL,
            headers={"Authorization": "Bearer " + key,
                     "Content-Type": "application/json"},
            json={"model": EMBED_MODEL, "input": list(texts)},
            timeout=20,
        )
        resp.raise_for_status()
        data = resp.json()["data"]
    except (requests.RequestException, ValueError, KeyError, TypeError):
        return None
    data = sorted(data, key=lambda d: d.get("index", 0))
    return [d["embedding"] for d in data]


def index_entry(entry_id: int, text: str) -> None:
    """Always index into FTS5; embed+store when online, else leave pending."""
    text = text or ""
    conn = _db()
    with _lock:
        conn.execute("DELETE FROM memory_fts WHERE rowid = ?", (entry_id,))
        conn.execute(
            "INSERT INTO memory_fts (rowid, entry_id, text) VALUES (?, ?, ?)",
            (entry_id, entry_id, text),
        )
        conn.commit()
    vecs = embed([text])
    if vecs:
        _store_embeddings([(entry_id, vecs[0])])


def reindex_pending(max_n: int = 50) -> int:
    """Embed FTS-indexed entries that still lack a vector. Returns count stored."""
    conn = _db()
    with _lock:
        rows = conn.execute(
            "SELECT entry_id, text FROM memory_fts "
            "WHERE entry_id NOT IN (SELECT entry_id FROM memory) LIMIT ?",
            (int(max_n),),
        ).fetchall()
    if not rows:
        return 0
    vecs = embed([r[1] or "" for r in rows])
    if not vecs or len(vecs) != len(rows):
        return 0
    _store_embeddings([(rows[i][0], vecs[i]) for i in range(len(rows))])
    return len(rows)


def search(query: str, k: int = 5) -> List[dict]:
    """History entry dicts + "score", best first. Never requires the network."""
    query = (query or "").strip()
    if not query or k <= 0:
        return []
    qvecs = embed([query])
    if qvecs:
        cosine = _cosine_search(qvecs[0], k)
        if cosine is not None:
            return cosine
    return _fts_search(query, k)


def _store_embeddings(pairs) -> None:
    conn = _db()
    with _lock:
        for entry_id, vec in pairs:
            conn.execute(
                "INSERT OR REPLACE INTO memory (entry_id, embedding, model) "
                "VALUES (?, ?, ?)",
                (entry_id, array("f", vec).tobytes(), EMBED_MODEL),
            )
        conn.commit()


def _cosine_search(qvec, k: int) -> Optional[List[dict]]:
    """Cosine over stored vectors. None (degrade to FTS5) if numpy or vectors absent."""
    try:
        import numpy as np
    except ImportError:
        return None
    conn = _db()
    with _lock:
        rows = conn.execute(
            "SELECT entry_id, embedding FROM memory WHERE embedding IS NOT NULL"
        ).fetchall()
    if not rows:
        return None
    q = np.asarray(qvec, dtype=np.float32)
    qn = float(np.linalg.norm(q))
    if qn == 0.0:
        return None
    q = q / qn
    ids = []
    vectors = []
    for entry_id, blob in rows:
        v = np.frombuffer(blob, dtype=np.float32)
        if v.size != q.size:
            continue
        ids.append(int(entry_id))
        vectors.append(v)
    if not vectors:
        return None
    mat = np.vstack(vectors)
    norms = np.linalg.norm(mat, axis=1)
    norms[norms == 0.0] = 1.0
    sims = (mat @ q) / norms
    order = np.argsort(-sims)[:k]
    scored = [(ids[i], min(1.0, max(0.0, float(sims[i])))) for i in order]
    return _entries(scored)


def _fts_search(query: str, k: int) -> List[dict]:
    terms = _TOKEN.findall(query.lower())
    if not terms:
        return []
    conn = _db()
    quoted = ['"%s"' % t for t in terms]
    # AND (all terms) first for precision; OR fallback for recall / syntax safety.
    for match in (" ".join(quoted), " OR ".join(quoted)):
        try:
            with _lock:
                rows = conn.execute(
                    "SELECT entry_id, rank FROM memory_fts "
                    "WHERE memory_fts MATCH ? ORDER BY rank LIMIT ?",
                    (match, int(k)),
                ).fetchall()
        except sqlite3.OperationalError:
            continue
        if rows:
            return _entries([(int(r[0]), _bm25_score(r[1])) for r in rows])
    return []


def _bm25_score(rank) -> float:
    # SQLite bm25/rank is negative, more negative = better. Map to 0-1ish.
    try:
        return max(0.0, 1.0 - math.exp(float(rank)))
    except (OverflowError, ValueError):
        return 0.0


def _entries(scored) -> List[dict]:
    history = state.get_history()
    out = []  # type: List[dict]
    for entry_id, score in scored:
        entry = history.get(entry_id)
        if entry is None:
            continue
        entry = dict(entry)
        entry["score"] = float(score)
        out.append(entry)
    return out
