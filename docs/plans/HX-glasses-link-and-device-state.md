# Plan HX: Glasses Link and Device State (a lost link is heard, and the glasses say when they are hot or out of date)

**Status:** 📝 Drafted 2026-10-10. Nothing built. Two PRs, both headless at their core: P0 the
audible link drop, P1 thermal and compatibility state. A device pass is owed after each.
**Origin:** The [October 2026 ecosystem review](../ecosystem-review-2026-10.md) (section 3, the
"Silent glasses link drop" and "Thermal and compatibility state not read" rows; Appendix B claim 8).
**Priority:** P0 is an accessibility defect: a blind wearer whose glasses drop hears nothing and
keeps talking to a phone in their pocket. P1 closes a deferral two plans have carried since July.
**Surfaces:** One pure cue policy, a fix to `SessionAnnouncementPolicy`, two new fields on
`GlassesDeviceState`, one production caller for an existing message function, and a
process-lifetime latch. No new setting, no new dependency, no experimental DAT API.

Evidence paths are under `OpenGlasses/Sources/`; line numbers as recorded by the review at
`7a0cc0e0`, re-read on `main` at `48bcae0c`.

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

## Scope

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

### P2: device pass (owed)

With the phone pocketed: walk out of range and hear the lost cue once; take the glasses off and
hear nothing; disconnect in Settings with VoiceOver on and hear one line. Read `thermalLevel` on a
warm day and see the posture explanation name the glasses. On a build the glasses refuse (an old
TestFlight), confirm one spoken update line and no repeated session attempts.

## Open questions

1. Should the lost cue repeat if the link stays down? Recommended: no. One cue at loss, the
   restored line on return; a repeating cue in a pocket is noise.
2. Speak the update requirement or only post it? Recommended: speak once, because the wearer of a
   refused build otherwise hears nothing from the camera at all.
3. Does `ThermalLevel` arrive often enough to be useful, or only near shutdown? P2 answers it.

## Dependencies

- **BV** (🚧 P1 and P2 core shipped; index and file agree): P1 closes BV's glasses-thermal
  deferral, and BV's row and file get a dated note saying so.
- **FF** (🚧, P0 PR1 and PR2 shipped): the delivery coordinator P0 reuses.
- **HJ** (📋 Planned): its row 3a (a compatibility refusal gives up in every presence) reads the
  same classification; the latch here is the process-wide half and should land first or with it.
- **CM** P1 (unbuilt): `WearStatePolicy` may later read `isWorn` beside this plan's state.
