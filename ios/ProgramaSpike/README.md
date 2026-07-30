# Programa iOS companion — tester setup

This is the iPhone companion app for Programa. It connects directly to a Mac
running Programa over a private peer-to-peer link (via iroh) — pairing works
over the internet through iroh's relay network, not just when both devices
are on the same Wi-Fi.

## Setup

1. On the Mac, open Programa and go to **Settings ▸ Phone**.
2. Set **Mobile Companion** from `Off` to `Paired Devices Only`. It is `Off`
   by default, so no phone can connect until you do this.
3. Click **Pair a Device…**. This opens a single-use, 5-minute pairing
   window and shows a QR code plus a live countdown.
4. On the iPhone, open the Programa app and tap **Scan QR Code** on the
   pairing screen.
5. Point the camera at the QR code on the Mac. The app fills in the pairing
   details automatically and connects.

If scanning isn't possible (no camera access, a Simulator build, or the scan
doesn't work), you have two fallbacks on the same screen:

- Paste the full pairing code text from under the Mac's QR code into the
  **Pairing code** field and tap **Use This Code**.
- Expand **Can't scan? Paste the payload and token manually** on the Mac and
  copy the two values into the **Advanced** section of the iOS pairing
  screen separately.

Once a device pairs successfully it's remembered — the pairing window is
single-use, but reconnecting later doesn't require re-pairing or a new code.

## iCloud requirement for notifications

Both the Mac and the iPhone must be **signed into the same iCloud account**
for background notifications (Live Activities, "an agent needs you" alerts)
to arrive. The app has no way to detect a mismatched Apple ID between the two
devices — if notifications never show up, check the Apple ID on both devices
first.

## Building locally

```bash
cd ios/ProgramaSpike
xcodegen generate
cd ../..
xcodebuild -project ios/ProgramaSpike/ProgramaSpike.xcodeproj \
  -scheme ProgramaSpike -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Camera-based scanning has no effect in the Simulator (no camera hardware) —
the **Scan QR Code** button degrades gracefully and shows a message instead
of crashing; use the paste fallback when testing there.
