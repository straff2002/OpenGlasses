# Rokid RV101 — hardware validation checklist

Everything a person holding the RV101 and a Mac needs in order to turn the dark transports in
`Sources/Services/{Display,Camera,Microphone}/Rokid/` into working ones. Nothing here needs to
happen for CI: the unit tests are deterministic and run without hardware.

## Prerequisites

| Need | Why |
| ---- | --- |
| Mac with Xcode 26+ / iOS 26 SDK | this repo's `project.base.yml` targets iOS 26 and `docs/BUILDING.md` pins Xcode 26 |
| iPhone 15 Pro Max (iOS 26+) | the phone half of the link |
| Rokid RV101 ("Rokid Glasses") | the device half |
| Apple developer team + a device provisioning profile | to install on hardware at all |
| *(optional, decisive)* Apple **Bluetooth logging profile** + PacketLogger | the only supported way to see GATT traffic on iOS |
| *(optional, decisive)* Rokid developer account with `appKey` / `appSecret` / `accessKey` | unlocks the AI-alliance iOS SDK instead of reverse engineering |

Add secrets to the **git-ignored** `project.local.yml` (the same file `MWDAT_META_APP_ID` uses);
never to a tracked file and never to a commit.

## Build and run

```bash
cp project.local.yml.example project.local.yml   # if not present already
./Scripts/install-xcodegen.sh
./Scripts/generate-xcodeproj.sh
open OpenGlasses.xcodeproj
```

Set the team in *Signing & Capabilities*, select the iPhone, run. Then:

1. **Settings → Display Backend → "Rokid RV101" → Scan for Glasses → Pair.** Note the peripheral
   UUID stored in `Config.rokidPeripheralID`.
2. **Settings → Camera → "Rokid RV101"** (read once at `CameraService` init — relaunch to apply).

## Per-surface pass criteria

### Display

- **Pass:** the transport reaches `connected`; a rendered card/notification appears on the glasses.
- **Expected today:** the backend is reachable and honest about its limits; with the placeholder
  UUIDs in `RokidBLETransport` it will not find the device. `GlassesDisplayError.noDisplay` surfaces
  in the HUD path rather than a hang.

### Camera

- **Pass:** `RokidCameraBackend.capturePhoto()` returns JPEG bytes and the image is the glasses
  camera's view.
- **Expected today:** `RokidCameraTransport.captureStill()` throws `.stillUnavailable`; the app
  falls back to the iPhone camera. `CameraFeatureGate` says so in Settings.

### Microphone

- **Pass (Bluetooth headset — works today):** the glasses appear as a Bluetooth input and an
  assistant turn transcribes from them. This needs no Rokid code at all.
- **Pass (native ARTC/Ai — not implemented):** `RokidMicrophoneBackend.startCapture()` throws
  `.streamUnavailable` until the envelope exists. That is the intended behaviour, not a bug.

## Closing the protocol gaps (2–4) by capture

This is the route that needs no vendor account.

1. Install the Apple Bluetooth logging profile on the iPhone (developer portal → *More* →
   *Bluetooth*). Reboot; enable logging; install **PacketLogger** on the Mac.
2. Launch the official Rokid app, bind the glasses, then exercise, in order: connect, speak to TTS,
   push a notification, take a photo, enable the mic.
3. Stop logging, save the `.pklg`, and export the ATT write/notify payloads.
4. Extract three things:
   - the **service and characteristic UUIDs** actually used (closes gap 3);
   - the **first ~40 frames after connect** (closes gap 4, the handshake);
   - the **byte layout** of TTS / notification / camera / mic commands (closes gap 2, Caps).
5. Send those back. Then only three constants/decoders change: the UUIDs in `RokidBLETransport`, the
   envelope in `RokidWireCodec`, and the `connect()` handshake. The seams and the tests do not move.

## Order of work once real bytes exist

1. UUIDs → the transport connects.
2. Caps envelope → `RokidWireCodec`.
3. Handshake → `RokidBLETransport.connect()`.
4. Param schemas → validate `RokidCommand.notification` / `.customView` against the device.
5. Still capture → `Med` command + network fetch in `RokidCameraTransport.captureStill()`.
6. ARTC audio + live frames → `RokidAudioTransport` / `RokidCameraTransport`, then flip
   `MicrophoneCapabilities.streamsWearerAudio` / `CameraCapabilities.liveFrames` **only** when they
   actually deliver.

## If you take the official SDK instead

The public CocoaPods `RokidSDK` is 1.10.2 from **2019** and predates XCFramework and
arm64-simulator slices, so it will not link on iOS 26. The AI-alliance SDK from
`developer.rokid.com` is the usable one. Whatever its packaging:

1. Gate the dependency behind `#if canImport(RokidSDK)` (or a dedicated bridge target) so the
   simulator build — and therefore CI — keeps compiling without it.
2. Implement `RokidTransporting`, `RokidAudioTransporting` and `RokidCameraTransporting` over the
   SDK. All three protocols already exist and the backends already consume them, so this is a
   drop-in replacement for the placeholder transports.
3. Keep the capability flags honest: `streamsWearerAudio` and `liveFrames` stay `false` until the
   SDK path is observed delivering audio/frames on the device.
