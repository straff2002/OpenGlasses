# Plan BA — Android Port (full roadmap to platform parity)

**Strategic fit:** OpenGlasses today is an iOS-only app for Ray-Ban Meta / Oakley Meta glasses. Meta now
ships an **official Android Device Access Toolkit** — so the one thing that would normally make a
smart-glasses port impossible (proprietary device access) is solved for the *camera/session* half by a
first-party SDK we already depend on the iOS twin of. **Honest header (corrected 2026-07-10): the
Android DAT is v0.3.0 with NO Display module** — "Display from v0.7" was the *iOS* SDK line; the HUD
half of the product is an open risk gating Phase 4, not a solved problem (see the contingency below).
Android is the larger global handset base and the larger Ray-Ban Meta owner base outside the US. This
plan is the route from "iOS app" to "second first-class native app at feature parity."

**Effort (corrected 2026-07-10 — the original headline contradicted its own phase table):** Large — a
platform reimplementation. The phases sum to **~21–30 weeks serial ≈ 5–7 engineer-months to full
parity** (the earlier "3–6" low end is unsupported); the cloud-only MVP (Phases 0–3) sums to
**7–10 weeks**, not 3–5, unless >1 engineer is staffed (state it if so). 6 months is the credible
floor: the iOS app reached its current 517-file / 85k-line shape in ~6 months of 536 commits with the
design cost already paid — and the port's target moves at ~200 commits/month.

**Status:** 📝 Drafted — not scheduled; **revised 2026-07-10 after a code-verified review.** This is a
*parent roadmap*; each phase below is its own milestone (and likely its own repo/PR stream), not a
single PR. House style still holds **within** each phase: deterministic, headless-testable core first;
live/device/backend edge deferred.

## Revision 2026-07-10 — drift control, parity cut, and contracts (binding on all phases)

1. **Parity ledger + freeze tag.** "iOS as the executable spec" is already stale 9 days after
   drafting (477 → 517 files; handshake v4 + Ed25519 device identity (#182), Simple Mode (#189),
   Tavily (#187), locale-aware speech, and Plans BJ/BK/BL all postdate it). The port pins **parity =
   iOS as of a named git tag**, maintains a **parity ledger keyed to the plan-letter index in
   docs/plans/README.md** (one row per plan: in-v1 / post-v1 / never), and every new iOS plan must
   declare its row on merge. The port targets the **post-BG flow-engine spine** (#157–#178), not the
   legacy architecture BG replaced.
2. **Parity-cut omissions to classify now** (in no phase today): Plan T offline queue + Plan U
   capture flows (**must move into the Phase 6 gate — the "B2B revenue live" exit is false without
   them**); the MCP client/server stack (Plans E/R/V — 23 source files, absent from every phase);
   the gateway protocol surface Android must speak compatibly (AR pairing, BH remote-invoke
   command/policy shapes, handshake v4); Plan BL's A2A+MCP contracts; memory/brain (AY recall,
   BrainStore ingest); and W presence throttle, AA first-aid, AE study mode, AF local server, AN
   projects, AQ diarization (incl. the HIPAA behavior matrix — compliance is not just Play Billing),
   AV visual memory, AW evolution loop, BI re-ask. Each gets an explicit in/out row, not silence.
3. **Shared-contract corpus (repo question answered).** Separate repo, but contracts get a canonical
   home + **golden-fixture corpus consumed by BOTH test suites**: vault JSON (Plan Q exports as
   fixtures), capture-flow JSON (U), gateway wire protocol (v4 + pairing + remote-invoke frames),
   A2A/MCP peer contracts (BL — copy its "contract only" documentation pattern), LLM wire-format
   goldens, pricing tables, license format. iOS's 177 headless test files are the spec's teeth —
   golden fixtures are the cheapest drift defense and work regardless of repo layout.
4. **No-Display contingency for Phase 4.** If DAT-Android ships no Display module on this timeline,
   the HUD backend alternative is the Plan AH EVEN G2 path (open BLE, no permission gate) — decide
   at the Phase 0 spike, don't discover it at Phase 4.
5. **Cross-platform entitlement is a Phase 6 requirement, not an afterthought.** No account system
   exists; StoreKit purchases are device-local. For B2B per-seat (mixed fleets are the *normal*
   case): the Field Assist Curve25519 offline license path (already format-portable) is the likely
   answer — state the policy (one license covers both platforms) and the Medical Compliance story
   (re-purchase vs receipt backend). Vault/brain/conversation **data portability** between a user's
   own installs rides Plan Q vault export + AN project bundles — name export/import compatibility as
   a parity requirement.
6. **Phase 1 feasibility riders:** always-on wake word on Android 14+ (foreground-service-type
   `microphone` background-start restrictions, Doze, OEM task-killers) is Phase-1 work, not the
   Phase-8 table row; **Play review is a launch gate** (always-listening mic + camera + face
   recognition hits sensitive-permissions declarations, Data Safety, biometric policy) — schedule it
   at Phase 0/1, not the Phase 9 listing checkbox; per-OEM BLE/SCO matrix budgeted, not one
   implementation; Phase 8 includes BD-class realtime resilience from day one.

---

## The reality check (verified against the codebase)

A scan of the 477 Swift files under `OpenGlasses/Sources` gives the honest shape of the job:

| Bucket | Size | Android reality |
|---|---|---|
| **UI layer** (`import SwiftUI` / `UIKit`) | 143 files | Full rewrite in **Jetpack Compose**. No transpile path; SwiftUI does not port. This is the bulk of the work. |
| **Hardware bridge** (`import MWDAT*`) | **8 files** | Rewrite against the **Android DAT SDK**. Tiny, well-isolated surface: connection, camera, display, session coordinator, error policy. The good news. |
| **On-device ML** (`import MLX*`) | 3 files | No equivalent — MLX is Apple-Silicon only. Needs a different runtime (Phase 7). |
| **Networking / LLM core** | `URLSession`-based (17 sites in `LLMService` alone) | Portable *as design*, not code → OkHttp/Ktor. Protocol shapes, tool schemas, JSON contracts all carry over. |
| **Business logic** (375 × `import Foundation`) | the long tail | Swift→Kotlin transliteration. Tedious but mechanical; the `NativeTool` protocol → registry → router architecture maps cleanly to Kotlin interfaces. 102 native-tool files to triage. |

**Key decision: this is a separate native Kotlin app, with the iOS app as the executable spec.** A shared
Kotlin-Multiplatform (KMP) core was considered and rejected as the *starting* posture: KMP would only
cover the Foundation/business-logic tail, while UI, the hardware bridge, and every Apple-framework feature
still need full Android implementations. The transliteration cost is paid either way; KMP adds build
complexity up front for a benefit that only materialises if both apps are then maintained against a shared
core. **Revisit KMP after Phase 2** if the ported core proves stable enough to be worth dual-sourcing.

---

## Framework portability map

Where each Apple framework the app leans on lands on Android. This is the per-feature risk register.

| iOS framework | Used for | Android target | Risk |
|---|---|---|---|
| `MWDATCore/Camera/Display` | glasses connect, stream, photo, HUD | **DAT for Android** (Maven, GitHub Packages) | Low for connect/camera; **Med for Display** — Android DAT is at v0.3.0 and ships only `mwdat-core` + `mwdat-camera`; no Display module observed yet (see verified API shape below) |
| SwiftUI / UIKit | all UI | Jetpack Compose | Med — volume, not difficulty |
| `URLSession` | LLM + all HTTP | Ktor / OkHttp | Low |
| `Speech` (STT) + wake word | voice loop entry | Android `SpeechRecognizer` / on-device | **High** — different lifecycle, the product's spine |
| `AVSpeechSynthesizer` + ElevenLabs | TTS | Android `TextToSpeech` + ElevenLabs (HTTP, portable) | Med |
| `AVFoundation` audio | session/route/interruption | `AudioManager` / `AudioFocus` / Oboe | **High** — Plans AO/AP/AS resilience work re-fought |
| Vision (7 files) | face rec, OCR, privacy blur, pose | **ML Kit** / MediaPipe | Med — re-implementable, different APIs |
| `NaturalLanguage` embeddings | RAG / memory / skill retrieval | ML Kit / ONNX / sentence-transformers | Med — affects AM/AX/AW |
| MLX (LLM/ASR/TTS on-device) | offline tier | MediaPipe LLM Inference / llama.cpp / ONNX / **Gemini Nano** | High — different engine + model formats |
| HealthKit | fitness coaching | **Health Connect** | Low-Med (good parity) |
| HomeKit | smart-home tool | **No real equivalent** → Google Home / Matter or drop | High |
| CarPlay | in-car HUD/voice | **Android Auto** (separate API) | High — first-class per project |
| AppIntents / Intents (18 files) | Siri shortcuts | App Actions / Assistant | High — different model |
| ActivityKit | Live Activities | Foreground-service notifications | Med |
| WatchConnectivity + Watch app/widgets | wearable companion | **Wear OS** (separate target) | High — whole sub-project |
| EventKit | calendar (proactive alerts, geofence) | Calendar Provider | Low |
| Contacts | multi-channel messaging | Contacts Provider | Low |
| StoreKit | IAP / subscriptions | **Play Billing** | Med — all revenue gating |
| `CryptoKit` (license, egress secrets) | Field Assist license, security | Tink / JCA (Curve25519 available) | Low — keep same key format |
| MapKit | nav / aircraft / vehicle | Maps SDK for Android | Low |
| ShazamKit | (music id) | No equivalent → drop | n/a |
| HaishinKit (RTMP) | broadcast | HaishinKit-Kotlin **or** other RTMP lib | Med |
| WebRTC | expert transport (L/M) | `org.webrtc` (same upstream) | Low-Med |
| `ActivityKit`/widgets | home-screen surface | App Widgets / Glance | Med |

---

## Verified DAT-Android API shape (v0.3.0)

The Kotlin SDK does **not** mirror the iOS API names — confirmed against the published `mwdat-core` /
`mwdat-camera` artifacts and a working MIT-licensed Compose reference app. Capture these in the Kotlin
equivalent of `.claude/rules/dat-conventions.md` during Phase 0:

- **Maven wiring:** `maven.pkg.github.com/facebook/meta-wearables-dat-android`, authed with a GitHub PAT
  (`GITHUB_TOKEN`) in `settings.gradle.kts`. Coordinates `com.meta.wearable:mwdat-core` and `:mwdat-camera`,
  version `0.3.0`. No `mwdat-display` artifact present.
- **Bootstrap order (strict):** request runtime perms (`BLUETOOTH`, `BLUETOOTH_CONNECT`, `INTERNET`) →
  `Wearables.initialize(context)` → start device monitoring. `initialize` must run before *any* Wearables
  call. Device pairing is `Wearables.startRegistration(app)` / `startUnregistration(app)`.
- **Permission gate** (our known "THE blocker"): the SDK ships an ActivityResult contract
  `Wearables.RequestPermissionContract()`; bridge it into Compose via a `registerForActivityResult` launcher
  + a `suspendCancellableCoroutine` so callers can `suspend fun request(Permission): PermissionStatus`.
- **Camera** differs from iOS's `Bool`+publisher model: `Wearables.startStreamSession(context, selector, config)`
  returns a `StreamSession`; frames arrive as a **Kotlin Flow** (`session.videoStream.collect { VideoFrame }`),
  and `session.capturePhoto()` is a **suspend that returns the photo directly** as `PhotoData.Bitmap` /
  `PhotoData.HEIC` (no separate `photoDataPublisher`). Selectors: `AutoDeviceSelector()` → `DeviceSelector`.
- **Audio routing to the glasses mic/speaker** is `AudioManager` Bluetooth-SCO: `MODE_IN_COMMUNICATION` +
  SCO connect, PCM16 mono @ 24 kHz (OpenAI-Realtime-native), `AudioRecord`/`AudioTrack`. The reference uses
  the legacy `startBluetoothSco()`; on API 31+ prefer `setCommunicationDevice(TYPE_BLE_HEADSET)`. This is the
  Android face of the iOS LE-Audio mic-routing gotcha — budget the same care here.
- **Device observables + firmware gate:** `Wearables.devices` (`Flow<Set<DeviceIdentifier>>`) and
  `Wearables.registrationState` are Flows to collect, and per-device
  `Wearables.devicesMetadata[id]` streams name + a `DeviceCompatibility` — surface
  `DEVICE_UPDATE_REQUIRED` as a "glasses firmware needs an update" prompt in Phase 0/1, or connect
  failures look like SDK bugs. (No iOS equivalent in our bridge today; it's a new-but-cheap UX row.)
- **Broadcast has no answer here:** the worked example's open code contains no RTMP stack (its
  advertised platform streaming isn't in the published source) — the Phase-4 RTMP-library choice
  for the HaishinKit port remains an open question, not a solved one.

### Reusable patterns (not code — MIT app as a worked example)

A small MIT-licensed reference app demonstrates the bridge end-to-end; treat it as a worked example for
Phase 0/1/8, transliterate rather than vendor (attribute if any snippet is copied):

| Pattern | Phase | What it de-risks |
|---|---|---|
| ActivityResult ↔ Compose permission bridge | 0 | The DAT permission gate — the single biggest connect blocker |
| `initialize` → monitor → register bootstrap sequence | 0 | Ordering bugs that look like "SDK doesn't work" |
| Warm/prepared `StreamSession` for instant photo-after-countdown | 4 | Capture latency without holding a live stream open |
| `AudioIoController` SCO routing + PCM16 24 kHz I/O | 1, 8 | Getting glasses mic/speaker as the realtime audio route |
| Foreground service + wakelock owning mic+SCO+WS | 8 | Conversation surviving screen-lock (our background rule) |
| OkHttp-WebSocket OpenAI Realtime client | 8 | Realtime protocol shape (append/delta) in Kotlin |

Everything above is **bridge/plumbing** reuse. The product surface (multi-LLM core, 36+ tools, vision
verticals, HUD launcher) has no counterpart there and is ours to port from the iOS spec.

### Second worked example: DAT-Android 1.0.1 in the field (added 2026-10-31)

A second MIT-licensed app, read 2026-10-31: `android-app/.../glasses/GlassesCamera.kt` in
[raunakpatil/smart-glasses-ai-agent](https://github.com/raunakpatil/smart-glasses-ai-agent) at
commit `bd64610`. It builds against **`com.meta.wearable:mwdat-core` / `mwdat-camera` 1.0.1**.
The v0.3.0 shape above is therefore out of date, and Phase 0 re-verifies it against 1.0.x. What
that code shows, all unverified by us:

- **The 1.0 shape matches iOS 0.9+/1.0.** `Wearables.createSession(SpecificDeviceSelector(id))` →
  `session.start()`, then wait for `DeviceSessionState.STARTED`, or `STOPPED` with the last
  `DeviceSessionError` from `session.errors`. Then `session.addCamera()` → `Camera`, and
  `camera.photo` → `Photo` with `state` (`PhotoState.STARTED`), `photoStream`, `errors` and
  `capturePhoto(PhotoResolution, PhotoQuality)`. Calls return `Result`-style values
  (`getOrNull()` / `errorOrNull()`). Device state is
  `Wearables.devicesMetadata[id].value.linkState` (`LinkState.CONNECTED`), plus `DonState` and
  `HingeState` types. Re-port `.claude/rules/dat-conventions.md`'s "connected means
  `linkState == .connected`" rule, not the v0.3.0 notes.
- **Check `camera.photo` against Meta's [Experimental] list before using it.** On iOS 1.0.0,
  standalone `Camera.photo` capture is Experimental, and an app that uses it can't be published (see
  the conventions file). The Android app uses it with no opt-in annotation, which says nothing
  about its status. If it is Experimental on Android too, Phase 4 captures from the stream, as iOS
  does.
- **`BLUETOOTH_SCAN` (with `neverForLocation`) is needed in practice**, not only `BLUETOOTH` and
  `BLUETOOTH_CONNECT`. Without it, the first session can work and every later one fails with "the
  glasses aren't connected" while the link stays DISCONNECTED. Add it to the Phase 0 bootstrap
  permission list above.
- **Pin the device; don't use `AutoDeviceSelector`.** Its "active device" needs a don-sensor
  signal, and it returns NO_ELIGIBLE_DEVICE until that arrives. This matches the iOS rule (bind to
  `GlassesConnectionSnapshot.connectedDeviceId`): pick the device whose `linkState` is CONNECTED.
- **The camera handshake fights the HFP/SCO call link.** Both share the glasses' Bluetooth
  connection, so that app drops SCO, waits a moment for Android to tear it down, opens the camera,
  then brings SCO back. Phase 1/8 audio routing and Phase 4 camera need one owner for this
  hand-off, the Android face of iOS's audio-session lease coordinator.
- **The glasses take about 10 s to accept a new session after the previous one closes.** That app
  keeps a standalone photo's session open briefly for follow-up shots, and waits for `STOPPED`
  (with a timeout) before opening the next one. That is the iOS "the camera capability frees only at
  `.stopped`" rule, seen from Android.
- **Photos arrive sideways.** The glasses send the sensor image with the rotation in EXIF, and
  `BitmapFactory` ignores the tag. Rotate before scaling, or the vision model sees portrait shots
  landscape.

## Phased roadmap

Each phase is a shippable milestone. Earlier phases gate later ones; within a phase, build the pure core
+ tests first, defer the device/live edge (per house style).

### Phase 0 — Bridge spike + project skeleton  *(~1 week, de-risks everything)*
Prove the hardware path before porting a line of our own logic.
- New Android Studio / Gradle project; wire the **DAT Android SDK** (GitHub Packages PAT, Maven repo) and
  **MockDeviceKit**.
- Vertical slice against the mock device: register → connect → receive a camera frame → capture a photo →
  push a `Display` HUD view → tear down.
- Establish the equivalents of our SDK conventions doc (`.claude/rules/dat-conventions.md`) for Kotlin —
  seed it from the **Verified DAT-Android API shape** section above.
- **First check:** confirm whether a Display module ships in 0.3.x (none observed at 0.3.0). If not, the HUD
  phases (4) wait on a DAT release that adds it — flag early, don't discover it in Phase 4.
- **Exit:** a throwaway app that connects to a mock (and, on a test handset, a real) pair, streams a frame,
  captures a photo, and — if Display is available — shows a HUD. Confirms device coverage, the permission
  gate, and Display parity (or its absence) firsthand.

### Phase 1 — Core conversational loop, cloud-only  *(~2 weeks)*
The product's spine, no glasses-optional features yet.
- Port `LLMService` multi-provider client (Anthropic / Gemini / OpenAI) over Ktor — streaming + tool-calling.
- Wake word → STT (Android `SpeechRecognizer` first; on-device later) → LLM → TTS (`TextToSpeech` +
  ElevenLabs HTTP). Re-fight a *minimal* slice of the audio-session resilience work (AO/AP/AS) — single
  owner, interruption + route handling.
- `ConversationStore`, `Config`/settings model, API-keys-to-Keystore (mirror Keychain approach).
- **Exit:** talk to the glasses, get a spoken answer, on a phone. Headless tests for the LLM client +
  provider fallbacks (Plan AI parity).

### Phase 2 — NativeTool framework + portable tools  *(~2–3 weeks)*
- Port the `NativeTool` protocol → `NativeToolRegistry` → `NativeToolRouter` (native-first, gateway
  fallback) as Kotlin interfaces.
- Triage the 102 tool files into **portable-now** (pure logic / HTTP: web search, calculators, subnet,
  unit/measurement, vehicle-over-Home-Assistant, weather, reminders-as-data, etc.), **needs-platform-API**
  (calendar, contacts, health, location/geofence, maps), and **needs-later-phase** (camera/vision/HUD).
  Port the portable-now set first.
- Bring across the agent harness + safety supervisor pure cores (Plans N, S, R) — these are mostly
  Foundation logic and gate the autonomous/gateway story (keep gated behind the Android equivalent of
  `agentModeEnabled`).
- **Exit:** a meaningful subset of the 36+ tools working, each headless-tested. *(KMP re-evaluation point.)*

### Phase 3 — Compose UI: main flow + settings + chat  *(~2–3 weeks)*
- Main listening flow (preserve the capsule-button + status-indicator identity; coral AI accent — never
  violet/cyan), onboarding, settings, and the standalone Chat experience (Plan AK) with Markdown rendering
  and streaming.
- **Exit:** shippable **cloud-only MVP** — internal beta candidate. Everything above this line is the
  fast path to "an Android user can use OpenGlasses."

### Phase 4 — Camera + Display HUD features  *(~2–3 weeks)*
- Frame publisher, photo capture, frame throttle/dedup gate (Plan AT), HUD DSL (`HUDScreen`) + the
  interactive HUD tasks/launcher (Plans X/Y) re-rendered through the Android `Display` view types.
- Teleprompter (AG), ambient captions overlay.
- **Exit:** glasses see + show on Android.

### Phase 5 — On-device vision / ML  *(~2–3 weeks)*
- Face recognition + auto-announce, OCR reading tool (A1), privacy blur, structured-vision substrate
  (AD/AC HECA, instrument reading, first-aid triage), pose/fitness form — all re-implemented on **ML Kit /
  MediaPipe**.
- Embedding backend (AM) on an Android embedding model → unblocks RAG (O/P), memory relevance (AX), skill
  retrieval (AW).
- **Exit:** the vision-heavy verticals work.

### Phase 6 — Platform-integration features  *(~2–3 weeks)*
- Health Connect (fitness/health vault B/AB), Calendar Provider (proactive alerts, geofence EventKit
  paths), Contacts (multi-channel messaging), Maps SDK, Play Billing for every IAP/subscription gate
  (Accessibility A, Medical Compliance, Field Assist tiers F/G/H — keep per-region pricing).
- HomeKit tool → Google Home / Matter **or** documented drop; ShazamKit → drop.
- Field Assist license verification (Curve25519 — reuse the existing key format and public key, JCA/Tink).
- **Exit:** the B2B (Field Assist) and consumer-IAP revenue paths are live on Android.

### Phase 7 — On-device inference tier  *(~3–4 weeks, hardest)*
- Replace the MLX paths: on-device LLM (MediaPipe LLM Inference / llama.cpp / Gemini Nano), SenseVoice ASR
  and Kokoro TTS equivalents (the vendored sherpa-onnx already ships an **Android** build — reuse it),
  on-device image generation (AL).
- Re-investigate the background-execution constraint from scratch (Android Foreground Services differ from
  iOS) — guard every local-inference path, mirroring the iOS "cloud-only when backgrounded" rule.
- **Exit:** offline tier reaches iOS parity.

### Phase 8 — Realtime voice + expert transports  *(~2–3 weeks)*
- Gemini Live + OpenAI Realtime sessions (WebSocket + audio) ported.
- Expert transports: Meeting-link (zero-infra, portable), MJPEG viewer, WebRTC (`org.webrtc`), RTMP
  broadcast.
- Usage/cost tracker (AU) capturing streamed + realtime tokens.
- **Exit:** the live/low-latency modes work.

### Phase 9 — Companion surfaces + polish to parity  *(~3–4 weeks)*
- **Wear OS** companion (replaces the watchOS app/widgets), App Widgets / Glance home surfaces, Live-
  Activity-equivalent foreground notifications, Android Auto (replaces CarPlay — first-class per project),
  App Actions / Assistant shortcuts (replaces AppIntents/Siri catalog Z).
- Localization (the iOS catalog ships **10 languages** — de, en, es, es-MX, fr, ja, pl, uk, zh-Hans,
  zh-Hant; the "~40 locales" claim was wrong — reuse the string catalogs), accessibility pass, Play
  Store listing + release pipeline (replaces Xcode Cloud; the *review/policy* work moved to Phase 0/1
  per the revision riders), share-target (replaces Share Extension).
- **Exit:** **full parity.**

---

## Dependency graph

```
Phase 0 (bridge spike)
   └──> Phase 1 (cloud voice loop)
            └──> Phase 2 (tool framework)  ──(re-evaluate KMP)──┐
                     └──> Phase 3 (Compose UI) ── MVP ship ─────┤
                              ├──> Phase 4 (camera + HUD)        │
                              │        └──> Phase 5 (vision/ML)  │
                              ├──> Phase 6 (platform features + revenue)
                              ├──> Phase 7 (on-device tier)
                              └──> Phase 8 (realtime + transports)
                                       └──> Phase 9 (companions + parity)
```

Phases 4–8 are largely parallelisable once Phase 3 lands. Phase 6 is the one that turns the port from
"works" into "earns."

---

## What we deliberately drop or defer (decide explicitly)

- **HomeKit smart-home tool** — no faithful Android analog; Google Home / Matter is a different surface.
- **ShazamKit** — no equivalent; cut.
- **CarPlay → Android Auto** — not a port, a parallel build; first-class per project, scheduled in Phase 9.
- **Apple Watch → Wear OS** — whole separate sub-project; Phase 9.
- **MLX** — replaced wholesale (Phase 7), not ported.

---

## Open questions

1. **One repo or two?** Separate `OpenGlasses-Android` repo vs. a `/android` directory in this repo.
   (Lean: separate repo — different toolchain, CI, and release cadence; share specs via `docs/`.)
2. **Min Android version** — DAT's stated floor is Android 10, but shipping DAT-Android apps in the wild
   target **`minSdk 31` (Android 12)** in practice (and the modern `AudioManager.setCommunicationDevice`
   SCO-routing path is API-31+ anyway). Lean: hold at 31 unless a concrete lower-device need appears.
3. **On-device LLM engine** — Gemini Nano (Pixel-gated, zero-download) vs. MediaPipe/llama.cpp (universal,
   heavy)? Likely both, device-tiered.
4. **KMP after Phase 2?** — worth dual-sourcing the core, or keep two native codebases and sync via the
   spec? Decide once the ported core is stable.
5. **DAT Android maturity** — Android DAT trails iOS: **v0.3.0 vs iOS 0.8.0**, and the camera/core modules
   ship without a Display module today (see verified API shape below). Connect + camera + photo are proven
   in the field; **Display/HUD parity is the open risk** and gates Phase 4. Validate Display availability
   and WiFi transport in Phase 0 on a test handset before committing the HUD-dependent phases.
6. **Release/CI** — Play Store internal track + Gradle CI to replace Xcode Cloud; signing + App-Group-
   equivalent (no direct analog — re-architect the watch/widget shared state).

---

## Effort summary

| Milestone | Phases | Rough effort (corrected 2026-07-10) | Outcome |
|---|---|---|---|
| **Cloud-only MVP** | 0–3 | ~7–10 weeks (sum of the phases; "3–5" assumed unstated parallel staffing) | An Android user can talk to their glasses and use core tools |
| **Glasses-complete** | +4, 5 | +4–6 weeks (Phase 4 gated on the Display contingency) | Camera, HUD, and vision verticals work |
| **Revenue-complete** | +6, 8 | +4–6 weeks (**Phase 6 gate now includes T offline queue + U capture flows + entitlement policy**) | IAP/B2B + realtime/expert modes live |
| **Full parity** | +7, 9 | +6–8 weeks | On-device tier, Wear OS, Android Auto, widgets, localization |

Serial total ≈ **21–30 weeks (5–7 engineer-months)** against a moving target — the parity ledger +
freeze tag in the revision section is what makes "parity" a fixed claim. The bridge spike (Phase 0)
still tells us within a week whether anything downstream is at risk, and now also decides the
no-Display contingency.
