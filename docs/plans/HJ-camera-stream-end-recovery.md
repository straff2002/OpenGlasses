# Plan HJ — Camera Recovery When the Glasses End the Stream (and the Phone Is Locked)

**Status:** 📋 Planned 2026-10-02 — nothing built. P0 (pure table) and P1 (wiring) are headless and
ship as one PR; P2 is a device session and rides with Plan [EO](EO-hevc-glasses-stream.md) P2.
**Origin:** A field report on DAT 1.0.0 from outside this codebase (another app built on the same
SDK): with the iPhone locked or backgrounded and background streaming on, the glasses session
**intermittently ends on its own**. RAW-codec streams ended after roughly 8–15 s with an
unexpected-error / "session ended by device" signal; an HEVC run did not end, but one run is not a
workaround and the cause is undetermined. We stream hvc1 by default since EO P1 and keep raw as an
escape hatch, so we are probably less exposed — but "probably" is not a recovery story, and reading
our own recovery code against that failure shape turned up a dead end and two blind spots that
matter whatever the cause turns out to be.
**Priority:** P1 for anything that streams with the phone in a pocket: Direct mode's background
voice with vision, Gemini Live / OpenAI Realtime with the camera, recording, broadcast and the
expert stream. A stream that dies under a locked phone and never comes back is silent — the only
thing that would tell the wearer is an on-screen notice they cannot see.
**Surfaces:** One new pure policy file, `MetaCameraBackend` wiring, one app-presence input on
`CameraService`. No SDK change, no experimental API, no new dependency, no new setting, no schema.

---

## Verified current behaviour (origin/main @ f2f49220, 2026-10-02)

Paths are under `OpenGlasses/Sources/`. Line numbers are as of that commit.

### What is already fixed

- **An unwanted stream `.stopped` does reconnect.** `CameraStreamStatePolicy.decide` checks intent
  first, then ownership, and returns `.stoppedWhileWanted` for a stop nobody asked for
  (`Services/Camera/CameraStreamStatePolicy.swift:88-104`). The backend's state listener reports
  "connecting", posts `stoppedNotice` once and calls `scheduleReconnect()`
  (`Services/Camera/MetaCameraBackend.swift:558-574`). The older note that an unexpected `.stopped`
  had no auto-reconnect is **out of date** — fixed in `83814e24` and gated by Plan FD P1.
- **The ladder is a table.** `StreamReconnectPolicy.next` answers intent → ownership → failure
  classification → budget (`Services/Camera/StreamReconnectPolicy.swift:44-58`), with delays from
  `StreamRecoveryPolicy.reconnectDelay` (1.5 s ×3, 3 s ×3, 5 s ×15; ~88 s budget,
  `Services/StreamRecoveryPolicy.swift:48-68`). A rung that wakes after a stop, a session
  replacement or a self-resume stands down (`StreamReconnectPolicy.mayAct`, `:68-73`).
- **A rung reuses the tiered rebuild.** `scheduleRung` sets `isRecoveringFromStall`, awaits
  `recoverFromStall()` and, if still not streaming, climbs again
  (`MetaCameraBackend.swift:1209-1217`). A rung's own failure therefore *does* re-arm the ladder.
- **"Ownership" no longer drops a reconnect.** The older note had `scheduleReconnect()` guarding on
  `!isRecoveringFromStall`. It now *defers* (`.deferToOwner`, 1 s, no rung spent) while a warm-up,
  stall recovery or capture owns the stream (`MetaCameraBackend.swift:1155-1171`).
- **Pauses are waited out, never restarted** (`StreamPausePolicy`, FD P1) — this plan does not touch
  that rule; a pause is not a terminal end.

### What is still open

1. **A stall recovery that fails, when the stall detector started it, is a dead end.** The detector
   sets `isRecoveringFromStall`, calls `recoverFromLinkStall()` → `recoverFromStall()`
   (`MetaCameraBackend.swift:1316-1323`). On a thrown rebuild, the catch path bumps
   `consecutiveRecoveryFailures`, resets the session on a cheap-tier failure, then sets
   `isStreaming = false` and sends `streamingChanged(false)` (`:1369-1381`) — and that is all.
   - It does **not** call `scheduleReconnect()`; only the state listener's `.stoppedWhileWanted` row
     and a failing rung do (`:574`, `:1217`).
   - The `.stopped` the dying stream emits *during* the recovery is classified as ours
     (`transitionIsOurs: isWarmingUp || isRecoveringFromStall`, `:517`) and so maps to `.waiting`
     (`CameraStreamStatePolicy.swift:97`) — the ladder never hears about it.
   - The detector loop then `continue`s forever on `guard self.isStreaming` (`:1289`): disarmed.
   - Net state: `continuousStreamingIntent == true`, `isStreaming == false`, no reconnect task, no
     give-up, no notice, wait reason left at `framesUnavailable`. The camera is wanted, gone, and
     nothing will try again until the wearer stops and starts by hand. (The *other* stall exit —
     `StallRecoveryBackoff` running out — is fine: it stops and says so, `:1428-1433`.)
2. **The ladder ignores session errors.** Its failure input is `lastStreamError` only
   (`MetaCameraBackend.swift:1159`). Session errors land in `lastSessionError` (`:447-467`), which
   only `ensureSessionLocked` reads (`:368`, `:387`). `CameraErrorPolicy.retryDisposition(for:
   DeviceSessionError)` already classifies `.thermalCritical`/`.batteryCritical`/
   `.insufficientSDKVersion` etc. as `stopRetrying` (`Services/CameraErrorPolicy.swift:139-159`) but
   is called only from tests (`OpenGlassesTests/CameraSessionLifecycleTests.swift:273-281`). A
   session ended by a device condition is retried for the full ~88 s.
3. **A flapping session never gives up.** `finishReconnect()` → `cancelReconnect()` zeroes
   `reconnectAttempt` (`MetaCameraBackend.swift:1247-1251`, `:1269-1274`), and the first fresh
   frame zeroes `consecutiveRecoveryFailures` and `framelessStallRecoveries` (`:1096`, `:1360`,
   `:629`). The reported failure shape — streams that come up and die again 8–15 s later — would
   therefore loop indefinitely: cold start (7–18 s), a few seconds of frames, end, "Camera dropped —
   reconnecting", repeat. Every cycle resets every counter; nothing escalates and nothing stops.
4. **The camera has no idea the phone is locked.** Nothing in `Services/Camera/` reads app state.
   Backgrounding with glasses connected calls `optimizeForBackground()`, which trims proactive
   alerts, face recognition and the privacy blur, and leaves the camera alone
   (`App/OpenGlassesApp.swift:511-540`, `:4953-4974`); background modes are audio,
   bluetooth-central and external-accessory (`Info.plist:259-264`). The ladder runs the same
   cadence locked or not, and its notices go to `NoticeCenter` as on-screen advisories
   (`Services/CameraService.swift:255-258`) — invisible in a pocket.
5. **Give-up under lock is final.** `giveUpReconnecting` clears `continuousStreamingIntent`
   (`MetaCameraBackend.swift:1223-1242`) — correct in the foreground (FD P1: an automatic loop must
   not outlive its give-up), but under lock it means the wearer unlocks to a camera that has
   silently stopped and needs a manual Start, with no record of why beyond the log.
6. **The session's own end is not observed.** We consume `deviceSession.errorStream()` but not
   `stateStream()`. Whether a device-ended session always surfaces as a stream `.stopped` (which the
   ladder does see) or can end with the stream left in another state is **unverified** on 1.0.0.

## Scope

**In:** a pure decision table for *a wanted stream ending terminally*, keyed on what ended it, the
app's presence, and how many times it has ended recently; the stall-failure handoff to the ladder;
session-error classification in the ladder; a flap counter that survives a successful reconnect; a
park-until-foreground outcome for a locked phone; the device lock matrix that tells us which codec
and which signal the field failure actually uses.

**Out (non-goals):**
- Changing the pause rule. A `.paused` stream is the wearer's to resume (FD P1); nothing here starts
  out of a pause.
- Any DAT **[Experimental]** API (voice invocations, camera audio, standalone `Camera.photo`, the
  Inputs/Motion/Speech modules). Device state is read only through stable `Device` accessors, and
  only if P2 shows it is needed.
- Keep-alive tricks to stop iOS suspending the app (silent audio, location pings). If the field
  failure turns out to be the OS, not the glasses, that is a separate plan with its own review.
- Auto-switching the wearer's codec setting. P3 may add a per-session codec *rung*; the stored
  setting is the wearer's.
- Local MLX inference. It cannot run backgrounded and this plan does not ask it to; nothing here
  adds a local-model path.
- Push notifications or spoken announcements of a camera drop (open question, P3).

---

## P0 — The table (pure, headless)

New file `Services/Camera/StreamEndRecoveryPolicy.swift`. No SDK imports in the decision types: the
SDK's errors are classified into a `Cause` at the edge, as `CameraStreamStatePolicy` does with
states.

```swift
enum StreamEndRecoveryPolicy {
    enum Cause: Equatable {
        case streamStopped                                    // .stopped, no error said why
        case streamError(CameraErrorPolicy.RetryDisposition)  // last StreamError, classified
        case sessionError(CameraErrorPolicy.RetryDisposition) // last DeviceSessionError, classified
        case stallRecoveryFailed                              // the detector's rebuild threw
    }
    enum Presence: Equatable { case foreground, background, locked }

    enum Decision: Equatable {
        case retry(after: TimeInterval, attempt: Int)
        case deferToOwner(after: TimeInterval)
        case standDown                         // nobody wants it
        case giveUp(notice: String)            // clear intent, say why (foreground)
        case parkUntilForeground(notice: String) // keep intent, stop climbing, resume once on unlock
    }

    static func decide(cause: Cause, presence: Presence, streamingIntended: Bool,
                       transitionIsOurs: Bool, attempt: Int,
                       recentEnds: Int) -> Decision
}
```

**Row order (load-bearing, same discipline as `StreamReconnectPolicy`):**

| # | Condition | Decision |
|---|---|---|
| 1 | `!streamingIntended` | `standDown` |
| 2 | `transitionIsOurs` **and** cause ≠ `stallRecoveryFailed` | `deferToOwner(1 s)` |
| 3 | cause is `streamError(.stopRetrying)` or `sessionError(.stopRetrying)` | `giveUp(notice)` foreground; `parkUntilForeground(notice)` background/locked — a hot or flat pair of glasses may well be fine by the time the phone is unlocked, but a compatibility refusal will not (see row 3a) |
| 3a | `sessionError(.stopRetrying)` for a compatibility refusal (update required / insufficient SDK) | `giveUp(notice)` in every presence — no unlock fixes it |
| 4 | `recentEnds >= flapLimit` (P0 proposes 3 within `flapWindow` = 120 s) | foreground: `giveUp(flapNotice)`; background/locked: `parkUntilForeground(flapNotice)` |
| 5 | budget spent (`reconnectDelay(attempt:) == nil` for the presence's cadence) | foreground: `giveUp(reconnectGaveUpNotice)`; background/locked: `parkUntilForeground(…)` |
| 6 | otherwise | `retry(after: cadence(presence, attempt), attempt)` |

- **Row 2's exception is the dead-end fix in table form.** `stallRecoveryFailed` is reported *by*
  the owner as it lets go, so ownership must not defer it — the caller clears the flag before
  asking, and the row says so explicitly so a future reorder cannot reintroduce the dead end.
- **Cadence by presence.** Foreground keeps today's `StreamRecoveryPolicy.reconnectDelay` untouched.
  Background/locked uses a slower, shorter ladder (P0 proposes 3 s ×2, then 10 s ×5: ~56 s) — the
  radio is shared with the voice link, the wearer cannot see the preview, and each cold start costs
  the glasses battery. The numbers are placeholders P2 replaces.
- **`recentEnds` is a value type, not a counter on the backend.** `StreamEndHistory` records
  terminal ends with an injected clock and answers `count(within:)`; a successful reconnect does
  **not** clear it (that is open item 3), a wearer Stop or Start does, and ends older than
  `flapWindow` age out.
- **Copy** (no plan letters, product name via the existing strings, no codec jargon):
  - `flapNotice`: "The glasses camera keeps dropping out, so it has stopped trying. Start the camera
    again when you're ready."
  - `parkedNotice` prefix for the locked case: "The glasses camera stopped while your phone was
    locked. It will try again when you open Avenkin." — shown on unlock, not posted into the void.

A second small pure decision, `StreamEndRecoveryPolicy.onForeground(parked: Bool,
streamingIntended: Bool, cameraPhase:) -> .resumeLadder | .nothing | .awaitSDKResume`, decides what
an unlock does: resume a parked ladder once at rung 0 **only** from a stopped camera (a paused one is
`.awaitSDKResume`, mirroring `LiveRecoveryCameraPolicy`), never if the wearer stopped it meanwhile.

**Gates:** pure tests only; no build-number bump needed for P0 alone, but P0 ships with P1.

## P1 — Wiring (headless-checkable)

1. **Failed stall recovery re-arms the ladder.** In `startStallDetection`'s `.linkStalled` arm,
   after `isRecoveringFromStall = false`, if the recovery threw (have `recoverFromStall()` return an
   outcome — `.recovered | .noFrame | .failed` — instead of only mutating flags) and intent is still
   set, enter the reconnect path exactly as the `.stoppedWhileWanted` row does: report connecting,
   post `stoppedNotice` once, `isReconnecting = true`, ask the table with `cause:
   .stallRecoveryFailed`. The rung path keeps its own re-climb (`:1217`) and ignores the outcome.
2. **One entry point.** `scheduleReconnect()` asks `StreamEndRecoveryPolicy.decide` instead of
   `StreamReconnectPolicy.next` directly; `StreamReconnectPolicy` stays as the foreground cadence
   and `mayAct` gate it already is (its tests stay green unchanged). The cause is built from
   `lastStreamError` **and** `lastSessionError` — a session `stopRetrying` wins over a transient
   stream error.
3. **Session errors survive to the ladder.** `watchSessionErrors` already records
   `lastSessionError`; clear it where `lastStreamError` is cleared on `.streaming`
   (`MetaCameraBackend.swift:524`) so a recovered episode cannot stop a later ladder.
4. **App presence reaches the camera.** `CameraService.notePresence(_:)`, fed from the existing
   `scenePhase` handler and `protectedDataWillBecomeUnavailable` / `protectedDataDidBecomeAvailable`
   (Scan Assist already observes the first, plus `didEnterBackground` and `didBecomeActive`,
   `OpenGlassesApp.swift:3497-3507`), forwarded to the
   backend as a plain enum. No camera behaviour changes on presence alone — it only feeds the table.
5. **Park instead of clearing intent when not in the foreground.** `parkUntilForeground` stops the
   ladder and the stall detector, reports stopped, records `isParked`, keeps
   `continuousStreamingIntent`, and logs `.reconnectParked`. A wearer Stop clears the park. On
   `.foreground`, `onForeground` decides; a resumed ladder starts at rung 0 with a fresh history and
   posts the parked notice. A second park in the same foreground-less stretch is not possible
   (parked means not climbing).
6. **Flap history.** `StreamEndHistory` lives on the backend; `.stoppedWhileWanted`, a failed stall
   recovery and a session-error end each record one end; `startStreaming()` and `stopStreaming()`
   reset it; `finishReconnect()` does not.
7. **Observe the session's end (log-only in P1).** Add a `deviceSession.stateStream()` watcher
   beside the error watcher, logging `.sessionStateChanged` with presence and codec. It drives
   nothing until P2 says whether a session can end without a stream `.stopped`; if it can, P3 routes
   it into the table as `.streamStopped`.
8. **Logging for P2.** Every decision logs `PrivacyLog.camera(.glasses, .streamEndDecision,
   detail: <decision case>, …)` with presence, codec, attempt and `recentEnds` — no identifiers, no
   free text.

**Gates:** full suite green, Release build green, `SWIFT_EMIT_LOC_STRINGS=NO` on headless builds,
build number bumped in all five spec pairs; index row and this Status line updated in the same PR.

## P2 — Device session: the lock matrix (deferred; rides with EO P2)

One wearing session on Ray-Ban Meta, phone locked in a pocket, Direct mode with background voice
and the camera on, then Gemini Live. Per `{hvc1, raw} × {high, medium} × {15 fps}`, three
10-minute locked runs each:

| Measure | Where it is read |
|---|---|
| Terminal ends per 10 min, and seconds from lock to first end | `streamStoppedWhileWanted`, `.sessionError`, `.sessionStateChanged` |
| Which signal arrived first: stream `.stopped`, `StreamError`, `DeviceSessionError`, session `.stopped` | camera events, in order |
| Whether a session end ever arrives **without** a stream `.stopped` | `.sessionStateChanged` vs `streamState` |
| Reconnect success under lock, time to first fresh frame | `reconnectAttempt` → `reconnected` → `frameReceived` |
| Flap shape: seconds of frames between ends | `frameReceived` counts between ends |
| Whether the voice link survived each end | `WakeWordService` route events + one spoken turn after |
| Battery/thermal over the run | `ThermalLevel`, battery accessor |
| Unlock behaviour: parked → resumed, notice shown once | `.reconnectParked`, `.reconnectAttempt` after `.foreground` |

Decisions the numbers make, written into **P2 findings** below with the raw counts: the background
cadence and budget; `flapLimit`/`flapWindow`; whether raw under lock is bad enough that the raw
setting should carry a "not recommended with the phone locked" hint; whether the session-state
watcher must drive recovery (P1 item 7). If **hvc1 never ends under lock and raw does**, that is
the strongest available answer to the field report and goes into EO's P2 findings too.

## P3 — What P2 unlocks (deferred, separate PR)

- A per-session codec rung: a raw stream that flaps under lock is rebuilt as hvc1 for the rest of
  that session (like `stallTierOverride`), the stored setting untouched — only if P2 shows raw-only
  flapping.
- Session-state watcher drives recovery, if P2 finds session ends with no stream `.stopped`.
- A spoken one-liner when a park happens during an active voice session ("the camera has
  stopped — I'll try again when you open the app"), only if the voice route is up — open question
  for Greig: is a spoken camera notice welcome, or noise?

---

## Tests

New `OpenGlassesTests/StreamEndRecoveryPolicyTests.swift`:
- Row order: intent beats everything (no notice for a stream nobody wants, even with
  `stopRetrying`); ownership defers every cause **except** `stallRecoveryFailed`.
- `stallRecoveryFailed` with intent, foreground, attempt 0 → `retry` (the dead-end regression,
  named for it).
- `streamError(.stopRetrying)` / `sessionError(.stopRetrying)`: foreground → `giveUp` with the
  classifier's own notice; locked → `parkUntilForeground`; compatibility refusal → `giveUp` in
  every presence.
- Session `stopRetrying` wins over a transient stream error in the cause builder.
- Foreground cadence identical to `StreamRecoveryPolicy.reconnectDelay` for every attempt
  (guards against P1 changing today's behaviour), and background budget < foreground budget.
- Budget spent: foreground → `giveUp(reconnectGaveUpNotice)`; locked → `parkUntilForeground`.
- Flap: `recentEnds == flapLimit - 1` retries, `== flapLimit` gives up / parks.
- `onForeground`: parked + stopped → `.resumeLadder`; parked + paused → `.awaitSDKResume`; parked
  but intent cleared → `.nothing`; not parked → `.nothing`.
- Notice copy carries no plan letters and no codec names (scan the static strings).

New `OpenGlassesTests/StreamEndHistoryTests.swift` (injected clock): ends inside the window count;
ends outside age out; a recorded success does not clear; reset clears.

Existing suites stay green unchanged: `CameraStreamStatePolicyTests`,
`CameraSessionLifecycleTests` (the `StreamReconnectPolicy` and `retryDisposition` rows),
`StallRecoveryBackoffTests`, `DATFieldHardeningTests`, `CameraReadinessTests`,
`LiveRecoveryCameraPolicy` tests.

Optional source guard (pattern of `TelemetryOptOutGuardTests`): `MetaCameraBackend.swift`'s
`.linkStalled` arm references the recovery outcome — cheap insurance against the handoff being
refactored away. Backend behaviour itself is not unit-tested: `Wearables` fatals in the test host,
which is why every decision above is pulled out into a pure type.

## Risks

- **Racing rebuilders.** The handoff in P1.1 must happen after `isRecoveringFromStall` is cleared,
  and still goes through `transitionLock` via `recoverFromStall`. A reconnect started from inside
  the detector's task must not run concurrently with a detector tick: the detector stays disarmed
  (`isStreaming == false`) until `restoreStreamingClaim`, which is what already keeps the ladder and
  the detector apart today.
- **Parking hides a real fault.** A parked camera looks stopped on unlock; the notice and log line
  are what keep it honest. A flap counter set too low gives up on a merely flaky link — P2 sets it.
- **Presence lies at the edges.** `scenePhase` reaches `.background` slightly after the lock
  transition and protected-data notifications arrive in a different order on different iOS
  builds; the table treats `background` and `locked` alike for every row that matters, so an
  ordering race changes only the cadence for one rung.
- **We are guessing at the cause.** The field report is one external app; hvc1 may already make
  this rare for us. P0/P1 are justified on their own (items 1–3 and 5 are bugs regardless); P2 is
  what tells us whether the lock-specific rows earn their place.
- **Battery.** A background ladder that retries is radio and glasses battery spent with nobody
  watching; the shorter background budget and the flap limit are the bound.

## Delivery

P0 + P1: one PR, `docs/plans` index and this Status line updated in it. P2: findings appended here
(and to EO's P2 findings if the codec answer is clear), no code beyond what the numbers force. P3:
a separate PR per item P2 actually justifies.

## P2 findings

*(empty — to be written after the device session)*
