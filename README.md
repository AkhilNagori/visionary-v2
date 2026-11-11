# Visionary — GPT-Live glasses

Talk naturally to the glasses. Click the button when you want to show them a
photo. The default firmware now uses an OpenAI **GPT-Live** session for streaming
speech, with a vision-capable Responses backend for photos. It no longer runs
the old record → transcribe → answer → text-to-speech pipeline.

The existing Raspberry Pi Zero 2 W hardware and Raspberry Pi OS 13 (Trixie),
including 32-bit `armhf`, can stay as they are. **No reflash is needed.** Internet
access and an OpenAI API key with access to the configured models are required.

## Using the glasses

| Action | Result |
|---|---|
| Power on | Connects to GPT-Live and starts the microphone |
| Speak normally | GPT-Live listens and answers aloud |
| Quick button click, then release | Takes one photo and brings it into the conversation |
| Hold 1–4 seconds, then release | Pauses or resumes the conversation |
| Hold 5 seconds | Safely shuts down the Pi |

Ask a question, wait for the reply, then speak again. There is no wake word and
no hold-to-ask gesture in this runtime. Double/triple clicks do not select the
old reading/recorder modes. Aim at a page and click to show it; ask follow-up
questions in the same conversation.

The default echo guard suppresses microphone uploads while the speaker is
playing, preventing the glasses from hearing themselves. This is **not acoustic
echo cancellation**: you cannot reliably interrupt a spoken reply by speaking
over it. Disable the guard only with an acoustically isolated output or an
independently tested echo-cancellation setup.

## Update your already-working Pi

On the Pi, first check for local changes; preserve any work before pulling:

```bash
cd ~/visionary-v2
git status --short
git pull --ff-only origin master
sudo bash firmware/setup.sh
sudo nano /etc/visionary.env
```

The installer preserves the existing API key and microphone settings and adds
missing Live settings. Keep your real `OPENAI_API_KEY` in that file; do not post
or commit it. Verify the following settings, with each name appearing once:

```ini
VISIONARY_RUNTIME=live
VISIONARY_LIVE_MODEL=gpt-live-1
VISIONARY_LIVE_BACKEND_MODEL=gpt-6-luna
VISIONARY_LIVE_VOICE=marin
VISIONARY_LIVE_ECHO_GUARD=1
VISIONARY_ALSA_PLAYBACK=plughw:0,0
VISIONARY_MIC_CHANNEL=1
VISIONARY_MIC_GAIN_DB=24
VISIONARY_MIC_HIGHPASS_HZ=100
```

Then start the updated services and watch the live log:

```bash
sudo systemctl restart visionary visionary-api
sudo journalctl -fu visionary
```

Ctrl+C exits the log viewer; it does not stop the glasses. Reboot instead if
setup installed a new I2S overlay. Run `setup.sh` for this migration: the older
app's code-only update does not install the new dependency or service settings.

For a first test, say “Hello, can you hear me?” after the connection is ready.
Then face a page, click once, and ask about it. Hold for about two seconds and
release to pause; repeat to resume. Pause closes the microphone and Live session.

The microphone still uses channel 1, approximately +24 dB digital gain and a
100 Hz high-pass filter, without an aggressive syllable-removing noise gate.
I2S hardware runs at 48 kHz; the cloud audio stream is mono 24 kHz PCM16.

See [the Live setup and troubleshooting guide](docs/LIVE_SETUP.md) for device
selection, API controls, cost/privacy details, and rollback.

## What runs now

- `firmware/main.py` selects the runtime; Live is the default.
- `firmware/live_main.py` owns the session, camera, button, and local commands.
- `firmware/live_client.py` speaks the GPT-Live WebSocket protocol and delegates
  photos to the vision backend.
- `firmware/live_audio.py` streams and conditions ALSA audio.
- `firmware/api.py` retains authenticated local status, pairing, preview, and
  history access, and adds conversation pause/resume controls.

The old modes, recorder, separate transcription/TTS, embedded visual-memory
search, mode packs, and flashcard generation are **not active in Live mode**.
Their source and stored data remain available for explicit legacy rollback.
The iOS app has not yet been redesigned for Live: its old mode/settings controls
are inactive, not a way to configure the new conversation.

Hardware assembly remains in [HARDWARE_TUTORIAL.md](HARDWARE_TUTORIAL.md). The
older [architecture](ARCHITECTURE.md), [software specification](SOFTWARE_SPEC.md),
[feature catalog](FEATURES.md), and [demo runbook](FRIDAY_RUNBOOK.md) describe the
legacy system or future ideas; they are not the current Live operating guide.

## Development

```bash
make venv
make test
VISIONARY_SIM=1 VISIONARY_RUNTIME=live .venv/bin/python firmware/main.py
```

SIM runs without Pi hardware or a paid cloud session. The old `make demo`
exercises the legacy reading pipeline, not Live integration. Real microphone,
speaker, camera and API access must still be verified on the Pi.

## Privacy and costs

Live mode starts listening at boot and streams microphone audio to OpenAI while
connected (except when the echo guard masks playback). Photos are sent when you
click or explicitly request capture through the local API; there is no automatic
background photo loop. Obtain permission before recording other people.

GPT-Live is billed by active session duration, including connected silence;
photo/backend requests add their own usage. Pause when not using the glasses:
pause closes the session, rather than leaving a billable muted connection open.
Check the current [GPT-Live guide](https://developers.openai.com/api/docs/guides/live)
and [API pricing](https://openai.com/api/pricing/) before extended use. Keep the
OpenAI key only on the Pi, not in the companion app or Git.
