# Plan JU — Rokid RV101 Glasses Backend

**Status:** 🚧 Phase 0 built 2026-10-26 from an outside contribution — every layer that can be
finished without hardware, with the Bluetooth/MFi edge shipped dark. Hardware validation (Phase 1)
is owed and needs a Rokid RV101 in hand. **Held, not merged (owner, 2026-10-26):** the branch waits
for a working Rokid route — now CXR-L, once the developer account's scopes and app name are agreed —
so an App Store review never meets a Rokid option that does nothing.

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
| **B. CXR-L, Rokid's phone SDK** | the phone, through a Custom View on the glasses | the `scopes` and `appName` agreed with Rokid's open platform; the SDK licence | a URL scheme and `rokidai` query in `Info.plist`, and `bluetooth-central` (already declared) — **no MFi** |
| **C. On-glasses agent** | an Avenkin agent running on the glasses | Agent Store review of the agent | a Bluetooth LE peripheral background mode — no MFi |

**The target is wearers outside mainland China (owner, 2026-10-26)** — that is what the contributor
is doing with their glasses. That sets the order:

1. **Route B leads, and it is real.** Rokid's CXR-L SDK has an iOS build, works with Hi Rokid
   outside mainland China, and needs no MFi accessory protocol. It reaches any wearer the App Store
   reaches. See "Route B — CXR-L" below.
2. **Route A is superseded unless B fails.** Phase 0's seams, codec and tests stay — they are what
   a CXR-L backend plugs into — but the reconstructed transport waits on MFi registration that
   Route B does not need.
3. **Route C is the fallback.** It needs nothing from Apple's MFi programme, but it reaches wearers
   only through Rokid's Agent Store, whose documentation mentions only users in mainland China.
   The command-line install puts the agent on a developer's own glasses, not a customer's. C moves
   up only if Rokid confirms the store reaches wearers elsewhere.

### Route B — CXR-L, Rokid's phone SDK (docs checked 2026-10-26)

From Rokid's open platform (`open.rokid.com`, SDK section → CXR-L, docs version 1.0.4):

- **What it is.** "The CXR-L SDK runs on the mobile phone. It works with Rokid Glasses and the
  Rokid AI App (or Hi Rokid)" — Rokid AI App in mainland China, **Hi Rokid overseas**. The same
  model as Meta's: the wearer authorises our app in Rokid's app once, and our app then talks to the
  glasses itself.
- **iOS.** CocoaPods `RGCxrClient` 1.0.4 with `RGCoreKit`, iOS 13+, an `ios_cxr_l_sample` project.
  `CxrClient.shared` with Combine publishers throughout.
- **`Info.plist`.** A URL scheme for the authorisation callback (forwarded to
  `CxrClient.shared.handleOpenURL`), `rokidai` in `LSApplicationQueriesSchemes`, `bluetooth-central`
  in `UIBackgroundModes` and the Bluetooth usage strings. **No `UISupportedExternalAccessoryProtocols`
  entry** — so App Review's MFi question does not arise on this route.
- **Authorisation.** `client.auth.authenticate(scopes:appName:completion:)` returns a token;
  "scopes and appName must follow what you agreed with the Rokid open platform" — this is the part
  the developer account is for. `statePublisher` reports expiry and logout.
- **Sessions.** `CustomView` (the phone sends a layout) or `CustomApp` (the phone installs and
  starts an Android APK on the glasses, built with the glasses-side CXR-S SDK, and exchanges custom
  commands with it). Nothing works until the "scene is built": for a Custom View, until it is open
  on the glasses.
- **Display.** `sendCustomViewIcons`, `openCustomView`, `updateCustomView` (only changed nodes),
  `closeCustomView`, `customViewRunningEventPublisher`. The layout is JSON with Android-style views —
  `LinearLayout`, `RelativeLayout`, `TextView`, `ImageView` — so a real HUD, not the text overlay
  Route A was limited to.
- **Camera.** `takePhotoWithData(width:height:quality:callback:)` returns JPEG `Data` — a direct fit
  for `GlassesCameraBackend.capturePhoto()`. Stills only; no live frames, as Phase 0 declared.
- **Audio.** `startRecord(_:codec:mode:)` / `stopRecord(_:)` with `audioEventPublisher`, and audio can
  be pushed to the glasses to play. That fills the native-audio gap in `RokidMicrophoneBackend`.
- **Device control.** Brightness and volume, 0–15, as soon as the link is up.
- **The catch: photo and audio need the Custom View open.** The capability matrix allows audio and
  photo only once a Custom View (or Custom App) is running, so the camera works while our HUD is
  showing. The backend opens a minimal Custom View before a capture if none is open.

**Fit with Phase 0.** A `CXRLDisplayBackend` renders `HUDScreen` to Custom View JSON — a driven
renderer like EVEN's — and `RokidCameraBackend` / `RokidMicrophoneBackend` get a CXR-L transport
behind the seams they already have. Their capability declarations hold; the stubs become real.

**Before adopting it** (the rule for any new SDK): read the SDK licence; review what it sends home
by default and disable or disclose it in `PrivacyInfo.xcprivacy` and the in-app privacy copy in the
same PR; pin it exactly; and package it for SwiftPM (an xcframework in a binary target), since the
project does not use CocoaPods. Confirm that Hi Rokid on iOS answers the `rokidai` scheme — the iOS
pages name only Rokid AI App — and whether Custom Commands need a glasses-side APK we would have
to build and ship (only if a Custom View is not enough).

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
- **Glasses → phone: selections, by voice first.** AIUI documents no Bluetooth write (see below),
  so the design does not depend on one. Items are numbered on the glasses and chosen with the voice
  grammar ("one", "two") that `selectItem(index:)` already serves. If a write turns out to exist,
  a write characteristic carries `{renderKey, itemId}` for taps, and a `renderKey` that no longer
  matches the current screen is ignored, so a late tap cannot act on a screen that has changed.
- **Capabilities, assumed until the agent can say.** Without a write, the agent cannot tell the
  phone what it can draw, so the phone uses the RV101's documented values for a connected Rokid
  agent: a 480 px wide canvas 120–352 px tall, one green channel over black, numbered items. The
  agent refuses a payload version it does not understand rather than drawing a guess. With a write,
  the agent sends the capabilities record on connect instead.

**Constraints the design must meet.**

1. **The payload is private even if the link is not.** HUD screens can carry answers, notes and
   job details, and AIUI documents neither bonding nor a write, so the phone cannot rely on an
   encrypted link or check who subscribed. Instead every payload is encrypted end to end: at pairing
   the phone shows a one-time code that the wearer enters in the agent once, both ends derive a key
   from it, and the phone encrypts each payload (AES-GCM) for the agent to decrypt with Web Crypto,
   which AIUI provides. Any other device that subscribes gets ciphertext. The route stays off when
   HIPAA mode is on, as the Web App mirror does. How comfortable that one-time code is to enter on
   the glasses is checked in C2.
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
5. **The HUD shows only while the agent is open.** AIUI runs an agent only while one of its pages
   or widgets is open; background running is reserved and unsupported. So Route C is a HUD the
   wearer opens, not one that wakes itself — unlike Meta's native display. Whether a widget can stay
   on the glasses and keep the connection is the first thing C2 checks; until then the phone treats
   a dropped subscription as the agent closing, and goes back to speaking its answers.

### What Rokid's AIUI documentation says (checked 2026-10-26)

| Question | Answer in the docs |
| --- | --- |
| Can the agent read the phone's screens? | **Yes.** Bluetooth LE client in the Web Bluetooth shape: `requestDevice`/`scanDevices` filtered by service UUID, `gatt.connect()`, `getPrimaryService`, `getCharacteristic`, `startNotifications()` and `characteristicvaluechanged`. Scanning and first connection need the page to be open and the wearer able to interact. |
| Can it write back? | **Not documented.** The API page and reference show no `writeValue`, `writeValueWithResponse`, `writeValueWithoutResponse` or `readValue`. Treated as unavailable. |
| Bonding or encryption? | **Not documented.** Hence constraint 1. |
| Message size (MTU)? | **Not documented.** The frame codec does not assume one. |
| Does it run in the background? | **No.** Agent Workers run with the `instant` or `foreground` lifetime, `foreground` only "while the current agent has an open Page or Widget"; the `background` lifetime is "reserved and is not supported in the current release". Workers cannot draw, and the only trigger is `open`. Hence constraint 5. |
| What happens when the page is hidden? | **Not documented.** `onHide` fires when a page is "moved to the background"; nothing says whether timers or connections survive. |
| The screen? | A 480 px wide canvas, 120–352 px tall, scrolling past that; one green channel (`#40ff5e`) over black, black being see-through; type from 11 to 24 px; errors stay green. Applies to Rokid Glasses 1 and 2. |
| Installing without the store? | **Yes, for development:** `npm install -g @yodaos-pkg/aix-cli` (Node 20+ and ADB), then `aix install` and `aix launch-page` with debugging allowed on the glasses. Whether that install persists, or can be shared with a few wearers, is not documented. |
| The Agent Store? | Review is about minimum necessary permissions, a description that matches the code, and an agent that starts, responds and returns normally; 3–5 preview files with at least one image and one video. The page mentions only users in mainland China; availability elsewhere, account type, fees and the developer agreement are not stated. |

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

**To confirm before C1** (the docs leave these open — ask Rokid or test with the CLI install):
whether the Bluetooth API can write after all; whether it bonds; whether a widget can stay open and
hold the connection; whether a connection survives `onHide`; the notification size; whether the
Agent Store reaches wearers outside mainland China, and under what agreement.

## Decisions owed

- **Rokid developer access (owner signed up, 2026-10-26; Route B's SDK found the same day).** MFi approval is per app: Rokid is an
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
- ~~Which Rokid route leads~~ — **decided 2026-10-26:** B (CXR-L), with A only if B fails and C as
  the fallback, because the target is wearers outside mainland China (see "Three routes"). C0, the
  shared payload, is still worth building for Meta's Web App surface on its own.
- **The CXR-L `scopes` and `appName`** to agree with Rokid's open platform under the new developer
  account, plus the SDK licence and its default telemetry.
- **Reversing Plan BP's "the mirror is not a backend" decision** so Meta's Web App and Rokid share
  one hosted backend with selections. BP's mirror mode would remain.
- **Publishing an Avenkin agent in Rokid's Agent Store** — under whose account, and on what terms.
