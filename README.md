# Visionary

AI glasses that read the world aloud. A visually impaired student in a mainstream classroom hits the same wall dozens of times a day: the worksheet being handed out, the page number on the board, the textbook paragraph everyone else is silently reading. Visionary is a pair of 3D-printed smart glasses with one button that reads printed material aloud, describes scenes, answers spoken questions about what you see, and keeps working offline when the WiFi drops. It runs on a Raspberry Pi Zero 2 W, the bill of materials is around $60, and every line of it is open source so you can verify what it does.

## Repo map

```
visionary/
├── firmware/          # runs on the Pi Zero 2 W: gesture engine, modes, local API, setup
├── dashboard/         # teacher-run classroom fleet view (their laptop, text-only)
├── tests/             # pytest + SIM demo; runs on any machine, no hardware needed
├── ios/               # SwiftUI companion app (pairing, history, remote control)
└── docs (*.md)
```

Docs:

- `PROJECT_OVERVIEW.md` — what Visionary is, why it exists, how it wins.
- `ARCHITECTURE.md` — module boundaries, function signatures, schemas, and protocols. The contract the code follows.
- `SOFTWARE_SPEC.md` — full software specification across all three tiers.
- `HARDWARE_TUTORIAL.md` — complete wiring and assembly build (BOM, pinout, step-by-step).
- `BUILD_PLAN.md` — the 48-hour hackathon build plan.
- `FEATURES.md` — feature-by-feature comparison against the Rabbit R1.
- `MOONSHOT_FEATURES.md` — the full feature universe the hardware can reach.
- `DEMO_AND_PREORDERS.md` — booth demo script and preorder playbook.
- `FRIDAY_RUNBOOK.md` — two-person hackathon runbook.

## Put it on a Raspberry Pi — exact steps

You need: a Raspberry Pi Zero 2 W, a microSD card (8GB or larger), a computer with [Raspberry Pi Imager](https://www.raspberrypi.com/software/) installed, your WiFi name and password, and an Anthropic API key. Wire the hardware per `HARDWARE_TUTORIAL.md` (camera, I2S amp and mic, button); the software boots and speaks even before the button and camera are wired, so you can test as you go.

### 1. Flash the SD card

1. Put the microSD in your computer and open Raspberry Pi Imager.
2. **Choose Device**: Raspberry Pi Zero 2 W.
3. **Choose OS**: Raspberry Pi OS (other) > **Raspberry Pi OS Lite (64-bit)** (Bookworm).
4. **Choose Storage**: your card.
5. Click **Next**, then **Edit Settings**:
   - General tab: hostname `visionary`, username `pi` with a password you'll remember, your WiFi SSID and password (add your phone hotspot as a second network later — it's the backup at demos), your locale and timezone.
   - Services tab: **Enable SSH** with password authentication.
6. Save, write, wait for verification, eject.

### 2. First boot and SSH in

1. Card into the Pi, power into the **PWR IN** micro-USB port (the one nearer the corner). First boot takes about 90 seconds.
2. From your computer on the same network:
   ```
   ssh pi@visionary.local
   ```
   Accept the fingerprint prompt and enter your password. If `.local` doesn't resolve, find the Pi's IP in your router or hotspot's device list and `ssh pi@<that-ip>`.

### 3. Install Visionary

On the Pi:

```
sudo apt update && sudo apt install -y git
git clone https://github.com/AkhilNagori/visionary.git
cd visionary
sudo bash firmware/setup.sh --with-whisper --with-wakeword
```

`--with-whisper` builds offline speech-to-text (takes ~10 minutes on the Zero 2 W). `--with-wakeword` installs the hands-free "Hey Jarvis" trigger. Both are optional; the script is idempotent, so re-run it any time to add a flag.

### 4. Add your API keys

```
sudo nano /etc/visionary.env
```

Set these two lines, then Ctrl+O, Enter, Ctrl+X to save and exit:

```
ANTHROPIC_API_KEY=sk-ant-your-key-here
OPENAI_API_KEY=sk-your-key-here
```

`ANTHROPIC_API_KEY` is required (vision and chat — get one at console.anthropic.com; $5 of credit covers hundreds of reads). `OPENAI_API_KEY` is optional: it enables cloud Whisper speech-to-text and the embeddings behind visual memory search.

### 5. Reboot and verify

```
sudo reboot
```

About 30 seconds later the glasses say **"Visionary ready"** — and on the very first boot, a 6-digit pairing code. From here no keyboard or screen is ever needed. Then check each piece:

- **Read**: single-press the button. You should hear the capture beep, then speech within a few seconds.
- **Audio**, if it's silent: `speaker-test -c1 -t sine -f 440` (Ctrl+C to stop).
- **Camera**: `libcamera-still -o test.jpg`, then `scp` it over and look at it. Set the lens focus to ~30cm per `HARDWARE_TUTORIAL.md` step 1 — this single adjustment decides whether OCR works.
- **Services**: `systemctl status visionary visionary-api` should both be active; `journalctl -u visionary -n 50` shows the log if not.
- **Pairing for the iOS app**: the QR is at `/opt/visionary/pairing_qr.png` (`scp pi@visionary.local:/opt/visionary/pairing_qr.png .`), or use the spoken 6-digit code with `http://visionary.local:8321` in the app's manual entry.

If something misbehaves, the troubleshooting table at the bottom of `HARDWARE_TUTORIAL.md` covers the common failures (no audio, silent mic, camera not detected, undervoltage).

## Gestures

One button on the temple. Everything is a press or a hold.

| Gesture | Action |
|---|---|
| Single press | Read whatever you are facing, aloud |
| Double press | Describe the scene |
| Triple press | Start / stop the recorder |
| Hold 1s, speak, release | Ask a question about what you see |
| Hold 5s | Safe shutdown |
| Say the wake word (when enabled) | Ask hands-free, no button |

The shipped wake-word trigger is "Hey Jarvis" (an openWakeWord model that runs locally); a custom "Hey Vision" model is a documented follow-up. When a background mode is running (two-way translate or navigation assist), a single press stops it instead of reading.

## Features by tier

### Tier 1 — core reading

- **Read anything** (single press): worksheets, textbooks, signs, menus, pill bottles, handwriting, read aloud in reading order.
- **Scene description** (double press): 2 to 3 concrete sentences on objects, people, layout, and visible text, framed from your point of view.
- **Translation reading** (config): foreign text in view is read in your language, any language to any language.
- **Offline mode** (automatic): no internet, on-device Tesseract OCR and Piper TTS take over seamlessly.
- **Spoken status** (boot and errors): the device never fails silently.
- **Safe shutdown** (hold 5s): spoken goodbye, clean halt.

### Tier 2 — voice interaction

- **Ask about what you see** (hold and speak): your question plus a photo go to the vision model, and the answer is spoken back.
- **Voice assistant** (hold and speak): general question and answer with short conversational memory.
- **Magic recorder** (triple press): records a lecture or conversation, then speaks and saves a transcript plus an AI summary.
- **Two-way translation** (config): a live interpreter loop, their language in your ear, your reply spoken aloud.

### Tier 3 — advanced

- **Visual memory**: every capture is embedded and searchable ("what room number was on that door?").
- **Wake word**: hands-free trigger via openWakeWord, around 15% CPU on the Zero 2 W, all audio processed locally.
- **Navigation assist**: periodic captures call out obstacles and signage. This is assistive information, not a certified safety device.
- **Agent actions**: "add this flyer's date to my calendar" is handled by tool-use and executed by the paired phone.
- **Classroom fleet dashboard**: a teacher sees reading activity across a class set, text summaries only.
- **Companion iOS app**: pairing, history, remote trigger, live view, visual memory search, and settings.

## Dev quickstart on a laptop

No Pi and no hardware required. Everything runs in SIM mode, which fakes the camera, microphone, and audio output.

```
make venv    # create .venv and install firmware/requirements.txt
make test    # generate golden images and run the pytest suite
make demo    # SIM end-to-end: single press -> read pipeline -> printed speech
```

`make dashboard` runs the classroom dashboard locally and `make ios-check` type-checks the Swift sources (needs Xcode).

## Companion app and dashboard

- iOS companion app: see `ios/README.md` for the build (XcodeGen or manual Xcode) and pairing.
- Classroom fleet dashboard: see `dashboard/README.md` to point it at your glasses and run it.

## Privacy

Press-to-capture only. Nothing is captured or uploaded except what you deliberately trigger. There is no continuous recording, no account, and no cloud storage. Reading history lives on the device. Wake-word audio is processed on-device and is never stored or uploaded. The classroom dashboard sees text summaries only, never images or audio, because it simply never requests those endpoints. Because the whole stack is open source, you can verify every one of these claims instead of trusting them.
