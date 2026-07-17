# Visionary — Complete Hardware Build Tutorial

Final architecture: Pi Zero 2 W brain, CSI camera eye, MAX98357A + speaker voice, ICS-43434 I2S ear, LiPo + TP4056 + PowerBoost 1000 Basic power, one button, one switch, 3D printed frame.

## Bill of materials

| Part | Role |
|---|---|
| Raspberry Pi Zero 2 W | brain |
| Waveshare RPi Zero V1.3 camera + Zero-size ribbon | eye |
| MAX98357A breakout | I2S amp (speaker out) |
| 1W 8Ω speaker | voice |
| Adafruit ICS-43434 breakout | I2S MEMS mic (voice in) |
| PowerBoost 1000 Basic | 3.7V → 5V @ 1A |
| TP4056 module | LiPo charging |
| 3.7V 2000mAh LiPo | battery (~3–4h) |
| Momentary push button | trigger |
| Mini slide switch | power on/off |
| 28–30 AWG wire, heat shrink, foam tape, zip ties | assembly |

Tools: soldering iron + thin solder, flush cutters, wire stripper, multimeter, hot glue or E6000, pliers (lens focus).

## The one clever trick in this build

The amp and mic share the Pi's single I2S bus — same clock wires, opposite data directions. One device-tree overlay (`googlevoicehat-soundcard`) drives both simultaneously. This is exactly the Google AIY Voice HAT topology (MAX98357A out + ICS-434xx in), so it's a well-trodden path. It means only ONE extra wire for the whole microphone.

## Master pinout (solder to these, nothing else)

| Signal | Pi physical pin | GPIO | Goes to |
|---|---|---|---|
| 5V in | pin 2 | — | PowerBoost 5V |
| GND in | pin 6 | — | PowerBoost GND |
| Amp VIN | pin 4 (5V) | — | MAX98357A VIN |
| Amp GND | pin 9 | — | MAX98357A GND |
| Mic 3V | pin 1 (3.3V) | — | ICS-43434 VDD ("3V") |
| Mic GND | pin 14 | — | ICS-43434 GND |
| BCLK (shared) | pin 12 | GPIO18 | amp BCLK **and** mic SCK/BCLK |
| LRCLK (shared) | pin 35 | GPIO19 | amp LRC **and** mic WS/LRCL |
| Audio out data | pin 40 | GPIO21 | amp DIN |
| Audio in data | pin 38 | GPIO20 | mic SD/DOUT |
| Button | pin 11 (GPIO17) + pin 39 (GND) | GPIO17 | across the button |

Also: mic **SEL/LR → GND** (left channel), amp **SD → leave unconnected**, amp **GAIN → unconnected** (9dB; jumper to GND later for 12dB if the con floor is loud).

## Build order — test after EVERY step

### Step 0 — Bench brain (no soldering)

1. Flash **Raspberry Pi OS Lite 64-bit (Bookworm)** with Raspberry Pi Imager. In the imager's settings: hostname `visionary`, enable SSH, add your home WiFi AND your phone hotspot.
2. Power the bare Pi from a normal USB supply into **PWR IN** (the micro-USB port nearer the corner). SSH in: `ssh pi@visionary.local`.
3. Copy over `code/` and run `sudo bash setup.sh` (see software doc — use the `googlevoicehat-soundcard` overlay, not `max98357a`).

### Step 1 — Camera

1. Pi OFF. Lift the CSI connector latch, ribbon in **contacts facing the board**, close latch.
2. Test: `libcamera-still -o test.jpg`, scp it over and look at it.
3. **Fix the focus now**: the lens is factory-focused past 1m; you read at ~30cm. Grip the lens barrel gently with pliers (score the glue dot with a blade if present), turn counterclockwise in tiny increments, re-shoot a printed page at 30cm each time until text is crisp. This step decides whether OCR works at all.

### Step 2 — Power chain

**Rule: never solder anything while the battery is connected.**

1. Solder the slide switch between PowerBoost **EN** and **GND** (switch closed = EN low = output OFF — so "on" position is switch OPEN; if that feels backwards, wire EN to a switch that connects EN→GND to turn off).
2. Battery leads → TP4056 **B+ / B−**. This connection is permanent (charge path).
3. Second pair of wires from the same battery terminals (or TP4056 B+/B− pads) → PowerBoost **BAT / GND** (discharge path). The battery feeds both boards in parallel.
4. PowerBoost **5V / GND** → Pi **pin 2 / pin 6**.
5. Before connecting the Pi: switch on, measure PowerBoost output with the multimeter — expect **5.0–5.2V**. Then connect the Pi and boot.
6. Charging: plug USB into the **TP4056** port, with the power switch OFF. Red = charging, blue/green = full. **Never charge while the Pi runs.**
7. Soak test: boot, run `libcamera-still` in a loop 20×, then `dmesg | grep -i volt` — must be clean.

### Step 3 — Speaker (MAX98357A)

1. Wire per the master pinout: VIN→pin 4, GND→pin 9, BCLK→pin 12, LRC→pin 35, DIN→pin 40. Speaker to the amp's + / − screw/solder terminals.
2. Test: `speaker-test -c1 -t sine -f 440` then `aplay /opt/visionary/sounds/ok.wav`. Too quiet? GAIN pin → GND.

### Step 4 — Microphone (ICS-43434)

1. Only 4 new connections: VDD→pin 1 (3.3V — **never 5V**), GND→pin 14, SD→pin 38, SEL→GND. SCK and WS **piggyback on the same pins 12 and 35** the amp already uses — solder the mic's clock wires onto the amp's clock joints or directly to the header.
2. Test record-then-play loop:
   ```
   arecord -D plughw:0,0 -f S32_LE -r 48000 -c 2 -d 3 t.wav && aplay t.wav
   ```
   (With the googlevoicehat overlay the card handles both directions; check names with `arecord -l` / `aplay -l`.)
3. Speak at arm's length — playback should be clearly intelligible. Some hiss is normal for MEMS; the software applies gain + high-pass.

### Step 5 — Button

Button across pin 11 (GPIO17) and pin 39 (GND). No resistor needed (internal pull-up). Test with the firmware running: single press should beep + capture.

### Step 6 — Full system dress rehearsal (still on the bench)

Run the complete loop 10 times on battery: press → read aloud; double-press → describe; hold-to-ask → answer. Then a battery runtime test while you print.

### Step 7 — Frame assembly

- **Right temple pod**: Pi + PowerBoost stacked with foam tape between (no shorts!), camera pod at the front corner angled ~15° down, ribbon folded inside.
- **Left temple pod**: LiPo + TP4056, USB charge port facing out/down, balances the weight.
- Speaker near the right ear, grille holes in the print. Mic port hole near the front (pointing forward-down toward your mouth), ICS-43434 port hole unobstructed.
- Button on top edge of the right pod (index-finger reach). Switch on the underside.
- Wires cross behind the head via a printed channel or braided sleeve. Zip-tie strain relief at every pod exit.
- Both Pi USB ports and the TP4056 port must stay reachable (debug, mic fallback, charging).
- Battery: pad it in foam, no screw pressure on the pouch, nothing sharp nearby.

## Safety notes (LiPo)

Don't pierce, crush, or solder directly onto the cell tabs. If it ever puffs, gets hot, or smells sweet — retire it outside, not in your bag. Charge on a non-flammable surface, and never unattended overnight before the con.

## Troubleshooting quick table

| Symptom | Cause | Fix |
|---|---|---|
| Pi reboots on capture | voltage sag | check solder joints thick/short; confirm PowerBoost not MT3608; battery charged |
| No audio out | wrong overlay | `googlevoicehat-soundcard` in config.txt, `dtparam=audio=off`, reboot |
| Mic records silence | SEL floating | SEL→GND; check SD on pin 38 |
| Audio + mic won't work together | two overlays fighting | remove `max98357a` overlay line, keep only googlevoicehat |
| Camera "not detected" | ribbon flipped/loose | contacts toward board, reseat both ends |
| Blurry OCR | lens focus | Step 1.3, re-twist at 30cm |
| Undervoltage in dmesg | thin wires | shorten/thicken 5V run, resolder |
