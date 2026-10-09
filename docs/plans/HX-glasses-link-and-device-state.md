# Plan HX: Glasses Link and Device State (a lost link is heard, and the glasses say when they are hot or out of date)

**Status:** 📝 Drafted 2026-10-10. Nothing built. Two PRs, both headless at their core: P0 the
audible link drop, P1 thermal and compatibility state. A device pass is owed after each.
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

### P2: device pass (owed)

With the phone pocketed: walk out of range and hear the lost cue once; take the glasses off and
hear nothing; disconnect in Settings with VoiceOver on and hear one line. Read `thermalLevel` on a
warm day and see the posture explanation name the glasses. On a build the glasses refuse (an old
TestFlight), confirm one spoken update line and no repeated session attempts.

For P3: on a phone that has never registered, pair and decline the camera permission in Meta AI,
and read `permissionNeeded` with a working button; grant it with the glasses in the case and read
`linkDown`; with another glasses app holding Developer Mode, record what the SDK reports and
whether `noDeviceSeen` is the honest reading of it.

## Open questions

1. Should the lost cue repeat if the link stays down? Recommended: no. One cue at loss, the
   restored line on return; a repeating cue in a pocket is noise.
2. Speak the update requirement or only post it? Recommended: speak once, because the wearer of a
   refused build otherwise hears nothing from the camera at all.
3. Does `ThermalLevel` arrive often enough to be useful, or only near shutdown? P2 answers it.
4. (P3) The registration listener calls `ensurePermission()` whenever the app is registered and
   the permission is not cached, which includes launch, and that function requests as well as
   checks. Should a launch ever leave for Meta AI unasked? Recommended: no — check at launch,
   request only inside a Connect the wearer pressed. Confirm what the listener does at launch
   before changing it.
5. (P3) The SDK keeps its own log in the app's caches. Should a not-connected support report say
   whether that log shows a refused registration or a missing glasses-side component?
   Recommended: not in P3; decide after the first report P3 produces.
6. (P3) Whether the tester's region or model matters is not something this app decides. P3 makes
   the report say which of the rows above they are in; that answers it or rules the app out.

## Dependencies

- **BV** (🚧 P1 and P2 core shipped; index and file agree): P1 closes BV's glasses-thermal
  deferral, and BV's row and file get a dated note saying so.
- **FF** (🚧, P0 PR1 and PR2 shipped): the delivery coordinator P0 reuses.
- **HJ** (📋 Planned): its row 3a (a compatibility refusal gives up in every presence) reads the
  same classification; the latch here is the process-wide half and should land first or with it.
- **CM** P1 (unbuilt): `WearStatePolicy` may later read `isWorn` beside this plan's state.
