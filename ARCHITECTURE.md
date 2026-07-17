# Visionary — Architecture & Interface Contract

This document fixes the module boundaries, function signatures, schemas, and
protocols for the whole codebase (firmware + local API + iOS app). Code and
this document must not drift: change the contract first, then the code.

## Repo layout

```
visionary/
├── firmware/              # runs on the Pi Zero 2 W (cwd = this dir)
│   ├── main.py            # entrypoint: gesture engine, dispatcher, UDS command server, boot
│   ├── audio.py           # local ALSA I/O + OpenAI TTS, SentenceSpeaker, Recorder, record_until_silence
│   ├── vision.py          # camera lifecycle, capture, preview
│   ├── brain.py           # OpenAI vision/chat (streaming + function-calling), cloud STT, online check, prompts
│   ├── state.py           # paths, config load/save, SQLite history + phone-action queue, pairing token + QR
│   ├── memory.py          # Tier 3: visual memory — embeddings + FTS5 search over history
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
| `VISIONARY_HOME` | data dir (config, db, captures, recordings, sounds, sock) | `/opt/visionary` |
| `VISIONARY_SIM` | `"1"` = simulation mode: no camera/GPIO/ALSA; print instead | unset |
| `VISIONARY_SIM_IMAGE` | path to JPEG/PNG returned by sim capture | unset (sim generates a text image) |
| `VISIONARY_SIM_WAV` | path to WAV returned by sim recorder | unset (sim generates 1s silence) |
| `OPENAI_API_KEY` | OpenAI API (vision/chat, STT, TTS, embeddings) — required | — |
| `VISIONARY_MODEL` | OpenAI model id | `gpt-4o-mini` |
| `VISIONARY_STT_MODEL` | OpenAI transcription model id | `gpt-4o-mini-transcribe` |
| `VISIONARY_TTS_MODEL` | OpenAI speech model id | `gpt-4o-mini-tts-2025-12-15` |
| `VISIONARY_TTS_VOICE` | OpenAI speech voice | `marin` |
| `VISIONARY_ALSA_CAPTURE` | arecord device | `plughw:0,0` |

SIM mode is decided **once per module import** via
`SIM = os.environ.get("VISIONARY_SIM") == "1"`.

### Paths (all under `$VISIONARY_HOME`, created by `state.ensure_dirs()`)

`config.json`, `history.db`, `token`, `pairing_qr.png`, `captures/`,
`recordings/`, `sounds/`, `visionary.sock`. Metrics: `/var/log/visionary/metrics.log`, falling back
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
  "voice": "marin",
  "rate": 1.0,
  "language": null,
  "two_way": {"enabled": false, "theirs": "es", "yours": "en"},
  "gestures": {"single": "read", "double": "describe", "triple": "recorder"},
  "features": {"ask": true, "recorder": true},
  "navigation": {"enabled": false, "interval_s": 3.0}
}
```

`language` = translation target for reading (`null` = read as-is). `rate` is a
speech-speed multiplier 0.5–2.0 passed to the OpenAI speech request.
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
    # POST text to OpenAI /v1/audio/speech using OPENAI_API_KEY,
    # VISIONARY_TTS_MODEL (default gpt-4o-mini-tts-2025-12-15), and the configured/OpenAI voice + rate;
    # play the returned WAV through local ALSA. No local speech-engine fallback.
    # Connection/API errors are logged and trigger the local error beep without
    # crashing the dispatcher. Sim: print("[speak] " + text)

class SentenceSpeaker:
    # Sentence-level cloud TTS: feed() text chunks; requests/speaks each completed
    # sentence (split on .!?\n) in order via a worker thread + queue, overlapping
    # speech requests/playback with model streaming.
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
    # set/cleared by both); used to prevent overlapping recordings.
```

## firmware/vision.py

```python
def init_camera() -> None                 # start Picamera2 once, keep running (capture < 300ms)
def capture_jpeg() -> bytes               # full-res still (1640x1232); sim: SIM image file or generated text image
def capture_preview_jpeg(size: Tuple[int, int] = (640, 480)) -> bytes   # for MJPEG /live
def save_capture(jpeg: bytes) -> str      # write HOME/captures/<ts>.jpg, return path
```

## firmware/brain.py

```python
class BrainOffline(Exception): ...

def is_online(force: bool = False) -> bool
    # socket check to api.openai.com:443 AND OPENAI_API_KEY present; cached 10s;
    # never blocks a button press for more than ~2s and only when the cache is stale.

def see(jpeg: bytes, prompt: str, on_text: Optional[Callable[[str], None]] = None,
        history_msgs: Optional[List[dict]] = None,
        tools: Optional[List[dict]] = None,
        tool_handlers: Optional[Dict[str, Callable[[dict], str]]] = None) -> str
    # OpenAI chat.completions API with streaming (SSE via requests, stream=True);
    # image sent as a data: URL image_url content part.
    # history_msgs = prior conversation turns (OpenAI message dicts) prepended.
    # Raises BrainOffline on network failure, RuntimeError on API error.
    # Tier 3 function-calling: when tools given, runs NON-streaming with a tool loop —
    # while the reply has tool_calls: run tool_handlers[name](args) -> str, append a
    # role:"tool" result, continue (max 5 rounds). Final text goes to on_text once and returns.

def chat(messages: List[dict], system: Optional[str] = None,
         on_text: Optional[Callable[[str], None]] = None) -> str
    # text-only OpenAI call, same error contract.

TOOL_SEARCH_MEMORY: dict   # OpenAI function schema: search_memory(query: str, k?: int)
TOOL_PHONE_ACTION: dict    # phone_action(type: calendar_event|reminder, title: str, date?: str, notes?: str)

def transcribe(wav_path: str) -> str
    # POST the deliberately captured WAV to OpenAI /v1/audio/transcriptions using
    # OPENAI_API_KEY and VISIONARY_STT_MODEL (default gpt-4o-mini-transcribe).
    # No local STT fallback; unavailable network/key raises BrainOffline.

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

## firmware/modes/

Each mode is module-level functions using the singletons above. Every mode:
uses `StageTimer`, starts with `beep("capture")` (or rec beeps), saves history,
and ends every failure path with `beep("err")` + a short spoken sentence.

```python
# read.py
def run_read() -> None
    # capture -> save_capture -> brain.see(read_prompt(cfg.language), on_text -> SentenceSpeaker)
    #   BrainOffline/failure -> beep("offline") + log; no on-device OCR/TTS fallback.
    # history kind="read" (extra {"language": lang} when translating)

# describe.py
def run_describe() -> None    # same shape, DESCRIBE_PROMPT; connectivity failure = error beep + log

# ask.py  (hold-to-ask; also the voice assistant — photo is always attached)
def ask_begin() -> None       # beep rec_start, Recorder.start()
def ask_end() -> None
    # Recorder.stop -> transcribe -> capture photo -> brain.see(question, ASK_SYSTEM context,
    # history_msgs = last 6 exchanges from in-RAM deque,
    # tools=[TOOL_SEARCH_MEMORY, TOOL_PHONE_ACTION],
    # tool_handlers={search_memory -> memory.search formatted as speakable lines,
    #                phone_action -> state.get_actions().add + "Queued for your phone."})
    # -> speak answer; store kind="ask", text=answer, extra={"question": q}.
    # Any OpenAI network/key failure ends with an error beep and a logged message;
    # there is no local transcription or answer fallback.
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
    # return the literal token NONE when nothing worth saying). No connectivity ->
    # play the local error beep, log "Navigation assist needs internet," and exit.
    # Checks stop_event between steps.
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
and calls `memory.reindex_pending()` when online (at most once a minute).

UDS command server (thread): JSON-lines over `HOME/visionary.sock`.
Requests/responses (one JSON object per line):

| Request | Response |
|---|---|
| `{"cmd":"capture","mode":"read"\|"describe"\|"recorder"}` | `{"ok":true}` (dispatched async) or `{"ok":false,"error":"busy"}` |
| `{"cmd":"speak","text":"..."}` | `{"ok":true}` |
| `{"cmd":"frame"}` | `{"ok":true,"jpeg_b64":"..."}` (640x480 preview) |
| `{"cmd":"status"}` | `{"ok":true,"online":bool,"busy":bool,"uptime":float,"recording":bool}` |

Boot: `ensure_dirs` → `get_token` → `init_camera` → start UDS server → if OpenAI
is reachable, speak "Visionary ready" and the first-boot 6-digit pairing code;
otherwise play the local error beep and log the network/key problem. Hardware
mode binds gpiozero `Button(17, pull_up=True,
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
- `setup.sh` (idempotent, Raspberry Pi OS Trixie 32-bit `armhf` or 64-bit): apt
  installs the camera/GPIO Python bindings, requests/Pillow/numpy, ALSA utilities,
  SoX, rsync, and Avahi; pip installs FastAPI, Uvicorn, and QR support. It enables
  the I2S overlay (`googlevoicehat-soundcard`, `dtparam=audio=off`), generates local
  event beeps, rsyncs `firmware/` → `/opt/visionary/app/`, creates
  `/etc/visionary.env` (`OPENAI_API_KEY` placeholder, chmod 600), and installs/enables
  both services plus Avahi. It installs no Piper, eSpeak, Tesseract, whisper.cpp,
  or openWakeWord, downloads no local models, and accepts no `--with-whisper` or
  `--with-wakeword` flags.

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
- `test_api.py` (`skipif` fastapi missing: 401 without token, config roundtrip, history,
  capture/speak against a fake UDS server fixture, image 404, /memory/search offline
  FTS5 path, /actions queue lifecycle add→pending→complete→gone)
- `test_memory.py` (index_entry + FTS5 search with embeddings unavailable,
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
`NSRemindersUsageDescription`). The app has no account or separate backend; it
talks to the glasses over the LAN, while the glasses call OpenAI for AI features.

```
ios/Visionary/
├── VisionaryApp.swift        # @main, injects AppState
├── AppState.swift            # @MainActor ObservableObject: pairing persistence (UserDefaults),
│                             # APIClient?, published DeviceStatus/DeviceConfig, connect()/pair()/forget()
├── Models.swift              # Codable, .convertFromSnakeCase: DeviceStatus, DeviceConfig, TwoWayConfig,
│                             # NavigationConfig, HistoryEntry (extra: [String:String]?),
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
    ├── SettingsView.swift    # OpenAI voice picker, rate slider 0.5–2.0, translation language,
    │                         # two-way toggle, navigation assist toggle + interval (with the
    │                         # assistive-info-not-safety-device disclaimer), WiFi form (POST /wifi),
    │                         # "Check for updates" (POST /update)
    └── RecorderView.swift    # kind=="recording" entries: transcript + summary, play /history/{id}/audio, share
```

TabView: Home / History / Search / Live / Recorder / Settings; PairingView shown
until paired. `ios/README.md`: `brew install xcodegen && xcodegen generate`
(or manual Xcode steps).

## Cross-cutting invariants

1. Hands-free/eyes-free: no glasses feature depends on a screen.
2. Cloud-honest: vision/chat, `gpt-4o-mini-transcribe`, `gpt-4o-mini-tts-2025-12-15`, and
   `text-embedding-3-small` all require internet and the same `OPENAI_API_KEY`.
   Connection failures produce a local beep and actionable log entry.
3. Triggered-capture privacy: there is no passive or always-listening capture.
   Deliberate actions upload the requested image/audio to OpenAI; explicitly started
   recorder/translation/navigation sessions capture only until stopped. History stays
   on device, and the classroom dashboard sees text summaries only, never images/audio.
4. RAM budget (512MB): all model inference runs in OpenAI's cloud; the Pi retains only
   bounded camera/audio buffers and application state. This supports Trixie `armhf`.
5. Perceived latency: first spoken sentence starts while the model is still streaming.
6. Navigation assist is assistive information, not a certified safety device — the
   framing appears in the prompt, the spoken disclaimer, the app, and the docs.

---

# v3 — Mode-pack platform + expanded feature universe

Implements MOONSHOT_FEATURES.md. Insight: most features are prompts on five
shared pipelines, so modes are DATA. Genuinely new machinery is listed after.

## firmware/packs.py — modes as data

Mode dict: `{"id","name","category","description","pipeline","prompt","options":{}}`.
`pipeline` ∈ `see` (capture+prompt→speak) | `ask` (hold-to-ask system prompt) |
`listen` (record→transcribe→prompt→speak) | `loop` (background periodic see) |
`session` (multi-turn, below).

```python
def load_modes() -> Dict[str, dict]      # builtin pack + HOME/packs/*.json (validated)
def install_pack(url: str) -> List[str]  # fetch JSON {"name","modes":[...]}, validate, save; returns mode ids
def remove_pack(name: str) -> bool
def list_packs() -> List[dict]           # [{"name","builtin":bool,"modes":[ids]}]
def run_mode(mode_id: str) -> None       # dispatch by pipeline (see/listen inline; loop/session via main.py)
```

`firmware/packs/builtin.json` ships EVERY ★ feature from MOONSHOT_FEATURES.md
as a mode with a crafted prompt (~35 modes: skim, explain_10, explain_phd, math,
handwriting, form_reader, pokedex, sommelier, currency_color, expiry, allergen,
tour_guide, chess, teleprompter(listen), whiteboard_email(see+phone_action),
language_immersion(loop), pronunciation(listen), recipe(session), done_check,
substitutions, mechanic, ikea(session), multimeter, wiring_check, med_verify,
price_check, receipt_split, quiz(session), socratic(session), i_spy(session),
escape_room(session), pub_quiz, roast, boarding_pass, meeting_scribe, ...).
Config: `"active_mode": null` (null = classic read); when set, single-press runs
that mode's pipeline instead. Gestures may also map `"mode:<id>"`.

## New machinery

- **modes/session.py**: `run_session(mode, stop_event)` — opening capture spoken
  through the mode prompt, then turn loop: record_until_silence → transcribe →
  brain.chat (mode prompt as system, photo on first turn) → speak; exits on
  "stop"/"exit"/stop_event/single-press; 20-turn cap.
- **modes/captions.py**: `run_captions(stop_event)` — Tier "live captions": VAD
  chunks → transcribe → `events.publish("caption", text)`; NO speech out. Config
  `"captions": {"help_phrase": null, "listen_name": null}`: transcript hit →
  spoken alert + event + (help) phone_action send_text to `emergency_contact`.
- **modes/briefing.py**: `run_briefing()` — fetch config `"feeds": []` RSS
  (requests + xml.etree) → brain.chat summary → speak. Exposed as mode + tool.
- **firmware/events.py**: `publish(kind, data)`, `get_since(seq) -> (seq, [events])`,
  ring buffer 500. main.py UDS adds `{"cmd":"events","since":n}`. api.py
  `GET /events` = SSE (`text/event-stream`), polls UDS every 0.5s.
- **firmware/flashcards.py**: table `cards(id,ts,question,answer,due,interval_d,ease)`
  in history.db; `generate_from_today(n=20)` via brain.chat over today's history;
  `due_cards()`; `review(card_id, grade 0..3)` SM-2-lite (again/hard/good/easy).
- **firmware/timers.py**: `set_timer(name, seconds)`, `list_timers()`,
  `cancel_timer(name)`; fire = speak "<name> timer is done" + event.
- **firmware/sdk.py**: the 3-function hack surface — `capture() -> bytes`,
  `speak(text)`, `listen(max_s=15) -> str`. Documented example in docstring.
- **brain**: new tools TOOL_SET_TIMER, TOOL_SET_MODE (switch active_mode by
  voice), TOOL_GET_BRIEFING — wired into ask.py handlers.
- **state config additions**: `active_mode`, `captions{}`, `feeds[]`,
  `emergency_contact: null`. There is no local-only inference mode.
- **Actions**: types add `send_text {to?,body}`, `email_draft {to?,subject,body}`,
  `note {title,body}`. iOS auto-executes ONLY calendar_event/reminder; the rest
  land in an in-app Actions inbox (iOS cannot auto-send messages/mail).

## API additions (same auth)

| `/modes` GET | all modes + active_mode | `/modes/active` POST `{"id"\|null}` |
| `/packs` GET / `/packs/install` POST `{"url"}` / `/packs/{name}` DELETE |
| `/events` GET SSE | `/flashcards/generate` POST / `/flashcards/due` GET / `/flashcards/{id}/review` POST `{"grade"}` |
| `/listen` POST `{"max_s"}` → `{"text"}` | `/timers` GET |

## iOS v3 — flagship quality

Tab restructure: **Home / Library / Live / Modes / Settings** (+ Pairing gate).
- `ModesView`: modes grouped by category, search, activate/deactivate, pack
  install via QR scan or URL field, pack management. This screen is the store.
- Live tab segmented: **Live** (MJPEG) / **Captions** (SSE client `EventSource`-style
  class, giant Dynamic-Type text, high contrast, auto-scroll, help-phrase badge) /
  **Guide** (MJPEG + push-to-talk text→`/speak` = remote sighted guide).
- Library tab segmented: **History / Search / Recorder / Flashcards / Notes**.
  FlashcardsView: generate, due badge, card-flip review with Again/Hard/Good/Easy.
  NotesView: `note` actions collected in-app, shareable.
- `ActionsInboxView` (badge on Home): send_text → prefilled MFMessageCompose,
  email_draft → MFMailCompose, note → save to Notes list.
- HomeView redesign: hero status, current-mode card, quick-action mode grid,
  actions-inbox badge.
- Polish bar: onboarding flow on first launch, haptics, matchedGeometry where it
  earns it, full VoiceOver, Dynamic Type, dark mode. No external packages.

Roadmap-only (hardware/OS-gated, do NOT build): VoIP calls, notification
mirroring, multi-glasses mesh, GPS navigation. MOONSHOT_FEATURES.md gets
built/roadmap annotations at finalize.
