# Rokid RV101 (Rokid Glasses) — Integration Notes

Status: **Phase 0 shipped** — display, camera and microphone seams (deterministic command
layer, renderer, `GlassesDisplayBackend` / `GlassesCameraBackend` conformances, a
`GlassesMicrophoneBackend` contract with an honest two-path capability set, CoreBluetooth
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

## Authoritative protocol (CXR-M SDK 1.0.8, decompiled)

`buildwithfenna/rokid-docs` (MIT) decompiles `com.rokid.cxr:client-m` **1.0.8**, built
2026-02-02 — the current SDK, not the 2019 pod. It settles the protocol shape.

**Transport — two Bluetooth layers on Android.** (1) BLE GATT is used only to discover the
device and *read a characteristic whose value is the RFCOMM socket UUID*; (2) a classic
Bluetooth **RFCOMM socket** then carries the `CXRSocketProtocol` stream. That split is why
an iOS port is not a recompile: iOS exposes no public RFCOMM API, so the iOS channel has to
carry the same stream over BLE GATT or MFi iAP2 instead of a socket.

**Frame layer (`CXRSocketProtocol`, native JNI).** `request(reqId, cmd, Caps)` /
`send(cmd, Caps, byte[])`; callbacks `onResponse(reqId, Caps)`, `onNotify(cmd, Caps)`,
`onReceived(cmd, Caps, byte[])`, `onAudioStream`, `onARTCFrame(byte[])`, `onDisconnect`.
Protocol version 4. The outer frame header lives in `libcxr-sock-proto-jni`, so it is not
derivable from the decompiled Java.

**Payload (`Caps`)** — ordered typed tuple, serialized natively. Types `V` void, `i` int32,
`u` uint32, `l` int64, `k` uint64, `f` float, `d` double, `S` string, `B` binary, `O` nested
Caps. A message is `[0]` command string, `[1]` optional JSON payload.

**Channels and commands:**

| channel | commands |
| --- | --- |
| `Dev` | `Dev_TimeUpdate`, `Dev_GetGlassInfo`, `Dev_GlassBrightness`, `Dev_GlassSound` |
| `Ai` | `Ai_Start`, `Ai_Heartbeat`, `ASR_Result`/`_None`/`_End`/`_Error`, `TTS_Result`, `TTS_AudioFinished`, `Ai_OpenCamera`, `Ai_TakePhoto` (JSON `{width,height,quality}`), `Exit`, `NoNetwork`, `Ai_Error`, `Pic_UploadError` |
| `Med` | `UnSync_Count`, `Sync_Start`, `Med_Take_Photo_Url` |
| `Sys` | `WordTips_SetTvConfig`, `WordTips_AiContent`, `WordTips_SendData` |
| `Trans` | `Trans_SetTvConfig`, `Trans_Result` |
| `Settings` | `Settings_Update` (`settings_photo_*`, `settings_video_*`, `settings_screen_offTimeout`, …) |
| `ARTC` | `OnStop` |

**Pairing.** Reconnection verifies the serial number: AES/CBC/PKCS5, key = `clientSecret`
(dashes stripped), IV = its first 16 bytes, decrypting a stored `snEncryptContent` and
checking it contains the glasses `deviceId`. First pairing skips the check, then syncs time.

**Camera** is still-capture only: `Ai_TakePhoto` returns bytes via
`PhotoResultCallback.onPhotoResult(status, byte[])`, and `Med_Take_Photo_Url` returns a URL.
There is no live-frame channel; ARTC delivers frames solely as `onARTCFrame(byte[])`.

**Microphone.** `AudioController.setCommunicationDevice()` routes to the Bluetooth SCO
(glasses speaker/mic) — the HFP path this app already uses; the ARTC audio stream is a
separate, SDK-internal channel.

> **Correction to Phase 0.** `RokidCommand` currently emits the legacy
> `{"cmd","key","param"}` JSON, but the current CXR-M SDK speaks `Caps` tuples over the
> channels above — so the JSON wire will not be understood by CXR-M firmware. The seam,
> renderer and tests stay correct at the `GlassesDisplayBackend` level; only `RokidWireCodec`
> needs to become a Caps encoder, which requires the native frame header or an iOS SDK.

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
- `OpenGlasses/Sources/Services/Display/Rokid/RokidCXRProtocol.swift` — the authoritative
  CXR-M channel/command vocabulary and `Caps` type tags. Additive: the transport is not yet
  migrated to it.
- `OpenGlasses/Sources/Services/Display/Rokid/RokidCXRRenderer.swift` — `HUDScreen`/content →
  the documented `Sys/WordTips_*` text overlay, with items flattened to numbered lines.
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
- `OpenGlasses/Sources/Services/Microphone/GlassesMicrophoneBackend.swift` — the
  `GlassesMicrophoneBackend` contract and the honest `MicrophoneCapabilities` (native
  stream vs Bluetooth-headset route).
- `OpenGlasses/Sources/Services/Microphone/Rokid/RokidMicrophoneBackend.swift` —
  `RokidAudioTransporting` seam, the dark `RokidAudioTransport` placeholder, and
  `RokidMicrophoneBackend` (ARTC/`Ai` stream not implemented; HFP route reported as real).
- `OpenGlassesTests/RokidMicrophoneBackendTests.swift` — capability/availability/frame
  hand-off tests over a mock transport.

**Display limit.** CXR-M documents no custom-HUD, item or button API — only the
`Sys/WordTips_*` text overlay — so on Rokid a `HUDScreen` is flattened to a caption and
`GlassesDisplayBackend.onItemSelected` cannot be driven from the display. Items are shown
numbered but are not selectable.

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
- **Microphone** (8-mic array): two paths, and the seam now says which is which.
  - *Bluetooth headset — works today.* The glasses pair as an HFP headset and
    `AVAudioSession` routes the whole voice loop through them (wake word, transcription,
    LLM, tools, TTS) with no protocol code at all — exactly what `GlassesTier.audioOnly`
    describes, and `MicRoutePolicy.bluetoothMicPorts` is where the route is recognised.
  - *ARTC / `Ai` audio — not implemented.* The device's own microphone as framed audio
    inside CXRService. `RokidMicrophoneBackend` declares `streamsWearerAudio: false`,
    `liveStream: false`, `routesViaBluetoothHFP: true`, so no caller can believe a native
    stream exists; `startCapture()` throws `.streamUnavailable` rather than opening a
    microphone that would never deliver. The frame contract is in place for when the
    envelope is captured: `onAudioFrame` carries encoded frames exactly as the vendor
    protocol puts them on the wire, described by `MicrophoneCapabilities.encoding`
    (Opus, 16 kHz mono, ~20 ms — the shape Meta's capture protocol documents on opcode
    `0x59`).

Note the existing `CaptureAudioRouter` is a *phone-mic* source router (the listener's shared
tap vs a standalone engine); it has no glasses-stream source, and the Meta
`microphoneAudio` notification is likewise modelled but not consumed anywhere. Decoding
Opus and adding a third source to `AudioSourceArbiter` is the follow-on once real bytes
exist.

`concurrentWithMic: true` is an assumption (QCS6490 has both an 8-mic array and a camera;
mutual exclusivity has not been confirmed on the Rokid SDK) and is flagged as unverified.

## Recovered from the device (live, 2026-10-22)

Read directly off the user's retail RV101 over `adb` (serial `1901092546045016`), so these are
observations rather than reconstruction:

- **Identity**: model `RG-glasses`, Android 12 / SDK 32, build `SKQ1.240613.001`, firmware
  `1.27.009-20261014-150203`, manufacturer `Rokid`. Bluetooth adapter MAC
  `AC:86:D1:58:DE:59`, adapter name `Glasses_5016`.
- **GATT (closes gap 3)** — one service, `00009100-0000-1000-8000-00805F9B34FB`, with six
  characteristics in registration order:

  | UUID suffix | Name | Properties |
  | --- | --- | --- |
  | `9300` | `IOS_CONNECTION_CHAR` | READ |
  | `9301` | `RFCOMM_CONNECTION_CHAR` | READ |
  | `9201` | `IOS_WRITE_CHAR` | WRITE (0x08), permission WRITE |
  | `9202` | `IOS_NOTIFY_CHAR` | NOTIFY (0x10), permission READ |
  | `9203` | `IOS_MFI_PAIRING_CHAR` | reserved for the MFi path |
  | `9204` | `IOS_MFI_NOTIFY_CHAR` | reserved for the MFi path |

  The iOS transport pair is therefore **write `9201`, notify `9202`**, both under service
  `9100`.
- **`/system/etc/cxr-service.json`** — the phone-link config the glasses ship with:
  `mtu { android: 4096, iphone_gatt: 500, iphone_socket: 4080 }` (an iOS write must stay
  under 500 bytes), `gatt.notify_timeout: 600`, `artc.frame_queue_size: 12`, `cxrproto`
  buffers 4 MiB / 2 MiB, and the MFi protocols `com.rokid.aiglasses` (id 194) and
  `com.rokid.global.aiglasses` (id 195). `identification_information` lists
  `RG301 Rokid Glasses`, confirming the RV101's product id.
- **Live traffic**: `cxr-service` served `Sys` and `Dev` requests from a connected phone
  throughout (`recv Request: id … cmd Sys`, `sending ShortMessage notify`), and the assist
  server was pushing `Sys / WordTips_AllDevices` — the `WordTips` overlay really is the text
  path this backend renders to.
- **Not recoverable this way**: the `Caps` frame header. HCI snoop logging does not activate
  on this build (`mSnoopLogSettingAtEnable = empty` even with `bluetooth_hci_log=1` and
  `bluetooth.btsnooplogmode=full`, and the bugreport reports no logs in
  `/data/vendor/ssrdump/`). The envelope lives in the native `CXRProtocol` code
  (`libcxr_service_jni.so`, symbols intact), so it needs a native disassembly or an Apple
  PacketLogger capture.

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
7. **Microphone audio**: the ARTC/`Ai` frame encoding plus an Opus decode step, then a
   third source in `AudioSourceArbiter`/`CaptureAudioRouter`. The seam and the honest
   capability set exist; the Bluetooth-headset route needs nothing.

## Frame format, from the device's own service

Recovered from `libcxr_service_jni.so` on the glasses (arm64, 708,608 bytes) with Ghidra:

- **Control/session packets** (`ControlSessionPacket::parse`): magic `'@' '@'` in bytes 0–1,
  big-endian total length in 2–3, two bytes at 4–5 (type/sequence), then TLV entries from
  byte 6 — each entry is a big-endian length, a big-endian id, then `length − 4` bytes of body.
- **MFi/iAP2 link packets** (`NativeMFIModule::buildLinkSyncPacket`): `0xFF 0x5A`, length,
  type/sequence, body, and a trailing checksum byte equal to the two's complement of the sum
  of the preceding bytes.
- **Commands and replies over the active channel use neither envelope.**
  `CXRProtocol::handleReadPacket` appends bytes to a buffer and repeatedly calls
  `rokid::Caps::parse2`, which returns the number of bytes consumed. The payload is a
  self-delimiting `Caps` blob, which is why no length header appears in the SDK docs.
- The device config reports `mtu.iphone_gatt = 500` and `gatt.notify_timeout = 600`.

Still unknown: the `Caps` element encoding (type tag plus length prefixes). `Caps::serialize`
and `parse2` are JNI thunks in this library, so their bodies are not in it. That is the only
remaining blocker to a working write path, and a short PacketLogger capture closes it faster
than further static work.

## Honesty note

Everything above the transport is deterministic and unit-tested; the Bluetooth/network edge
is community-reconstructed and inert until a paired device exists. Until the gaps close, the
Rokid paths carry the same "early / not yet hardware-validated" state the EVEN G2 backend
ships with — by design.
