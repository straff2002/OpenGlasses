# Plan AP — Audio-Session Resilience P2 (self-healing realtime audio: interruptions, route changes, Bluetooth input)

**Status:** ✅ Core shipped (this branch). Follow-up to [Audio-Session Resilience](audio-session-resilience.md)
(#114). Pure `AudioInterruptionPolicy` + `AudioRoutePolicy` + both realtime managers reworked
(permanent engine, serial lifecycle queue, idempotent node/tap guards, generation counter,
interruption/route recovery, BT-input selection + speaker fallback). **15 new tests** (9 interruption +
6 route), 20 audio tests total; Debug + Release green. No new SPM dependency. `stopCapture()`
kept **synchronous** (the teardown barrier runs on the lifecycle queue) so the two session managers'
call sites are untouched. Cross-subsystem lease coordinator shipped as **Plan AS**. Live
interruption/route-flip recovery still owed on device — one audio session shared with AS/BJ/BO's
on-glasses smoke test.

**Doc corrections (2026-07-10 review):**
- **File names are stale throughout this doc:** BG P4 (`5e5bc15`) merged the twin audio managers into
  one `Sources/Services/Audio/RealtimeAudioEngine.swift` — all of AP's shipped machinery (policies,
  permanent engine, generation counter, lifecycle queue) lives there now; read every
  `GeminiLiveAudioManager`/`OpenAIRealtimeAudioManager` reference below as `RealtimeAudioEngine`.
- **Two open questions were resolved in code:** `stopCapture()` stayed synchronous (build-order step
  5's "awaited barrier" didn't happen — the status paragraph is the truth); and the fallback message
  was resolved as **log-only** (`RealtimeAudioEngine.swift:506-508` — no HUD/TTS surfacing exists, so
  the "using phone audio" user-facing promise below is *not* implemented; either close it or make
  surfacing a small named follow-up).
- **Unflagged ownership hole in this plan's own recovery path — fixed.** `resumeAfterInterruptionOnQueue`
  now checks `AudioInterruptionPolicy.mayResume(engineOwner:currentOwner:)` against
  `AudioSessionCoordinator.shared.currentOwner` before reactivating, closing the gap where another
  owner (mode switch during the call, wake word reclaimed) could have the resume reactivate over it.
  Plan BJ (#218/#220/#222) shipped the prerequisite off-main activation seam this fix builds on.
  (The route-reset path was already fine — it re-enters via `setupAudioSession`, which re-acquires
  through the coordinator.)
- **Device validation re-scoped:** fold AP's live interruption/route recovery check into Plan BJ's
  on-glasses smoke test (BJ's list already includes phone-call interruption recovery + BT route
  change) — one device session, not two. Plan BJ also notes this engine's deliberate main-thread
  activation hop as the agreed post-BJ follow-up.

P1 (#114) stopped the two realtime audio managers from **crashing** on a bad `AVAudioFormat` and gave
them a graceful `setActive` fallback. It did **not** make them **recover**. Today a phone call, a
Bluetooth route flip, or the glasses dropping off the LE-Audio mic mid-call leaves
`GeminiLiveAudioManager` / `OpenAIRealtimeAudioManager` with a dead `AVAudioEngine` and no path back —
the session limps on producing silence until the user manually restarts it. Neither manager observes
`AVAudioSession.interruptionNotification` or `routeChangeNotification` (only `WakeWordService` and
`OpenGlassesApp` do), and the `onInterrupted` hook in `GeminiLiveSessionManager` is **Gemini
protocol-level barge-in**, not an OS audio interruption — so it does not help here.

This plan brings the two realtime managers up to a **self-healing** standard: observe OS audio
interruptions and route changes, recover the engine graph deterministically, and actively prefer the
glasses' Bluetooth-HFP/LE input with a clean phone-speaker fallback when that route isn't available —
exactly the iOS 26 LE-Audio mic-routing failure mode in `[[reference_dat_glasses_gotchas]]`.

## What we fix
- **Recover from OS audio interruptions** — on `.began` pause the engine and remember capture state;
  on `.ended` with `shouldResume`, re-activate the session and restart the engine + player. Today: a
  phone call permanently kills the live session.
- **Recover from route changes** — on `oldDeviceUnavailable` / `newDeviceAvailable`, tear the graph
  down and re-establish it on the new route instead of running a stale, silent engine.
- **Prefer the glasses input, fall back cleanly** — actively select the `bluetoothHFP` / `bluetoothLE`
  input when present; when it isn't, override to the phone speaker and surface one clear
  "using phone audio until Bluetooth connects" message rather than silently capturing nothing.
- **Idempotent, crash-proof engine graph** — keep the `AVAudioEngine` permanent for the manager's
  lifetime (never nil/replace it); guard tap-install and node-attach with `isInputTapInstalled` /
  `isPlayerNodeAttached` so a double-start or stop-without-start can't trap.
- **No stale audio across a restart** — a generation counter on the tap/accumulator discards in-flight
  buffers from a torn-down session so old audio can't bleed into the new one.

## Scope — exactly the two realtime managers (plus pure policy helpers)
In scope (the gap):
- `OpenGlasses/Sources/Services/GeminiLive/GeminiLiveAudioManager.swift` — add interruption +
  route-change observers and recovery, BT input selection + speaker fallback, idempotent node/tap
  guards, generation counter, serial lifecycle queue + `async` teardown barrier.
- `OpenGlasses/Sources/Services/OpenAIRealtime/OpenAIRealtimeAudioManager.swift` — identical treatment
  (it mirrors the Gemini manager line-for-line on these paths).

Out of scope (leave them):
- `WakeWordService.swift` — already observes interruptions/route changes; the P1 reference, not a
  target.
- `GeminiLiveSessionManager` / `OpenAIRealtimeSessionManager` — keep the existing Gemini-protocol
  `onInterrupted` (barge-in) and websocket reconnect wiring; this plan adds OS-level recovery *below*
  them in the audio manager, transparent to the session layer.

## Architecture — the seams
The device-coupled behaviour is pushed into two **pure** decision functions so the heart of the work
is unit-tested without hardware; the managers become thin executors of the returned action.

```swift
/// Maps an OS audio interruption into a recovery action. Pure.
enum AudioRecoveryAction: Equatable { case none, pause, resume, resetGraph }

enum AudioInterruptionPolicy {
    static func action(for type: AVAudioSession.InterruptionType,
                       shouldResume: Bool, isCapturing: Bool) -> AudioRecoveryAction
    static func action(for routeChange: AVAudioSession.RouteChangeReason,
                       isCapturing: Bool) -> AudioRecoveryAction
}

/// Decides input selection + output fallback from the available ports and mode. Pure.
struct AudioRouteDecision: Equatable {
    let preferredInputPortType: AVAudioSession.Port?   // bluetoothHFP/LE, or nil → leave default
    let overrideToSpeaker: Bool
    let fallbackMessage: String?                       // user-facing, or nil when the route is good
}

enum AudioRoutePolicy {
    static func decide(availableInputs: [AVAudioSession.Port],
                       currentRoute: [AVAudioSession.Port],
                       useIPhoneMode: Bool, forceSpeaker: Bool) -> AudioRouteDecision
}
```

The managers: install NotificationCenter observers in `setupAudioSession`, route each event through
the policy, and execute the returned `AudioRecoveryAction` on the serial lifecycle queue; apply
`AudioRoutePolicy.decide(...)` right after activation (and on `newDeviceAvailable`) to pick the input
and emit the fallback message. Happy-path behaviour is unchanged; only interruption/route paths gain
recovery.

## Files
New (`OpenGlasses/Sources/Services/Audio/`):
- `AudioInterruptionPolicy.swift` — pure event → `AudioRecoveryAction`.
- `AudioRoutePolicy.swift` — pure ports/mode → `AudioRouteDecision`.

Touch:
- `GeminiLive/GeminiLiveAudioManager.swift` — observers + recovery, idempotent guards, generation
  counter, serial lifecycle queue, `async stopCapture()`, route/input selection via the policy.
- `OpenAIRealtime/OpenAIRealtimeAudioManager.swift` — same.
- (If `stopCapture()` becomes `async`) the two session managers' teardown call sites — `await` it.

## Build order
1. **Policies + tests** — `AudioInterruptionPolicy`, `AudioRoutePolicy`, fully unit-tested. No device.
2. **Engine-graph hardening** — permanent engine + `isInputTapInstalled`/`isPlayerNodeAttached` guards
   + generation counter on the Gemini manager; tap/accumulator drop stale buffers across restart.
3. **Interruption/route recovery** — wire observers → policy → action on the serial lifecycle queue;
   `pause`/`resume`/`resetGraph` re-establish the engine. Apply `AudioRoutePolicy` after activation.
4. **OpenAI manager** — identical treatment.
5. **Serial lifecycle queue + `async` teardown** — move graph mutations off the MainActor; make
   `stopCapture()` an awaited barrier so teardown can't race the next session's setup.

## Tests
- `AudioInterruptionPolicy`: `.began` while capturing → `.pause`; `.ended`+`shouldResume` while
  capturing → `.resume`; `.ended` not resuming → `.none`; `oldDeviceUnavailable` while capturing →
  `.resetGraph`; any event while not capturing → `.none`. Pure, exhaustive over the cases.
- `AudioRoutePolicy`: HFP/LE input present → selects it, no fallback message; glasses mode with no
  hands-free route → `overrideToSpeaker = true` + the "using phone audio…" message; iPhone mode /
  `forceSpeaker` → speaker, no message. Pure.
- Generation counter: buffers tagged with a superseded generation are dropped; only the current
  generation reaches `onAudioCaptured` — asserted around the accumulator without a live engine.

## Deferred (next plan, not this one)
- **Cross-subsystem audio-session lease coordinator** — a single owner of the shared
  `AVAudioSession` via lease token + generation, with stale-release suppression and
  deactivate-only-when-no-newer-lease. OpenGlasses has **seven** subsystems that touch
  the session (WakeWord, GeminiLive, OpenAIRealtime, LiveTranslation, TTS, Transcription, recording),
  so a single arbiter is genuinely valuable — but it's a larger architectural change touching all of
  them and earns its own plan after this lands.

## Open questions / decisions needed
- **Reset aggressiveness** — `oldDeviceUnavailable` mid-call: full graph reset + restart
  vs. pause-and-wait for the route to settle. A reset is more robust; a pause is gentler on
  a flapping BT link. Likely reset, with a short debounce.
- **Fallback message surfacing** — log only, or also surface to the session layer for a HUD/TTS line
  ("using phone audio")? Prefer routing it up so the user knows why audio moved off the glasses.
- **`stopCapture()` becoming `async`** — cleanest for the teardown barrier, but ripples to both
  session managers' call sites. Acceptable (small, local) — confirm before changing the signature.

## Why this matters
These are the **live AI conversation** paths, and the failure modes this plan fixes are the common
ones on these glasses: a phone call comes in, the user walks out of LE-Audio range, or iOS reshuffles
the Bluetooth route mid-sentence. P1 made sure those don't *crash*; today they still *silently kill
the conversation*. This makes the session **heal itself** — pause and resume across an interruption,
re-home onto the new route, and tell the user when audio has to fall back to the phone — with the
device-coupled decisions captured in pure, fully-tested policies and only the wiring left
device-pending.
