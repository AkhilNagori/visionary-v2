# Visionary iOS Companion App

SwiftUI app for pairing with, monitoring, and remote-controlling Visionary glasses. The glasses never require the app; this is convenience for a parent, teacher, or the wearer's own phone.

Everything is device-local. No accounts, no cloud backend, no analytics. The app speaks HTTP to the glasses on your local network and nowhere else; captures, history, and recordings never leave the Pi. Because the whole stack is open source, you can verify that claim instead of trusting it.

## Build

Requires Xcode 15+ (iOS 16.0 deployment target), Swift 5.9, no external packages.

### With XcodeGen (recommended)

```
brew install xcodegen
cd ios
xcodegen generate
open Visionary.xcodeproj
```

Pick your signing team under Signing & Capabilities, choose a simulator or device, and run.

### Without XcodeGen

1. Xcode > File > New > Project > iOS > App. Product name `Visionary`, interface SwiftUI, minimum deployment iOS 16.0.
2. Delete the template `ContentView.swift` and the generated `VisionaryApp.swift`.
3. Drag this directory's `Visionary/` folder into the project navigator (create groups, add to the app target).
4. In the target's Info tab, add these keys:
   - `NSCameraUsageDescription`: "The camera is used only to scan the pairing QR code shown by your Visionary glasses."
   - `NSLocalNetworkUsageDescription`: "Visionary talks directly to your glasses over the local network."
   - `NSBonjourServices`: array with one item, `_visionary._tcp`
5. Build and run.

The Bonjour and local-network keys are required, not optional. Without them iOS silently blocks discovery and all LAN requests.

## Pairing

At first boot the glasses mint a bearer token, speak it as a 6-digit code, and write a QR to `/opt/visionary/pairing_qr.png` on the Pi. The QR payload is JSON:

```json
{"url": "http://<hostname>.local:8321", "token": "123456"}
```

Ways to pair, in order of least effort:

1. **Scan the QR** with the Pairing screen's camera (print it or open the PNG on any screen, e.g. `scp pi@visionary.local:/opt/visionary/pairing_qr.png .`).
2. **Nearby devices**: the glasses advertise `_visionary._tcp` over Bonjour, so discovered devices appear in the Pairing screen automatically. Tap one and enter the spoken 6-digit code.
3. **Manual entry**: type `http://visionary.local:8321` plus the 6-digit code the glasses spoke at boot.

Pairing is validated against the device's `/status` endpoint before it sticks, then persists across app launches. "Forget device" in Settings unpairs.

## Tabs

Home (status plus remote Read/Describe triggers), History (everything the glasses read, with thumbnails), Live (MJPEG preview for lens focus and aiming practice), Recorder (transcripts and AI summaries of recordings), Settings (voice, speech rate, translation language, WiFi, updates).

Battery shows a dash in v1: the PowerBoost Basic has no fuel gauge, so the API reports `null`.
