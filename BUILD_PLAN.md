# Visionary AI Glasses — 48-Hour Hackathon Build Plan

Goal by Saturday morning: one polished wearable demo unit + one "guts on a board" display unit + preorder pipeline.

## What it does (demo version)

Single button press → camera snaps the page → Claude vision reads ALL text aloud through the speaker in a natural voice, ~4–6 s. Double press → describes the whole scene ("a whiteboard with a diagram, two people to your left..."). Works offline too (Tesseract OCR + Piper TTS) when WiFi drops — huge credibility point at a crowded conference.

## Hardware audit

| Have | Role | Status |
|---|---|---|
| Pi Zero 2 W | brain | ✅ |
| Waveshare RPi Zero V1.3 camera (CSI) | eye | ✅ use this, NOT the analog spy cam |
| MAX98357A | I2S amp | ✅ |
| 1W 8Ω speaker | voice | ✅ |
| TP4056 | charging circuit | ✅ charge path only |
| 3.7V 2000mAh LiPo | power | ✅ ~3–4h runtime |
| PowerBoost 1000 Basic | 5V boost | ✅ real 1A boost, replaces the sagging MT3608 |
| Adafruit USB mini mic + OTG adapter | voice input | ✅ plugs into Pi data port |
| SPH0645 I2S MEMS mic | v2 in-frame mic | ✅ do NOT wire before Saturday |
| 3D filament + printer | frame | ✅ |

## Power chain (PowerBoost 1000 Basic + TP4056)

```
LiPo + / −  →  TP4056 B+ / B−            (permanent — charging path)
LiPo + / −  →  PowerBoost BAT / GND      (parallel — discharge path)
Slide switch:  PowerBoost EN ↔ GND       (EN pulled low = output off)
PowerBoost 5V / GND  →  Pi pin 2 / pin 6
```

- Charge through the TP4056's USB port **with the switch OFF**. Never charge while running.
- MAX98357A VIN comes from Pi 5V rail (pin 4).
- Verify with `dmesg | grep -i volt` after a few captures — should be clean. If you ever see undervoltage, fall back to a USB power bank into the Pi's PWR port (bring one Saturday regardless).

## Wiring pinout (Pi Zero 2 W header)

| Wire | Pi pin | GPIO |
|---|---|---|
| Power bank | micro-USB PWR IN port | — |
| MAX98357A VIN | pin 4 (5V) | — |
| MAX98357A GND | pin 9 (GND) | — |
| MAX98357A BCLK | pin 12 | GPIO18 |
| MAX98357A LRC | pin 35 | GPIO19 |
| MAX98357A DIN | pin 40 | GPIO21 |
| MAX98357A SD | leave unconnected (on = mono L+R/2) | — |
| MAX98357A GAIN | unconnected = 9dB (jump to GND for 12dB if too quiet) | — |
| Button leg 1 | pin 11 | GPIO17 |
| Button leg 2 | pin 14 (GND) | — |
| Speaker | amp + / − | — |
| Camera | CSI ribbon (Zero-size connector, contacts toward board) | — |

## Camera focus — do this or OCR will fail

The V1.3-style lens is fixed-focus at ~1m+. Reading distance is 25–40cm. **Twist the lens** (grip with pliers gently or the supplied tool; some have a glue dot — score it with a blade) counterclockwise a fraction of a turn until text at 30cm is sharp. Check with `libcamera-still -o test.jpg` over SSH.

## Software (files in firmware/)

1. Flash **Raspberry Pi OS Lite 64-bit (Bookworm)** with Raspberry Pi Imager. Preconfigure WiFi (home + your phone hotspot SSID) and SSH in the imager settings.
2. `scp` the repo over, then `sudo bash firmware/setup.sh`.
3. Put your Anthropic API key in `/etc/visionary.env` (console.anthropic.com — $5 of credit covers hundreds of demo reads on Haiku).
4. Reboot. It announces "Visionary ready" on boot. No keyboard/screen ever needed at the booth.

## 3D printed frame strategy

Don't design a full glasses frame from scratch — no time to iterate fit. Instead:

- **Print a chunky "tech bar"**: a rectangular hollow temple-arm pod (~110 × 25 × 18mm) that zip-ties/screws onto cheap sunglasses or safety glasses. Holds Pi + boost + TP4056 stacked with foam. Battery goes in a matching pod on the *other* temple (weight balance) or at the back strap.
- **Camera pod** on the front corner, angled ~15° downward (you look down at a page).
- Speaker pod near the ear, grille holes toward the ear.
- Search Printables/Thingiverse for "Raspberry Pi Zero glasses" / "smart glasses frame" first — remixing beats modeling. Budget 3 print iterations max: rough fit test (30% infill draft), refined, final in your best color.
- Print a **spare of everything** and a phone-stand style **display base** that holds the glasses at eye level on the booth table.
- Both Pi micro-USB ports must stay accessible (power in + debug).

## Schedule

### Thursday (today)
- Now: order missing parts (overnight). Flash SD card. Start `setup.sh` on the bare Pi powered by a normal USB supply — software doesn't need the battery chain.
- Evening: get the full pipeline working on the bench: button → beep → Claude reads a page aloud. Fix camera focus. Start printing draft frame pods overnight.

### Friday
- Morning: solder amp + button (only 6 solder joints left in the whole build). **Test after every solder step.** Verify power bank runs the full pipeline for 30 min.
- Afternoon: fit everything into printed pods (pods are lighter now — no battery/charger inside), refine print, final print. Cable-manage the temple; add a zip-tie strain relief where the USB cable leaves the frame.
- Evening: full dress rehearsal ×10 runs. Battery runtime test. Set up phone hotspot as known WiFi. Build display unit (spare parts on a laser-cut/printed plate, labeled) if time. Charge everything. Print preorder QR sign.
- **Freeze the software Friday 8pm. No changes after.**

### Saturday
- Bring: TWO fully charged power banks + spare cable, phone hotspot, laminated one-pager, QR sign, spare SD card (cloned image!), small toolkit, tape. Swap banks at lunch — never demo below 20%.

## Contingencies

- Cloud/WiFi dies at venue → offline mode kicks in automatically (Tesseract + Piper). Practice this demo path too.
- Audio too quiet on the con floor → GAIN pin to GND (12dB), and lean speaker to visitor's ear; also keep a small USB speaker as backup via aplay.
- Pi crashes → systemd auto-restarts the app in 3s; hard crash → power cycle takes ~25s, fill with pitch talk.
- Unit breaks → display unit is your backup demo; video of it working on your phone is the backup-backup. **Record a demo video Friday night.**
