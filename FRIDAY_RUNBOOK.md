# Friday Runbook — two-person split (Idan: software/booth · Akhil: hardware)

## TONIGHT before sleep (non-negotiable)

- [ ] **Start the overnight print**: temple pods + camera pod, draft quality. The printer is your longest lead time — it must run while you sleep.
- [ ] Charge: LiPo (on TP4056, on a plate, not unattended-while-asleep — charge it during the evening, unplug before bed), both power banks, phone.
- [ ] Camera focused at 30cm (test.jpg proof).
- [ ] Text-only AI pipeline proven on the Pi (the python snippet reading a worksheet).
- [ ] Make the **preorder form** (Tally/Google Form: name, email, tier $79/$99/$149, qty) → QR code → in tomorrow's print queue.

## FRIDAY — Akhil (hardware track)

| When | Task | Done-when |
|---|---|---|
| AM | Power chain: TP4056 + PowerBoost + switch (HARDWARE_TUTORIAL step 2) | Pi boots on battery, `dmesg` clean after 20 captures |
| AM | Amp + speaker (step 3) | `aplay ok.wav` audible across a room |
| Midday | ICS-43434 mic (step 4) | record→playback loop intelligible |
| Midday | Button (step 5) | press → beep → spoken reading |
| PM | Fit into refined pods, final print in best filament | wearable, nothing rattles, ports reachable |
| PM | Strain relief, cable routing, hot glue | survives 20 on/off head cycles |

Rule: **test after every solder joint**. A multimeter continuity check costs 10 seconds; a fried Pi costs the demo.

## FRIDAY — Idan (software track)

| When | Task | Done-when |
|---|---|---|
| AM | Triage the agent-built code: deploy **Tier 1 only** to the Pi first | single/double press flawless 10/10 on bench |
| Midday | Add Tier 2 hold-to-ask once mic is soldered | 5 consecutive good voice Q&As |
| Midday | Recorder + translation ONLY if ahead of schedule | — |
| 4pm | **Latency pass**: streaming TTS starts < 4s after press | measured, logged |
| 6pm | Full dress rehearsal with Akhil: 20 end-to-end runs on battery, on the **phone hotspot** (Saturday's network) | ≥18/20 clean |
| 7pm | Record the demo video (phone, good light, real worksheet) | 60s clip on both phones |
| 8pm | **SOFTWARE FREEZE.** Clone SD card to .img + flash the spare card | spare card boots |
| Eve | Print: QR signs ×2, one-pagers ×50 (PROJECT_OVERVIEW condensed), laminate 3 demo props | in the go-bag |

Warning on the 12-agent build: 173k tokens of untested code ≠ a demo. Deploy incrementally — Tier 1 alone, prove it, then add one module at a time. The dashboard, tests, and iOS app do NOT go on the Pi; they're repo/roadmap material. If integration fights you at 5pm, ship yesterday's simple visionary.py — it already does the demo that sells.

## Go-bag (pack Friday night, not Saturday morning)

- [ ] The glasses (charged) + spare battery
- [ ] 2 power banks + short micro-USB cable (tether fallback)
- [ ] Spare Pi Zero 2 W + cloned SD + spare SD
- [ ] Display "guts" unit or labeled component board + "$60 BOM" card
- [ ] 3 laminated props (worksheet / menu / handwritten note)
- [ ] QR signs ×2, one-pagers, tape, zip ties, toolkit (iron optional but heroic)
- [ ] Phone with hotspot + demo video; Pi Connect logged in for emergency debug
- [ ] Multimeter, spare wire, hot glue sticks
- [ ] Water, snacks — you can't leave a busy booth

## Saturday morning (30 min, at venue)

1. Power on glasses → "Visionary ready"
2. Hotspot up → confirm cloud read works once
3. Kill WiFi → confirm offline read works once  ← rehearse this; it's your best trick
4. Tape QR sign, stack one-pagers, props out, video looping
5. First visitor: run DEMO_AND_PREORDERS.md script

## If it all goes wrong matrix

| Disaster | Response |
|---|---|
| Glasses dead Saturday AM | Spare Pi + cloned SD into the frame; else display unit + video + strong pitch — preorders don't require a live demo, they require a story |
| Venue RF swamp kills hotspot | Offline mode IS the demo — "no internet needed, watch" |
| Voice features flaky | Demo Tier 1 only; say "voice ships in the kit" — read-aloud alone beat the science fair |
| Battery build unstable | Power bank in pocket, cable down the temple — nobody at Open Sauce will mind |
