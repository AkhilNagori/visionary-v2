# Visionary — Full Software Specification

Firmware (all three tiers) + companion iOS app. Firmware Tier 1 exists in `code/`; this doc is the complete blueprint for everything else.

## Project context

**What Visionary is.** Low-cost AI smart glasses that give visually impaired students independent access to printed classroom material. A head-mounted camera sees what the wearer faces; a Raspberry Pi Zero 2 W sends the image to a vision LLM (or an on-device OCR pipeline when offline) and speaks the result through a bone-adjacent speaker. One button, four gestures, no screen, no app required.

**Why it exists.** Commercial equivalents (OrCam MyEye and similar) cost $2,000–4,000 and are closed hardware — out of reach for nearly every school. Visionary's bill of materials is ~$60. The project started as a science fair build (camera → CRNN → text-to-speech) and is evolving into an open-source kit: same mission, modern brain — the CRNN is replaced by cloud vision models with a fully offline Tesseract+Piper fallback, so it works in classrooms with no WiFi.

**Design principles** (every feature must pass these):
1. *Hands-free and eyes-free* — audio in, audio out, single-button grammar. If a feature needs a screen, it belongs in the companion app, not the glasses.
2. *Offline-degradable* — every cloud feature has an offline fallback or a graceful spoken failure. A student's ability to read must not depend on the school's WiFi.
3. *Press-to-capture privacy* — no continuous recording, nothing stored or uploaded except what the wearer deliberately triggers. Verifiable, because it's open source.
4. *Kit-buildable* — a motivated teenager with a soldering iron builds one in an afternoon from the docs. No custom PCBs in v1.

**Where it's going.** v1 = 30 founder kits (hand-assembled/self-assembled, this month). v2 = integrated frame with in-temple mic + battery, companion iOS app, classroom multi-unit tooling.

## Feature catalog — all tiers

### Tier 1 — Core reading (ship Saturday)

| # | Feature | Gesture | What the user experiences |
|---|---|---|---|
| 1 | **Read anything** | single press | Beep → ~4s → natural voice reads the worksheet/menu/sign/pill bottle in reading order, cleaned for speech (no "page 3 of 12" clutter). Handwriting included. |
| 2 | **Scene description** | double press | 2–3 concrete sentences: objects, people, layout, visible text. POV framing — "to your left," "in front of you." |
| 3 | **Translation reading** | single press (language set in config) | Foreign text in view → hears it in their language. Any → any. |
| 4 | **Offline mode** | automatic | No internet → local Tesseract OCR + Piper TTS take over seamlessly; short "offline" chirp is the only difference. |
| 5 | **Spoken status** | boot / errors | "Visionary ready," "I couldn't find any text," "battery low" — the device never fails silently. |
| 6 | **Safe shutdown** | hold 5s | Spoken goodbye, clean halt. |

### Tier 2 — Voice interaction (mic; build Friday if Tier 1 is perfect)

| # | Feature | Gesture | What the user experiences |
|---|---|---|---|
| 7 | **Ask about what you see** | hold 1s + speak | "Which of these is gluten-free?" → photo + question to vision model → spoken answer. The killer demo. |
| 8 | **Voice assistant** | hold + speak (no visual question) | General Q&A with short conversational memory ("what did I just ask?"). |
| 9 | **Magic recorder** | triple press start/stop | Records lecture/conversation → transcript + AI summary, spoken back and saved to history. |
| 10 | **Two-way translation** | config mode | Live interpreter loop: their Spanish → your English in-ear; your English → Spanish out loud. |

### Tier 3 — v2 roadmap (booth talking points, not weekend code)

| # | Feature | What it adds |
|---|---|---|
| 11 | **Visual memory** | Every capture embedded + searchable: "what room number was on that door?" |
| 12 | **Wake word** | "Hey Vision" — hands-free trigger (openWakeWord, ~15% CPU on the Zero 2 W). |
| 13 | **Navigation assist** | Periodic captures → obstacle/sign callouts (assistive-info framing, explicitly not a certified safety device). |
| 14 | **Agent actions** | "Add this flyer's date to my calendar" → tool-use → executed via the paired phone. |
| 15 | **Classroom fleet** | Teacher dashboard: reading activity across a class set, no audio/images shared, text-only summaries. |
| 16 | **Companion iOS app** | Pairing, history, remote trigger, live focus view, settings (spec below). |

## System context

- **Device**: Pi Zero 2 W (quad A53, 512MB RAM — the real constraint), Raspberry Pi OS Lite 64-bit Bookworm.
- **Audio**: one I2S bus, `googlevoicehat-soundcard` overlay → ALSA card with playback (MAX98357A) + capture (ICS-43434, 48kHz S32_LE; downsample to 16kHz mono for STT).
- **Input**: one GPIO button (17). Gesture grammar: single / double / triple / hold.
- **Cloud**: Anthropic API (vision + chat), OpenAI Whisper API or local whisper.cpp for STT. All cloud calls must have offline fallbacks or graceful spoken failures.
- **Config**: `/etc/visionary.env` (keys), `/opt/visionary/config.json` (voice, speed, language, mode flags — the iOS app edits this file via the local API).
- **Process model**: single Python service (`visionary.service`, systemd, auto-restart) + optional `visionary-api.service` for the app/API. Watchdog: systemd `Restart=on-failure`.

## Repo layout (target)

```
visionary/
├── firmware/
│   ├── main.py            # entrypoint, event loop, gesture router
│   ├── audio.py           # play/beep/speak (Piper), record (ALSA), VAD
│   ├── vision.py          # picamera2 capture, preprocessing
│   ├── brain.py           # cloud (Claude/Whisper) + offline (tesseract/whisper.cpp) with auto-fallback
│   ├── modes/             # read.py, describe.py, ask.py, recorder.py, translate.py
│   ├── state.py           # config load/save, history store (SQLite)
│   └── api.py             # FastAPI local server for iOS app
│   └── setup.sh
├── ios/                   # SwiftUI companion app
└── hardware/              # STLs, wiring
```

---

## Tier 1 — Core (MUST be flawless for Saturday)

| Feature | Trigger | Pipeline | Latency target |
|---|---|---|---|
| Read aloud | single press | capture → Claude vision (READ prompt) → Piper TTS | < 6s to first audio |
| Scene description | double press | capture → Claude vision (DESCRIBE prompt) → TTS | < 6s |
| Translation reading | config flag / auto | same as Read, prompt adds "translate to {lang}" | < 6s |
| Offline read | automatic on no-net | capture → preprocess (grayscale, autocontrast, deskew) → Tesseract → TTS | < 10s |
| Boot-to-ready | power switch | systemd → spoken "Visionary ready" | < 30s |
| Audio feedback | every action | beeps: capture / ok / err / offline | instant |
| Safe shutdown | hold 5s | spoken goodbye → `shutdown -h` | — |

Engineering notes:
- Speak the FIRST sentence as soon as it streams in (use Claude streaming API) — perceived latency is the demo.
- Keep camera started continuously (capture in <300ms) rather than cold-starting per press.
- Connectivity check is cached 10s; never block a press on it.

## Tier 2 — Voice (build only after Tier 1 is demo-perfect)

| Feature | Trigger | Pipeline |
|---|---|---|
| Ask-about-what-you-see | hold 1s, speak, release | record while held → Whisper STT → capture photo → Claude (image + question) → TTS |
| Voice assistant | hold with no readable scene / config | record → STT → Claude chat (with short conversation memory) → TTS |
| Magic recorder | triple press start/stop | record to file (chunked) → Whisper transcript → Claude summary → speak summary, store both |
| Two-way translation | config mode | VAD-segmented loop: hear ES → speak EN; hold-to-talk EN → speak ES |

Engineering notes:
- STT: cloud Whisper API first (Zero 2 W can't run whisper > tiny well). Offline: whisper.cpp `tiny.en` quantized, ~8–15s for a short utterance — acceptable fallback, announce "offline, thinking slower."
- Recording: ALSA capture 48k stereo → mono 16k with `numpy` decimation; simple energy VAD to trim silence.
- Conversation memory: last 6 exchanges in RAM, cleared on shutdown.
- RAM budget: never load whisper.cpp and anything heavy simultaneously; run STT as a subprocess that exits.

## Tier 3 — v2 roadmap (pitch material, do not build pre-conference)

- **Memory**: every capture + transcript embedded (cloud embeddings) into SQLite-VSS; query "what did that poster say an hour ago?"
- **Navigation assist**: periodic low-res captures → obstacle/sign callouts (strictly assistive-info framing, not a safety device).
- **Agent actions**: "add this to my calendar" → Claude tool-use → iOS app executes via EventKit.
- **Classroom dashboard**: teacher web view of anonymized reading activity across a kit fleet.
- **Wake word**: openWakeWord ("hey vision") — feasible on Zero 2 W at ~15% CPU.

---

## Local API (feeds the iOS app) — FastAPI on port 8321

| Endpoint | Method | Purpose |
|---|---|---|
| `/status` | GET | battery est., WiFi, online/offline, version, uptime |
| `/config` | GET/PUT | voice, rate, target language, gestures, feature flags |
| `/history` | GET | paginated: captures, transcripts, summaries, timestamps |
| `/history/{id}/image` | GET | the captured photo |
| `/capture` | POST | remote-trigger any mode (`{"mode":"read"}`) |
| `/live` | GET | MJPEG low-res preview stream (setup/focus aid) |
| `/speak` | POST | TTS arbitrary text (accessibility remote / demo fun) |
| `/wifi` | POST | add network credentials |

Security: bearer token printed as QR at first boot (`/opt/visionary/pairing_qr.png`, also spoken as a 6-digit code). LAN only, no port forwarding.

## Companion iOS app (SwiftUI) — v2, post-conference

**Purpose**: setup, history, and remote control. The glasses never *require* the app.

Screens:
1. **Pairing** — scan the QR (device URL + token). Fallback: manual code entry.
2. **Home / status** — connection, battery, online/offline, big "trigger read" and "describe" buttons (a parent/teacher can trigger for a student).
3. **History** — timeline of captures: thumbnail, extracted text, play TTS audio, share/export. This is huge for the classroom story: a teacher can review what a student read today.
4. **Live view** — MJPEG stream for lens-focus setup and aiming practice.
5. **Settings** — voice (Piper model), speech rate, target translation language, gesture remap, WiFi manager, OTA update trigger.
6. **Recorder** — list of recordings + transcripts + AI summaries, share as text/audio.

Architecture: SwiftUI + async/await URLSession against the local API; Bonjour (`_visionary._tcp`) for discovery so it "just finds" the glasses on the hotspot; no accounts, no cloud backend — everything device-local (this is also your privacy pitch).

Stretch: BLE provisioning for first-time WiFi setup (Pi as peripheral via `bluezero`), push-style updates via WebSocket `/events`.

## Cross-cutting

- **Privacy**: press-to-capture only; nothing uploaded except the pressed capture to the AI API; history stays on device; document it in the README — booth visitors WILL ask.
- **Latency instrumentation**: log per-stage ms (capture / upload / model / TTS start) to `/var/log/visionary/metrics.log` — you'll want real numbers for the pitch and for tuning.
- **OTA**: `git pull && systemctl restart visionary` behind `/update` endpoint; kits ship pointing at your repo.
- **Testing**: golden-image test set (10 photos: worksheet, menu, handwriting, low light...) + `pytest` that runs the offline pipeline against them; smoke script `make demo` that fakes a button press end-to-end.
- **SD image**: once Tier 1+2 work, `dd` the card to a `.img` — that image IS the product you flash for all 30 kits.

## Build order for the next 48h

1. Tier 1 solid on bench (tonight) → freeze prompts.
2. Mic in (Friday AM) → `ask.py` (hold-to-ask) ONLY.
3. If dress rehearsal passes by Friday 6pm: `recorder.py` (triple press). Else skip.
4. Friday 8pm: software freeze, clone SD, record demo video.
5. API + iOS app: next week, before kits ship. Show Tier 3 + app as mockups/roadmap on the booth one-pager.
