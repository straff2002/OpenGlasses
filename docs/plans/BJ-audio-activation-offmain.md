# Plan BJ — Off-Main Audio-Session Activation (Thread Performance hang-risk)

**Status:** ✅ Code complete — PR1 seam + serialization merged
([#218](https://github.com/straff2002/OpenGlasses/pull/218)), PR2 wiring merged (core
[#220](https://github.com/straff2002/OpenGlasses/pull/220), leaves
[#222](https://github.com/straff2002/OpenGlasses/pull/222)); Plan BO
([#223](https://github.com/straff2002/OpenGlasses/pull/223)) followed. **Only the
on-glasses smoke test remains** (see Verification) — it was the stated merge gate but the
PRs merged ahead of hardware time, so it's now a post-merge validation owed on the next
device session. (Status header corrected 2026-07-15; it still said "Planned" with all
three PRs merged.)

## The problem
Xcode's Thread Performance Checker flags **AVAudioSession hang-risk** on the app's hottest path:
synchronous session activation on the main thread while the session is active can stall the UI
(worst on Bluetooth route changes — exactly the glasses path).

**Complete call-site inventory (code-verified 2026-07-10).** The original draft listed five sites;
the audit found eleven. In scope:

- **`WakeWordService`** — direct `AVAudioSession` calls on the main actor, bypassing the coordinator:
  - `pauseOtherAudio` (`WakeWordService.swift:145–146`) + the `overrideOutputAudioPort` at `:152`
  - `resumeOtherAudio` (`WakeWordService.swift:176–178`)
  - `configureAudioSession` (`WakeWordService.swift:221–233`, both CarPlay and normal branches)
  - `handleAudioInterruption(.ended)` — `setActive(true)` at `:307` (coordinator-bypassing; easy to miss)
  - `deactivateAudioSession` — direct `setActive(false)` fallback at `:439`
- **`TextToSpeechService`** — `AVAudioPlayer.play()` *implicitly* activates the session on main:
  the **main speech player** (`:619`, ElevenLabs + Kokoro playback — reachable without a prior
  activation when `pauseOtherAudio` early-returns in CarPlay/call-active modes,
  `WakeWordService.swift:123,127`), the tone/thinking players (`:395`, `:418`, `:767`), photo tone
  (`:366`), the thinking-timer repeat (`:771`); plus `overrideOutputAudioPort` on main in `speak()`
  (`:177–179`) and the `AVSpeechSynthesizer` fallback (`:641`).
- **`LiveTranslationService`** — `setCategory` + `setActive(true)` on the main actor (`:95–96`),
  re-run on every `restartListening()` cycle during continuous translation.
- **`TranscriptionService`** — fallback `AVAudioEngine.start()` on the main actor (`:149`, `:203`).

**Known-clean by inspection:** MemoryRewind/AmbientCaption (forwarded buffers only), MusicControlTool
(`MPMusicPlayerController`), `RealtimeAudioEngine.resumeAfterInterruptionOnQueue` (already on the
lifecycle queue).

**Explicitly out of scope (and therefore the TPC gate below is scoped, not absolute):** the realtime
managers also activate on main — `GeminiLiveSessionManager:331/:396`,
`OpenAIRealtimeSessionManager:218/:267`, and `RealtimeAudioEngine.attemptAudioResetOnQueue:438–441`
*deliberately* hops to main for `setupAudioSession` (that main-hop was Plan AP's deadlock-avoidance
design around `syncOnAudioLifecycleQueue` re-entrancy, `:511–516`). Moving realtime activation is a
separate follow-up with its own deadlock analysis; BJ does not touch it and does not claim its
warnings.

These are hang-**risk** warnings, not crashes, and are long-standing (not a regression). They are
invisible in Release (TPC is debug-only), but the underlying block is real.

## Why the coordinator is the fix home — and the two design corrections

Plan AS built `AudioSessionCoordinator` as the single session owner. It **deactivates off-main**
(`release` → `deactivationQueue.async`, `AudioSessionCoordinator.swift:106`) but **activates on the
caller's thread** (`acquire` runs `AudioSessionActivator.activate` inline, `:82`) — and the
WakeWordService methods above don't even use `acquire` (wake word self-activates then records via
`assumeOwnership`, `WakeWordService.swift:241`).

**Correction 1 — one queue, not a mirrored second queue.** The original draft proposed an
`activationQueue` mirroring `deactivationQueue`. That preserves (and widens) an existing race:
`release()` decides `.deactivate` under `stateQueue` but executes `setActive(false)` later on
`deactivationQueue` (`:103–108`), while an `acquire` activates elsewhere — a delayed deactivation can
land *after* a newer owner's activation and kill its session. BJ therefore puts **activation and
deactivation on one serial `sessionIOQueue`** (total order), and the deactivation block **re-checks
the ledger** before calling `setActive(false)` so a superseded deactivation becomes a no-op. This
*closes* the existing hole rather than copying it.

**Correction 2 — a new `reconfigure` path; do not reuse `AudioSessionActivator.activate`.** The
existing activator always deactivates first (`setActive(false, .notifyOthersOnDeactivation)`,
`AudioSessionActivator.swift:27` — would kill the live session mid-conversation and make Music
resume mid-pause) and has a fallback retry that silently swaps to `.default`+`[.defaultToSpeaker]`,
dropping `mixWithOthers` and the Bluetooth options (`:36–39`). Wake word's pause/resume/configure
never deactivate first and never fall back. The coordinator's new `reconfigure(...)` runs
setCategory→setActive **without a prior deactivate and without any fallback** — a transient failure
surfaces to the caller; it never silently changes the tuned options. Plan AS's contract (wake word
"keeps its hand-tuned `mixWithOthers` activation … those must not change") is preserved by
construction, not by hoping the shared path behaves.

## PR1 — the seam + serialization (deterministic, headless-testable)

The original draft claimed `AudioSessionActivator` "is unit-testable" — it is not: it takes a
concrete `AVAudioSession` with no protocol seam and has zero tests, and the coordinator is a
singleton with a hard-wired `AVAudioSession.sharedInstance()` (`AudioSessionCoordinator.swift:16–22,
83, 108`). **Building the seam is the real first phase:**

- `AudioSessionConforming` protocol (setCategory/setActive/overrideOutputAudioPort/currentRoute…)
  adopted by `AVAudioSession` and by a recording fake. Injected into `AudioSessionActivator` and
  `AudioSessionCoordinator` (keep `.shared` for production; add an internal init for tests — per
  house rule, tests use fresh instances, never `.shared`).
- Single serial `sessionIOQueue` for activation + deactivation with ledger re-check on deactivate
  (Correction 1); async `acquireOffMain(...)` and `reconfigure(...)` (Correction 2). Sync `acquire`
  stays for non-main callers.
- **Ledger-ahead-of-reality guard:** with async activation, `currentOwner` can say X before X's
  `setActive(true)` has run — and both `WakeWordService.handleAudioInterruption` (`:297–298`) and
  `ExpertCallAudioCoordinator.isBlockedByRealtime` consult it. The coordinator exposes
  `activationSettled` (the pending-activation barrier) so those checks can await/see the truth.

**PR1 tests (headless, no live `AVAudioSession`):** activation runs on `sessionIOQueue`, not the
caller's thread; setCategory-before-setActive order preserved; a superseded deactivation no-ops
(the race test — both directions driven on controllable executors); failed activation rolls the
lease back **through the coordinator** (today that invariant is only tested at the ledger level);
`reconfigure` never deactivates first and never falls back (recorded-args spy guards the
"must not change" contract); category/mode/options pass through verbatim.

## PR2 — wiring the call sites (thin edge — device-verified)

**Status:** 🚧 Wiring shipped — core ([#220](https://github.com/straff2002/OpenGlasses/pull/220)):
WakeWordService (pause/resume/configure/interruption/deactivate) + TextToSpeechService
(beginPause/endPause + main speech player) + `ConversationStartSequence.Deps` + CarPlay/App callers;
leaves ([#222](https://github.com/straff2002/OpenGlasses/pull/222)): `LiveTranslationService` +
`TranscriptionService` fallback. Compiles + headless suites + Release green; **on-glasses smoke test
gates merge**. **Two adjustments from the plan letter:** (1) `assumeOwnership` is **kept, not
retired** — wake word must not deactivate-first, so it records ownership then activates through the
no-deactivate `reconfigure` (rather than `acquireOffMain`, which deactivates first). (2) `stopSpeaking`
stays **synchronous** (barge-in must stop *now*); only its resume-other-audio is dispatched off-main,
so it doesn't ripple async to ~12 teardown callers.

- `WakeWordService.pauseOtherAudio` / `resumeOtherAudio` / `configureAudioSession` become `async`
  and route through `reconfigure` with the **identical** category/mode/options. The `:307`
  interruption-ended path and `:439` deactivation fallback route through the coordinator too;
  decide `assumeOwnership`'s fate explicitly — it is retired once wake word activates via the
  coordinator (nothing else uses record-only ownership).
- **Refcount reentrancy:** `pauseHoldCount` (`:120, :131–134, :162–166`) is currently atomic only
  because the methods are synchronous on the main actor; async-ification adds suspension points
  inside count-then-configure. Rule: mutate the count synchronously *before* the first await, and
  serialize the configure itself on `sessionIOQueue`, so nested `beginPause`/`endPause`
  (TTS `TextToSpeechService.swift:112`, conversation start `OpenGlassesApp.swift:2277`) still nest
  cleanly.
- **The async-ification is a breaking change to named seams — all updated in this PR:**
  - `ConversationStartSequence.Deps` types `configureAudioSession`/`pauseOtherAudio` as sync
    `@MainActor () -> Void` (`ConversationStartSequence.swift:19, 28`) — Deps, `run()`, and
    `ConversationStartSequenceTests` change; that file's ordering comment says it's load-bearing.
  - `TextToSpeechService.beginPause`/`endPause`/`stopSpeaking` (sync today; `stopSpeaking` is called
    from barge-in and `ExpertCallAudioCoordinator.swift:70`) — teardown must await the resume, not
    fire-and-forget.
  - `returnToWakeWord` (`OpenGlassesApp.swift:3338–3343`): resume → disconnect tone → "Resuming…"
    speech is an audible ordering; each step awaits the prior.
  - `reconfigureAudioSession` callers (`CarPlaySceneDelegate:171`, `OpenGlassesApp:327, :426`) and
    `startDirectTranscription` (Action-Button path) await the configure before starting engines.
  - Every engine-start-after-activation path awaits: `startListening` → `configureAudioSession` →
    `startRecognition` → `engine.start()` (`WakeWordService.swift:399, 405, 599`) **including** the
    interruption-ended and route-change restart Tasks (`:308, :346–351`).
- `TextToSpeechService`: coordinator owns activation before any `AVAudioPlayer.play()` (all six
  player sites, incl. `:619`); move the `speak()` `overrideOutputAudioPort` (`:177–179`) behind the
  awaited activation. `LiveTranslationService:95–96` and the `TranscriptionService` fallback engine
  starts route through the coordinator the same way.

## Scope / non-goals
- **No behaviour change** to categories, options, modes, mix/duck semantics, or pause/resume
  sequencing — the hand-tuned glasses/iPhone routing stays byte-for-byte (now enforced by the
  no-deactivate/no-fallback `reconfigure` + spy test, not by convention).
- Out: realtime managers' activation (see inventory — deliberate main-hop from Plan AP; separate
  follow-up), any new audio features.

## Verification
- Headless: the PR1 seam/race tests + updated `ConversationStartSequenceTests` + full suite green.
- **On-glasses smoke test (required before PR2 merge):** wake word start, tap-to-talk, TTS playback,
  pause-and-resume-other-audio (music playing → ask → resumes, tone/speech order intact), a Bluetooth
  route change mid-session, live translation loop, and an interruption (phone call) recovery.
  **TPC gate (scoped):** the WakeWordService / TTS / LiveTranslation / Transcription-attributed
  hang-risk warnings are gone; realtime-attributed warnings are expected to remain and are tracked
  as the follow-up. No audible/latency regression. Cannot be validated without Ray-Ban hardware.

## Sequencing
Independent of BH/BI. Natural continuation of the AO/AP/AS audio-resilience line; reuses the
`AudioSessionCoordinator`/`AudioSessionLedger` machinery. Two PRs: PR1 seam + serialization
(headless), PR2 call-site wiring (device smoke test gates merge). The realtime-activation follow-up
(with the `syncOnAudioLifecycleQueue` deadlock analysis) is **Plan BO** — sequenced strictly after
this plan's PR2 and sharing its on-glasses smoke session.
