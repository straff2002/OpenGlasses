# Plan AS — Audio-Session Lease Coordinator (single owner of the shared `AVAudioSession`)

**Status:** 🚧 Foundation + all exclusive owners + coexisting riders shipped. The deterministic
`AudioSessionLedger` core is headless-tested; the live `AudioSessionCoordinator` seam is in place and
adopted by the two realtime managers + wake-word baseline (exclusive owners) and live translation +
TTS (coexisting riders). The coordinator is now the complete source of truth for audio usage
(`audioActivity`). The only remaining item — trimming `AppState.switchMode`'s hardware-settling
sleep (`OpenGlassesApp.swift:1086`, still the 500 ms `Task.sleep`) — was **re-sequenced 2026-07-10:
after Plan BJ PR1**, and BJ PR1 has since merged, so the trim is now unblocked. BJ's single
`sessionIOQueue` totally orders activate/deactivate, which is precisely what makes the "wait for the
session to release" hack removable deterministically. Remaining: replace the sleep with an awaited
coordinator release barrier; device-validate. No new SPM dependency.

**Plan BJ cross-reference (2026-07-10 — three claims below are corrected by BJ):**
1. "Stale teardown is structurally impossible" is decision-time true, execution-time false:
   `release()` decides `.deactivate` under `stateQueue` but executes `setActive(false)` later on
   `deactivationQueue` while `acquire` activates inline on the caller's thread — a delayed
   deactivation can land after a newer owner's activation. BJ Correction 1 (one serial queue +
   ledger re-check at execution) closes it.
2. `assumeOwnership` was **not** retired in BJ PR2 — BJ deliberately kept it
   (`WakeWordService.swift:236-237`), and adoption has since widened to `TranscriptionService` and
   `StandaloneMicTapService`. Read the wake-word mechanism below as still current.
3. The "dedicated deactivation queue" description becomes one shared `sessionIOQueue` under BJ.

**Known non-participants (2026-07-10 inventory — direct session callers the ledger never
arbitrates):** `WakeWordService` `:307` (interruption-ended reactivation — owner-checked but
coordinator-bypassing) and `:439` (no-lease deactivation fallback); `LiveTranslationService:95-96`
(rider whose `beginCoexisting` is bookkeeping only — it still self-activates every restart cycle);
`TextToSpeechService`'s implicit `AVAudioPlayer.play()` activations. All of those are in BJ PR2's
wiring list. **One is in no plan:** `RealtimeAudioEngine.resumeAfterInterruptionOnQueue:414-416`
reactivates with no `currentOwner` check — assigned to Plan AP's doc as a pre-validation fix.

**Update (wake-word increment):** `WakeWordService` now registers as the baseline `.wakeWord` owner
via a new register-only `AudioSessionCoordinator.assumeOwnership(_:)` — it keeps its hand-tuned
`mixWithOthers` activation and pause/resume **exactly as-is** (those must not change) and only records
ownership after a successful `configureAudioSession`, so a live session supersedes it cleanly and its
CarPlay-dismissal deactivation now routes through `release` (deactivates only if still current — it
can no longer tear down a live session that preempted it). All three exclusive owners
(`.wakeWord`/`.geminiLive`/`.openAIRealtime`) are now arbitrated by one ledger.

Follow-up to [Audio-Session Resilience P2](audio-session-resilience-p2.md). P2 made each realtime
manager *self-heal*; this plan makes the **whole app agree on who owns the mic**.

## The problem
Seven subsystems each activate the one shared `AVAudioSession` independently — `WakeWordService`
(always-on baseline, with a reference-counted `pauseOtherAudio`/`resumeOtherAudio` hold),
`GeminiLiveAudioManager`, `OpenAIRealtimeAudioManager`, `LiveTranslationService`,
`TranscriptionService` (rides the wake-word engine), and `TextToSpeechService` (ducks via the
wake-word hold). There is **no central ownership**: each calls `setActive(true)` on its own, and the
only mutual exclusion is `AppState.switchMode`'s manual *stop-old → sleep 500 ms → start-new* dance.
Two failure modes fall out of that:
- A preempted subsystem's **late, asynchronous teardown** (an interruption reset, a delayed
  `stopCapture`) calls `setActive(false)` and **deactivates the session a newer owner just acquired**.
- After a live session ends, whether the session is left active or deactivated is incidental, so the
  always-on listener's resume depends on timing rather than a defined handoff.

## What we build
A single arbiter the subsystems go through instead of touching `setActive` directly.

### Deterministic core — `AudioSessionLedger` (pure, tested)
Last-acquire-wins ownership with the one invariant that matters:
- `acquire(owner, token)` supersedes any prior holder and bumps a monotonic generation; returns the
  new lease + the lease it preempted.
- `release(lease)` returns `.deactivate` **only if `lease` is still current**, else
  `.superseded(by:)` (a newer owner holds it — do nothing) or `.alreadyReleased`.

That release rule *is* the fix: a preempted owner can never tear the session out from under whoever
took it. Fully unit-tested (`AudioSessionLedgerTests`) — no hardware, no session.

### Live seam — `AudioSessionCoordinator` (singleton)
Wraps the ledger behind a serial state queue and performs the real work:
- `acquire(owner, category, mode, options, configure)` → `ledger.acquire` + `AudioSessionActivator.activate`
  (preferred → `.default` fallback preserved); rolls the lease back and rethrows on activation failure.
- `release(lease)` → `ledger.release`; on `.deactivate`, `setActive(false, .notifyOthersOnDeactivation)`
  on a dedicated deactivation queue; `.superseded` / `.alreadyReleased` are logged no-ops.
- `currentOwner` snapshot for diagnostics.

## Scope
**In (this PR):**
- `AudioSessionLedger.swift` (pure core: `AudioSessionOwner`, `AudioSessionLease`,
  `AudioSessionReleaseDecision`, the ledger) + `AudioSessionLedgerTests`.
- `AudioSessionCoordinator.swift` (live singleton seam).
- **Adopt in the two realtime managers** — `GeminiLiveAudioManager` / `OpenAIRealtimeAudioManager`
  acquire (`.geminiLive` / `.openAIRealtime`) in `setupAudioSession` and release in `stopCapture`.
  They're the highest-contention exclusive owners, already reworked in P2, and *should* deactivate on
  stop so the listener resumes cleanly — the lowest-risk, most-correct first adoption.

**Now adopted (wake-word increment):**
- **`WakeWordService`** — registers as the baseline `.wakeWord` owner via the register-only
  `assumeOwnership(_:)` after each successful `configureAudioSession`, and routes its
  CarPlay-dismissal deactivation through `release`. Its tuned `mixWithOthers` activation and
  reference-counted `pauseOtherAudio`/`resumeOtherAudio` hold are **untouched** — they manage the
  `mixWithOthers` option while wake word owns the session, not ownership itself.

**Now modelled as coexisting riders (non-exclusive holds):**
- **`LiveTranslationService`** — `live_translate` is an agent tool invoked *mid-conversation*, so
  translation runs **under** the wake-word session it was triggered from, using `.measurement` +
  `.mixWithOthers` and never deactivating on stop. Making it an exclusive owner (preempt + deactivate)
  would tear down the wake-word listener that's meant to stay — a regression. So it registers a
  **coexisting hold** (`beginCoexisting(.liveTranslation)` / `endCoexisting`): pure bookkeeping, its
  tuned `.measurement` activation untouched, no preemption, no deactivation.
- **`TextToSpeechService`** — output rider that ducks other apps via the wake-word
  `pauseOtherAudio`/`resumeOtherAudio` hold; not a mic owner. Registers a coexisting
  `.textToSpeech` hold around `beginPause`/`endPause` (its existing ducking untouched).

These make the coordinator the **complete source of truth** for audio usage (`audioActivity` =
exclusive owner + coexisting riders) without changing any tuned behaviour.

**Deferred (next increments):**
- **`TranscriptionService`** — reuses the wake-word engine (no own `setActive`); it already runs
  under wake word's ownership, so no lease is needed. Revisit only if standalone recording grows a
  session of its own.
- **`AppState.switchMode`** — the manual *stop → sleep 500 ms → start* is a hardware-settling delay;
  trimming it needs on-device validation, so it stays until then.

## Build order
1. **Ledger + tests** — pure arbitration, fully tested. ✅
2. **Coordinator** — serial-queue wrapper + real activation/deactivation through `AudioSessionActivator`. ✅
3. **Realtime adoption** — acquire/release in both managers; reset re-acquires (same owner, new
   generation) so a mid-session reset never double-deactivates. ✅
4. **Wake-word adoption** — register-only `assumeOwnership(.wakeWord)` after each successful
   `configureAudioSession`; deactivation through `release`; tuned activation + pause/resume untouched. ✅
5. **Coexisting riders** — `beginCoexisting`/`endCoexisting` + `audioActivity` snapshot; adopted by
   live translation and TTS as non-exclusive holds (no preemption, no deactivation). ✅
6. **(Next)** trim `switchMode`'s settling sleep — on-device only.

## Tests
- `AudioSessionLedger`: acquire on free session (no preemption, generation 1); second acquire
  preempts + bumps generation; release-current → `.deactivate` + frees; **stale release after
  preemption → `.superseded(by:)`, current unchanged**; release when free → `.alreadyReleased`;
  double-release → deactivate once then no-op; generation monotonic; re-acquire by the same owner
  supersedes its own earlier lease. Pure, no hardware.

## Open questions / decisions needed
- **Precedence enforcement** — today the coordinator is pure last-acquire-wins (acquire always
  succeeds, preempting). Should a low-precedence acquire (wake word) be *rejected* while a high one
  (a live call) holds, or always granted? Last-acquire-wins matches the existing `switchMode` flow
  (which tears down first); enforced precedence is a later option once wake word is wired.
- **Preemption callback** — should the coordinator notify a preempted owner so it can tear itself
  down, rather than relying on `AppState` to stop it first? Useful once >2 subsystems participate.
- **TTS modelling** — exclusive lease vs a non-exclusive "duck" that nests under the current owner
  (its current `pauseHoldCount` behaviour). Lean duck.

## Why this matters
With every subsystem managing the shared session independently, "who owns the mic" is implicit and
timing-dependent — the root of sessions going silent after a preemption. A single ledger with
generation-gated release makes ownership explicit and makes the dangerous case (a stale teardown
deactivating a live session) structurally impossible. Landing the pure core + the two realtime
adopters first keeps the always-on wake-word path — the riskiest to disturb — for a deliberate
follow-up, with the hard part (the arbitration invariant) already proven in tests.
