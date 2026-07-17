# Visionary — Architecture & Interface Contract

This document fixes the module boundaries, function signatures, schemas, and
protocols for the whole codebase (firmware + local API + iOS app). Code and
this document must not drift: change the contract first, then the code.

## Repo layout

```
visionary/
├── firmware/              # runs on the Pi Zero 2 W (cwd = this dir)
│   ├── main.py            # entrypoint: gesture engine, dispatcher, UDS command server, boot
│   ├── audio.py           # play/beep/speak (Piper), SentenceSpeaker, Recorder, record_until_silence
│   ├── vision.py          # camera lifecycle, capture, preview, OCR preprocessing
│   ├── brain.py           # Claude vision/chat (streaming + tool-use), Whisper STT, Tesseract OCR, online check, prompts
│   ├── state.py           # paths, config load/save, SQLite history + phone-action queue, pairing token + QR
│   ├── memory.py          # Tier 3: visual memory — embeddings + FTS5 search over history
│   ├── wakeword.py        # Tier 3: openWakeWord listener ("hey vision" trigger)
│   ├── metrics.py         # per-stage latency logging
│   ├── api.py             # FastAPI local server :8321 (separate process; talks to main via UDS)
│   ├── modes/             # read.py, describe.py, ask.py, recorder.py, translate.py, navigate.py (+ __init__.py)
│   ├── requirements.txt   # dev/test deps (Pi gets most deps via apt in setup.sh)
│   ├── setup.sh           # one-shot Pi provisioning (idempotent)
│   └── systemd/           # visionary.service, visionary-api.service, avahi-visionary.service (XML)
├── dashboard/             # Tier 3: classroom fleet dashboard (teacher-run FastAPI web app)
├── tests/                 # pytest; runs on any machine via SIM mode (no Pi hardware needed)
├── ios/                   # SwiftUI companion app (XcodeGen project.yml + Visionary/ sources)
├── Makefile               # test / golden / demo / ios-check
└── *.md                   # docs
```

## Global conventions

- **Python 3.9-compatible syntax** (dev machines run 3.9; the Pi runs 3.11).
  No `match`, no `X | Y` in annotations. Use `typing.Optional`, `typing.List`, etc.
- Firmware modules import each other **as top-level modules** (`import audio`,
  `from modes import read`) — the service runs with `WorkingDirectory=` the
  firmware dir; tests insert `firmware/` into `sys.path`.
- All subprocess use goes through `subprocess`; never shell=True with
  user-supplied strings.
- Errors NEVER fail silently: every user-facing failure path ends in a beep
  and/or spoken sentence.

### Environment variables

| Var | Meaning | Default |
|---|---|---|
| `VISIONARY_HOME` | data dir (config, db, captures, voices, sounds, sock) | `/opt/visionary` |
| `VISIONARY_SIM` | `"1"` = simulation mode: no camera/GPIO/ALSA; print instead | unset |
| `VISIONARY_SIM_IMAGE` | path to JPEG/PNG returned by sim capture | unset (sim generates a text image) |
| `VISIONARY_SIM_WAV` | path to WAV returned by sim recorder | unset (sim generates 1s silence) |
| `ANTHROPIC_API_KEY` | Claude API | — |
| `OPENAI_API_KEY` | Whisper STT API (optional) | — |
| `VISIONARY_MODEL` | Claude model id | `claude-haiku-4-5` |
| `VISIONARY_ALSA_CAPTURE` | arecord device | `plughw:0,0` |

SIM mode is decided **once per module import** via
`SIM = os.environ.get("VISIONARY_SIM") == "1"`.

### Paths (all under `$VISIONARY_HOME`, created by `state.ensure_dirs()`)

`config.json`, `history.db`, `token`, `pairing_qr.png`, `captures/`,
`recordings/`, `voices/`, `sounds/`, `visionary.sock`, `whisper/` (optional
whisper.cpp install). Metrics: `/var/log/visionary/metrics.log`, falling back
to `$VISIONARY_HOME/metrics.log` when not writable.

## firmware/state.py

```python
HOME: str                       # resolved VISIONARY_HOME
def ensure_dirs() -> None
DEFAULT_CONFIG: dict            # exactly the schema below
def load_config() -> dict       # defaults deep-merged with config.json (file wins)
def save_config(cfg: dict) -> None   # atomic (tmp + os.replace)

class History:                  # SQLite at HOME/history.db, thread-safe (lock)
    def add(self, kind: str, text: str, extra: Optional[Dict[str, str]] = None,
            image_path: Optional[str] = None, audio_path: Optional[str] = None) -> int
    def list(self, page: int = 1, per_page: int = 20) -> dict
        # {"entries": [entry...], "page": n, "per_page": n, "total": n}, newest first
    def get(self, entry_id: int) -> Optional[dict]
def get_history() -> History    # lazy singleton

def get_token() -> str          # 6-digit string; created+persisted (chmod 600) on first call;
                                # also writes pairing_qr.png (see QR payload) if `qrcode` importable
def pairing_payload() -> dict   # {"url": "http://<hostname>.local:8321", "token": "123456"}

class Actions:                  # Tier 3 phone-action queue, same DB file, thread-safe
    def add(self, action_type: str, payload: Dict[str, str]) -> int   # status="pending"
    def list_pending(self) -> List[dict]
    def complete(self, action_id: int, status: str, result: str = "") -> bool
        # status ∈ done | failed; False if id unknown
def get_actions() -> Actions    # lazy singleton
```

Action dict: `{"id": int, "ts": float, "type": str, "payload": Dict[str, str],
"status": "pending"|"done"|"failed", "result": str}`.
`type` ∈ `calendar_event | reminder`. `payload` string values only —
calendar_event: `{"title", "date" (ISO8601), "notes"?}`; reminder: `{"title", "notes"?}`.
Schema: `actions(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, type TEXT,
payload TEXT, status TEXT, result TEXT)`.

Entry dict: `{"id": int, "ts": float, "kind": str, "text": str,
"extra": dict|None, "image_path": str|None, "audio_path": str|None}`.
`kind` ∈ `read | describe | ask | recording | translate`.
`extra` values are **always strings** (e.g. `{"question": ..., "summary": ...,
"language": ...}`) — the iOS app models it as `[String: String]`.

Schema: `entries(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, kind TEXT,
text TEXT, extra TEXT, image_path TEXT, audio_path TEXT)` — `extra` stored as JSON.

### config.json schema (DEFAULT_CONFIG)

```json
{
  "voice": "en_US-lessac-low",
  "rate": 1.0,
  "language": null,
  "two_way": {"enabled": false, "theirs": "es", "yours": "en"},
  "gestures": {"single": "read", "double": "describe", "triple": "recorder"},
  "features": {"ask": true, "recorder": true},
  "wake_word": {"enabled": false, "model": "hey_jarvis"},
  "navigation": {"enabled": false, "interval_s": 3.0}
}
```

`wake_word.model` is an openWakeWord pretrained model name; a custom
"hey vision" model is a documented follow-up (training one is out of scope),
so the shipped default trigger phrase is "hey Jarvis".

`language` = translation target for reading (`null` = read as-is). `rate` is a
speech-speed multiplier 0.5–2.0 (maps to piper `--length-scale 1/rate`).
Modes call `load_config()` at the start of each action, so config changes via
the API take effect without a restart.

## firmware/metrics.py

```python
class StageTimer:
    def __init__(self) -> None            # starts the clock
    def mark(self, stage: str) -> None    # records ms since previous mark
    def log(self, event: str) -> None     # appends one line to the metrics log
```

Line format: `ts=<unix> event=read capture_ms=213 model_ms=1830 tts_first_ms=420 total_ms=2460`
(stage keys are whatever was marked, plus `total_ms`).

## firmware/audio.py

```python
def play(path: str, wait: bool = False) -> None          # aplay; sim: print
def beep(name: str) -> None
    # name ∈ capture | ok | err | offline | rec_start | rec_stop  (HOME/sounds/<name>.wav)
def speak(text: str, wait: bool = True) -> None
    # Piper (voice + rate from load_config(); model HOME/voices/<voice>.onnx,
    # sample rate read from the voice's .json, default 16000) piped to aplay raw.
    # Fallback: espeak-ng. Sim: print("[speak] " + text)

class SentenceSpeaker:
    # Streaming TTS: feed() text chunks; speaks each completed sentence (split on .!?\n)
    # in order via a worker thread + queue, overlapping TTS with model streaming.
    def feed(self, chunk: str) -> None
    def close(self) -> None       # flush remainder, block until all speech done
    first_audio_ts: Optional[float]   # monotonic time first sentence started speaking (for metrics)

class Recorder:
    def start(self) -> None       # arecord S32_LE 48k stereo -> tmp wav; sim: no-op
    def stop(self) -> str         # stop, convert to 16k mono WAV (sox; numpy fallback), return path
    recording: bool

def record_until_silence(max_s: float = 15.0, silence_s: float = 1.2) -> Optional[str]
    # blocking capture that stops after `silence_s` of low energy (numpy RMS on raw
    # stream) or max_s; returns 16k mono wav path, or None if nothing above threshold.
    # sim: returns VISIONARY_SIM_WAV or generated silence.

def capture_in_use() -> bool
    # True while a Recorder or record_until_silence owns the mic (module-level flag,
    # set/cleared by both). wakeword.py pauses inference while True.
```

## firmware/vision.py

```python
def init_camera() -> None                 # start Picamera2 once, keep running (capture < 300ms)
def capture_jpeg() -> bytes               # full-res still (1640x1232); sim: SIM image file or generated text image
def capture_preview_jpeg(size: Tuple[int, int] = (640, 480)) -> bytes   # for MJPEG /live
def preprocess_for_ocr(jpeg: bytes) -> "PIL.Image.Image"   # grayscale + autocontrast
def save_capture(jpeg: bytes) -> str      # write HOME/captures/<ts>.jpg, return path
```

## firmware/brain.py

```python
class BrainOffline(Exception): ...

def is_online(force: bool = False) -> bool
    # socket check to api.anthropic.com:443 AND ANTHROPIC_API_KEY present; cached 10s;
    # never blocks a button press for more than ~2s and only when the cache is stale.

def see(jpeg: bytes, prompt: str, on_text: Optional[Callable[[str], None]] = None,
        history_msgs: Optional[List[dict]] = None,
        tools: Optional[List[dict]] = None,
        tool_handlers: Optional[Dict[str, Callable[[dict], str]]] = None) -> str
    # Claude messages API with streaming (SSE via requests, stream=True).
    # history_msgs = prior conversation turns (Anthropic message dicts) prepended.
    # Raises BrainOffline on network failure, RuntimeError on API error.
    # Tier 3 tool-use: when tools given, runs NON-streaming with a tool loop —
    # while stop_reason=="tool_use": run tool_handlers[name](input) -> str, append
    # tool_result, continue (max 5 rounds). Final text goes to on_text once and returns.

def chat(messages: List[dict], system: Optional[str] = None,
         on_text: Optional[Callable[[str], None]] = None) -> str
    # text-only Claude call, same error contract.

TOOL_SEARCH_MEMORY: dict   # Anthropic tool schema: search_memory(query: str, k?: int)
TOOL_PHONE_ACTION: dict    # phone_action(type: calendar_event|reminder, title: str, date?: str, notes?: str)

def transcribe(wav_path: str) -> str
    # online + OPENAI_API_KEY -> OpenAI whisper-1; else whisper.cpp at HOME/whisper/
    # (binary `main`, model ggml-tiny.en.bin) as a subprocess that exits (RAM budget);
    # else raise BrainOffline.

def ocr(jpeg: bytes) -> str               # preprocess_for_ocr + pytesseract; RuntimeError if unavailable

READ_PROMPT: str; DESCRIBE_PROMPT: str; ASK_SYSTEM: str; SUMMARY_PROMPT: str
NAVIGATE_PROMPT: str   # short assistive callouts: hazards, signage, doorways; POV framing;
                       # explicitly assistive-information, not a certified safety system
def read_prompt(language: Optional[str]) -> str   # READ_PROMPT (+ "Translate everything to {language}." if set)
```

Prompt text: refined from the original single-file build; the canonical copies live in `brain.py`.

## firmware/memory.py — Tier 3 visual memory

Every history entry becomes searchable ("what room number was on that door?").
Tables live in the same `history.db`: `memory(entry_id INTEGER PRIMARY KEY,
embedding BLOB, model TEXT)` (float32 bytes) + FTS5 `memory_fts(entry_id, text)`.
No sqlite-vss: cosine similarity over numpy in Python is plenty for on-device scale.

```python
def embed(texts: List[str]) -> Optional[List[List[float]]]
    # OpenAI text-embedding-3-small (OPENAI_API_KEY); None when offline/no key.
def index_entry(entry_id: int, text: str) -> None
    # Always insert into FTS5; embed+store when online, else leave pending.
def reindex_pending(max_n: int = 50) -> int
    # Embed entries missing vectors (called opportunistically when online). Returns count.
def search(query: str, k: int = 5) -> List[dict]
    # Cosine over embeddings when query embedding available, FTS5 (with OR-term fallback)
    # otherwise — search NEVER requires the network. Returns history entry dicts + "score".
```

Modes call `memory.index_entry(...)` right after `history.add(...)` (read,
describe, ask, recording). If numpy is missing, embedding search degrades to
FTS5 silently.

## firmware/wakeword.py — Tier 3 wake word

openWakeWord listener (~15% CPU on the Zero 2 W), strictly local processing —
audio never stored or uploaded; document this in the module docstring.

```python
def available() -> bool          # openwakeword importable AND a model resolvable
def start(on_wake: Callable[[], None]) -> bool
    # spawn daemon listener thread (16k mono mic stream); False if unavailable.
    # MUST pause inference while other capture is active (checks a shared
    # audio-in-use flag exposed as audio.capture_in_use() -> bool).
def stop() -> None
```

`audio.py` therefore also exposes `capture_in_use() -> bool` (True while a
Recorder or record_until_silence owns the mic). openwakeword import lives
inside functions; SIM: `available()` is False.

## firmware/modes/

Each mode is module-level functions using the singletons above. Every mode:
uses `StageTimer`, starts with `beep("capture")` (or rec beeps), saves history,
and ends every failure path with `beep("err")` + a short spoken sentence.

```python
# read.py
def run_read() -> None
    # capture -> save_capture -> online? brain.see(read_prompt(cfg.language), on_text -> SentenceSpeaker)
    #   BrainOffline/failure -> beep("offline") -> brain.ocr -> speak (or "I couldn't find any text.")
    # history kind="read" (extra {"language": lang} when translating)

# describe.py
def run_describe() -> None    # same shape, DESCRIBE_PROMPT; offline fallback = OCR + explain-scene-needs-internet

# ask.py  (hold-to-ask; also the voice assistant — photo is always attached)
def ask_begin() -> None       # beep rec_start, Recorder.start()
def ask_end() -> None
    # Recorder.stop -> transcribe -> capture photo -> brain.see(question, ASK_SYSTEM context,
    # history_msgs = last 6 exchanges from in-RAM deque,
    # tools=[TOOL_SEARCH_MEMORY, TOOL_PHONE_ACTION],
    # tool_handlers={search_memory -> memory.search formatted as speakable lines,
    #                phone_action -> state.get_actions().add + "Queued for your phone."})
    # -> speak answer; store kind="ask", text=answer, extra={"question": q}.
    # Offline: transcribe may still work via whisper.cpp; if see() is offline,
    # fall back to memory.search(question) (FTS5 works offline) and speak the top hit,
    # else "I need internet to answer questions."
def ask_from_wake() -> None   # wake-word entry: record_until_silence instead of hold, then same as ask_end
def reset_memory() -> None

# recorder.py  (triple press toggles)
def toggle() -> None
    # start: beep rec_start, Recorder.start(). stop: beep rec_stop, speak "Processing recording.",
    # transcribe -> chat(SUMMARY_PROMPT) -> speak summary -> history kind="recording",
    # text=transcript, extra={"summary": s}, audio_path=<HOME/recordings/...>.
is_recording() -> bool

# translate.py  (two-way interpreter; runs while config two_way.enabled)
def run_two_way(stop_event: "threading.Event") -> None
    # loop: record_until_silence -> transcribe -> chat("translate ...") -> speak.
    # Direction heuristic documented in-module. Exits promptly when stop_event set.

# navigate.py  (Tier 3 navigation assist; runs while config navigation.enabled)
def run_navigation(stop_event: "threading.Event") -> None
    # On start speaks a one-line disclaimer ("Navigation assist gives information,
    # not safety guarantees."). Loop every cfg navigation.interval_s:
    # capture_preview_jpeg -> brain.see(NAVIGATE_PROMPT + the previous callout for
    # continuity) -> speak ONLY when the callout is new/changed (model instructed to
    # return the literal token NONE when nothing worth saying). Offline -> speak
    # "Navigation assist needs internet." once and exit. Checks stop_event between steps.
```

## firmware/main.py

```python
class GestureEngine:
    # Pure logic, testable: no GPIO imports. Injected clock for tests.
    def __init__(self, on_single, on_double, on_triple, on_hold_start, on_hold_end,
                 on_shutdown, multi_window=0.45, hold_time=1.0, shutdown_time=5.0,
                 clock=time.monotonic) -> None
    def press(self) -> None
    def release(self) -> None
    # Semantics: presses shorter than hold_time count into a click burst; burst ends
    # multi_window after the last release -> 1/2/3 clicks fire single/double/triple.
    # Held >= hold_time fires on_hold_start immediately (recording starts while held);
    # release before shutdown_time fires on_hold_end; held >= shutdown_time cancels the
    # ask (on_hold_end(cancelled=True)) and fires on_shutdown.
    # on_hold_end signature: on_hold_end(cancelled: bool = False)
```

Dispatcher: a `threading.Lock` (`busy`) — actions run on daemon threads;
a press while busy is ignored EXCEPT recorder-stop and stopping a background
loop. Gesture→mode routing honors `config["gestures"]`. When a background loop
(two-way translate OR navigation assist) is active, single press stops it
instead of reading.

Tier 3 lifecycle (owned by main.py): a slow config watcher (~5s poll, plus a
check on every dispatch) reconciles background threads with config —
`two_way.enabled` ↔ translate thread, `navigation.enabled` ↔ navigate thread,
`wake_word.enabled` ↔ `wakeword.start(on_wake=modes.ask.ask_from_wake)`.
Also calls `memory.reindex_pending()` when online (at most once a minute).

UDS command server (thread): JSON-lines over `HOME/visionary.sock`.
Requests/responses (one JSON object per line):

| Request | Response |
|---|---|
| `{"cmd":"capture","mode":"read"\|"describe"\|"recorder"}` | `{"ok":true}` (dispatched async) or `{"ok":false,"error":"busy"}` |
| `{"cmd":"speak","text":"..."}` | `{"ok":true}` |
| `{"cmd":"frame"}` | `{"ok":true,"jpeg_b64":"..."}` (640x480 preview) |
| `{"cmd":"status"}` | `{"ok":true,"online":bool,"busy":bool,"uptime":float,"recording":bool}` |

Boot: `ensure_dirs` → `get_token` (first boot only: speak the 6-digit pairing
code) → `init_camera` → start UDS server → speak "Visionary ready." (+ " Offline
mode." when offline). Hardware mode binds gpiozero `Button(17, pull_up=True,
bounce_time=0.05)` press/release to the engine. SIM mode runs a stdin REPL:
`1`/`2`/`3` = clicks, `a` = hold start, `r` = hold release, `s` = status, `q` = quit.

`main()` picks hardware vs SIM from `VISIONARY_SIM`.

## firmware/api.py — local API on :8321

FastAPI app, run by uvicorn (separate `visionary-api.service`). ALL endpoints
require `Authorization: Bearer <token>` matching `state.get_token()` → else 401.
Talks to the main service only via the UDS protocol above (module-level helper
`uds_call(payload: dict, timeout: float = 5.0) -> dict`).

| Endpoint | Method | Behavior |
|---|---|---|
| `/status` | GET | `{"online","battery":null,"wifi":<ssid via iwgetid or null>,"version","uptime","busy","recording"}` (merges UDS status; `version` from `VERSION` const) |
| `/config` | GET | `state.load_config()` |
| `/config` | PUT | body deep-merged into config after key validation (unknown top-level keys → 422); returns saved config |
| `/history` | GET | `?page=&per_page=` → `History.list()` |
| `/history/{id}/image` | GET | FileResponse of `image_path` (404 if none) |
| `/history/{id}/audio` | GET | FileResponse of `audio_path` (404 if none) |
| `/capture` | POST | `{"mode":"read"}` → UDS capture; 409 when busy |
| `/live` | GET | `multipart/x-mixed-replace` MJPEG, ~4 fps of UDS `frame` |
| `/speak` | POST | `{"text":"..."}` → UDS speak |
| `/wifi` | POST | `{"ssid","psk"}` → `nmcli connection add` (no shell interpolation) |
| `/update` | POST | `git pull` in the app dir + `systemctl restart visionary visionary-api` |
| `/memory/search` | GET | `?q=&k=` → `{"results": memory.search(q, k)}` (text-only entries + score) |
| `/actions` | GET | `{"actions": state.get_actions().list_pending()}` |
| `/actions/{id}` | POST | `{"status":"done"\|"failed","result":"..."}` → mark executed (404 unknown id) |

Battery is `null` in v1 (no fuel gauge on the PowerBoost Basic) — clients show "—".

## systemd + setup

- `visionary.service`: `python3 main.py`, `WorkingDirectory=/opt/visionary/app`,
  `EnvironmentFile=/etc/visionary.env`, `Restart=on-failure`, `RestartSec=3`.
- `visionary-api.service`: `uvicorn api:app --host 0.0.0.0 --port 8321`, same cwd/env.
- `avahi-visionary.service` → `/etc/avahi/services/`: advertises `_visionary._tcp` port 8321.
- `setup.sh` (idempotent, Bookworm): apt (picamera2, gpiozero, requests, PIL, numpy,
  tesseract + pytesseract, espeak-ng, alsa-utils, sox, avahi-daemon), pip (piper-tts,
  fastapi, uvicorn, qrcode) with `--break-system-packages`, I2S overlay
  (`googlevoicehat-soundcard`, `dtparam=audio=off`), piper voice download, sox-generated
  beeps (6 sounds), rsync `firmware/` → `/opt/visionary/app/`, `/etc/visionary.env`
  (ANTHROPIC_API_KEY, OPENAI_API_KEY placeholders, chmod 600), install+enable both
  services + avahi file. Optional `--with-whisper` flag builds whisper.cpp + tiny.en
  into `HOME/whisper/`. Optional `--with-wakeword` flag pip-installs openwakeword and
  pre-downloads its models.

## dashboard/ — Tier 3 classroom fleet dashboard

Teacher-run web app (their laptop, same LAN), NOT on the glasses. Polls each
device's local API and shows **text-only** reading activity — no images, no
audio, ever (it simply never requests those endpoints; say so in the UI footer).

```
dashboard/
├── app.py            # FastAPI: background poller + JSON endpoints + single HTML page
├── devices.example.json   # [{"name": "Station 1", "url": "http://visionary.local:8321", "token": "123456"}]
├── static/index.html # vanilla JS single page: per-student cards + aggregate strip
└── README.md         # run: uvicorn app:app --port 8400; copy devices.example.json -> devices.json
```

app.py contract: loads `devices.json` (path via `VISIONARY_FLEET_CONFIG` env,
default `./devices.json`); a background thread polls each device `/status` +
`/history?page=1&per_page=20` every 15s into an in-RAM snapshot (device name →
{online, last_seen, reads_today, recent: [{ts, kind, first_line_of_text}]});
`GET /` serves the page, `GET /fleet` returns the snapshot JSON. Text truncated
to 120 chars — summaries, not surveillance. Uses `requests`; no database.

## Tests (`tests/`, pytest, no hardware)

- `conftest.py`: session-scoped `sys.path` insert of `firmware/`; autouse fixture sets
  `VISIONARY_SIM=1` and a per-test `VISIONARY_HOME` tmp dir **before** importing
  firmware modules (import inside fixtures/tests, or reload `state`).
- `generate_golden.py`: PIL-renders `tests/golden/` images (worksheet, menu, big-text
  sign, low-contrast page, blank page) + `expected.json` of must-contain substrings.
- `test_state.py` (config merge/atomic save, history CRUD + pagination, token stability)
- `test_gestures.py` (fake clock: single/double/triple, hold→ask, 5s→shutdown-cancels-ask)
- `test_audio.py` (SentenceSpeaker splitting/order in sim, Recorder sim path)
- `test_brain.py` (is_online cache w/ monkeypatched socket; `see()` SSE parsing against
  a fake streamed response; transcribe routing; all network mocked)
- `test_offline_read.py` (`skipif` tesseract missing: ocr(golden) contains expected text)
- `test_api.py` (`skipif` fastapi missing: 401 without token, config roundtrip, history,
  capture/speak against a fake UDS server fixture, image 404, /memory/search offline
  FTS5 path, /actions queue lifecycle add→pending→complete→gone)
- `test_memory.py` (index_entry + FTS5 search with embeddings unavailable (offline),
  cosine ranking with a monkeypatched embed(), reindex_pending)
- `test_dashboard.py` (`skipif` fastapi missing: /fleet snapshot shape with the device
  poller monkeypatched — no real network)
- `demo_smoke.py`: `make demo` — SIM end-to-end: generate golden → single press → read
  pipeline → printed speech output. Exits nonzero on failure.

Makefile (repo root): `venv` (python3 -m venv .venv + pip install -r firmware/requirements.txt),
`test` (pytest), `golden`, `demo`, `ios-check` (swiftc -typecheck against the
iphonesimulator SDK, iOS 16 target).

## iOS app (`ios/`, SwiftUI, iOS 16+)

XcodeGen `project.yml` (app target `Visionary`; Info.plist keys:
`NSCameraUsageDescription`, `NSLocalNetworkUsageDescription`,
`NSBonjourServices` = `["_visionary._tcp"]`, `NSCalendarsUsageDescription`,
`NSRemindersUsageDescription`). No accounts, no cloud — device-local.

```
ios/Visionary/
├── VisionaryApp.swift        # @main, injects AppState
├── AppState.swift            # @MainActor ObservableObject: pairing persistence (UserDefaults),
│                             # APIClient?, published DeviceStatus/DeviceConfig, connect()/pair()/forget()
├── Models.swift              # Codable, .convertFromSnakeCase: DeviceStatus, DeviceConfig, TwoWayConfig,
│                             # WakeWordConfig, NavigationConfig, HistoryEntry (extra: [String:String]?),
│                             # HistoryPage, PairingPayload, MemoryHit (entry + score),
│                             # PhoneAction (id, ts, type, payload [String:String], status)
├── APIClient.swift           # async/await URLSession + Bearer token:
│                             #  status(), getConfig(), putConfig(_), history(page:), image(id:) -> UIImage?,
│                             #  capture(mode:), speak(_), wifi(ssid:psk:), update(), liveRequest() -> URLRequest,
│                             #  audioRequest(id:) -> URLRequest, memorySearch(_:k:) -> [MemoryHit],
│                             #  pendingActions() -> [PhoneAction], completeAction(id:status:result:)
├── DeviceDiscovery.swift     # NWBrowser for _visionary._tcp -> [DiscoveredDevice(name, url)]
├── ActionRunner.swift        # Tier 3 agent actions: polls pendingActions() while app is active,
│                             # executes via EventKit (EKEvent for calendar_event, EKReminder for reminder,
│                             # permission-aware), then completeAction(done/failed). Owned/started by AppState.
├── MJPEGView.swift           # URLSessionDataDelegate multipart parser -> UIImage stream
└── Views/
    ├── PairingView.swift     # QR scan (VisionKit DataScannerViewController wrapper) + manual URL/code entry
    │                         # QR payload = JSON {"url": "...", "token": "123456"}
    ├── HomeView.swift        # status card + big Read / Describe buttons (POST /capture)
    ├── HistoryView.swift     # timeline, thumbnails via APIClient.image(id:), detail w/ text + share
    ├── SearchView.swift      # Tier 3 visual memory: search field -> memorySearch results
    │                         # ("what room number was on that door?"), tap-through to entry detail
    ├── LiveView.swift        # MJPEGView of /live
    ├── SettingsView.swift    # voice picker, rate slider 0.5–2.0, translation language, two-way toggle,
    │                         # wake word toggle, navigation assist toggle + interval (with the
    │                         # assistive-info-not-safety-device disclaimer), WiFi form (POST /wifi),
    │                         # "Check for updates" (POST /update)
    └── RecorderView.swift    # kind=="recording" entries: transcript + summary, play /history/{id}/audio, share
```

TabView: Home / History / Search / Live / Recorder / Settings; PairingView shown
until paired. `ios/README.md`: `brew install xcodegen && xcodegen generate`
(or manual Xcode steps).

## Cross-cutting invariants

1. Hands-free/eyes-free: no glasses feature depends on a screen.
2. Offline-degradable: every cloud path has a fallback or graceful spoken failure.
3. Press-to-capture privacy: nothing captured/uploaded except deliberate triggers;
   history stays on device. Tier 3 opt-ins keep the spirit: wake-word audio is
   processed locally and never stored/uploaded; navigation captures are sent to the
   vision API only while the wearer has navigation explicitly enabled; the classroom
   dashboard sees text summaries only, never images or audio.
4. RAM budget (512MB): whisper.cpp and other heavy work run as subprocesses that exit;
   never simultaneously with a model-heavy step. openWakeWord budget ≤ ~15% CPU.
5. Perceived latency: first spoken sentence starts while the model is still streaming.
6. Navigation assist is assistive information, not a certified safety device — the
   framing appears in the prompt, the spoken disclaimer, the app, and the docs.
