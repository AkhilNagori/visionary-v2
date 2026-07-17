# Visionary — Feature Spec vs. Rabbit R1

R1 today ($199): voice AI chat, magic camera (vision Q&A), translation, voice recorder with transcripts/summaries, third-party agents, DLAM computer control. It's a thing you hold and look at. Ours is hands-free, on your face, seeing what you see — and works offline, which the R1 fundamentally cannot.

## Tier 1 — core, guaranteed by Saturday (no mic needed)

1. **Read anything** (single press): worksheets, books, menus, signs, handwriting, pill bottles. Cloud vision cleans it up for natural speech — not raw OCR garble.
2. **Scene description** (double press): "a whiteboard with a supply-demand graph, two people at a table to your left." R1's magic camera, but from your eyes' POV, hands-free.
3. **Instant translation reading**: point at Spanish/French/Chinese/any text → hear it in English. One-line prompt change, zero extra code. (R1 headline feature — matched.)
4. **Offline mode, automatic**: WiFi dies → Tesseract + Piper take over seamlessly. **The R1 is a brick without internet. This is your killer talking point at a hardware con.**
5. **Fully open source, $60 BOM**: hackers can build/mod it. R1 is a closed $199 box.

## Tier 2 — unlocked by the $7 INMP441 mic (order tonight)

6. **Ask about what you see** (hold button, talk): "which of these is gluten free?", "summarize this page", "what's the wifi password on that sign?" Photo + your question → spoken answer. *This is the R1's core loop, but head-mounted.*
7. **Voice assistant**: general Q&A, no camera needed. Whisper API (or local whisper.cpp tiny for offline) → OpenAI → Piper.
8. **Magic recorder equivalent**: triple-press to record a lecture/convo → transcript + AI summary spoken back or saved. (R1's newest headline feature — matched.)
9. **Two-way translation conversations**: they speak Spanish, you hear English; you speak, it speaks Spanish out the speaker.

## Tier 3 — say "coming in v2" at the booth, don't build

- Continuous memory ("what did that poster an hour ago say?") — store captures + embeddings
- Navigation assist for low vision (obstacle callouts)
- Agent actions (add to calendar/shopping list from what you see)
- Multi-user classroom dashboard for teachers

## Button map (final)

| Gesture | Action |
|---|---|
| Single press | Read text in view |
| Double press | Describe scene |
| Hold + speak (mic) | Ask anything about what you see / general question |
| Triple press (mic) | Record + transcribe + summarize |
| Hold 5s | Shutdown |

## The comparison slide/sign for the booth

| | Visionary | Rabbit R1 |
|---|---|---|
| Price | **$60 BOM / $99 kit** | $199 |
| Hands-free wearable | **Yes** | No — hold it |
| Sees what YOU see | **Yes** | Point it manually |
| Works offline | **Yes** | No |
| Open source | **Yes** | No |
| Reads for visually impaired | **Designed for it** | No |
| Screen, scroll wheel, polish | No | Yes |
| Voice Q&A / translation / recorder | Yes (with mic) | Yes |

Honesty note for the pitch: don't claim "better than R1" flatly — say "everything the R1 does that matters, hands-free, offline-capable, at a third of the price, and open source." Concede the pretty hardware; it makes the rest credible.

## Build-order discipline

Tier 1 must be flawless before any Tier 2 work — a perfect read-aloud demo beats five flaky features. Mic arrives Friday: wire it (VDD→3.3V pin 1, GND, SCK→pin 12 shared, WS→pin 35 shared, SD→GPIO20 pin 38, L/R→GND), enable `dtoverlay=googlevoicehat-soundcard` or i2s-mmap capture, and implement ONLY feature 6 (hold-to-ask). Features 7–9 are Friday-evening stretch goals; skip them if the dress rehearsal isn't done. Software freeze stays at Friday 8pm.
