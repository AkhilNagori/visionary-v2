# Visionary — Full Software Specification

Firmware (all three tiers) + companion iOS app. The firmware lives in `firmware/`; this doc is the complete blueprint.

## Project context

**What Visionary is.** Low-cost AI smart glasses that give visually impaired students independent access to printed classroom material. A head-mounted camera sees what the wearer faces; a Raspberry Pi Zero 2 W sends the image to OpenAI vision and plays OpenAI-generated speech through a bone-adjacent speaker. One button, four gestures, no screen, no app required. Internet access is required for AI features.

**Why it exists.** Commercial equivalents (OrCam MyEye and similar) cost $2,000–4,000 and are closed hardware — out of reach for nearly every school. Visionary's bill of materials is ~$60. The project started as a science fair build (camera → CRNN → text-to-speech) and is evolving into an open-source kit: same mission, modern cloud brain. Moving inference to OpenAI makes the install smaller and supports the existing 32-bit `armhf` Pi while improving vision and speech quality.

**Design principles** (every feature must pass these):
1. *Hands-free and eyes-free* — audio in, audio out, single-button grammar. If a feature needs a screen, it belongs in the companion app, not the glasses.
2. *Cloud-honest* — AI features require working internet and one `OPENAI_API_KEY`; connection failures produce a prompt error beep instead of pretending an offline model exists.
3. *Triggered-capture privacy* — no passive or always-listening capture. Only a deliberate gesture or explicitly started recorder/translation session records and uploads the image/audio needed for that action. Verifiable, because the device code is open source.
4. *Kit-buildable* — a motivated teenager with a soldering iron builds one in an afternoon from the docs. No custom PCBs in v1.

**Where it's going.** v1 = 30 founder kits (hand-assembled/self-assembled, this month). v2 = integrated frame with in-temple mic + battery, companion iOS app, classroom multi-unit tooling.

## Feature catalog — all tiers

### Tier 1 — Core reading (ship Saturday)

| # | Feature | Gesture | What the user experiences |
|---|---|---|---|
| 1 | **Read anything** | single press | Beep → ~4s → natural voice reads the worksheet/menu/sign/pill bottle in reading order, cleaned for speech (no "page 3 of 12" clutter). Handwriting included. |
| 2 | **Scene description** | double press | 2–3 concrete sentences: objects, people, layout, visible text. POV framing — "to your left," "in front of you." |
| 3 | **Translation reading** | single press (language set in config) | Foreign text in view → hears it in their language. Any → any. |
| 4 | **Connection handling** | automatic | No internet or invalid key → prompt error beep and a logged actionable error; AI actions wait for connectivity. |
| 5 | **Spoken status** | boot / errors | "Visionary ready," "I couldn't find any text," "battery low" when TTS is available; local beeps still report connection errors. |
| 6 | **Safe shutdown** | hold 5s | Spoken goodbye when online, then a clean halt. |

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
| 12 | **Navigation assist** | Explicitly started periodic captures → obstacle/sign callouts (assistive-info framing, explicitly not a certified safety device). |
| 13 | **Agent actions** | "Add this flyer's date to my calendar" → tool-use → executed via the paired phone. |
| 14 | **Classroom fleet** | Teacher dashboard: reading activity across a class set, no audio/images shared, text-only summaries. |
| 15 | **Companion iOS app** | Pairing, history, remote trigger, live focus view, settings (spec below). |

## System context

- **Device**: Pi Zero 2 W (quad A53, 512MB RAM), current Raspberry Pi OS Lite Trixie; both 32-bit `armhf` and 64-bit are supported because model inference runs in the cloud.
- **Audio**: one I2S bus, `googlevoicehat-soundcard` overlay → ALSA card with playback (MAX98357A) + capture (ICS-43434, 48kHz S32_LE). Firmware selects the configured live I2S slot, applies a 100 Hz high-pass and +24 dB limited digital gain with final headroom, then produces 16kHz mono for STT.
- **Input**: one GPIO button (17). Gesture grammar: single / double / triple / hold.
- **Cloud**: one `OPENAI_API_KEY` powers vision/chat (`gpt-4o-mini` by default), STT (`gpt-4o-mini-transcribe`), TTS (`gpt-4o-mini-tts-2025-12-15`, voice `marin`), and embeddings (`text-embedding-3-small`). There is no local model fallback; AI features require internet.
- **Config**: `/etc/visionary.env` (API secret and hardware/audio overrides), `/opt/visionary/config.json` (voice, speed, language, mode flags — the iOS app edits this file via the local API).
- **Process model**: single Python service (`visionary.service`, systemd, auto-restart) + optional `visionary-api.service` for the app/API. Watchdog: systemd `Restart=on-failure`.

## Repo layout (target)

```
visionary/
├── firmware/
│   ├── main.py            # entrypoint, event loop, gesture router
│   ├── audio.py           # OpenAI TTS + local ALSA play/beep/record and VAD
│   ├── vision.py          # picamera2 capture, preprocessing
│   ├── brain.py           # OpenAI vision/chat/STT + connection handling
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
| Read aloud | single press | capture → OpenAI vision (READ prompt) → OpenAI `gpt-4o-mini-tts-2025-12-15` (`marin`) | < 6s to first audio |
| Scene description | double press | capture → OpenAI vision (DESCRIBE prompt) → TTS | < 6s |
| Translation reading | config flag / auto | same as Read, prompt adds "translate to {lang}" | < 6s |
| Connection failure | automatic on no-net | error beep → log actionable network/key failure; no upload or inference | instant |
| Boot-to-ready | power switch | systemd → spoken "Visionary ready" | < 30s |
| Audio feedback | every action | beeps: capture / ok / err / offline | instant |
| Safe shutdown | hold 5s | spoken goodbye → `shutdown -h` | — |

Engineering notes:
- Speak the FIRST sentence as soon as it streams in (use the OpenAI streaming API) — perceived latency is the demo.
- Keep camera started continuously (capture in <300ms) rather than cold-starting per press.
- Connectivity check is cached 10s; never block a press on it.

## Tier 2 — Voice (build only after Tier 1 is demo-perfect)

| Feature | Trigger | Pipeline |
|---|---|---|
| Ask-about-what-you-see | hold 1s, speak, release | ALSA record while held → `gpt-4o-mini-transcribe` → capture photo → OpenAI (image + question) → `gpt-4o-mini-tts-2025-12-15` |
| Voice assistant | hold with no readable scene / config | record → STT → OpenAI chat (with short conversation memory) → TTS |
| Magic recorder | triple press start/stop | ALSA record to file (chunked) → `gpt-4o-mini-transcribe` → OpenAI summary → `gpt-4o-mini-tts-2025-12-15` summary, store both |
| Two-way translation | config mode | VAD-segmented loop: hear ES → speak EN; hold-to-talk EN → speak ES |

Engineering notes:
- STT: upload the deliberately captured 16kHz mono WAV to OpenAI `gpt-4o-mini-transcribe`. The Pi does not install or run whisper.cpp.
- Recording: ALSA captures 48k stereo; firmware selects the live I2S channel,
  filters/amplifies it with SoX, and resamples to 16k mono. Session capture uses an
  adaptive noise-floor VAD with hysteresis; it preserves all samples and keeps
  ambiguous speech instead of applying an aggressive gate. Deliberate one-shot
  listens conservatively retain an unresolved loud opening; continuous modes
  suppress a steady, speechless baseline to avoid repeated STT uploads.
- Conversation memory: last 6 exchanges in RAM, cleared on shutdown.
- RAM budget: keep only camera/audio buffers and application state on the Pi; all model inference runs in OpenAI's cloud.

## Tier 3 — v2 roadmap (pitch material, do not build pre-conference)

- **Memory**: every capture + transcript embedded (cloud embeddings) into SQLite-VSS; query "what did that poster say an hour ago?"
- **Navigation assist**: periodic low-res captures → obstacle/sign callouts (strictly assistive-info framing, not a safety device).
- **Agent actions**: "add this to my calendar" → OpenAI function-calling → iOS app executes via EventKit.
- **Classroom dashboard**: teacher web view of anonymized reading activity across a kit fleet.

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
5. **Settings** — OpenAI voice, speech rate, target translation language, gesture remap, WiFi manager, OTA update trigger.
6. **Recorder** — list of recordings + transcripts + AI summaries, share as text/audio.

Architecture: SwiftUI + async/await URLSession against the local API; Bonjour (`_visionary._tcp`) for discovery so it "just finds" the glasses on the hotspot. The companion app has no account or separate backend; the glasses still send deliberately triggered AI inputs directly to OpenAI.

Stretch: BLE provisioning for first-time WiFi setup (Pi as peripheral via `bluezero`), push-style updates via WebSocket `/events`.

## Cross-cutting

- **Privacy**: no passive or always-listening capture. Triggered image/audio inputs are uploaded to OpenAI for processing; recorder/translation sessions run only after explicit start and stop. History stays on device. Review OpenAI API data controls before classroom use and document this boundary clearly.
- **Latency instrumentation**: log per-stage ms (capture / upload / model / TTS start) to `/var/log/visionary/metrics.log` — you'll want real numbers for the pitch and for tuning.
- **OTA**: `git pull && systemctl restart visionary` behind `/update` endpoint; kits ship pointing at your repo.
- **Testing**: golden-image test set (10 photos: worksheet, menu, handwriting, low light...) + `pytest` with every OpenAI call mocked; smoke script `make demo` fakes a button press end-to-end in SIM mode.
- **SD image**: once Tier 1+2 work, `dd` the card to a `.img` — that image IS the product you flash for all 30 kits.

## Build order for the next 48h

1. Tier 1 solid on bench (tonight) → freeze prompts.
2. Mic in (Friday AM) → `ask.py` (hold-to-ask) ONLY.
3. If dress rehearsal passes by Friday 6pm: `recorder.py` (triple press). Else skip.
4. Friday 8pm: software freeze, clone SD, record demo video.
5. API + iOS app: next week, before kits ship. Show Tier 3 + app as mockups/roadmap on the booth one-pager.
