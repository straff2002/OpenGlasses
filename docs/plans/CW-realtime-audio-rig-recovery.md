# Plan CW — Realtime Audio Rig Recovery

**Status: 🚧 Core shipped 2026-08-22** — P1 + P2 + two of P3's three items landed; P4 device
verification is still owed, and one P3 item (drain the playout tail at hang-up) is deferred with a
reason recorded below.

A realtime reply arrives as a stream of PCM deltas that we schedule onto a player node as they land.
The rig underneath that player is not stable: `AVAudioSession` re-routes, and **a route settle
briefly stops the engine**. Today a route change mid-reply does not pause the rig — it *rebuilds*
it, and every already-scheduled buffer is detached and discarded with no accounting and no
notification to anyone.

The failure this produces is specific and nasty: **the first reply of a session is the one most
likely to be lost.** `.playAndRecord` + voice-processing IO settles over the first second or so of a
session — the exact window in which the first response's audio is already queued. Later turns come
up on a stable route, rebuild nothing, and play fine. So the symptom is *"it didn't speak the first
time, then it worked every time after"*, which reads as a flaky backend rather than as an audio-rig
bug, and is why this has not been chased down before.

Two independent defects stack to produce it:

1. **A stopped engine is treated as a broken graph.** `RealtimeAudioEngine.handleRouteChangeNotification`
   (`RealtimeAudioEngine.swift:542`) asks `AudioInterruptionPolicy.action(for:isCapturing:)`
   (`AudioInterruptionPolicy.swift:66`), which returns `.resetGraph` for `.oldDeviceUnavailable` **and
   `.newDeviceAvailable`** — and a glasses HFP mic coming up at session start is precisely
   `.newDeviceAvailable`. `attemptAudioResetOnQueue` (`:584`) then tears the whole graph down and
   rebuilds from `setupAudioSession`. But if the nodes are still attached to the same engine and only
   the engine stopped, `start()` would have been sufficient and would have kept the queued reply.
   The scheduling path already knows this — `playAudioOnQueue` (`:387`) restarts a dead engine rather
   than dropping the data — the *recovery* path just doesn't.
2. **A genuine rebuild drops playback silently.** `tearDownEngineGraphOnQueue(flushPendingAudio:)`
   (`:608`) — despite the name — flushes only **captured uplink** audio (`accumulatedData`). The
   playback side is `playerNode.stop()` + `detach`, and whatever was scheduled and unplayed is gone.
   Nothing carries it to the new graph, nothing counts it, and — the part that compounds the
   damage — nothing tells the backend. `OpenAIRealtimeSessionManager.swift:131` reports
   `confirmedPlayedMilliseconds` on `conversation.item.truncate` so the model's context matches what
   the wearer heard; a rebuild bypasses that path entirely, so the model believes it delivered a
   reply that was never rendered and the conversation continues from a false premise.

**Dropping buffered audio is silent, and silence sounds exactly like "the assistant never spoke".**
That is what makes this worth a plan rather than a one-line guard: the class of bug is
"audio that was queued must survive the rig changing under it", and the fix has to be a decision we
can test headlessly, not a reflex added at one call site.

## Scope note — this is not CC, CJ or AO again

- **[CC](CC-duplex-live-audio.md)** established the duplex *tier* (voice processing on a fresh
  engine, graded fallback to half-duplex). CW does not touch that decision; it is about what happens
  to the rig **after** the tier is chosen.
- **[CJ](CJ-survey-hardening-sweep.md) item 6** established that played-milliseconds come from
  hardware completion callbacks, never wall-clock. CW extends that ledger to cover a case it does
  not currently see — buffers discarded by a *rebuild* rather than by `stopPlayback()`.
- **AO / `AudioSessionCoordinator`** arbitrates *ownership* of the shared session between engines.
  CW is downstream of that: it assumes we still own the session and asks only whether the graph
  needs rebuilding.

## P1 — `AudioGraphRecovery` (pure core, lands first) ✅

A pure decision function, no `AVAudioEngine` in its signature, over an observed graph state:

```
inputs:  reason (route change / interruption end / scheduling-time discovery)
         engineRunning: Bool
         nodesAttached: Bool
         formatChanged: Bool          // input format differs from the one the tap was built for
         isCapturing: Bool
output:  .none | .restart | .rebuild(carryPlayback: Bool)
```

The rules, each of which is a bug we are choosing not to have:

- **Nodes attached + engine stopped + format unchanged ⇒ `.restart`.** The session-start settle. No
  teardown, no re-tap, queued playback survives untouched.
- **Format changed ⇒ `.rebuild`**, unconditionally. A tap and a converter built for 48 kHz phone
  input produce garbage on an 8 kHz HFP link; this is the same hazard [CU](CU-voice-turn-latency.md)
  P2 names for the VAD converter, one layer up. Restarting into a stale format is worse than
  rebuilding.
- **Nodes detached ⇒ `.rebuild(carryPlayback: true)`.** The graph really is broken; the pending
  reply still must not evaporate.
- **Not capturing ⇒ `.none`.** Matches today's `isCapturing` guard.

Testable as a table of `(state) → action` fixtures, which is the whole point of extracting it: the
current logic is three booleans read inline on the lifecycle queue, where none of these cases can be
exercised without hardware.

## P2 — Playback carry-over and honest accounting ✅

`playerNode.scheduleBuffer` is fire-and-forget; once scheduled we cannot ask the node what it still
holds. So the carry-over has to be maintained on our side, as a **pending queue that mirrors what
was scheduled**, retired by the same `.dataPlayedBack` completion that already drives
`PlaybackProgressLedger`. That mirror is the deliverable — pure, bounded, and unit-testable without
an engine:

- `scheduled(frames:)` already returns a generation; the mirror stores `(generation, buffer)` and
  drops entries as their completion fires.
- On `.rebuild(carryPlayback: true)`: drain the mirror, then re-schedule the survivors onto the new
  player node **under the same generation**, so the ledger's played-count is continuous across the
  rebuild rather than restarting at zero.
- On a rebuild where carry-over is impossible or refused (format change — the buffers no longer
  match the output format), **the discarded frames must be reported, not swallowed**:
  `confirmedPlayedMilliseconds` stays truthful, and the session manager gets the same
  truncate-on-loss path it already uses for barge-in. A reply the wearer did not hear must not stay
  in the model's context as though they did.
- Bound the mirror by bytes, not by count. Servers burst whole sentences ahead of real time, so
  several seconds of PCM can be outstanding; an unbounded mirror is a memory leak on a long session.

**Deferred out of P2, deliberately:** Gemini Live. `GeminiLiveSessionManager` has no played-ms
consumer today (`confirmedPlayedMilliseconds` is read only by the OpenAI manager,
`OpenAIRealtimeSessionManager.swift:131`), so the truncate half has nothing to talk to there. The
carry-over itself is engine-level and benefits both; the reporting half lands for OpenAI Realtime
first and Gemini follows when its interrupt path is wired.

## P3 — Teardown hygiene 🚧

Three small ones, each a known way for the *next* session to come up wrong:

- **Disable voice processing before dropping an engine.** `prepareEngineOnQueue` (`:336`) enables it
  on a fresh engine and `replaceEngineOnQueue` (`:364`) discards that engine without ever calling
  `setVoiceProcessingEnabled(false)`. Our per-capture fresh-engine construction probably covers this
  by luck — the reported failure mode elsewhere is *"no mic on the next session until relaunch"* —
  but relying on ARC to retire an IO unit is not a guarantee we should be making. Explicit stop →
  disable → reset, then drop.
- **Refuse to start a deaf engine.** After enabling voice processing we already probe for the
  zero-sample-rate dead-IO signature (`VoiceProcessingProbe`). Apply the same check on `.restart`:
  a restart that comes back at 0 Hz must escalate to `.rebuild`, not report success.
- **Drain the playout tail before the route drops.** Rendered is not heard on a Bluetooth HFP link.
  A farewell or an end cue that is followed immediately by session deactivation gets truncated, or
  surfaces from the phone speaker after the route has already switched back. Wait the output
  latency plus a margin before tearing the rig down.

  **Deferred, 2026-08-22.** The only place this belongs is `stopCapture()`, which both session
  managers call from a synchronous `@MainActor stopSession()`; a bounded wait there blocks the main
  thread at hang-up, which is a worse defect than the one it fixes. Doing it properly means an
  `async` teardown signature through both managers — a change with its own blast radius that has no
  business riding along with a playback-accounting fix. Landing the policy alone was rejected: an
  unreferenced pure function is not a partial fix, it is dead code that reads as one.

## Riders

- **Route-pinned cues.** Any tone that belongs to a live session — start, end, error — must be
  rendered through *that session's* engine, not a private one, or it plays out of the phone speaker
  after a route switch instead of in the wearer's ear. Cheap to get right while P3 is already in the
  teardown ordering; wrong by default otherwise.
- **Per-route input gain.** The phone mic at arm's length reads much quieter than a glasses mic at
  the temple, and every downstream threshold — barge-in, and CU P2's acoustic detector — is
  calibrated against that level. A clamped per-`MicRoute` gain belongs with CU P2's threshold work,
  not here; noted so the two don't get tuned against each other.

## P4 — Device verification (deferred, gates the defaults)

Everything above is decision logic and can be tested headlessly. What cannot:

- **First-reply survival on glasses HFP**, cold session, repeated — the whole point. Instrument with
  CU P1's `TurnTimeline` (`firstAudioAt` present or absent) rather than by ear.
- **Route-change mid-reply**: glasses disconnect while speaking, phone call in and out, AirPods
  stolen mid-sentence. Assert continuity of `confirmedPlayedMilliseconds` across each.
- **Restart-vs-rebuild ratio** in the field. If `.restart` never fires, the policy is mis-tuned; if
  `.rebuild` never fires, we have not tested a real route flip.
- **Teardown**: mic alive on the session immediately after a hang-up, no orange indicator left on.

## Non-goals

- **Reopening the duplex tier decision.** CC's fresh-engine-then-enable ordering stays exactly as it
  is; it is load-bearing on recent iOS builds.
- **A general audio-graph state machine.** The decision function is deliberately four rules over five
  booleans. If it grows past a table, that is a signal we have mis-modelled the problem, not a reason
  to build a framework.
- **Direct-mode TTS playback.** `TextToSpeechService` schedules through its own path with different
  failure modes; if the mirror proves useful there it can be lifted later.

## Open questions

- Should `.newDeviceAvailable` still map to `.resetGraph` at all once `.restart` exists, or does the
  format check subsume it? Leaning subsume — but it needs P4's restart/rebuild ratio to answer
  honestly. **Still open.** The shipped table is deliberately trigger-invariant and a test
  (`testDecisionIsInvariantAcrossTriggers`) pins that, so adding a per-trigger branch has to be a
  decision somebody makes rather than one that drifts in.
- ~~Does the carry-over mirror belong in `RealtimeAudioEngine` or beside `PlaybackProgressLedger`?~~
  **Answered by building it:** `PendingPlaybackMirror` is its own pure type alongside the ledger and
  **shares the ledger's generation** rather than minting one. The two are updated at exactly the
  same three points (scheduled / played / reset), so there is one source of truth for "what is
  outstanding" without merging two things that answer different questions — the ledger says what
  was *heard*, the mirror holds what has *not been*.
- Is there a bounded number of rebuilds after which we should stop trying and surface a real error
  to the wearer, rather than looping a rebuild that keeps failing?
