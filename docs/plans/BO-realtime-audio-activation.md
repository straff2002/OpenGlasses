# Plan BO — Realtime Audio Activation (post-BJ follow-up)

**Status:** ✅ Code shipped ([#223](https://github.com/straff2002/OpenGlasses/pull/223)) —
both realtime managers' `setupAudioSession` now activates off-main via the coordinator's
`acquireOffMain`; `attemptAudioResetOnQueue` recovery hops to a `@MainActor` Task and awaits it; the
queue-ordering / deadlock-freedom contract is documented in the `RealtimeAudioEngine` header. Headless
coordination tests + Release green; **on-glasses smoke test still owed** (PR #223 merged without a
recorded smoke pass — shares BJ's session: Gemini
Live + OpenAI Realtime start/stop, phone-call interruption + BT route flip mid-realtime, TPC panel
clean across the app). **Sequenced strictly after Plan BJ PR1+PR2** (both merged).
**Origin:** Plan BJ's 2026-07-10 re-scope deliberately excluded the realtime managers from the
off-main activation move; the review sweep confirmed that exclusion leaves TPC hang-risk warnings
and one ownership hole in a path that today belongs to no plan. This plan is that home.

## The residue BJ leaves (verified)

- `GeminiLiveSessionManager` (`@MainActor`) calls `audioManager.setupAudioSession` at `:331/:396`;
  `OpenAIRealtimeSessionManager` at `:218/:267` — session activation on the main thread.
- `RealtimeAudioEngine.attemptAudioResetOnQueue` **deliberately hops to main** for
  `setupAudioSession` (`RealtimeAudioEngine.swift:438-441`) — that main-hop was Plan AP's
  deadlock-avoidance design around `syncOnAudioLifecycleQueue` re-entrancy (`:511-516`). Moving it
  is exactly the deadlock analysis BJ declined to do inline.
- After BJ, the scoped TPC gate passes with realtime-attributed warnings still present; this plan
  removes those.

## Prerequisites (why this must wait for BJ)

BJ PR1 builds the seam this plan needs: `AudioSessionConforming` + injectable coordinator, the
single serial `sessionIOQueue` with ledger re-check, and the `activationSettled` barrier. BJ PR2
retires `assumeOwnership` and proves the async-ification pattern on the wake-word/TTS callers.
Plan BM P5 lands the `resumeAfterInterruptionOnQueue` owner check (a standalone bug fix that must
not wait for this plan).

## Build (one PR)

1. Route both realtime managers' `setupAudioSession` through the coordinator's off-main
   `acquireOffMain`, awaiting `activationSettled` before engine start — same pattern as BJ PR2's
   wake-word wiring.
2. **The deadlock analysis is the deliverable, not a rider:** map every path into
   `syncOnAudioLifecycleQueue` (`RealtimeAudioEngine.swift:511-516`) against the new
   `sessionIOQueue` hop; the recovery path (`attemptAudioResetOnQueue`) must not sync-wait on a
   queue that can be waiting on it. Document the queue-ordering contract in the file header.
3. Preserve Plan AP's recovery semantics (generation counters, self-healing rebuild) — behavior
   unchanged, thread unchanged *observable* ordering; only where activation runs moves.
4. Remove the "realtime out of scope" carve-outs from BJ's TPC gate: after this PR the hang-risk
   warnings are gone across the app, full stop.

## Tests
- Headless (on BJ's fakes): manager acquire lands on `sessionIOQueue`; engine start awaits
  `activationSettled`; a recovery reset during a pending activation neither deadlocks nor
  double-activates (drive both queues with controllable executors).
- Device (gates merge, one session with BJ's smoke list): Gemini Live + OpenAI Realtime start/stop,
  phone-call interruption mid-realtime, BT route flip mid-realtime, and the TPC panel clean.

## Sequencing
After BJ PR2. Shares BJ's on-glasses smoke session (and Plan AP's device-validation item folds in
here — one device pass covers AP recovery + BJ + BO).
