# Visionary — Project Overview

*AI glasses that read the world aloud. $60 in parts. Open source. One OpenAI key.*

## The problem

A visually impaired student in a mainstream classroom hits the same wall dozens of times a day: the worksheet being handed out, the page number on the board, the textbook paragraph everyone else is silently reading. Existing solutions are either a human (an aide reading aloud — no independence, limited availability) or hardware like OrCam MyEye at $2,000–4,000 per student — a price that means most schools own zero. Phone apps exist, but require holding and aiming a screen you can't see, with two hands a student needs for everything else.

## The product

Visionary is a pair of 3D-printed smart glasses with one button:

- **Press once** — it reads whatever you're facing, aloud, in a natural voice: worksheets, textbooks, handwriting, menus, signs, pill bottles.
- **Press twice** — it describes the scene: what's around you, who, where, what's written.
- **Hold and talk** — ask about what you see: "which answer did I circle?", "what's the homework on the board?"
- **One OpenAI key.** Vision, chat, speech recognition, speech generation, and visual-memory embeddings use the same API credential. Internet access is required for AI actions.

The wearer never touches a screen. Parents and teachers optionally pair a phone app to see reading history, trigger reads remotely, and adjust voice/language.

## Why it wins

| | Visionary | OrCam MyEye | Rabbit R1 | Phone apps |
|---|---|---|---|---|
| Price | **$60 BOM / $99 kit** | $2,000–4,000 | $199 | "free" + $1k phone |
| Hands-free, sees your POV | Yes | Yes | No | No |
| Works offline | No — internet required for AI | Partially | No | Some |
| Open source / repairable | **Yes** | No | No | No |
| Built for classrooms | **Yes** | Clinical market | No | No |

The honest concession: we don't have their industrial design or certifications — yet. We have a 30–60× price advantage and a hackable platform, which is exactly the right trade for schools and makers.

## How it works (one paragraph)

A head-mounted camera captures on button press. A Raspberry Pi Zero 2 W sends the image to OpenAI vision, which returns clean reading-order text or a scene description. The Pi sends spoken input captured through ALSA to `gpt-4o-mini-transcribe`, requests spoken output from `gpt-4o-mini-tts-2025-12-15` with voice `marin`, and plays the returned audio through the temple speaker with ALSA. Chat and `text-embedding-3-small` memory search use the same `OPENAI_API_KEY`. No vision or speech model runs on the Pi; internet access is required. Battery is a 2000mAh cell with proper boost/charge circuitry; runtime is about 3–4 hours of active classroom use.

## Origin story

Visionary began as a science fair project: a camera on printed frames and an on-device text-and-speech prototype built to help visually impaired students read handouts. It worked. This version keeps that mission and moves the AI workload to OpenAI for better results on real-world materials, speech, handwriting, low light, and complex layouts while keeping the Pi software small enough for 32-bit `armhf` hardware.

## Roadmap

- **Now — v1 "Founder Kit" (30 units)**: hand-assembled or self-solder kit, printed frame, preloaded SD card, full docs. $99 preorder ($79 solder-it-yourself / $149 assembled).
- **+3 months — v2**: integrated frame (in-temple mic, battery, custom thin PCB), iOS companion app, and visual memory search.
- **+6–12 months — Classroom Edition**: class-set of 10 + teacher dashboard, district pilot programs, grant-funded distribution (assistive-tech funding exists precisely for this gap).

## Business snapshot

- BOM ~$55–60 at qty 1; ~$40 at qty 100. Kit at $99 = healthy margin for a bootstrapped run of 30.
- Sold as an **open-source DIY electronics kit inspired by an accessibility project** — not as a certified medical/assistive device. No clinical claims; that keeps v1 legally simple while the mission story remains true.
- Ongoing cost honesty: cloud reads cost ~$0.003–0.01 each; kits include a bring-your-own-API-key model or a bundled starter credit.
- Community flywheel: open hardware invites mods (new languages, new frames, new features) → the R1 can't do that.

## Privacy, in one breath

Capture is deliberate, not passive. A triggered feature uploads its requested image and/or microphone recording to OpenAI; there is no always-listening wake word or background microphone capture. History lives on the device, and the device code is public so you can verify when capture and upload occur. Review OpenAI's API data controls before classroom use.

## Team

Built by Idan Kestenbom. Started at a science fair; debuting at Open Sauce 2026.

## The ask (booth version)

Try it — press the button. If you'd build one, preorder a Founder Kit at the QR code: 30 units, ships within 6 weeks, everything included plus the docs that got you this demo.
