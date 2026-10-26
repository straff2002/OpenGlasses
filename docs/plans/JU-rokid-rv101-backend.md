# Plan JU — Rokid RV101 Glasses Backend

**Status:** 🚧 Phase 0 built 2026-10-26 from an outside contribution — every layer that can be
finished without hardware, with the Bluetooth/MFi edge shipped dark. Hardware validation (Phase 1)
is owed and needs a Rokid RV101 in hand. **Held, not merged (owner, 2026-10-26):** the branch waits
for Rokid's answer on developer access and MFi registration, so an App Store review never meets a
Rokid option that does nothing.

**Design added 2026-10-26 (no code):** three routes to the Rokid display, including an on-glasses
AIUI agent with the phone as a Bluetooth LE peripheral, which needs no MFi; and a shared on-glasses
HUD format, promoted from Plan BP's `WebHUDPayload`, for Meta's Web App surface and Rokid alike.

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

## Three routes to the Rokid display

Added 2026-10-26, design only — nothing below is built.

| Route | What draws the HUD | Needs from Rokid | Needs from Apple |
| --- | --- | --- | --- |
| **A. Reconstructed CXR** (Phase 0) | the phone, through Rokid's command protocol | MFi registration of this bundle ID | the MFi protocol in `Info.plist` (App Review checks the registration) |
| **B. Official iOS SDK** | the phone, through Rokid's SDK | SDK access, app keys, licence; maybe MFi registration | depends on the SDK's transport |
| **C. On-glasses agent** | an Avenkin agent running on the glasses | Agent Store review of the agent | a Bluetooth LE peripheral background mode — no MFi |

Route A is what Phase 0 built, and it is blocked on MFi. Route B depends on what Rokid offers.
Route C is the one we can design and test now, and it needs nothing from Apple's MFi programme.

### Route C — an AIUI agent on the glasses, the phone as a Bluetooth LE peripheral

**What AIUI is.** Rokid's platform for agents that run on the glasses in Rokid's own runtime
(QuickJS and Skia), written in JavaScript with WeChat-style WXML/WXSS markup and published through
the Hi Rokid Agent Store after Rokid's review. Its documentation names no iOS SDK, phone companion
API, MFi or app keys. LAN networking is marked unsupported. What it does offer is a Bluetooth LE
**central** API in the Web Bluetooth shape — `navigator.bluetooth.requestDevice`/`scanDevices`,
`device.gatt.connect()`, `getPrimaryService`/`getCharacteristic`, and
`characteristic.startNotifications()` — plus cards, lists, buttons, tables and a canvas to draw
with, and a desktop web simulator for debugging without the glasses.

**The shape.** The phone advertises one Avenkin GATT service (`CBPeripheralManager`). A small
Avenkin agent on the glasses scans for that service, connects, subscribes, and renders whatever HUD
payload the phone sends. The phone stays the brain — model, memory, tools, consent and voice loop
are unchanged; the agent is a display and a button panel, nothing more.

- **Phone → glasses: screens.** One notify characteristic carries the shared HUD payload (below),
  framed because a payload can exceed one notification: each frame carries a sequence number, the
  frame count and its index, and the agent reassembles by sequence and drops an incomplete one. The
  `renderKey` already in the payload lets the agent skip a screen it is already showing.
- **Glasses → phone: selections.** A write characteristic carries `{renderKey, itemId}` when the
  wearer picks an item; a `renderKey` that no longer matches the current screen is ignored, so a
  late tap cannot act on a screen that has changed. AIUI's documentation shows no explicit write
  call — if writes turn out to be unavailable, selection falls back to the voice grammar ("one",
  "two") that `selectItem(index:)` already serves, and the route still works as a display.
- **Hello.** On connect the agent writes a capabilities record: renderer name and payload version,
  screen size, colour (Rokid is monochrome per its design guide), and input kind. The phone
  condenses to it as it already does for the other backends. Without writes, the phone assumes the
  RV101's known values for a connected Rokid agent, and the agent refuses a payload version it
  does not understand rather than drawing a guess.

**Constraints the design must meet.**

1. **The link is private by default.** HUD screens can carry answers, notes and job details. Every
   characteristic requires an encrypted, bonded link; if AIUI's runtime cannot bond, the route ships
   with a one-time pairing code shown on the phone and entered on the glasses, and stays off when
   HIPAA mode is on, as the Web App mirror does.
2. **Discovery happens in the foreground.** A backgrounded iOS peripheral moves its service UUID
   into Apple's overflow area, which a non-Apple central generally cannot see, so the first
   connection is made with the app open; an established connection continues in the background
   under the `bluetooth-peripheral` mode. That background mode is a new `Info.plist` entry and needs
   its App Review justification written at the same time.
3. **Off unless chosen.** The peripheral never advertises unless Rokid is the chosen display and the
   agent is paired, so a Meta wearer's phone never broadcasts an Avenkin service.
4. **The agent is ours and small.** Its source lives in this repository (a `glasses-agents/rokid/`
   folder), renders only the shared payload, makes no network calls of its own, and is reviewed
   against the same privacy rules as the app.

## The shared on-glasses HUD format

Two kinds of display backend exist or are planned:

- **Driven** — the phone draws through a vendor protocol: Meta's native display SDK, EVEN G2 over
  Bluetooth, Rokid Route A or B. Each needs its own renderer and transport, and keeps it.
- **Hosted** — software on the glasses draws, and the phone only sends a description of the screen:
  Meta's Web App surface (Plan [BP](BP-web-hud-mirror.md), shipped as a mirror) and Rokid Route C.

Hosted renderers should share **one wire format** rather than each inventing one, so the next pair
of glasses with an app platform gets a renderer and a transport and nothing else.

**The format is `WebHUDPayload`, promoted.** It already exists as BP's `Codable` wire form of a
`HUDScreen` — `title`, `lines` (`text`, `icon`, `emphasis`), `items` (`id`, `label`, `style`) and
`renderKey` — with stable wire names. Promoting it means:

- a top-level `version`, so a renderer can refuse a payload newer than it understands instead of
  guessing;
- renaming it for what it is (for example `GlassesHUDPayload`) with BP's HTML renderer as its first
  consumer and the Rokid agent as its second;
- golden JSON fixtures in the repo that both the Swift tests and the agent's own tests read, so the
  two ends cannot drift;
- the selection record (`renderKey`, `itemId`) and the capabilities record defined beside it, so
  every hosted renderer answers the same way.

**One hosted backend, many transports.** Today BP's mirror is deliberately *not* a
`GlassesDisplayBackend`: it copies whatever the real backend shows. With two hosted renderers, a
single hosted backend makes sense — a `GlassesDisplayBackend` that turns screens into the shared
payload and hands them to a transport: BP's existing HTTP server for Meta's Web App, a Bluetooth LE
peripheral for Rokid. Selections coming back make hosted screens interactive, which a mirror is not.
BP's mirror mode stays available; reversing its "not a backend" decision is listed below for the
owner.

## Route C phases (not scheduled)

- **C0 — shared payload, headless.** Version the payload, add the selection and capabilities
  records, the frame codec (split, reassemble, drop incomplete, ignore stale `renderKey`), and the
  golden fixtures. Pure and testable without hardware, like every other Phase 0 here.
- **C1 — phone peripheral, dark.** The `CBPeripheralManager` transport behind a Developer switch,
  off by default, with the hosted backend over it; the background mode and its review note.
- **C2 — the agent.** The AIUI agent in `glasses-agents/rokid/`, rendering the fixtures in Rokid's
  desktop simulator first — the hardware-free loop — then on the glasses.
- **C3 — on the glasses and in the store.** Pairing, background reconnect, battery and legibility
  on a real RV101; then Agent Store submission. Rokid joins onboarding when C3 passes.

**To confirm before C1:** whether AIUI's Bluetooth API can write; whether it bonds; how an agent is
launched and whether it keeps running while the wearer does something else; the notification size
it receives; and the Agent Store's terms.

## Decisions owed

- **Rokid developer access (owner signing up, 2026-10-26).** MFi approval is per app: Rokid is an
  MFi licensee and registered its own app, but it has not registered this one, and only the
  accessory maker can. Ask Rokid for (1) its iOS SDK and app keys for this bundle ID, (2) MFi
  registration of the bundle ID for `com.rokid.aiglasses` if that SDK or our transport uses it,
  and (3) the SDK's licence and what it sends home by default. A community iOS app integrates a
  Rokid iOS SDK (`RGCxrClient`) with custom-view calls; if it is real and licensable, it replaces
  the reconstructed transport as Phase 1 and lifts the text-overlay-only display limit. Its
  telemetry is reviewed and disabled or disclosed in the same PR (the rule for any new SDK), and it
  needs an xcframework or SwiftPM wrapper, since the project does not use CocoaPods.
- Failing that, whether to keep Rokid support to the BLE path and the Bluetooth-headset voice
  loop.
- Whether Rokid appears in the public Display Backend picker before Phase 1, as EVEN G2 does, or
  moves under Developer with the camera switch.
- **Which Rokid route leads.** Route C needs nothing from Apple's MFi programme and can start with
  C0 today; Route A waits on MFi registration; Route B waits on what Rokid offers.
- **Reversing Plan BP's "the mirror is not a backend" decision** so Meta's Web App and Rokid share
  one hosted backend with selections. BP's mirror mode would remain.
- **Publishing an Avenkin agent in Rokid's Agent Store** — under whose account, and on what terms.
