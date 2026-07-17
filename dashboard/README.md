# Visionary — Classroom Fleet Dashboard

A teacher-run web page that shows live reading activity across a class set of
Visionary glasses. Runs on your laptop, on the same WiFi as the glasses. It is
**not** installed on the glasses.

## Quickstart

1. `cp devices.example.json devices.json`
2. Edit `devices.json` — one entry per pair of glasses. Get each pair's `url`
   and 6-digit `token` from its pairing QR (or the code the glasses speak on
   first boot). Example entry: `{"name": "Ada's glasses", "url":
   "http://visionary.local:8321", "token": "123456"}`.
3. `pip install fastapi uvicorn requests`
4. `uvicorn app:app --port 8400`
5. Open `http://localhost:8400` in a browser.

Stations appear within 15 seconds and the page auto-refreshes every 10 seconds.
Set `VISIONARY_FLEET_CONFIG` to point at a `devices.json` somewhere other than
the current directory. If no `devices.json` exists yet, the page shows setup
instructions instead of cards; unreachable glasses show as offline and keep
their last-known activity.

## Privacy

The dashboard sees text summaries only. It polls each device's `/status` and
`/history` endpoints and nothing else — it never requests the image or audio
endpoints, so no picture or sound a student captures ever leaves their device.
Each reading is trimmed to a single short line (120 characters), so what the
teacher sees is a summary of activity, not a transcript of everything a student
read. Everything lives in RAM on the teacher's laptop; there is no database and
nothing is written to disk or sent anywhere off the local network.
