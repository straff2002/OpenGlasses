# Rokid RV101 (Rokid Glasses) — Integration Notes

Status: **Phase 0 shipped** — deterministic command layer + renderer + backend + a
CoreBluetooth skeleton, all unit-tested. The Bluetooth edge ships dark (see "Open gaps").
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
- `Med` / `Ai` / `ARTC` — camera and real-time audio/video (separate services; out of
  scope for the display backend).

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

Display selection: **Settings → Display Backend → "Rokid RV101"**. XcodeGen globs
`OpenGlasses/Sources` and `OpenGlassesTests`, so no project file edit is needed — run
`./Scripts/generate-xcodeproj.sh` after adding these files.

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

## Honesty note

Everything above the transport is deterministic and unit-tested; the Bluetooth edge is
community-reconstructed and inert until a paired device exists. Until gaps 1–5 close, the
Rokid display path carries the same "early / not yet hardware-validated" state the EVEN G2
backend ships with — by design.
