# Plan JV — Meta's Experimental Glasses Features, TestFlight Only ("Hey Meta, open Avenkin" and glasses gestures)

**Status:** 🚧 P0 + P1 built 2026-11-17 (headless; one branch). Owed: P1's device questions (P3),
the flagged builds' own TestFlight group, a catalog sync for the new strings (the resolver's six
failure sentences in every build, the Settings toggle and its footer only in a flagged one), then
P2 (Inputs probe) and P3. Drafted 2026-10-26; owner decision taken the same day (below).
**Origin:** issue 857 (2026-10-26). A tester with Ray-Ban Meta Gen 2 glasses, using Qwen in mainland
China, asked for a low-power way to start Avenkin from the glasses with the iPhone locked in a
pocket: "Hey Meta, open Avenkin" through Meta's voice invocations, or a gesture of the app's own that
leaves Meta's music, camera and assistant controls alone.
**Related:** Plan [GJ](GJ-remappable-temple-gestures.md) (temple taps; its P2 device run is still
owed and runs alongside P3 here), Plan [JE](JE-store-build-glasses-suspension.md) (the store copy
suspends the glasses), Plan [GU](GU-wake-word-audio-and-power.md) (wake-word power),
`.claude/rules/dat-conventions.md`.

---

## Why this needs its own lane

Both features exist in the DAT 1.0.0 we already pin, and both are labelled **[Experimental]**. The
SDK's changelog says experimental features "can be built and tested against, though apps using them
cannot be published yet":

- **Voice invocations.** `VoiceInvocationsStream` (in `MWDATCore`, which we link) delivers
  `VoiceInvocation` requests to the app. The only one is `LaunchApp` (`responseHandle`,
  `deviceIdentifier`). The app answers it through `ResponseHandle.sendSuccess(actionOutput:)` /
  `sendFailure(actionOutput:)`. Failures arrive as `VoiceInvocationError`. The stream is created
  with `init(wearables:)` and started per device with `start(deviceIdentifier:)`; it needs no
  `DeviceSession`. `MockDeviceTestClient.sendLaunchAppAction(deviceId:)` drives it from a UI test.
- **Inputs.** The `MWDATInputs` module (not linked today) adds `DeviceSession.addInputs(configuration:)`
  → `Inputs`, whose `events` stream carries `InputEvent`: `nav(direction:)`, `select`, `back`,
  `button(.action)`, `capture(.shortPress | .hold | .doublePress)` and `drag`. Each event carries an
  `InputSource` (`captouch`, `captureButton`, `actionButton`, `neuralBand`, `neuralBandDrag`).
  `InputsConfiguration` picks the sources, and `consumeBack` defaults to `true`, meaning the app
  takes the back gesture for itself.

## Decision (owner, 2026-10-26)

TestFlight builds may carry these features; App Store builds never do. The owner chose **an opt-in
generation flag in the same app** over checking the install channel at runtime and over a separate
beta app:

- `AVENKIN_DAT_EXPERIMENTAL=1 ./Scripts/generate-xcodeproj.sh` adds `project.experimental.yml`.
  That spec links `MWDATInputs`, sets `-D DAT_EXPERIMENTAL` and stamps the build. Without the
  variable, the project is exactly today's.
- Every line that touches an experimental API is compiled only under `#if DAT_EXPERIMENTAL`. An
  unflagged binary does not contain it, as opposed to containing it switched off.
- **Publishing is unaffected.** The App Store copy stays what JE made it: publishable today as a
  phone-only app. Every unflagged build is a store candidate, as now.
- A flagged build is **never submitted for review**. App Store review checks the binary it is
  given, so an unflagged build has nothing experimental in it to see. (The rule is Meta's; Apple
  has none here. Beta App Review sees flagged TestFlight builds, and that is fine.)

**The cost, accepted with the decision.** JE's premise is "one upload serves both channels": the
build testers ran is the build promoted to the store. A flagged build cannot be promoted, so each
store release needs **its own unflagged upload** from the same commit. That costs one more archive
and one more build number per release. The unflagged build also differs from what the experimental
testers ran by exactly the flagged code, which is why P0 keeps that code off every path the
unflagged app runs.

## What was built (2026-11-17)

- **P0.** `project.experimental.yml` links `MWDATInputs`, sets `AVENKIN_DAT_EXPERIMENTAL: "YES"` and
  defines the condition in `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, per configuration at the project
  level (`DEBUG DAT_EXPERIMENTAL` / `DAT_EXPERIMENTAL`, as the phone-only overlay does), not `-D` in
  `OTHER_SWIFT_FLAGS` (which an overlay would have to restate in full) and not on the app target
  alone (the unit-test target must compile the flagged-only tests too); `-showBuildSettings` shows
  it on the app and test targets in Debug and Release. A build
  phase prints a "TESTFLIGHT ONLY" warning on every flagged build. `generate-xcodeproj.sh` adds the
  spec only under `AVENKIN_DAT_EXPERIMENTAL=1`, refuses it when any CI / Xcode Cloud marker is set or
  with `OPENGLASSES_PHONE_ONLY=1` (the store product has no glasses SDK since `project.glasses-sdk.yml`),
  and prints a loud banner. The stamp is `AvenkinDATExperimental` in the authored `Info.plist`
  (`"NO"` in base; the phone-only derivation writes `"NO"` literally and its artifact check fails
  anything else). `AppBuildIdentity.datExperimental` reads it and the report's first line reads
  `… · TestFlight · DAT experimental · glasses-beta · com.…`. `DATExperimentalPolicy` (pure) is the
  verdict above, with its line beside `Build variant: … · Glasses:` in the report. `DATExperimentalGuardTests`
  holds the four checks, plus the generator's refusals and a roster of the three `DAT_EXPERIMENTAL`
  call sites outside `Glasses/Experimental/` (the start-up call, the Settings section, the policy's
  own `isCompiledIn`). `Scripts/check-archive-dat-experimental.sh` (tested by
  `Scripts/tests/test_check_archive_dat_experimental.py`) also accepts a `.app`, looks for Motion and
  Speech too, and reads load commands as well as `Frameworks/`.
- **P1.** Outside the lane, compiled and tested in every build: `VoiceInvocationResolver` (over
  `TempleContext` plus "another person is on the line"), `VoiceInvocationLedger` (the support report's
  per-glasses record: each request with the app's run state and lock state, how and how fast it was
  answered and whether the SDK took the answer, a result that came after the deadline, stream errors
  and link drops with the seconds since the last request — for the HFP field report), a
  `.voiceInvocation` live-activation source (explicit), and `GlassesConnectionService.connectedDeviceIds`.
  Inside `Glasses/Experimental/`: the `VoiceInvocationSource` seam, `MetaVoiceInvocationSource`
  (one `VoiceInvocationsStream` per device on `Wearables.shared`, listeners in a `ListenerTokenBag`),
  `GlassesVoiceInvocationService` (streams follow `connectedDeviceIds`; one answer per request, the
  first of the action's result and a 5 s deadline), `DATExperimentalFeatures.start(appState:)` and
  the Settings section **Hey Meta, open Avenkin (beta)** (default on). The service is tested with a
  fake source in a flagged project only; no `MockDeviceTestClient` UI test yet (the UI-test target
  does not link the mock client).

## P0 — The lane (no feature yet)

- **`project.experimental.yml`** adds the `MWDATInputs` product to the app target, appends
  `-D DAT_EXPERIMENTAL` to `OTHER_SWIFT_FLAGS` (keeping `$(inherited)`, `KOKORO_ENABLED` and
  `SHERPA_ONNX_ENABLED`), and sets `AVENKIN_DAT_EXPERIMENTAL: "YES"`.
  `project.base.yml` sets it to `"NO"`.
- **`Scripts/generate-xcodeproj.sh`** includes the file only when `AVENKIN_DAT_EXPERIMENTAL=1`, in
  the same way as `OPENGLASSES_OFFICE_TRANSPORT`, and prints a loud line saying the result must
  never be submitted for review.
- **The stamp.** `Info.plist` gains `AvenkinDATExperimental` = `$(AVENKIN_DAT_EXPERIMENTAL)`.
  `AppBuildIdentity` reads it, and the support report's first line becomes
  `2026.10 (570) · 1a2b3c4d5 · TestFlight · DAT experimental · com.…`, so every report from a
  flagged build says so.
- **`DATExperimentalPolicy` (pure).** A feature runs only when all of these hold: the build is
  flagged; the channel is TestFlight, a development build or the simulator (a flagged build
  promoted to the store by mistake still runs nothing, and on that copy JE never configures the SDK
  anyway); `GlassesSupportPolicy.isSupported`; and the wearer's own switch is on. The policy's
  report line is added to the support report next to JE's `Glasses:` line.
- **Code layout.** All experimental code lives under `OpenGlasses/Sources/Glasses/Experimental/`.
  Each file is wrapped whole in `#if DAT_EXPERIMENTAL … #endif`. The one call site that starts it
  (in the glasses services' start-up) is a single `#if` block that calls a single entry point.
- **Guard tests (`DATExperimentalGuardTests`).** These are source scrapes in the
  `TelemetryOptOutGuardTests` style (`#filePath` repo root):
  1. `project.base.yml`, `project.watch.yml` and `project.tests.yml` never name `MWDATInputs`,
     `MWDATMotion` or `MWDATSpeech`.
  2. `generate-xcodeproj.sh` includes `project.experimental.yml` only behind
     `AVENKIN_DAT_EXPERIMENTAL`.
  3. Any line under `OpenGlasses/Sources` naming `VoiceInvocationsStream`, `LaunchApp`,
     `ResponseHandle`, `import MWDATInputs`, `addInputs`, `InputEvent`, `Camera.photo`,
     `audioCodec` or `audioFramePublisher` sits in a file under `Glasses/Experimental/` whose first
     non-comment line is `#if DAT_EXPERIMENTAL`, or inside the one roster-listed call site.
     (`Camera.photo`, `audioCodec` and `audioFramePublisher` are listed because they are
     experimental too, though this plan uses none of them.)
  4. Base sets the stamp to `"NO"`, the experimental spec sets it to `"YES"`, and the authored
     `Info.plist` carries the key.
- **The artefact check.** `Scripts/check-archive-dat-experimental.sh <path.xcarchive>` reads the
  archived app's `Info.plist` stamp and looks for `MWDATInputs.framework` in `Frameworks/`. It
  prints `STORE-SAFE` or `TESTFLIGHT ONLY — DO NOT SUBMIT`, and exits non-zero when the two
  disagree. This follows the pre-archive staleness lesson: check the artefact, not the source.
- **No new CI, no new repository.** The guard tests run in the existing unit-test job. The flagged
  variant is compiled by hand: in each JV PR before it opens, and by the owner before each flagged
  upload. Flagged code can therefore break unnoticed between flagged builds, and that is accepted
  to keep CI as it is. Xcode Cloud workflows stay unflagged. Flagged archives are made only by
  hand, from the owner's checkout.
- **Release routine** (written into the plan's *Owed* and the release notes template): flagged
  builds go to a TestFlight group of their own, with "Experimental glasses build — not a store
  candidate" in What to Test. The store candidate is the unflagged upload from the same commit.

## P1 — "Hey Meta, open Avenkin"

- **`GlassesVoiceInvocationService`** owns one `VoiceInvocationsStream` per connected device. It
  starts when `GlassesConnectionService.phase` reaches `.connected` for that device (link state, per
  the conventions — never registration) and stops when the device leaves or the link drops. It
  listens on `invocationsPublisher` and `errorPublisher` through a `ListenerTokenBag`.
- **`VoiceInvocationResolver` (pure).** It takes the `TempleContext` the temple taps already build
  and returns an outcome. A `LaunchApp` means what "start talking" means everywhere else:
  - In Direct mode it calls `handleWakeWordDetected(manual: true)`. In a live mode it calls
    `requestLiveSession(_, source: .voiceInvocation)`.
  - While Avenkin is already listening it is a no-op that still answers success. While Avenkin is
    speaking it interrupts and listens.
  - With the mic muted it answers failure, with a short reason Meta can say.
  - In a session another person is part of (`liveTranslation`, `expertCall`) it is ignored, the
    same as `ownerBlocksClaim`.
  - The reply goes back through `sendSuccess` / `sendFailure` with an `actionOutput` of at most a
    sentence. A request is never left unanswered: on a timeout of a few seconds the service answers
    failure.
- **Setting.** It lives under Devices & Privacy › Glasses, labelled as a beta, and appears only in a
  flagged build. It defaults **on**, because it fires only when the wearer says the phrase.
- **Tests.** The resolver's table runs headless. The service is tested with a fake stream behind a
  `VoiceInvocationSource` seam. One UI test drives `MockDeviceTestClient.sendLaunchAppAction`. It is
  compiled only in a flagged project, so it runs by hand with the PR, not in CI.
- **Device questions (P3):** does the invocation reach a backgrounded app with the phone locked
  when nothing else keeps the app alive (wake word off, temple taps off)? Does Meta cold-start the
  app when it is not running, or fail? What name does Meta's assistant expect, and is it the name
  registered for the app in Meta's developer centre? Does "Hey Meta" work at all where the tester
  is, and in which language? Meta's assistant may not take Mandarin, and it may not be reachable in
  mainland China.

## P2 — Glasses gestures through Inputs (measure first, then map)

- **Measure before mapping anything.** A diagnostics-only `InputsProbe` in the Developer panel adds
  `Inputs` on the shared `DeviceSessionCoordinator` session (a new `.inputs` capability) with
  `sources: [.captouch]` and `consumeBack: false`. It logs every event with its source and time, and
  stops itself after five minutes. P3 answers what it finds:
  - which events a Gen 2 actually sends;
  - whether Meta still plays and pauses music, and still takes the long press, while the app is
    subscribed;
  - what holding a session in standby costs the glasses' battery per hour.
- **Then a small map, off by default.** Only after the probe shows events Meta does not also act
  on: a "Glasses gestures (beta)" list in Devices & Privacy › Glasses, where each of those events
  (likely `select`, `back` and the swipes) can be set to a `TempleAction`. The list reuses
  `TempleActionResolver`, so the actions, earcons and Agent Mode rule are GJ's. Every gesture
  defaults to *nothing*.
- **Never:** `captureButton` (Meta's camera), `consumeBack: true`, or any gesture the probe saw
  Meta also handle. The Neural Band and the action button are out of scope until someone has the
  hardware.
- **Battery rule.** If P3 measures a standby session as costly, gestures run only while a
  conversation is open (hang up, mute), and starting a conversation stays with "Hey Meta", the
  temple taps, the Watch and the Action Button.

## P3 — Device pass, with the tester on Gen 2 glasses

Run together with GJ P2, which needs the same person and glasses:

- GJ's tap calibration (which tap arrives as which media command);
- P1's device questions;
- P2's probe log and battery reading.

The tester reports through a support report from a flagged build; its first line identifies the
build. Nothing ships to the store from this phase.

## Not in this plan

- `MWDATMotion`, `MWDATSpeech`, standalone `Camera.photo`, and camera audio.
- Any experimental API in an unflagged build, or any runtime switch that turns one on in the App
  Store copy.
- Promoting either feature to the store. When Meta marks one stable, a follow-up moves it out of
  `Glasses/Experimental/` and out from behind the flag, and rewrites the JE review notes. Until
  Meta's production channel opens, the store copy has no glasses at all (JE).

## Owed / open

1. **Meta's developer centre:** do experimental features work for testers in the app's release
   channel, or only on glasses with Developer Mode on? If only the latter, P1 and P2 reach the owner's
   own glasses and nobody else's, and this plan stops at P0 + P1 until that changes.
2. **TestFlight lanes:** confirm a separate external group for flagged builds (recommended), rather
   than sending flagged builds to every tester.
3. The `.claude/rules/dat-conventions.md` rule is amended in this PR to point here.
