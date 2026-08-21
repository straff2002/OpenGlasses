# Plan CQ — Third-Party Glasses Backends (camera seam + two device classes)

**Status:** 🚧 P0 + P1 built (2026-08-09) — the shared foundation, both fully headless.

**P0 ✅** `GlassesTier` + pure `GlassesTierPolicy` (most-capable-wins; "not connected" stays
distinct from "connected but limited"), widened `MicRoutePolicy.glassesNameMarkers` guarded by a
false-positive corpus, and a "Connected Glasses" section in Settings → Hardware & Privacy that
states the tier, what the camera can do, and which features are unavailable — instead of letting
the user find the limits one failure at a time.

**P1 ✅** `GlassesCameraBackend` seam. `MetaCameraBackend` is a pure extraction of the DAT half —
session/stream lifecycle, permission flow, stall detection, tiered recovery, idle teardown, retry
loops, comments and all — and `CameraService` keeps its public surface exactly, so none of the ~50
consuming files changed. `CameraCapabilities` + pure `CameraFeatureGate` turn a backend's limits
into copy a user can read; `startStreaming()` now refuses with that copy rather than failing
obscurely. Readiness is asked as `isReady(configuringIfNeeded:)` because the Meta backend
configures the SDK on demand to answer, and that prompts for Bluetooth — correct at a capture,
wrong from a view body.

**P4 ✅** the Track B protocol core, also headless: `CRC16Modbus` (written from the published
catalogue parameters, pinned by the catalogue's own check value), `CapturePacket` (six-byte header,
little-endian length and CRC, MTU chunking) and `CaptureFrameAssembler` — a *stateful stream*
reader, because fragmentation here is a property of the link with no fragment indices to key off,
so a write can carry half a frame, three frames, or a boundary in the middle. Resynchronisation is
tested as a first-class behaviour: a dropped write would otherwise leave a partial frame that never
completes and a channel dead for the session. `CaptureCommand`/`CaptureNotification` model **only**
the attested opcodes and payloads, with the known gaps named rather than guessed.
`CaptureControlReply` is built around the one real trap — several control sub-types execute while
their reply's status fields stay unpopulated, so "failed" and "we cannot tell" are distinct
outcomes, and the test that proves it carries a positive control (the same bytes on a
status-bearing sub-type *do* read as a failure).

**Ordering deviation, stated:** the plan puts Track A first and that recommendation stands on the
merits. It was not followed because there is no hardware, which blocks Track A's P2/P3 entirely
and makes adding a beta third-party SPM dependency unverifiable. P4 is the only remaining phase
that can be *finished* rather than started. It ships dark and dead — nothing constructs a
`CapturePacket` until P5 adds a transport.

Still unstarted: **A/P2, A/P3** (vendor SDK dependency + hardware), **B/P5, B/P6, B/P7** (hardware,
and P6/P7 additionally gated on the cellular experiment).

**Companion to:** Plan AH, which did this for the *display* half (`GlassesDisplayBackend`, EVEN G2
as the first second-renderer). This plan does it for the *camera* half, and generalises "which
glasses can OpenGlasses drive?" into a stated device-tier model.
**Shape:** P0 and P1 are shared foundations. Then two tracks — **Track A** a documented, MIT-licensed
vendor SDK; **Track B** a reconstructed OEM protocol on ~NZ$100 retail hardware. One PR per phase.

---

## Why this matters now

Two things landed at once. A ~NZ$100 OEM camera-glasses platform is on retail shelves under a dozen
brand names, with an AI service its own listing says expires **six months after activation** — a
dated, well-defined population of people with working camera glasses and no assistant. And a
developer-oriented camera-glasses vendor now ships an **MIT-licensed native iOS Bluetooth SDK** for
direct phone-to-glasses connection: no vendor cloud, no account, and critically **no permission
gate** of the kind that has blocked our own Meta on-glasses testing for months
(`reference_dat_glasses_gotchas`).

Between them they cover both ends of the market. What they have in common is the reason this plan
exists: neither can be supported today, because unlike the display half, the camera half of the app
has no backend seam at all.

## Hard scope limit (state up front, applies to BOTH classes)

**Neither device class delivers live camera frames to the app.**

- The documented-SDK class captures stills to a **webhook URL** and streams by *pushing* to a remote
  RTMP / SRT / WHIP ingest endpoint. The vendor documentation is explicit that the SDK does not
  expose local frame buffers or continuous camera access to the host app.
- The OEM class captures to **onboard storage**; the phone must then fetch. Over BLE you get a
  thumbnail on the order of a kilobyte — useless for OCR, labels, serial plates, or any of the
  dense-visual work Plans CN/BT/AD exist to serve. Full resolution means joining the glasses' own
  WiFi access point and pulling files over HTTP. That class additionally has **camera and microphone
  as mutually exclusive modes** — it cannot listen and look at the same time.

So on both, every `framePublisher` consumer is unavailable out of the box: face recognition, CK sign
language, BT reading companion, scene watcher, camera-sourced ambient captions, CE frame pinning,
BU/CC live modes, L WebRTC, RTMP broadcast, video recording, CP's outbound relay.

The difference is that on the documented-SDK class there is a **credible route back** — see P3 — and
on the OEM class there is only an unverified one. That asymmetry drives the ordering.

| | Documented-SDK class | OEM capture-to-storage class |
|---|---|---|
| Voice loop, wake word, TTS, agent, text features | ✅ today, zero code (P0) | ✅ today, zero code (P0) |
| Still capture → vision tools | ✅ P2, sub-second with warm-up | 🟡 P6, seconds + network hop |
| Live frames → `framePublisher` | 🟡 P3 loopback spike — plausible | 🟡 P7 spike — unverified, may not exist |
| Button / touch / wear events | ✅ P2, richer than DAT | ❌ not exposed |
| Mic PCM into our ASR | ✅ P2 (16 kHz PCM or LC3 + VAD) | ❌ mode-exclusive with camera |
| Licence | MIT, actively maintained | none detectable — clean-room only |
| Entitlements / store paperwork | none | Hotspot Configuration |

## The blocking device experiment (Track B only)

**Do not start P6 before answering this.** When an iPhone joins the glasses' access point via
`NEHotspotConfiguration`, that network has no route to the internet. Does iOS keep cellular data
alive for our URLSession traffic, or does the app go dark until we leave the AP?

If it does not, every cloud-backed capture becomes join → download → leave → wait for reassociation
→ *then* call the model: a multi-second stall with a visible connectivity blip, on a device that
also cannot hear the user while its camera is engaged. At that point P6 is not worth building and
Track B stops at thumbnails.

Twenty minutes with hardware and a debug button. It gates most of Track B's cost.

---

## Shared foundation

### P0 — Audio-tier support (no protocol work at all) ✅

Our microphone and speaker path is not DAT-bound. `MicRoutePolicy` matches on
`AVAudioSession.Port` (`.bluetoothHFP` / `.bluetoothLE` / `.headsetMic`) and on port-name markers
(`MicRoutePolicy.swift:40`). Both device classes pair as ordinary Bluetooth headsets, so **both
already carry the full voice loop today** — wake word → transcription → LLM → tools → TTS. The only
reason it feels unsupported is cosmetic: the port name won't match `meta`/`ray-ban`/`oakley`, so the
app labels them "Headset Mic (AirPods etc.)" and the user has no reason to believe the glasses are
involved.

1. Widen `glassesNameMarkers` to cover both classes' naming, keeping the list data-only so it grows
   without a code change.
2. A `GlassesTier` descriptor (`audioOnly` / `displayOnly` / `camera`) surfaced in Settings, so the
   app says *"Connected as an audio device — camera features need a supported camera backend"*
   instead of failing feature by feature.
3. Settings + README copy: supported devices become a tier table, not a single product name.
4. Tests: marker matching, tier resolution.

Fully headless. An afternoon. **This is the highest value-per-hour in the plan by a wide margin.**

### P1 — `GlassesCameraBackend` seam ✅

The display half is backend-agnostic because Plan AH made it so. The camera half is not:
`CameraService` is a concrete `@MainActor class` importing `MWDATCamera` directly
(`CameraService.swift:14`), and ~50 files reach into it.

Two things keep this tractable. Consumers use only a narrow slice — `capturePhoto()`,
`framePublisher`, `latestFrame`, `isStreaming`, `startStreaming`/`stopStreaming` — and Plan CP is
already inserting `OutboundFrameRelay` between the publisher and every outbound consumer, so the
fan-out side has a single chokepoint by construction.

1. Extract `GlassesCameraBackend` with `MetaCameraBackend` as a **pure** extraction — DAT session
   and stream lifecycle, stall detection, recovery policy move wholesale; existing camera tests stay
   green untouched. Same discipline as `MetaDisplayBackend`.
2. `CameraCapabilities`: `liveFrames`, `stillCapture`, `stillLatency` (immediate / sub-second /
   seconds), `concurrentWithMic`, `hardwareEvents`. This is the type honest degradation hangs off,
   and the table above is its test fixture.
3. A pure capability gate consulted at feature entry points, so unsupported features grey out with a
   reason instead of throwing at the moment of use.
4. `CameraService` keeps its name and published properties; it becomes the backend-neutral
   coordinator, exactly as `GlassesDisplayService` did.

Fully headless. **Worth doing even if both tracks are abandoned** — it is what lets any future
camera device in (including Plan BA's Android DAT) without touching 50 call sites.

**As built**, three notes worth carrying forward:

- The backend talks to the coordinator over a single `CameraBackendEvent` stream rather than a
  set of callbacks, so all the `@Published` mirroring lands in one `handle(_:)`. `.frame(nil)`
  doubles as "invalidate the cache", which is how a torn-down session's last frame is stopped
  from standing in for the next capture.
- Readiness became `isReady(configuringIfNeeded:)`. A plain property was wrong: the Meta backend
  configures the SDK on demand in order to answer, and configuration prompts for Bluetooth — fine
  at a capture, not fine from the Settings view body that describes the connected device. UI
  passes `false` and takes a pessimistic answer.
- The seam paid for itself immediately in testability. The coordinator's routing rules — phone
  fallback, the refusal to silently swap cameras on a *ready* backend's failure, event mirroring,
  the streaming gate — are now unit-tested against a mock, where before they sat behind
  `Wearables`, which traps in a unit-test process.

---

## Track A — documented-SDK camera glasses (do this first)

The vendor ships `mentra-bluetooth-sdk-ios` via SwiftPM, MIT, iOS 15.1+, currently beta and actively
pushed. Direct BLE from our app to the glasses; no vendor app, cloud, or account in the path.

### P2 — Backend over the vendor SDK

The API surface is richer than DAT's in the places that matter to us:

- **Stills:** `requestPhoto(...)` with size tier, compression, and manual exposure/ISO;
  `warmUpCamera(...)` pre-opens the session (capped ~60 s) so a subsequent capture is fast.
  Delivery is by webhook — so we run a **loopback receiver**: a localhost HTTP endpoint on the phone,
  passed as the webhook URL, whose upload handler resolves the pending `capturePhoto()` continuation.
  That is the whole trick, and it makes this backend's `stillCapture` genuinely competitive with
  Meta's.
- **Microphone:** `mic_pcm` emits continuous 16 kHz / 16-bit / mono / signed-LE PCM — the exact
  shape our ASR path wants — with `mic_lc3` and VAD/loudness gating as alternatives. This is a
  better mic route than routing through `AVAudioSession`, and it is independent of the camera.
- **Hardware events:** `button_press` (with press type), `touch_event`, and `head_up` wear detection,
  delivered through `MentraBluetoothSDKDelegate`. These feed **Plan CH** (media-button trigger),
  **Plan W** (presence), and **Plan CM P1**'s doff-aware auto-pause — on hardware we can actually
  buy, without waiting on Meta's rollout.
- Battery, RSSI, WiFi/hotspot status, RGB LED, gallery mode, OTA.

Work: `MentraCameraBackend` conforming to P1's protocol; a pure `PhotoWebhookReceiver` (request
routing, multipart parse, continuation correlation, timeout) tested headlessly against synthetic
uploads; a warm-up policy (when to pre-open, when to let it lapse) as a pure core, wired to Plan BV's
`PowerPolicyService` so warm-up backs off under `conserve`/`reserve`; hardware-event bridging into
the existing trigger surfaces.

Capabilities declared: `liveFrames: false`, `stillCapture: true`, `stillLatency: .subSecond`,
`concurrentWithMic: true`, `hardwareEvents: true`.

Headless except the BLE edge and the on-device latency numbers. Ships dark behind backend selection,
same as EVEN.

### P3 — Live-frame loopback spike (the phase that decides how much of ❌ reopens)

`startStream(...)` pushes camera video to an RTMP, SRT, or **WHIP/WebRTC** ingest endpoint, with
keep-alive maintained by the SDK. Nothing says that endpoint has to be remote.

Point it at a receiver we run, and the frames come back to us. We are unusually well-placed to try
this: Plans L and M already built WebRTC transport, signalling, and `WebRTCStreamingService`, so a
WHIP ingest is closer to a rearrangement of existing parts than new infrastructure. Two candidate
shapes, in order of preference:

1. **On-device WHIP receiver** — glasses → phone directly over the local network. Lowest latency, no
   hosting, works offline. Highest uncertainty: whether the glasses can reach a phone-hosted ingest
   on the same network, and what the SDP/ICE path looks like when both peers are local.
2. **LAN or self-hosted relay** — glasses → relay → phone. Falls back on Plan M's existing
   deployment story; adds a hop and a dependency, but is a known quantity.

Deliverable is a decision with numbers, not a feature: achievable frame rate, end-to-end latency,
decode cost, thermal behaviour, and battery drain over ten minutes. If it lands, `liveFrames` flips
true for this backend and most of the ❌ column reopens through the existing `framePublisher` — with
CP's privacy relay already sitting in the right place. If it doesn't, we lose a spike and Track A
still ships as a strong stills-plus-events backend.

Hard timebox. Nothing downstream may assume the outcome.

---

## Track B — OEM capture-to-storage glasses (do this second, if at all)

Same hardware class as the retail ~NZ$100 glasses and most of the sub-$150 AliExpress camera
glasses, which are largely the same OEM platform rebadged.

### P4 — Capture-protocol core (pure) ✅

The BLE protocol has been reconstructed by the community. Framing is a one-byte sentinel, a command
id, a little-endian length, a CRC-16/MODBUS over the payload, then the payload; anything past the
ATT payload ceiling fragments. Commands cover mode selection (photo / video start-stop / audio
start-stop / AI capture), battery and charging state, media counts, time sync and version queries.
Completion arrives as a notification; a thumbnail can be pulled over the same channel.

All of it a pure codec with no CoreBluetooth in sight, mirroring `EvenPacket`:

1. `CapturePacket` encode/decode — framing, length, fragmentation, reassembly.
2. CRC-16/MODBUS implemented **from the published algorithm and validated against published test
   vectors** — no community bytes copied, per the licensing rider below.
3. Command enum and response parser, including the case where a response is structurally valid but
   the parser's allowlist doesn't populate the status fields — a known trap in this protocol family,
   where a command executes while the parsed reply still reads as its default error. Our parser must
   distinguish **failed** from **unparsed**; conflating them makes working commands look broken.
4. Golden fixtures for every command round-trip.

Fully headless.

**As built**, two departures from the sketch above worth recording:

- Reassembly is a **stateful stream reader** (`CaptureFrameAssembler`), not a
  `reassemble([Packet])`. The described format has no fragment index or continuation flag —
  fragmentation is just the MTU chopping a byte stream — so frames have to be recovered by
  buffering and rescanning. That made *resynchronisation* the interesting behaviour rather than
  an afterthought: a single dropped write leaves a partial frame that will never complete, and
  with no way out the channel is dead for the rest of the session. The assembler drops a byte and
  rescans, counts what it discarded so the cost is measurable, and caps its buffer.
- The command set models **only what is attested** and names the gaps in the type's own
  documentation instead of filling them: discrete photo/video/audio opcodes, media enumeration and
  time sync are absent, as is any command for *leaving* livestream mode. A guessed byte sent to a
  camera on someone's face is not a guess worth making, and an invented constant would read as
  fact to the next person.

### P5 — Transport + backend, shipping dark

`CaptureBLETransport` (CoreBluetooth, foreground-only v1, no state restoration — consistent with
`EvenBLETransport`'s decisions and the app's other lifecycle constraints), plus the
`GlassesCameraBackend` conformance mapping our calls onto P4's commands. Pairing UI beside the
existing EVEN pairing surface.

Ships dark. Every byte-level claim is a community reconstruction awaiting hardware validation, in
the same words Plan AH used for the same reason. `stillCapture` here means the **thumbnail** —
enough to prove the round trip, not enough to answer a question about what the user is looking at.

Capabilities declared: `liveFrames: false`, `stillCapture: true`, `stillLatency: .seconds`,
`concurrentWithMic: false`, `hardwareEvents: false`. That last pair is what the P1 gate exists for.

### P6 — Media transfer (gated on the device experiment above)

`NEHotspotConfiguration` join, candidate-IP probe, manifest fetch, concurrent HTTP file pull, rejoin.
Needs the **Hotspot Configuration entitlement** — real App Store paperwork and a new capability on
the App ID, which per `project_xcode_cloud_new_target_signing` is exactly the kind of change that
breaks the Xcode Cloud archive on signing until registered upstream. Budget for that, not just code.

The pure part worth isolating: an ordering policy guaranteeing we are back on a routable network
*before* any model call is attempted, and that a capture interrupted mid-transfer degrades to the
thumbnail rather than to nothing.

### P7 — RTSP live-preview spike (speculative, may not exist)

Traces of an RTSP-over-WiFi path exist in this hardware family — a BLE command entering a streaming
mode, then a standard RTSP URL on the device's own network. The reconstruction is explicitly
unverified at runtime, addressing differs per hardware variant, one variant's route is WiFi-Direct
which iOS does not expose at all, and there is **no confirmed command for leaving streaming mode
safely**. Run only if P6 came back green and a device is in hand. Expect nothing.

---

## Licensing rider

Two different regimes, and the plan must not blur them.

- **Track A** depends on a real MIT-licensed vendor SwiftPM package. Normal dependency hygiene
  applies: pin it exactly (per Plan CD P3's lesson — `from:` admits breaking minors, and this package
  is pre-1.0 *and* beta), refresh `ci_scripts/Package.resolved` per
  `project_xcode_cloud_resolved`, and attribute in About.
- **Track B** has no licensed source anywhere in the space — one community README claims a permissive
  licence its repository does not actually contain. Treat all of it as **documentation of a wire
  format, never as source to port.** Swift written from the described format, validated against
  independently published algorithm vectors, exactly as `EvenPacket` was. The vendor SDK for that
  platform is proprietary; we do not link, vendor, or wrap it.

## Non-goals

- Wrapping or shipping any proprietary vendor SDK binary.
- Supporting any vendor's own cloud AI, subscription, or account system.
- A generic "any BLE glasses" abstraction. Two concrete camera backends is the bar for generalising;
  a speculative third is not.
- Firmware modification, OTA-side work, or debug-mode unlocks on Track B hardware.
- Display support on either class — neither has a display. Track A's vendor sells display glasses
  too, but those route through a cloud SDK, which is a different plan.

## Open questions

1. **The Track B cellular experiment.** Gates P6 and P7.
2. **Does the loopback receiver in P2 survive backgrounding?** A localhost HTTP endpoint during a
   capture is fine in the foreground; the app's other lifecycle constraints say assume not otherwise.
   If it doesn't, `stillCapture` is foreground-only on Track A and the gate must say so.
3. Does Track B's thumbnail have any legitimate use? ~1 KB is hopeless for reading, but might carry a
   coarse scene classifier or a "did the capture frame the thing at all" check before paying for a
   full transfer. Measure before dismissing.
4. Given Track B's camera/mic exclusivity: does a capture duck the wake word for its duration, or
   refuse while a live conversation runs? Leaning duck-with-narration — silently going deaf is the
   failure mode users report as a crash.
5. Should P1's capability gate retro-fit the EVEN display backend's unavailable-feature list, which
   Plan AH documents but does not enforce in code? Probably yes; same mechanism.
6. Track A is **beta software** (pre-1.0, actively churning). Do we ship it user-visible, or keep it
   behind the developer panel until it stabilises? Leaning developer-panel first.

## Device landscape (why a tier model, not a device list)

Sorting the market by *what OpenGlasses needs from it* produces three tiers, and nearly every device
on sale falls cleanly into one:

| Tier | Needs from us | Cost to support |
|---|---|---|
| **Audio-only** | nothing — already works | **zero** (P0 is labelling) |
| **Display** | a `GlassesDisplayBackend` | seam exists (Plan AH); per-device protocol work |
| **Camera** | a `GlassesCameraBackend` | **seam does not exist — that is P1** |

Two observations that shape the effort:

- **Live frames to a phone are the line between ~$100 and ~$300+ hardware**, and even above it the
  vendor answer is "push to an ingest endpoint", not "here are your buffers". Power, thermals and
  bandwidth make it genuinely hard. We should stop expecting to find local frame access on anything
  but Meta, and design the app to degrade honestly instead — which is precisely what P1 buys.
- **The cheap end is one OEM platform wearing many badges.** Supporting Track B supports most of the
  sub-$150 camera-glasses market at once. That is the argument for Track B despite everything above:
  not one product, a category.

## Rider — a cheaper unlock than either track

Plan AH's `EvenBLETransport` ships dark with its **auth handshake stubbed pending capture logs**. A
community reconstruction of that handshake — seven packets, reported working — now exists
independently of us. That is the single blocker between Plan AH step 5 and our HUD rendering on real
shipping hardware. Same Track B licensing rider applies. It is cheaper than anything here and should
be scheduled ahead of both tracks.
