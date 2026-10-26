# Plan JU — Rokid RV101 Glasses Backend

**Status:** 🚧 Phase 0 built 2026-10-26 from an outside contribution — every layer that can be
finished without hardware, with the Bluetooth/MFi edge shipped dark. Hardware validation (Phase 1)
is owed and needs a Rokid RV101 in hand.

**Origin:** a contributor with a retail RV101 built a third backend on the seams Plan
[AH](even-display-backend.md) (display) and Plan [CQ](CQ-third-party-glasses-backends.md) (camera)
already ship, recovered the command encoding from their own glasses, and added a hardware probe.
This plan brings that work in and records what has to stay true while it is unproven.

The protocol notes live beside the code rather than here:
[`docs/rokid-rv101.md`](../rokid-rv101.md) (device, communication model, what is in the tree),
[`docs/rokid-caps-encoding.md`](../rokid-caps-encoding.md) (the recovered frame and Caps grammar)
and [`docs/rokid-hardware-validation.md`](../rokid-hardware-validation.md) (the checklist for the
first session with the glasses).

## Phase 0 — built (deterministic core, dark edge)

- **Display.** `RokidDisplayBackend: GlassesDisplayBackend` behind a `RokidTransporting` seam;
  `RokidCapsCodec` + `RokidIAP2Packet` re-encode 3,215 of 3,216 captured frames byte for byte;
  `RokidCXRRenderer` flattens a `HUDScreen` to the documented text overlay with numbered items,
  because the glasses expose no custom-HUD or button API. Picked in Settings → Display Backend,
  inert until glasses are paired there — the same state the EVEN G2 backend shipped in.
- **Camera.** `RokidCameraBackend: GlassesCameraBackend` declares the hardware truth —
  `liveFrames: false`, stills only and slow — so `CameraFeatureGate` explains what is unavailable.
  Its transport always reports unavailable, so captures fall back to the iPhone camera.
- **Microphone.** A `GlassesMicrophoneBackend` contract; the glasses already run the full voice
  loop as a Bluetooth headset, and the native audio stream is declared absent rather than stubbed.
- **Transports.** `RokidBLETransport` (the GATT bootstrap, real UUIDs) is the default;
  `RokidMFITransport` (an `EASession` — the channel the capture shows commands travel on) is
  selected only by the `rokidUsesMFI` default.

## Constraints that hold until Phase 1 says otherwise

1. **No Rokid protocol in the committed `Info.plist`.** iOS opens an `EASession` only for a
   protocol under `UISupportedExternalAccessoryProtocols`, and App Review rejects one the accessory
   maker has not registered the app for in Apple's MFi program. A hardware spike adds
   `com.rokid.aiglasses` and `com.rokid.global.aiglasses` locally and never commits them;
   `RokidAccessoryProtocolGuardTests` enforces it. Shipping the MFi path needs Rokid to register the
   app, which is a decision owed (below).
2. **Unproven switches stay out of the public settings.** The camera choice and the link probe sit
   in Settings → Advanced → Developer. Choosing the Rokid camera before its transport exists would
   only take the glasses camera away from a Ray-Ban wearer.
3. **No captures, serials, addresses or keys in the repo.** A capture carries the glasses'
   `deviceKey`, `deviceSecret` and `deviceSeed` in cleartext, so it is a credential. The docs keep
   the grammar and placeholders, never the contributor's device identifiers.
4. **Our own bytes.** The wire format is written here from observation; no vendor code is ported
   or linked (the same rule as CQ Track B).

## Phase 1 — hardware validation (owed)

Run `docs/rokid-hardware-validation.md` with the glasses: pair over BLE, try the MFi session with
the local plist edit, send `Dev_GetGlassInfo` from the probe, then a text overlay. Each step
records whether the transport, the session id rule and the overlay commands work.

**Onboarding waits for this phase.** Onboarding's Add a Device page offers Meta glasses only (EVEN G2
is not there either). Rokid joins it — as a glasses choice that leads to pairing — only once the
display path has worked on the glasses. Until then a Rokid wearer still gets the whole voice loop
with no setup, because the glasses pair as an ordinary Bluetooth headset.

## Phase 2 — camera stills and native audio (not scheduled)

The camera's still fetch travels the glasses' network path, not Bluetooth; native audio needs the
framed stream and an Opus decode. Both wait for Phase 1.

## Decisions owed

- Whether to approach Rokid to register the app for MFi (needed before the MFi path can ship), or
  to keep Rokid support to the BLE path and the Bluetooth-headset voice loop.
- Whether Rokid appears in the public Display Backend picker before Phase 1, as EVEN G2 does, or
  moves under Developer with the camera switch.
