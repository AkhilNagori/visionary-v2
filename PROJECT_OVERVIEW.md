# Visionary — Project Overview

*AI glasses that read the world aloud. $60 in parts. Open source. Works offline.*

## The problem

A visually impaired student in a mainstream classroom hits the same wall dozens of times a day: the worksheet being handed out, the page number on the board, the textbook paragraph everyone else is silently reading. Existing solutions are either a human (an aide reading aloud — no independence, limited availability) or hardware like OrCam MyEye at $2,000–4,000 per student — a price that means most schools own zero. Phone apps exist, but require holding and aiming a screen you can't see, with two hands a student needs for everything else.

## The product

Visionary is a pair of 3D-printed smart glasses with one button:

- **Press once** — it reads whatever you're facing, aloud, in a natural voice: worksheets, textbooks, handwriting, menus, signs, pill bottles.
- **Press twice** — it describes the scene: what's around you, who, where, what's written.
- **Hold and talk** — ask about what you see: "which answer did I circle?", "what's the homework on the board?"
- **No internet? It still reads.** A fully offline OCR + speech pipeline takes over automatically — critical for classrooms, and something a Rabbit R1 or Humane Pin fundamentally cannot do.

The wearer never touches a screen. Parents and teachers optionally pair a phone app to see reading history, trigger reads remotely, and adjust voice/language.

## Why it wins

| | Visionary | OrCam MyEye | Rabbit R1 | Phone apps |
|---|---|---|---|---|
| Price | **$60 BOM / $99 kit** | $2,000–4,000 | $199 | "free" + $1k phone |
| Hands-free, sees your POV | Yes | Yes | No | No |
| Works offline | **Yes** | Partially | No | Some |
| Open source / repairable | **Yes** | No | No | No |
| Built for classrooms | **Yes** | Clinical market | No | No |

The honest concession: we don't have their industrial design or certifications — yet. We have a 30–60× price advantage and a hackable platform, which is exactly the right trade for schools and makers.

## How it works (one paragraph)

A head-mounted camera captures on button press. A Raspberry Pi Zero 2 W sends the image to a frontier vision model that returns clean, reading-order text or a scene description, spoken through a temple-mounted speaker via neural TTS. Offline, the same press routes to on-device OCR (Tesseract) and on-device TTS (Piper). A MEMS microphone adds voice questions, dictation, and live translation. Battery is a 2000mAh cell with proper boost/charge circuitry; runtime ~3–4 hours of active classroom use.

## Origin story

Visionary began as a science fair project: a camera on printed frames, a CRNN text-recognition model, and espeak — built to help visually impaired students read handouts. It worked. This version keeps that mission and replaces the brain: frontier vision models for accuracy on real-world materials (handwriting, low light, layouts) with the offline pipeline preserving the original self-contained spirit.

## Roadmap

- **Now — v1 "Founder Kit" (30 units)**: hand-assembled or self-solder kit, printed frame, preloaded SD card, full docs. $99 preorder ($79 solder-it-yourself / $149 assembled).
- **+3 months — v2**: integrated frame (in-temple mic, battery, custom thin PCB), iOS companion app, wake word, visual memory search.
- **+6–12 months — Classroom Edition**: class-set of 10 + teacher dashboard, district pilot programs, grant-funded distribution (assistive-tech funding exists precisely for this gap).

## Business snapshot

- BOM ~$55–60 at qty 1; ~$40 at qty 100. Kit at $99 = healthy margin for a bootstrapped run of 30.
- Sold as an **open-source DIY electronics kit inspired by an accessibility project** — not as a certified medical/assistive device. No clinical claims; that keeps v1 legally simple while the mission story remains true.
- Ongoing cost honesty: cloud reads cost ~$0.003–0.01 each; kits include a bring-your-own-API-key model or a bundled starter credit.
- Community flywheel: open hardware invites mods (new languages, new frames, new features) → the R1 can't do that.

## Privacy, in one breath

Press-to-capture only. No continuous recording, no accounts, no cloud storage — history lives on the device, and the code is public so you can check.

## Team

Built by Idan Kestenbom. Started at a science fair; debuting at Open Sauce 2026.

## The ask (booth version)

Try it — press the button. If you'd build one, preorder a Founder Kit at the QR code: 30 units, ships within 6 weeks, everything included plus the docs that got you this demo.
