# GPT-Live setup and troubleshooting

This guide is for the default Live runtime. You can keep the existing Pi OS,
Wi-Fi, SSH, camera/I2S overlay, OpenAI key, and local history. Do not reflash or
delete `/etc/visionary.env` to perform this update.

## 1. Install on an existing Pi

```bash
cd ~/visionary-v2
git status --short
git pull --ff-only origin master
sudo bash firmware/setup.sh
sudo nano /etc/visionary.env
```

If Git reports local changes, preserve them before updating. The setup script
copies firmware into `/opt/visionary/app`, installs system packages and units,
and stops the previous services during deployment. It preserves existing env
values and appends missing defaults. It uses distro `python3-websocket` for the
Live transport, plus distro FastAPI/Uvicorn/QR packages, rather than pip builds
or the OpenAI Python SDK. This avoids Rust build requirements on 32-bit armhf.

Keep the existing real `OPENAI_API_KEY` and check these lines appear once:

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

Save with Ctrl+O, Enter, Ctrl+X. Start the new services:

```bash
sudo systemctl restart visionary visionary-api
sudo systemctl --no-pager --full status visionary visionary-api
sudo journalctl -fu visionary
```

If setup installed a new I2S overlay, reboot instead. If it was already working,
restarting services is sufficient. Ctrl+C leaves the log viewer, not the service.
Service “active” means the process is running; verify that the Live session
actually connects before testing conversation. Authentication/model-access
errors must be resolved in the API account, not by repeatedly changing ALSA.

The first upgrade must use `setup.sh`: the older `/update` endpoint only copies
code and does not install dependencies or updated unit files.

## 2. Learn the controls

| Control | What happens |
|---|---|
| Boot | Opens a Live session and microphone |
| Speak | Live handles speech recognition, conversation, and spoken output |
| Click and release in under 1 second | Takes a photo and adds visual context |
| Hold 1–4 seconds, release | Toggles pause/resume |
| Hold 5 seconds | Powers down safely |

Start with “Hello, can you hear me?” Wait for the answer before speaking again.
Face a well-lit page, click once, and ask what it says. Photos are interpreted
through a vision backend, so the first answer about a new image can take longer
than a simple spoken reply. A photo is not a continuous camera stream.

Pause closes the microphone and cloud session; resume starts a new connection.
Do not assume a resumed/reconnected conversation preserves all previous context:
repeat the question or take the photo again if necessary. Old double-click,
triple-click, hold-to-ask and recorder/mode gestures are not active.

## 3. Microphone and speaker

The existing wearable-microphone corrections remain: channel 1 only, +24 dB
requested gain with headroom limiting, and a 100 Hz high-pass filter. There is
no aggressive local noise gate that cuts quiet syllables. These corrections
raise speech and noise together; they cannot fix poor physical signal-to-noise.

```ini
VISIONARY_ALSA_CAPTURE=plughw:0,0
VISIONARY_ALSA_PLAYBACK=plughw:0,0
VISIONARY_MIC_CHANNEL=1
VISIONARY_MIC_GAIN_DB=24
VISIONARY_MIC_HIGHPASS_HZ=100
VISIONARY_LIVE_ECHO_GUARD=1
```

Both I2S capture and playback use 48 kHz because the combined card shares a
clock. Audio is converted to/from mono 24 kHz PCM16 for Live. Use the correct
ALSA device names for your card; a USB device can change card numbering.

With echo guard enabled, outgoing microphone samples are silenced while the
speaker plays and briefly afterward. This avoids self-feedback, but is not
full-duplex acoustic echo cancellation: speech during playback is not uploaded.
Wait until each answer finishes. Set `VISIONARY_LIVE_ECHO_GUARD=0` only when the
speaker is acoustically isolated from the mic or you have independently tested
echo cancellation; otherwise the model can hear and reply to itself.

If audio devices fail, stop the service before taking exclusive access:

```bash
sudo systemctl stop visionary
arecord -l
aplay -l
speaker-test -D plughw:0,0 -r 48000 -c 2 -t sine -f 440
```

Keep the speaker away from your ear for the initial test; Ctrl+C stops it.
Then restore the service:

```bash
sudo systemctl start visionary
```

## 4. Models, photo handling, and billing

`VISIONARY_LIVE_MODEL=gpt-live-1` selects the Live voice model. The session
uses `VISIONARY_LIVE_VOICE=marin`. GPT-Live accepts audio/text, not a camera JPEG
directly: the client sends photos to the Responses backend selected by
`VISIONARY_LIVE_BACKEND_MODEL=gpt-6-luna`, then returns the visual result into
the live conversation using the documented `response.item.create` /
`response.create` delegation flow. Both services use the same OpenAI API key.

Live uses its session/audio event protocol rather than the previous one-shot
Whisper/transcription and TTS requests. See the official
[GPT-Live guide](https://developers.openai.com/api/docs/guides/live) for the
protocol and model capabilities.

Live is billed for active session time, including connected silence. A paused
session is closed, not merely muted. Vision-backend requests have separate
usage. Check [current API pricing](https://openai.com/api/pricing/) and your
account limits before leaving the glasses connected for long periods. A real
cloud test requires a valid key and incurs usage; SIM tests do not open sessions.

## 5. Local API and companion app

The API still listens on port 8321 and requires the existing pairing bearer
token. This token is **not** the OpenAI API key. Do not put the OpenAI key in a
phone client, shell-history curl command, screenshot or shared log.

| Endpoint | Live behavior |
|---|---|
| `GET /status` | Includes `runtime`, `connected`, `paused`, `state`, `last_error` |
| `POST /capture` with `{"mode":"photo"}` | Captures one image for the conversation |
| `POST /capture` with `read` or `describe` | Compatibility aliases for a photo request |
| `POST /conversation` with `{"action":"pause"}` | Closes the mic and Live session |
| `POST /conversation` with `resume` or `toggle` | Resumes or toggles the conversation |
| `POST /speak` | Adds a request for Live to say something; wording may vary |
| Preview, events, pairing, history GETs | Retained |

Legacy config mutation, active modes, pack installation/removal, recorder,
one-shot listen, flashcard generation, and embedding-based memory search return
HTTP 409 in Live mode instead of invoking the old models. Historical records
remain readable. The iOS app has not yet been redesigned for Live; its old
mode/settings UI is inactive. Use the physical button or `/conversation` for
pause/resume.

## 6. Troubleshooting order

1. **No connection:** follow `sudo journalctl -fu visionary`. Check Wi-Fi,
   key/model access, quota, and session errors. Do not share the API key.
2. **Connected but cannot hear you:** check capture device and mic channel,
   then check that the session is not paused. Speak after playback finishes
   because the default echo guard masks overlapping speech.
3. **Replies appear but no sound:** check playback card and speaker wiring.
   Do not start a second ALSA test while the runtime owns the card.
4. **Photo errors:** camera ownership/availability is separate from voice.
   Stop Visionary before using `rpicam-still`; then restart it. Verify the
   backend model accepts the photo request and is accessible to your key.
5. **Self-feedback:** keep echo guard enabled; isolate speaker from microphone.
   Additional digital gain will also amplify feedback and room noise.
6. **Long pauses:** inspect session/backend errors and network stability. An
   HTTP 200 from `/v1/models` alone does not prove a Live connection or photo
   delegation is working.

The service uses unbuffered Python, so log updates should arrive promptly.
Do not enable transcript logging in shared environments without consent.

## 7. Explicit legacy rollback

Source and data are preserved. To run the previous behavior again, edit
`/etc/visionary.env`, set `VISIONARY_RUNTIME=legacy`, then restart both services:

```bash
sudo systemctl restart visionary visionary-api
```

This intentionally restores the old one-shot speech/vision pipeline and
gestures. It is not a fallback automatically selected when Live fails.
