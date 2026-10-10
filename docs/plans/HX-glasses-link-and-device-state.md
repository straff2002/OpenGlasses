# Plan HX: Glasses Link and Device State (a lost link is heard, and the glasses say when they are hot or out of date)

**Status:** ✅ P0, P1, P3a and P3 shipped 2026-10-10; the device pass (P2) is owed. P0: a glasses
link that drops unasked plays the descending pair and tells VoiceOver "Glasses disconnected", and a
Disconnect or glasses taken off, which stay silent, are no longer withheld from VoiceOver. P1: the
glasses' thermal level and compatibility are read while connected; hot glasses move the power
posture; glasses that ask for a firmware or app update are said so once per process; and a session
the glasses refuse because the build is too old is asked for once per process instead of on every
camera start. P3a: Devices & Privacy › Glasses has a row to press whenever the glasses are not
connected. P3: glasses that are added but not connected say why (camera access needed, Meta AI
not showing them, or out of reach) on that screen, on the session card, in the connect failure
message, in the Developer panel and in the support report; the Meta camera permission's status is
kept; it is asked for once inside a Connect the wearer pressed; and the launch paths that used to
ask for it only read it. A device pass is owed for every phase.
**Follow-ups 2026-10-10:** four gaps the phases' own notes recorded are closed (see Follow-ups): a
camera start the app begins by itself no longer opens Meta AI for the permission; a lost link has
its own sound; the update notice stands for as long as it is true and no longer; and a refused
build ends the camera's own retries as well as its starts.
**Amended 2026-10-10:** P3 added — glasses that are added but not connected say why. It stands
apart from P0 and P1, touches none of their files, and can ship first; a tester is waiting on it.
**Origin:** The [October 2026 ecosystem review](../ecosystem-review-2026-10.md) (section 3, the
"Silent glasses link drop" and "Thermal and compatibility state not read" rows; Appendix B claim 8).
**Priority:** P0 is an accessibility defect: a blind wearer whose glasses drop hears nothing and
keeps talking to a phone in their pocket. P1 closes a deferral two plans have carried since July.
**Surfaces:** One pure cue policy, a fix to `SessionAnnouncementPolicy`, two new fields on
`GlassesDeviceState`, one production caller for an existing message function, and a
process-lifetime latch. No new setting, no new dependency, no experimental DAT API.

Evidence paths are under `OpenGlasses/Sources/`; line numbers as recorded by the review at
`7a0cc0e0`, re-read on `main` at `48bcae0c`. P3's evidence was read on `main` at `e89a9c4d`.

---

## Why

**The link drop is silent.** When `isConnected` falls, `AppState` calls `releaseGlassesHardware()`
and logs (`App/OpenGlassesApp.swift:746-748`); the hardware release stops the wake word, live
sessions, the camera and speech, and plays nothing (`:894-908`). The return plays
`playConnectTone()` (`:749-755`). `playDisconnectTone()` (`Services/TextToSpeechService.swift:692`)
is called only from the end-of-turn path and the live-session earcon map, never on link loss.
VoiceOver is silenced too: `SessionAnnouncementPolicy.hasOwnAudioCue` returns `true` for
`.glassesConnected` in both directions, with the comment "`playConnectTone()` /
`playDisconnectTone()`" (`Services/Accessibility/SessionAnnouncementPolicy.swift:89-91`), so the
"glasses disconnected" line is suppressed on the strength of a tone that never plays. Plan
[FF](FF-blind-assistant-readiness.md)'s audible lifecycle covers a *live session's* connection, not
the glasses link.

**Thermal and compatibility are on the listener we already hold.** `WearablesGlassesLinkSource`
subscribes `Device.addDeviceStateListener(_:)` per device and maps link, battery, charging and
worn (`Services/GlassesConnectionPhase.swift:44-52`). `DeviceState` also carries `thermalLevel`
and, since 1.0.0, `compatibility`. Neither is read:
- `PowerPolicyService.glassesThermal` is `{ nil }` (`Services/Power/PowerPolicyService.swift:58`).
  Plan [BV](BV-power-policy.md)'s deferral still says it needs "the DAT `deviceStateStream`",
  which 1.0.0 removed; the listener is the replacement and is already subscribed.
- `DATCompatibilityMessage.message(for: Compatibility)` (`Services/StreamRecoveryPolicy.swift:217`)
  has test callers only (`OpenGlassesTests/BRHardeningTests.swift:141,147-148`).
- The camera clears its compatibility notice at the start of every session cycle
  (`Services/Camera/MetaCameraBackend.swift:805`), so an `insufficientSDKVersion` refusal, which
  only shipping a newer app can fix, is rediscovered and retried on every start.

**Added but not connected is one unexplained state (P3, 2026-10-10).** A tester with a current
Ray-Ban Meta pair and Developer Mode on reported that pairing completes with no error and the app
still shows the glasses as not connected. The app is behaving as written, and that is the problem:
- **The rule.** Connected means a listed device whose link is up. Registered with no device
  listed is `addedDisconnected`, the same phase as a pair asleep in its case, and its status text
  is the same "Not connected" as glasses that were never added
  (`Services/GlassesConnectionPhase.swift:78`).
- **A device is listed only after a permission is granted in Meta AI.** The app asks from the
  registration listener — `try? await cameraService.ensurePermission()`
  (`App/OpenGlassesApp.swift:4037`). Three attempts (`Services/Camera/MetaCameraBackend.swift:237`),
  then the failure is thrown away: no notice, no status, and nothing asks again until a relaunch,
  a registration change or a camera action.
- **The one message the wearer does get names the wrong things.** After Connect waits 15 seconds:
  "Glasses registered but no device appeared (state 3). Make sure the glasses are on, nearby, and
  connected in the Meta AI app" (`Services/RegistrationFlow.swift:134`). It prints a raw state
  number and mentions neither the permission nor Developer Mode's one-app-at-a-time limit, the
  two things most likely to be true of someone who has just paired.
- **The Developer panel repeats it.** The Glasses Link probe answers "Not connected — pair via
  the Meta AI app" (`Services/Diagnostics/SubsystemProbes.swift:14-17`) to someone who has paired.
- **The support report cannot tell the cases apart.** Its phone section says "Glasses: not
  connected" (`App/SupportReporting.swift:139`); registration, the number of devices listed and
  the permission's status are only in the event ring, if launch is still in it.
- **There is nothing to press.** After onboarding the only connect action is Devices & Privacy ›
  Glasses › "Connect to Meta AI", and it is shown only while the app is *not* registered
  (`App/Views/SettingsView.swift:1065`). The session card's pill deliberately stopped starting a
  connect and posts a hint instead (`App/Views/StatusIndicator.swift:266-278`). So a wearer who is
  registered with no device listed has no control anywhere that retries or asks for the
  permission; only a relaunch does.
- **Dead code beside it.** `requestEarlyPermission(allowRequest:)` is only ever called with
  `false` (`App/OpenGlassesApp.swift:4076`, `:4084`), so its request branch and the device poll
  after it never run.
- **Not ours:** nothing in the link path filters by device model (`Services/GlassesLinkSource.swift`),
  so a newer pair is not excluded by this app; and the glasses-side update actions already exist
  (`App/Views/SettingsView.swift:1022`, `:1033`).

## Scope

**In (P3):** one pure diagnosis of why added glasses are not connected; the permission's outcome
kept instead of discarded; the camera permission asked for as part of a Connect the wearer
started; the status line, the connect failure message, the Developer panel probe and the support
report all reading that diagnosis.

**In:** a link-lost earcon and a VoiceOver line at the moment of loss, silent when the loss is
expected; a link-restored line for VoiceOver; thermal and compatibility read into
`GlassesConnectionService` while connected; `PowerPolicyService` fed from it; an update
requirement announced once at link time; `insufficientSDKVersion` latched for the process.

**Non-goals:**
- Reading `hingeState`. Fold and doff are already covered by `donState` and
  `GlassesSleepPolicy`.
- Acting on thermal state beyond feeding `PowerPolicyService`. What each posture does is BV's
  checklist.
- Changing reconnect behaviour. The camera ladder is Plans FD and HJ.
- Push notifications for a link drop while the app is suspended.

## Design

### P0 · `GlassesLinkCuePolicy` (pure)

New file `Services/Accessibility/GlassesLinkCuePolicy.swift`.

```swift
enum GlassesLinkCuePolicy {
    enum Cause: Equatable {
        case linkLost            // linkState left .connected without a request
        case userDisconnected    // Settings disconnect, glasses removed, sign-out
        case doffedStandDown     // GlassesSleepPolicy stood down after the doff grace
        case appTerminating
    }
    enum Cue: Equatable { case lost, restored, none }

    static func onLoss(cause: Cause, wasWorn: Bool?, standDownActive: Bool) -> Cue
    static func onRestore(lostCueWasPlayed: Bool) -> Cue
}
```

- `onLoss` is `.lost` only for `.linkLost` while the glasses were not known to be off the face
  (`wasWorn != false`) and no doff stand-down is active. Taking the glasses off, a deliberate
  disconnect and app termination are silent: the wearer did it and knows.
- `onRestore` keeps today's connect tone and adds the restored VoiceOver line only when a lost cue
  was played, so a cold connect at launch is unchanged.
- The cause comes from where the loss was observed: `AppState.applyGlassesPhase(_:)` already knows
  whether a disconnect was requested (the Settings action and `stopObserving()` set it);
  `GlassesConnectionService.isWorn` and the sleep policy's state give the rest.

**Delivery.** The lost cue is `playDisconnectTone()` followed, when VoiceOver is running, by a
short announcement, "Glasses disconnected". It goes through FF's `AudibleLifecycleCoordinator`
queue so it cannot land on top of the assistant's voice, and it plays **after**
`releaseGlassesHardware()` has stopped speech, from the phone speaker if that is the route left.
The restored line is "Glasses connected" and follows the existing connect tone.

**The VoiceOver fix.** `SessionAnnouncementPolicy.hasOwnAudioCue` returns `true` for
`.glassesConnected(true)` (the connect tone plays) and, for `.glassesConnected(false)`, returns
what `GlassesLinkCuePolicy` decided: `true` when the lost cue played (so no double voice), and
`false` when the loss was silent by policy. That second case is deliberate: a deliberate
disconnect is still worth one VoiceOver line, because the earcon was skipped and a screen-reader
user may not have seen the switch take effect. The stale comment is corrected. The
`announcement(for:)` switch gains the `.glassesConnected` lines it currently marks unreachable.

**Corrected 2026-10-10:** the code disagreed with this section on where the cause comes from, on
the worn reading and on the delivery. What shipped, and why, is under Phases › P0.

### P1 · Thermal and compatibility state

- `GlassesDeviceState` gains `thermal: GlassesThermal?` (the app's own enum mapped from
  `ThermalLevel`, with `@unknown default` to nil) and `compatibility: GlassesCompatibility?`
  (mapped from `Compatibility`: compatible, deviceUpdateRequired, sdkUpdateRequired, undefined).
  `WearablesGlassesLinkSource` maps both in the listener it already runs; nothing else touches SDK
  types.
- `GlassesConnectionService` publishes `thermal` and `compatibility` **only while `phase ==
  .connected`**, exactly as `batteryLevel` and `isWorn` are, and through the pure
  `GlassesConnectionSnapshot`, so a stale reading never outlives the link.
- `PowerPolicyService.glassesThermal` is wired to `GlassesConnectionService.thermal` through the
  existing `ThermalLevel → ThermalPressure` mapping (BV P2). A missing or stale reading stays nil,
  which BV's fusion already treats as "no signal".
- **Update requirement at link time.** A pure `CompatibilityNoticePolicy` decides, from the
  compatibility value and whether it has been said this process, whether to announce. On the
  first connected state with `deviceUpdateRequired` or `sdkUpdateRequired`, the app speaks
  `DATCompatibilityMessage.message(for:)` once (its first production caller) and posts it to
  `NoticeCenter`. `undefined` and `compatible` say nothing.
- **`insufficientSDKVersion` latch.** `DeviceSessionError.insufficientSDKVersion` is terminal
  (`.claude/rules/dat-conventions.md`): the glasses refuse this build. A process-lifetime
  `SDKRefusalLatch` (a small actor-isolated flag on `CameraService`, set from the session-error
  watcher or from `compatibility == .sdkUpdateRequired`) makes every later camera start fail fast
  with the existing app-update copy instead of a fresh session attempt, and survives the per-cycle
  clear at `MetaCameraBackend.swift:805` (that line keeps clearing every other notice). It resets
  only on relaunch, which is the only thing that can change the answer.

**Corrected 2026-10-10:** the code and the SDK disagreed with this section on what may latch, on
the shape of the two new fields, on where the thermal mapping takes its input and on how the
sentence is said. What shipped, and why, is under Phases › P1.

### P3 · `GlassesReachabilityDiagnosis` (pure)

A value computed from what the app already knows — registration, how many devices the SDK lists,
each listed device's link, and the Meta camera permission's last known status (granted, not
granted, failed with a summary, not yet checked):

| Diagnosis | When | What the wearer is told |
|---|---|---|
| `notAdded` | not registered, nothing listed | Add your glasses |
| `awaitingApproval` | registration in flight | Approve in Meta AI (today's wording) |
| `permissionNeeded` | registered, nothing listed, permission not granted or its check failed | Allow camera access for this app in Meta AI — with a button that asks |
| `noDeviceSeen` | registered, permission granted, nothing listed | Meta AI has not shown this app your glasses: wake them, check they are connected in Meta AI, and that no other glasses app is using Developer Mode |
| `linkDown` | a device is listed, none connected or connecting | Your glasses are out of reach: on, out of the case, nearby |
| `linkComingUp` | a listed device is connecting | Connecting… |
| `connected` | a listed device's link is up | (today's wording) |

No raw state numbers in anything shown or spoken. The diagnosis is a reading of state, not a new
source of truth: `GlassesConnectionSnapshot` still owns the phase and `applyGlassesPhase` is still
the only writer of `isConnected`.

**Corrected 2026-10-10:** the code disagreed with this section on what the registration listener
did, on where the permission's status can be written, on how many times a request may open Meta
AI, and on where the session card can show a line. What shipped, and why, is under Phases › P3.

**Wiring.**
- `ensurePermission()`'s outcome at the registration listener is recorded into a published
  permission status instead of being dropped by `try?`.
- `connectGlasses()` — the Connect the wearer pressed — asks for the camera permission once
  registration has landed and it is not granted, before its wait for the link. Requesting
  deep-links to Meta AI, which is why it belongs to a user-initiated action and nowhere else; the
  never-reached `allowRequest: true` branch and its device poll are removed.
- `RegistrationFlow.connectFailureMessage` takes the diagnosis; the registered-but-nothing-listed
  string above is retired.
- The session card and Devices & Privacy › Glasses show the diagnosis line and, for
  `permissionNeeded`, the button.
- The Glasses Link probe reports the diagnosis.
- The support report's phone section gains one line when not connected: registration, devices
  listed, permission status, and each listed device's link — tokens and counts only.

## Phases

### P0: audible link drop (one PR)

`GlassesLinkCuePolicy`; the cause plumbing in `applyGlassesPhase`; delivery through the lifecycle
coordinator; the `SessionAnnouncementPolicy` fix and comment.

**Tests:** `GlassesLinkCuePolicyTests` (a table: link lost while worn → lost; while unknown worn →
lost; while doffed → none; during a stand-down → none; user disconnect → none; restore after a
played lost cue → restored; cold connect → none). `SessionAnnouncementTests` gains: a played
lost cue suppresses the VoiceOver line; a silent deliberate disconnect announces it; connect
stays suppressed. A source guard (the `TelemetryOptOutGuardTests` pattern) that
`releaseGlassesHardware` is followed by the cue decision on the loss path, so a refactor cannot
quietly drop it.

**Shipped 2026-10-10.** `GlassesLinkCuePolicy` (`Services/Accessibility/GlassesLinkCuePolicy.swift`)
holds the plan's `Cause`, `Cue`, `onLoss` and `onRestore`, and three things the plan did not name:
`cause(from:to:)`, which reads the cause off the `GlassesUse` either side of the change; a `Ledger`
that remembers whether the last loss's cue is owed, played or absent; and
`delivery(stillOwed:route:waited:)`, which says whether an owed cue goes now.
`AppState.isConnected`'s `didSet` calls `cueGlassesOutOfUse()` straight after
`releaseGlassesHardware()`, and `cueGlassesInUse()` where it used to call `playConnectTone()`. A
lost cue is `playDisconnectTone()` and then, for VoiceOver, "Glasses disconnected"; a restore is the
connect tone as before and, only after a lost cue that was heard, "Glasses connected".
`SessionAnnouncementPolicy.hasOwnAudioCue` returns `true` for a connection and, for a loss, what the
new `AnnouncementContext.glassesLossCuePlayed` says; its comment is corrected and
`announcement(for:)` words both directions. Tests: `GlassesLinkCuePolicyTests` (30: the table, the
cause, the ledger, the delivery, the worn reading), `SessionAnnouncementTests` (six new, replacing
the one that asserted the old silence) and `GlassesLinkCueSourceGuardTests` (5, reading
`OpenGlassesApp.swift`).

**What the code corrected (2026-10-10):**
- **`applyGlassesPhase(_:)` does not know whether a disconnect was requested.** Nothing sets such
  a flag: a Disconnect never changes the phase (the SDK has no app-side disconnect, so the link
  stays up), and `stopObserving()` has no production caller. The request lives in `GlassesUse` as
  a stand-down with a reason, so the cause is read there: link gone → `linkLost`; link up with a
  `.user` stand-down → `userDisconnected`; with an `.automatic` one → `doffedStandDown`. The
  decision is made in `isConnected`'s `didSet`, where the release is, against `appliedGlassesUse`,
  the value `applyGlassesUse()` last wrote the mirrors from.
- **`doffedStandDown` is every automatic stand-down.** `GlassesUse` has one automatic reason for
  both the doff grace and the silence sleep; both are the app's own doing with the link up, and
  both are silent.
- **"Glasses removed" is the phase reaching `noGlassesAdded`.** The app has no unregister action;
  registration gone with nothing listed is done by hand in Meta AI, so it is read as
  `userDisconnected`. A pair that is still registered or listed and stops answering is `linkLost`.
- **Nothing produces `appTerminating`.** The app tears nothing down on its way out. The case
  stays in the policy, silent, for a caller that one day knows. `stopObserving()`, if it ever
  gains a caller, resets the snapshot to `noGlassesAdded`, which is silent already.
- **`standDownActive` is never true where the app asks today.** While stood down the glasses are
  already out of use, so the link going changes nothing `isConnected` reports: no release and no
  cue. The policy keeps the rule, and `cause(from:to:)` reads a link lost under a stand-down as
  `linkLost` with the stand-down active, for a caller that hears link changes directly.
- **`GlassesConnectionService.isWorn` is nil by the time the phase arrives.** The service
  publishes details first and the phase last, and worn is live only while connected. The snapshot
  now keeps `lastLiveWorn`, the last reading taken while the link was up, and the cue reads that.
- **The cue does not go through `AudibleLifecycleCoordinator`.** The coordinator refuses every
  signal unless Blind Assistant is the selected live preset, its queue belongs to one live session
  (the next `sessionStarted` empties it), and its falling pair is taught as "the connection dropped
  and I'm trying to get it back". A glasses cue has to sound for every wearer, with no session.
  `AppState` delivers it with the coordinator's own two rules, through the same
  `AudibleLifecyclePolicy.SpeechRoute` reading (now one `speechRoute` property both use): wait
  while the assistant is speaking or VoiceOver is reading one of the app's announcements, and go
  anyway after `maxQueuedWait` (8 s), because a long answer must not bury the fact.
- **The cue waits half a second after the release.** `stopSpeaking()` hands the audio session
  back a moment later (`endPause()` → `resumeOtherAudio()` → `handBackSession()`), and a
  deactivation cuts off a tone that is playing; `TurnAudioRelease.toneSettleSeconds` exists for
  the same reason at the end of a turn. The tone player itself is separate from the speech player
  and survives `stopSpeaking()`.
- **Owed is not played.** VoiceOver's own line is decided on the next main-actor turn, before the
  tone sounds, so it is withheld as soon as the app owes the cue. If the glasses come back before
  the cue is heard it is dropped (it would now be false) and the restore is an ordinary one.
- **The fact reaches the policy through the context, not the transition.** The `$isConnected`
  sink only has the Bool; `glassesLossCuePlayed` is read from the ledger when the context is built.
- **The restored line comes from the cue, not from the policy.** A connection always has the
  connect tone, so `hasOwnAudioCue` is always `true` for it; `cueGlassesInUse()` says "Glasses
  connected" itself, after the tone. The policy's wording for a connection is there for the day
  the tone goes.
- **The lines are not in the catalog.** No `SessionAnnouncementPolicy` line is localised; these
  two follow that.
- **Losing the Bluetooth audio route with the link up plays nothing.** Two other callers run the
  same release for that. It is not a link loss, and if the glasses have really gone the link's own
  drop follows and is cued then.

**Owed on a device:** with the phone locked in a pocket and the wake word listening, walk out of
range: the link-lost earcon from the phone, once (three slow falling notes since the follow-up;
it was the descending pair), and how long after the audio route dropped it came
(the SDK decides when the link is down). The same with listening off or push-to-talk, where the
app holds no audio session at that moment and may not be allowed to start the tone from the
background. Drop the link while the assistant is mid-answer: the answer stops, the tone follows and
is not cut off, and other audio resumes; if the tone is clipped, `settleSeconds` is too short. Walk
back in: the connect tone, and "Glasses connected" with VoiceOver on. The earcon itself has to be
heard, which no test can do: from a pocket, all three notes; end a conversation and then drop the
link, and tell the two sounds apart without thinking; with VoiceOver on, "Glasses disconnected"
after the third note and not under it. Take the glasses off, fold
them, case them: nothing. Disconnect on the session card with VoiceOver on: one "Glasses
disconnected" and no tone. Remove the app's access in Meta AI: nothing but VoiceOver's line, and
record whether the phase really reaches `noGlassesAdded`. Glasses that do not report worn: confirm
what `donState` reads just before a drop.

### P1: thermal, compatibility, latch (one PR)

The two `GlassesDeviceState` fields and their mapping; publication while connected; the
`PowerPolicyService` wiring; `CompatibilityNoticePolicy`; `SDKRefusalLatch`.

**Tests:** `GlassesConnectionServiceTests` (thermal and compatibility published only while
connected, cleared on disconnect, never stale); `PowerPolicyServiceTests` (a hot glasses reading
moves posture; nil leaves it alone); `CompatibilityNoticePolicyTests` (said once per process, not
for compatible or undefined); `SDKRefusalLatchTests` (a latched refusal fails the next start
without a session attempt, through a fake backend seam; it survives the per-cycle notice clear).
`BRHardeningTests` keep their `message(for:)` cases. No test touches `Wearables` (it fatals in the
test host); every decision is a pure type.

**Shipped 2026-10-10.** `GlassesDeviceState` carries `thermal` (`GlassesThermal?`) and
`compatibility` (`GlassesCompatibility`); `WearablesGlassesLinkSource` maps both, in the seed and in
the listener, and is still the only place the SDK's device state is read.
`GlassesConnectionSnapshot.liveThermal` and `liveCompatibility` are nil unless the link is up, and
`GlassesConnectionService` publishes them as `thermal` and `compatibility` before the phase.
`AppState.configurePower()` points `PowerPolicyService.glassesThermal` at that reading through
`ThermalPressure(_: GlassesThermal)`, and a thermal change re-evaluates the posture when it happens
rather than at the next thirty-second sample. `CompatibilityNoticePolicy`
(`Services/CompatibilityNoticePolicy.swift`) decides the update notice and keeps the record for the
process; `AppState.glassesCompatibilityChanged(_:)` posts the sentence to `NoticeCenter` and says
it. `SDKRefusalLatch` (`Services/Camera/SDKRefusalLatch.swift`) is a value on `CameraService`, set
by a new backend event (`.sdkRefused`) that the session-error watcher sends for
`insufficientSDKVersion`; a latched `startStreaming()` or glasses `capturePhoto()` throws
`CameraError.incompatible` with the app-update sentence before the backend is called. The log
carries each reading as it changes (`compatibilityRead`, `thermalRead`, as case names) and the
latch (`sdkRefusalLatched`, `startRefusedByLatch`), which is what the device pass reads. Tests:
`GlassesConnectionServiceTests` (5 new) and `GlassesConnectionPhaseTests` (3 new),
`PowerPolicyServiceTests` (5 new, one of them the wiring end to end through the fake link source),
`CompatibilityNoticePolicyTests` (19), `SDKRefusalLatchTests` (13, eight of them through
`CameraService` and the fake backend) and `GlassesDeviceStateWiringSourceGuardTests` (6, reading the
three callers that cannot run in a test host). `BRHardeningTests` is unchanged.

**What the code corrected (2026-10-10):**
- **The compatibility reading does not latch. Only a refused session does.** The plan had
  `compatibility == .sdkUpdateRequired` set the latch as well. The SDK's own description of that
  reading is that the app should be updated and "some features may be unavailable"; and for an old
  build it has two different answers when a session is actually asked for, the terminal
  `insufficientSDKVersion` and the nonblocking `dwaOutOfStuRange`, with which the session carries
  on. The reading cannot say which of the two the glasses will give. Latching on it risked
  switching off, at every launch, a camera that works. So the reading is announced and nothing
  more, and the first session the glasses refuse sets the latch: one session attempt per process
  instead of one per start, which is the defect the latch was for. A source guard keeps the
  reading from reaching the camera.
- **The latch is a value, not an actor.** `CameraService` is main-actor bound and so is everything
  that writes it, so `SDKRefusalLatch` is a small struct it holds, with no way to clear it.
- **The watcher is in the backend and the starts are in the coordinator**, so the refusal crosses
  the seam as an event. That is also what makes it testable: the fake backend sends `.sdkRefused`
  and the test counts that it is never asked to start or capture again.
- **The per-cycle clear is handled where it lands.** The backend still clears its notice at the
  top of `ensureSessionWithRetry()` (line 811 now). `CameraService` turns a clear into "the refusal
  stands" when latched (`SDKRefusalLatch.notice(afterBackendReported:)`) and into a clear
  otherwise. Once latched the coordinator no longer reaches that line at all.
- **A latched capture fails; it does not fall back to the phone.** Connected glasses that cannot
  serve a capture have always failed rather than photograph whatever the phone is pointing at, and
  the refusal keeps that. With the glasses away the phone camera works as before.
- **Automatic work inside the backend is not gated by the latch.** The reconnect ladder and stall
  recovery start only from a stream that was running, which refused glasses never give. Giving up
  on a compatibility refusal inside the ladder is Plan HJ's row 3a. **Closed 2026-10-10:** "never"
  was not provable, and a stream start retried a refused session itself; see Follow-ups, item 4.
- **`ThermalLevel` is frozen**, so its mapping has no `@unknown default`; its `.unknown` is what
  maps to nil. `Compatibility` is not frozen, and a case a later SDK adds reads as `undefined`. A
  test compares the two case counts so that day is noticed.
- **The glasses' "no thermal concern" is `GlassesThermal.normal`.** The SDK calls it `.none`, which
  on an optional reads as nil.
- **`GlassesDeviceState.compatibility` is not optional.** A device always has a reading
  (`undefined` when it has not said), like `charging`. Only the published value is optional: nil
  is the link being down, `undefined` is connected glasses that have not said.
- **The thermal mapping took the SDK's type.** `ThermalPressure(_: ThermalLevel)` lived in
  `PowerPolicyService.swift` with an SDK import. It now takes `GlassesThermal`, the file imports
  nothing from the SDK, and a test pins that the two steps together are the table BV shipped. One
  difference, and no posture changes with it: an unknown level used to read as nominal and is now
  no signal.
- **`message(for:)` has an overload for the app's own enum**, which is the production caller. The
  SDK-typed one that `BRHardeningTests` call stays and delegates through the link source's mapping,
  so there is one sentence per requirement.
- **Once per process is once per sentence.** A firmware requirement and a too-old app are
  different things to do, so each is said once. The record is keyed by the sentence because the
  camera's own compatibility notice (BR P2) uses the same one for a refused build: it now checks
  the same record, so a refusal met at link time and again at the first photo is said once.
- **Said means played.** A sentence that speech withheld (glasses-only audio with the app stood
  down, silent mode) or that failed is forgotten and said at the next connection. One that was
  cut short counts.
- **The sentence waits four seconds, then for the route, with no bound.** The connection has its
  own sounds first, and the audio hand-off to the glasses two and a half seconds in stands aside
  for anything already speaking, which would leave the wake word on the wrong microphone. The
  wait reuses P0's route reading and decision (`GlassesLinkCuePolicy.delivery`) without its
  eight-second bound: P0's cue is a tone, this is a sentence, and saying it over the assistant
  would cut the answer off. The notice is on screen meanwhile.
- **Only while connected is the reading being non-nil**, checked again at the moment of speaking.
  A link that goes first drops the sentence unsaid, and the next connection says it.
- **The firmware notice on screen is cleared by the next camera cycle.** It is posted under the
  glasses' notice source, which the backend's per-cycle clear empties. It has been said by then,
  and a camera that then fails for that reason posts its own.
- **Nothing takes the notice back when the glasses become compatible.** A warning stays until it
  is dismissed or the next camera cycle clears it. **This and the note above were closed
  2026-10-10:** see Follow-ups, item 3.

**Owed on a device:** read `thermalLevel` on a warm day or during a long stream: whether it moves
at all before the camera's own thermal stop, and whether "conserving — glasses running warm"
appears in the device-info answer and lifts when they cool (open question 3). With glasses that
want a firmware update, connect and hear the sentence once, about four seconds after the connect
tone and not over anything; reconnect and hear nothing. On a build the glasses refuse: one spoken
update line whichever of the link or the first photo meets it first; the first camera start fails
after one session attempt and every later one at once (`startRefusedByLatch` in the log, no
`sessionAttemptFailed`); relaunch and it is asked once more. Since the follow-up that first start
may be a stream start as well as a photo: one `warmupAttemptFailed`, no `warmupRetry`, and the
app-update sentence as its error. With glasses that want a firmware update: the notice is still on
screen after a photo, goes when the glasses are put in their case, and is back, unspoken, when
they reconnect. And the question this phase could not answer from a desk: what `compatibility`
reads on glasses whose sessions still start, and on glasses that refuse (open question 9).
`compatibilityRead` in a support report from either pair answers it.

**Gates (both):** full suite and Release build green, `SWIFT_EMIT_LOC_STRINGS=NO`,
privacy-logging gate; index row, this Status line and BV's row and file updated in the P1 PR.

### P3a: something to press (one small PR, first)

The smallest useful slice of P3, shippable before the diagnosis exists. Devices & Privacy ›
Glasses shows a row whenever glasses are added and not connected, not only when unregistered:
registered with nothing listed → "Allow camera access in Meta AI", which runs the permission
check and request as the wearer's own action and shows the outcome (granted, refused, or the
failure's summary) in the row's footer instead of dropping it; unregistered keeps today's "Connect
to Meta AI". The pill's away hint names where the row is. No change to the pill's tap, which stays
a hint by design.

**Tests:** a pure row-state function (unregistered → connect; registered, not connected → allow
access; connected → no row) and the outcome-to-footer mapping. P3 then replaces the row's own
state function with the diagnosis.

**Shipped 2026-10-10.** `GlassesConnectRow.resolve(registration:phase:)`
(`Services/SettingsHub/GlassesConnectRow.swift`) picks the row and `GlassesSettingsView` draws it.
"Allow camera access in Meta AI" calls `cameraService.ensurePermission()` through
`GlassesCameraAccessOutcome.request`, whose two closures are the test seams, and keeps the answer
as `granted`, `refused`, `phoneCameraDenied` or `failed(SafeErrorSummary)`. The footer says what
the row is for until it is pressed and how the last press ended after; the outcome is also said to
VoiceOver, because the footer changes while focus is still on the button. The pill's away hint now
ends "…or reconnect in Settings › Devices & Privacy › Glasses." Launch is unchanged, and the
never-reached `allowRequest: true` branch is still there for P3 to remove. `GlassesConnectRowTests`
(14) covers the row, the outcome and every footer.

**What the code corrected (2026-10-10):**
- **The row is not limited to "nothing listed".** The view reads the phase, not the SDK's device
  count, so every registered pair without a link gets the row, including one that is listed and
  asleep in its case. For that pair the press answers at once that access is allowed, and the
  `granted` footer carries what else to check (on, out of the case, nearby, connected in Meta AI,
  no other glasses app holding Developer Mode). Telling the two apart is the diagnosis's job.
- **No row while a link is up or coming up, whatever registration reads.** The old row showed
  whenever registration read below registered, which includes a healthy link during one of
  registration's bounces through lower states. Pressing it there did nothing.
- **`ensurePermission()` throws two errors only.** `CameraError.permissionDenied` covers iOS's own
  camera permission as well as Meta's, so the outcome reads iOS's authorisation after the attempt
  to tell them apart and sends the wearer to the right Settings. Every other failure leaves as
  `CameraError.sdkNotRegistered` after three attempts; the SDK's own error is logged inside the
  backend and not thrown. So "the failure's summary" under the row is that one token today. P3's
  recorded permission status has to be written inside the backend, where the SDK's error still
  exists, for the summary to say more.
- **The summary is shown as one word.** The case or type name, else the category. The code is
  left out: beside a case name it is the case's position in its enum, the same kind of number as
  the raw registration state this plan removes.
- **The outcome is view state.** It lives as long as the Glasses screen does and is cleared when
  the row leaves, so an old answer is not shown under a new disconnection. P3's published
  permission status replaces it, and the launch check can then feed the same footer.
- **The away hint dropped "check the Meta AI app".** The notice card shows four lines, and the
  path to the row is the part that must survive a large text size.

**Owed on a device:** registered with the permission never granted, press the row and confirm
Meta AI opens once, and that granting brings the device into the list and the row away; decline
and read the refused footer; with iOS's camera permission off for the app, read the iPhone
Settings footer; with a pair in its case, read the allowed footer straight away. Also time the
failure path: `ensurePermission()` waits and retries inside itself (three attempts, four seconds
apart), so the spinner can run for most of a minute, and a request that fails rather than being
refused may open Meta AI more than once. If either is true in the hand, P3 should give the
wearer's request its own single attempt.

### P3: added but not connected says why (one PR, independent of P0 and P1)

`GlassesReachabilityDiagnosis`; the recorded permission status; the permission request inside
`connectGlasses()`; the four readers (status line, failure message, probe, support report); the
dead branch removed.

**Tests:** `GlassesReachabilityDiagnosisTests` (the table above, plus: a failed permission check
with nothing listed is `permissionNeeded`, not `noDeviceSeen`; a listed device wins over
permission status; several devices follow the snapshot's multi-device rule).
`GlassesConnectionServiceTests` through the existing fake link source and a fake permission seam:
a Connect on a registered, ungranted pair asks once and no launch path asks at all.
`RegistrationFlowTests` for the new messages and the absence of a state number. A report-line test
that carries counts and tokens and no device name or identifier. No test touches `Wearables`.

**Gates:** as P0 and P1; the new strings follow the catalog's sync-and-translate precedent in
their own commit.

**Shipped 2026-10-10.** `GlassesReachabilityDiagnosis` (`Services/GlassesReachabilityDiagnosis.swift`)
is the table above as `resolve(registration:links:permission:)`, with the short status line for
each case. `GlassesReachability` holds the three facts it is read from (registration, each listed
device's link, the permission's status) and words the support report's line and the Developer
panel's. `GlassesCameraPermission` is the status: not checked, granted, not granted, declined,
iPhone camera off, or failed with a `SafeErrorSummary`.

`GlassesConnectionService` publishes `cameraPermission` and `reachability`, and its
`connectionStatus` now follows the diagnosis. It reads the permission, without asking, when
registration lands, when the device list empties, and when Devices & Privacy › Glasses opens.
`requestCameraAccess()` is the wearer's own request, and `requestCameraAccessForConnect()` is the
permission half of a Connect. Both go through a one-method seam, `GlassesCameraPermissionSource`,
which in the app is `CameraService` and behind it `MetaCameraBackend.cameraPermission(asking:)`:
the one new place the SDK's permission calls are made, and where its error is summarised.

`AppState.connectGlasses()` asks once registration has landed and nothing is listed, before its
wait, and skips the wait when the answer was no. The registration listener no longer touches the
permission; `requestEarlyPermission(allowRequest:)` and its device poll are gone.
`RegistrationFlow.connectFailureMessage` takes the reachability and has a sentence per cause.

Readers: the session card's headline during a connect and the "Glasses away" pill's hint
(`SessionCardGlassesPill.awayHint(for:)`); Devices & Privacy › Glasses (`GlassesConnectRow`, now
built from the reachability: a button for *not added* and *permission needed*, a line with nothing
to press for *no device seen* and *link down*); the connect failure message; the Developer panel's
Glasses Link check; and one line in the support report's phone section, for example
`Glasses link: permissionNeeded — registration registered, devices listed 0, camera permission notGranted`.
The log carries the diagnosis and the permission's status each time they change
(`reachabilityRead`, `cameraPermissionRead`), and Meta AI's answer to a request
(`permissionRequested`).

Tests: `GlassesReachabilityDiagnosisTests` (23: the table, a failed check, a listed device
winning, several devices, agreement with the phase for every combination, the status lines, the
report line with identifiers and names kept out, the Developer panel's wording, the permission
error summaries), `GlassesConnectionServiceTests` (22 new, through the fake link source and a
fake permission source: every launch path reads and none asks; a Connect on a registered,
ungranted pair asks once, whether it is granted, declined or fails; nothing is asked of an
unregistered app or a listed pair), `RegistrationFlowTests` (6 new) and
`RegistrationFlowConfigMessageTests` (updated), `GlassesConnectRowTests` (13, rewritten for the
swap), `TalkEntryPolicyTests` (the hints) and `CameraServiceCoordinatorTests` (3 new).

**What the code corrected (2026-10-10):**
- **Line numbers.** The registration listener's call was at `App/OpenGlassesApp.swift:4187`, not
  `:4037`; the two `allowRequest: false` calls at `:4226` and `:4234`; the report's line at
  `App/SupportReporting.swift:140`; the phase's status text at
  `Services/GlassesConnectionPhase.swift:98`. `RegistrationFlow.swift:134`,
  `MetaCameraBackend.swift:237` and `SubsystemProbes.swift:14-17` were as recorded.
- **What the registration listener did at launch (open question 4).** Two launch paths touched
  the permission. `autoConnectGlasses()` read it with `allowRequest: false` and, when it was
  granted, set the camera's cached flag. The registration listener called `ensurePermission()`,
  which checks *and requests*, three attempts, every time the SDK reported "registered" while that
  cached flag was false. So a registered wearer without the permission was sent to Meta AI by any
  registration event that arrived after the listener was installed: the SDK settling to registered
  after launch, or one of registration's dips and returns mid-session. Whether the SDK also
  delivers the current state on subscription cannot be read from its interface; the device pass
  records it. Now neither path asks. The listener keeps the raw state and nothing else, and the
  connection service reads the permission when registration lands.
- **Launch also prompted for the iPhone's camera.** `requestEarlyPermission` asked iOS for camera
  access when the wearer had never answered, before reading Meta's. The read does not need it, so
  that prompt went with the function. The wearer's own request still asks iOS first, as
  `ensurePermission()` does.
- **A request that fails can open Meta AI three times; a refusal cannot (P3a's question).**
  In `ensurePermission()` a `requestPermission` that *returns* "denied" is thrown out of the loop
  at once. One that *throws* (the SDK's timeout, an internal error, a request already in progress)
  is caught, waited four seconds on, and made again, up to three times. The wearer's request is
  therefore its own single attempt, `cameraPermission(asking: true)`, and
  `GlassesCameraAccessOutcome.request` over `ensurePermission()` is gone. `ensurePermission()`
  itself is unchanged for camera starts, which are Plans FD and HJ's.
- **In `ensurePermission()` a failed check never reaches the request.** A `checkPermissionStatus`
  that throws is retried and then given up on without `requestPermission` being called, and the
  SDK's `PermissionError` has `noDevice` and `noDeviceWithConnection` cases. If the SDK cannot read
  the permission while nothing is listed, the old path could never ask for it, which would be this
  phase's tester exactly. That cannot be settled from a desk. The wearer's request asks even when
  the read failed.
- **The status is published by the connection service, and written from three places.**
  `GlassesConnectionService.cameraPermission` is set by the reads above, by the wearer's request,
  and by what a camera start learned: `ensurePermission()` now reports how its permission step
  ended as a backend event (`.cameraPermission`), which `CameraService` hands on. The plan had the
  listener's `ensurePermission()` outcome recorded; the listener no longer calls it.
- **The SDK's permission errors summarise to their type's name only.** They describe themselves,
  so `SafeErrorSummary` drops the case name and keeps the ordinal, and every failure read
  "PermissionError". `MetaCameraBackend.permissionSummary(of:)` names the case (`noDevice`,
  `metaAINotInstalled`, `requestTimeout` and the rest), which is what the footer and the report
  show.
- **The diagnosis is published with its facts, not derived from the phase.** A device being listed
  moves the diagnosis from *permission needed* to *link down* and leaves the phase where it was, so
  a view that watched the phase would not redraw. `reachability` is published on any change and
  mirrored by `AppState.glassesReachability`.
- **`GlassesConnectionPhase.statusText` is gone.** The diagnosis words the status line, including
  the three cases the phase could not tell apart.
- **Registration in flight is the SDK's own "registering" state.** A Connect that is waiting at a
  lower state shows `connect()`'s "Approve … in the Meta AI app" line as before.
- **The other connect failure sentence carried a state number too.** "Glasses registration didn't
  complete (state N)", for a contributor build, lost its number.
- **The session card has no standing glasses line, by design.** Phone-first: the card reports the
  session, and the glasses' state lives on the pill. So the diagnosis reaches the card in the two
  places a glasses line already appears: the headline while the wearer's Connect is under way, and
  the hint the "Glasses away" pill posts when tapped, which now says why and still names Devices &
  Privacy › Glasses.
- **Only two diagnoses have something to press.** *Not added* keeps "Connect to Meta AI" and
  *permission needed* has "Allow camera access in Meta AI". *No device seen* and *link down* get a
  line and no button: the app cannot bring a link up, and P3a's button could only answer "already
  allowed" there. P3a's footer for a granted permission became the *no device seen* line; its
  other three outcome footers are unchanged.
- **A Connect does not wait for a link that cannot come.** When the permission was declined, is
  off for the iPhone's camera, or reads not granted, the failure is reported at once rather than
  after fifteen seconds. A read that failed or has not run still gets the wait.
- **The read is repeated where the line is read.** A status from launch goes stale when the
  wearer allows or takes back camera access in Meta AI, so it is read again when Devices & Privacy
  › Glasses opens (not while connected) and when a listed device disappears.
- **The cached flag is set only once iOS has allowed the camera.** It is `ensurePermission()`'s
  fast path past iOS's prompt, and a read alone asks iOS nothing.
- **The Developer panel also stopped calling paused glasses unpaired.** Its check reads "in use",
  so glasses whose link is up but stood down failed with "pair via the Meta AI app". It now says
  the link is up and the app is stood down. The support report's line likewise reads `connected`
  there, beside the older "Glasses: not connected".
- **Two launch paths outside the connection can still ask, and are not changed here.** With a
  live mode selected, launch starts the camera after a second and a half, and "start Blind
  Assistant on launch" starts a session; both reach the backend's `ensurePermission()`, which
  requests. They are camera starts the wearer configured, and gating them belongs with the
  camera's own start rules. Recorded so the answer to open question 4 is not read as wider than
  it is. **Closed 2026-10-10:** neither asks any more; see Follow-ups, item 1.
- **Strings.** The row's two new titles and the *link down* line are in the catalog with ru and
  es-MX. The status lines, the failure message, the pill's hint, the Developer panel and the
  report line are not localised today, and these follow that.

**Owed on a device:** on a phone that has registered and never granted the permission, launch
and confirm Meta AI does not open, the session card's pill hint and Devices & Privacy › Glasses
both say camera access is needed, and a support report carries
`permissionNeeded … camera permission notGranted`. If the report instead reads
`failed(noDevice)`, the SDK cannot read the permission with nothing listed: record it, and press
the button to see whether the request can still open Meta AI. Press "Allow camera access in Meta
AI": Meta AI opens once; allow it, and the row becomes "Meta AI isn't showing your glasses yet" or
goes straight to the glasses connecting; decline it, and read the declined footer with no second
trip to Meta AI. From a fresh install, press "Connect to Meta AI" and count the hand-offs: one
for the approval and one for camera access, and no fifteen-second wait after a decline. Put a
listed pair in its case: "Glasses out of reach", no button. With another glasses app holding
Developer Mode, record which diagnosis shows and what the report line says. With VoiceOver on,
press the button and hear where things stand when Meta AI returns. Record whether the registration
listener fires at launch for an already registered app (`registrationState` in the event log
straight after `configured`). Since the follow-up, launch with the permission missing in each of
the two ways the app starts the camera by itself: with a live mode selected, and with "start Blind
Assistant on launch" on. Meta AI must not open either time; the log carries
`permissionNotRequested`; the camera notice says camera access is needed and names Devices &
Privacy › Glasses; the row there asks when pressed. Then start the camera by hand with the
permission still missing and confirm that does open Meta AI, once. Background the app with Blind
Assistant on launch set and return: no hand-off on the way back in either.

### P2: device pass (owed)

With the phone pocketed: walk out of range and hear the lost cue once; take the glasses off and
hear nothing; disconnect in Settings with VoiceOver on and hear one line. Read `thermalLevel` on a
warm day and see the posture explanation name the glasses. On a build the glasses refuse (an old
TestFlight), confirm one spoken update line and no repeated session attempts.

For the follow-ups: hear the link-lost earcon and tell it from the end of a conversation; launch
with the camera permission missing, both ways, and see Meta AI stay shut; watch the update notice
survive a photo and go when the glasses do. The full lists are under each phase.

For P3: on a phone that has never registered, pair and decline the camera permission in Meta AI,
and read `permissionNeeded` with a working button; grant it with the glasses in the case and read
`linkDown`; with another glasses app holding Developer Mode, record what the SDK reports and
whether `noDeviceSeen` is the honest reading of it. The full list is under Phases › P3.

## Follow-ups (2026-10-10)

Four gaps the phases above recorded and left. Each was checked against the code before it was
changed; where the code disagreed with the note, the code was followed.

### 1 · A camera start the app begins by itself does not open Meta AI

**What the code showed.** Both paths P3 named reach `MetaCameraBackend.ensurePermission()`, and
that is the only place a camera start asks. A live mode's launch start calls
`cameraService.startStreaming()` a second and a half in. "Start Blind Assistant on launch" goes
through `LiveSessionActivator`, whose mode switch starts the camera and whose session start claims
it. `CameraService.startStreaming()` does not look at the link first, so a registered app with
nothing listed got as far as the request. One signal already existed and one did not:
`LiveActivationSource.isExplicit` separates a request the wearer made (Action Button, Siri, wake
word, the app's control, a temple tap) from one the app made (launch, foreground, the return from
an offline hand-off), and the launch camera start had nothing.

**What changed.** `CameraPermissionRequestPolicy` (`Services/Camera/`) is the decision: granted
proceeds; not granted asks when the wearer began the start and fails without asking when the app
did. Who began it is a task-local (`initiator`, default the wearer), the shape
`TurnRecorder.isOffTurnWork` already has, because the start crosses the coordinator's coalescing
task, a mode switch and a session manager before it reaches the permission. It is set in two
places and nowhere inferred: `startModeSubstrateOnLaunch()` wraps its start in
`startedByApp { }`, and the activator runs every request as the wearer's or the app's by
`isExplicit`. `ensurePermission()` asks the table after the read; an unasked start publishes the
status as not granted (so the diagnosis reads *permission needed*), sends the session card's own
hint as the camera's notice ("Glasses need camera access in Meta AI — allow it in Settings ›
Devices & Privacy › Glasses."), logs `permissionNotRequested` and throws
`CameraError.permissionNotRequested` without going round its retry loop.

**Wider than launch, on purpose.** The activator's rule covers a return to the foreground and the
offline return as well: they are the same kind of request, and a hand-off on foregrounding is the
same surprise.

**Limits.** A wearer's start that joins an app-begun start still in flight gets that start's
answer (the coordinator coalesces): it fails with the notice, and the next press asks. A live
session the app started without a camera can still ask later, when its own reconnect restarts the
camera; that path is the session's recovery and is not changed here. The iPhone's own camera
prompt is not a hand-off and is unchanged. And if a pair is listed while the permission is not
granted (it was taken back in Meta AI), the diagnosis reads the link, not *permission needed*, so
the notice names a screen with no row on it; starting the camera by hand still asks.

**Tests:** `CameraPermissionRequestPolicyTests` (15: the table, the mark and its scope, the mark
reaching the fake backend through a start, a claim and a capture, an unasked failure leaving the
status, the notice and nothing armed, and two source guards on `ensurePermission()` and the
launch call site) and `LiveSessionActivatorTests` (4 new).

### 2 · A lost link has its own sound (open question 7)

**What the code showed.** Tones are not data: each is a function with its numbers in it, played
either as one generated buffer (the descending pair) or as `playTone` calls a few hundredths of a
second apart (the connect pair, the restored triad, the failure double). The temple-tap earcons
are the exception, and one of them, "ended", is already a three-note fall (660, 494, 330 Hz, a
third of a second).

**What changed.** `GlassesLinkCuePolicy.lostEarcon` is the new cue's three notes as data: 587 Hz
for 0.16 s, 466 Hz for 0.16 s, 392 Hz for 0.24 s (D5, B♭4, G4: a falling minor triad, 0.62 s in
all). `TextToSpeechService.playLinkLostTone()` plays them the way the restored triad is played,
and `cueGlassesOutOfUse()` calls it. Against its neighbours: three notes where the
end-of-conversation pair has two, each longer than that pair's and the whole more than twice as
long, starting a fourth above it; falling where the connect pair and the restored triad rise; no
repeated pitch where the failure and recording doubles repeat one; and against the temple "ended"
fall, half as wide, nearly twice as long, held at the end, and sharing no pitch. The lowest note
is 392 Hz because the cue is usually heard from a phone in a pocket: a last note the speaker
dropped would leave a falling pair. VoiceOver's line now waits for the earcon's own length
(`lostLineDelaySeconds`), which is longer than the pair's. The Blind Assistant's "connection
dropped" keeps the pair it was taught with.

**Tests:** `GlassesLinkCuePolicyTests` (6 new: the shape, the notes not overlapping, the length,
the pair, every temple earcon, the line's wait) and `GlassesLinkCueSourceGuardTests` (the cue plays
the earcon and not the pair; the earcon plays the policy's notes). The existing tones were not
turned into data to be compared against; the pair's numbers are written into the one test that
needs them.

### 3 · The update notice is on screen while it is true, and no longer

**What the code showed.** Both gaps were real, and the second was wider than recorded.
`glassesCompatibilityChanged(_:)` posted on the first reading and never cleared. The backend sets
its compatibility notice to nil at the top of every session cycle, the property's `didSet` sends
that whether or not it changed, and `CameraService` answers every nil by clearing the whole
`.glasses` notice source: so any photo took the update notice away. Independently, a source holds
one notice, so any other glasses notice replaced it. And dismissal on the notice card is by text,
in the view; nothing was ever removed from `NoticeCenter` by the wearer.

**What changed.** The notice has its own source, `AppNotice.Source.glassesUpdate`, which only the
reading posts to and only the reading clears. `CompatibilityNoticePolicy.standing(for:)` decides
it at every change of the reading: a requirement on connected glasses stands; compatible, not
said, or the link gone withdraws. Speaking is untouched: `Ledger.note(_:)` still decides that,
once per process, after the standing decision.

**What follows.** A notice comes back on screen, unspoken, when the glasses reconnect still
asking. One the wearer dismissed stays hidden while the card remembers its text. A warning that
stands for a whole connected session outranks every advisory posted meanwhile on that card (the
card shows one notice, highest severity first); the camera's own conditions still show on the
camera's own line. That ranking is the card's and is not changed here.

**Tests:** `CompatibilityNoticePolicyTests` (5 new) and `GlassesDeviceStateWiringSourceGuardTests`
(the wiring, and that the camera never touches the new source).

### 4 · A refused build ends the camera's own retries

**What the code showed.** The note said the reconnect ladder and stall recovery cannot run for
refused glasses because they start only from a stream that was running. That is likely and not
provable: a session can report the refusal under a stream that is up (the watcher stays attached),
and a ladder climbing for a pair that went out of range can be answered by a different pair. When
it happens the ladder reads only the *stream's* last error, so it would spend its ninety seconds
building sessions to be refused. Two more things the note did not have: a stream start's own
warm-up made a second session attempt after the first was refused, and threw the SDK's raw error
rather than the app-update sentence; and a stop that arrived while a reconnect was climbing
returned before it stopped the stall detector, leaving it armed.

**What changed.** `CameraService` stops the camera when the latch sets, through the same
`stopStreaming()` a wearer's Stop uses, whether or not it believes anything is running. That
clears the intent both ladders read, cancels a rung that is waiting and releases a start still in
flight. `SDKRefusalLatch.terminalError(for:)` is the pure reading of a failed attempt: a refusal
is not retried, and `warmUpStream()` throws `CameraError.incompatible` with the app-update
sentence instead of trying again. `stopStreaming()` in the backend stops the detector before its
guard. The compatibility reading still latches nothing, and a notice alone still stops nothing.

**Tests:** `SDKRefusalLatchTests` (9 new: the classifier; through the fake backend, a refusal
under a running stream stops it once, the stop is sent with nothing running, a second report does
not stop twice, nothing starts afterwards, a notice stops nothing; and three source guards on the
warm-up, the stop's order and the two report sites).

**For Plan HJ:** row 3a's process-wide half is done here. HJ's table still owns what the ladder
does with every other session error.

## Open questions

1. Should the lost cue repeat if the link stays down? Recommended: no. One cue at loss, the
   restored line on return; a repeating cue in a pocket is noise. **P0 shipped it that way.**
2. Speak the update requirement or only post it? Recommended: speak once, because the wearer of a
   refused build otherwise hears nothing from the camera at all. **P1 shipped it that way.**
3. Does `ThermalLevel` arrive often enough to be useful, or only near shutdown? P2 answers it.
4. (P3) The registration listener calls `ensurePermission()` whenever the app is registered and
   the permission is not cached, which includes launch, and that function requests as well as
   checks. Should a launch ever leave for Meta AI unasked? Recommended: no — check at launch,
   request only inside a Connect the wearer pressed. Confirm what the listener does at launch
   before changing it. **P3 shipped it that way**, for the connection's own launch paths; what
   the listener did, and the two camera starts at launch that still reach a request, are under
   Phases › P3. **Those two were closed by the 2026-10-10 follow-up.**
5. (P3) The SDK keeps its own log in the app's caches. Should a not-connected support report say
   whether that log shows a refused registration or a missing glasses-side component?
   Recommended: not in P3; decide after the first report P3 produces. **P3 does not read it.**
6. (P3) Whether the tester's region or model matters is not something this app decides. P3 makes
   the report say which of the rows above they are in; that answers it or rules the app out.

7. (P0, 2026-10-10) The link-lost cue is `playDisconnectTone()`, the same descending pair that
   ends every conversation. Out of the blue it is unambiguous; in the middle of a conversation it
   sounds like the conversation ending, which is half the truth. Should a lost link have its own
   earcon? Decide after the device pass; the policy and the delivery do not change either way.
   **Answered 2026-10-10: yes.** Three slow falling notes (`GlassesLinkCuePolicy.lostEarcon`); see
   Follow-ups, item 2. Whether the notes chosen are the right ones is for the ear, on a device.
8. (P0, 2026-10-10) Glasses-only audio (`Config.glassesOnlyAudio`) keeps the assistant's voice off
   the phone speaker when the glasses are away. No tone is gated by it, so the lost cue sounds from
   the phone. Recommended: leave it; the cue is the one thing that has to be heard there.

9. (P1, 2026-10-10) Should `compatibility == sdkUpdateRequired` latch the camera off without
   waiting for a session to be refused? P1 shipped it not latching, because the SDK does not say
   that reading means sessions are refused. If the device pass shows the reading only ever
   appears on glasses that refuse, it can latch too and save the one attempt. If it also appears
   on glasses that work, the spoken sentence ("too old for your glasses") is too strong for it and
   wants the gentler wording `DATCompatibilityMessage.advisory(for:)` already has.

## Dependencies

- **BV** (🚧 P1 and P2 core shipped; index and file agree): P1 closes BV's glasses-thermal
  deferral, and BV's row and file get a dated note saying so. **Done 2026-10-10.**
- **FF** (🚧, P0 PR1 and PR2 shipped): P0 reuses its route reading and its bounded wait, not the
  coordinator itself (see Phases › P0).
- **HJ** (📋 Planned): its row 3a (a compatibility refusal gives up in every presence) reads the
  same classification; the latch here is the process-wide half and should land first or with it.
  **Done 2026-10-10** for a refusal of the build (Follow-ups, item 4).
- **CM** P1 (unbuilt): `WearStatePolicy` may later read `isWorn` beside this plan's state.
