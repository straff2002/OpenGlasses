# Rokid RV101 (Rokid Glasses) — Integration Notes

Status: **Phase 0 shipped** — display *and* camera backends (deterministic command layer,
renderer, `GlassesDisplayBackend` + `GlassesCameraBackend` conformances, CoreBluetooth
skeleton), all unit-tested. The Bluetooth/network edge ships dark (see "Open gaps").
Channel selection and hardware validation are Phase 1.

## Device

Rokid RV101 ("Rokid Glasses", model family "RG-glasses") is an Android 12 (API 32) AI
glasses platform: Qualcomm QCS6490, firmware 1.15.004, a 480×640 portrait micro-display,
Sony IMX681 camera, 8-microphone array, Bluetooth 5.2, ~16 sensors, and 3DOF head tracking
(`librfm3dof.so`).

## Communication model

All phone↔glasses traffic goes through **CXRService** on the device:

| channel          | clientType | used by |
| ---------------- | ---------- | ------- |
| BT RFCOMM socket | 1          | Android |
| BLE GATT         | 2          | iPhone (no MFi) |
| MFi iAP2 socket  | 3          | iPhone (MFi) — protocol `com.rokid.aiglasses` / `com.rokid.bolonglasses` |

On top of the transport sits a proprietary **Caps** binary serialization (native lib), and
on top of Caps sits a **JSON command** vocabulary `{"cmd","key","param"}` across 21
categories: `Sys`, `Dev`, `Settings`, `Ota`, `Wifi`, `Proxy`, `Med`, `Music`, `Broadcast`,
`ARTC`, `Ai`, `Trans`/`Tra`, `Jsai`, `Nav`, `Pay`, `Ntf`, `Schedule`, `Memo`, `Journey`,
`Order`, `Custom_View`.

Relevant to this app's HUD:

- `Ntf` — phone notifications forwarded to the glasses display.
- `Custom_View` — "third-party custom UI": the third-party HUD path.
- `Nav` — navigation guidance.
- `Sys/Tts_SendPlayTts` — speak text. The only command whose param schema is published
  (`{"content":"…"}`).
- `Med` / `Ai` / `ARTC` — camera and real-time audio/video. `Med` is the still-capture
  category (see "Camera & microphone" below); `Ai`/`ARTC` are the frame/audio streams (not
  yet wired).

## Two integration paths

1. **Official Rokid Mobile SDK** (CocoaPods `RokidSDK ~> 1.10.2`) — requires a Rokid
   developer account and AppKey/AppSecret/accessKey
   (`RokidMobileSDK.shared.initSDK(appKey:appSecret:accessKey:…)`); provides Account,
   Binder (BLE), Device, Vui (cards / ASR / TTS / TOPIC), and Media modules. Recommended
   for a production app; blocked for this fork until credentials exist.
2. **Raw BLE** — what Phase 0 targets: CoreBluetooth → the JSON command layer, with the
   Caps framing + GATT UUIDs as the open gap. The community docs name the characteristics
   (`IOS_WRITE_CHAR`, `IOS_NOTIFY_CHAR`, `IOS_MFI_PAIRING_CHAR`, …) but not their UUIDs.

## What's in the tree now

- `OpenGlasses/Sources/Services/Display/Rokid/RokidCommand.swift` — JSON command model,
  interim wire codec, documented (`tts`) and reconstructed (`notification`, `customView`,
  `clearCustomView`) primitives.
- `OpenGlasses/Sources/Services/Display/Rokid/RokidScreenRenderer.swift` —
  `HUDScreen`/content → commands, with the reconstructed `Ntf`/`Custom_View` param shapes.
- `OpenGlasses/Sources/Services/Display/Rokid/RokidDisplayBackend.swift` —
  `GlassesDisplayBackend` conformance, `RokidTransporting` seam, `Config` keys
  (`rokidPeripheralID`, `rokidPairingConfigured`).
- `OpenGlasses/Sources/Services/Display/Rokid/RokidBLETransport.swift` — CoreBluetooth
  skeleton (ships dark).
- `OpenGlassesTests/RokidDisplayBackendTests.swift` — command/renderer/backend tests over
  a mock transport.
- `OpenGlasses/Sources/Services/Camera/Rokid/RokidCameraBackend.swift` — `CameraBackendChoice`,
  `Config.cameraBackend`, `RokidCameraTransporting` seam, the dark `RokidCameraTransport`
  placeholder, and `RokidCameraBackend: GlassesCameraBackend`.
- `OpenGlassesTests/RokidCameraBackendTests.swift` — camera-backend tests over a mock
  transport.

Display selection: **Settings → Display Backend → "Rokid RV101"**. Camera selection is
`Config.cameraBackend` (`CameraBackendChoice`), read once at `CameraService` init — a change
takes effect on next launch (unlike display, which switches live). XcodeGen globs
`OpenGlasses/Sources` and `OpenGlassesTests`, so no project file edit is needed — run
`./Scripts/generate-xcodeproj.sh` after adding these files.

## Camera & microphone

The camera path is **not** BLE: BLE carries control only, and a single still is far too
large for a GATT write. `RokidCameraBackend` therefore declares the honest capability set —
`liveFrames: false`, `stillCapture: true` with `stillLatency: .seconds`, `hardwareEvents:
false` — and `CameraFeatureGate` turns that into user-readable answers ("Live Preview needs
a live camera feed …", "Captures … take several seconds"). Still captures degrade to the
iPhone camera until a real transport lands.

- **Still capture** (`Med`): send a capture command, fetch the JPEG over the glasses'
  network path. Ships dark in `RokidCameraTransporting.captureStill()`.
- **Live frames** (`Ai`/`ARTC`): out of scope until a network ingest exists — the app's
  whole vision stack is built on `CameraService.framePublisher`, which only a real frame
  transport can feed.
- **Microphone** (8-mic array): **deferred**. There is no `GlassesMicrophoneBackend` seam to
  mirror — the app's mic input is AVAudioSession/phone-centric (`AudioCapture/*`,
  `ASR/SenseVoiceRecognizer`), and the glasses' mic audio (over `Ai`/`ARTC`) is a different
  transport again. The honest next slice is display → camera → a dedicated audio-source
  abstraction, in that order.

`concurrentWithMic: true` is an assumption (QCS6490 has both an 8-mic array and a camera;
mutual exclusivity has not been confirmed on the Rokid SDK) and is flagged as unverified.

## Open gaps (Phase 1 — needs hardware + one decision)

1. **Channel**: confirm raw BLE is reachable on the user's RV101, versus the Rokid SDK
   being mandatory (iOS partner access).
2. **Caps framing**: recover the binary serialization from a BLE capture of the Rokid app.
3. **GATT UUIDs**: the concrete service/characteristic UUIDs for the write/notify paths
   (currently placeholders in `RokidBLETransport`).
4. **Auth handshake**: any app-level handshake after connect (the EVEN G2 has a 7-packet
   one; Rokid likely does too).
5. **Param schemas**: validate the reconstructed `Ntf` / `Custom_View` / `Nav` key and
   param shapes against what the device accepts.
6. **Camera still-fetch / live-frame ingest**: the `Med` capture + network fetch, and the
   WiFi path that would feed `CameraService.framePublisher` for `Ai`/`ARTC` live frames.
7. **Microphone audio**: a dedicated audio-source abstraction for the 8-mic array (deferred;
   see "Camera & microphone").

## Honesty note

Everything above the transport is deterministic and unit-tested; the Bluetooth/network edge
is community-reconstructed and inert until a paired device exists. Until the gaps close, the
Rokid paths carry the same "early / not yet hardware-validated" state the EVEN G2 backend
ships with — by design.
