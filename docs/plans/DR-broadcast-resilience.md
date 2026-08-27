# Plan DR — Broadcast Resilience and Evidentiary Recording

**Status:** 📝 Drafted (2026-08-27)
**Origin:** 2026-08-27 ecosystem review — verified gap: a dropped RTMP connection mid-broadcast dies silently.
**Priority:** P1 is the user-visible bug ("my stream just stopped"); P2/P3 are capability growth.

`BroadcastService` ([BroadcastService.swift](../../OpenGlasses/Sources/Services/BroadcastService.swift))
has no reconnect, retry, or backoff anywhere. `StreamRecoveryPolicy` looks adjacent but is Plan BR's
*camera*-stream recovery — it restores frames from the glasses to the phone, and nothing restores the
phone-to-RTMP leg. A network blip during a live broadcast today ends the broadcast, and the wearer
(whose phone is pocketed) finds out from their audience.

---

## Relevant seams

- `OpenGlasses/Sources/Services/BroadcastService.swift` (HaishinKit `RTMPConnection`/`RTMPStream` wiring)
- `OpenGlasses/Sources/Services/BroadcastSupport.swift`
- `OpenGlasses/Sources/Services/StreamRecoveryPolicy.swift` (pattern precedent only — camera leg, do not extend)
- `OpenGlasses/Sources/Services/SessionRecorderController.swift`, `RecordedSessionStore.swift` (P3)
- `OutboundFrameRelay` (privacy chokepoint — any new outbound consumer subscribes here, never to
  `cameraService.framePublisher`; see CLAUDE.md Privacy Filter scope)

## Decisions and invariants

1. **Reconnect is policy, not wiring.** A pure `BroadcastRecoveryPolicy` decides, from
   `(consecutiveFailures, elapsedSinceLastHealthy, userStopped)`, one of
   `reconnect(delay:)` / `giveUp(reason:)`. Exponential backoff 2 s → 30 s cap, bounded attempts
   (default 5), reset on a healthy interval. Testable as a table, no network.
2. **A reconnecting broadcast is announced, not silent.** State gains
   `.reconnecting(attempt:delay:)`; TTS gets one spoken notice on first drop and one on give-up —
   not one per attempt (the wearer can't act on a countdown).
3. **User stop always wins.** `userStopped` short-circuits the policy to `giveUp` without a spoken
   failure notice; a deliberate stop must never read as an error (same lesson as the camera leg's
   deliberate-stop handling in Plan DT).
4. **Multi-destination is N independent sessions, not one shared fate.** Each extra destination gets
   its own connection, stream, per-destination state machine, and its own bounded retry (default 1 —
   secondary destinations are best-effort). One destination failing must not touch the others or the
   primary. Frames fan out as copies from the single privacy-filtered relay tap.
5. **Recording outlives broadcasting.** If local session recording is active, a broadcast drop never
   interrupts it — the local artifact is the thing of record.

## Phases

**P1 — Reconnect core (pure).** `BroadcastRecoveryPolicy` + `BroadcastSessionState` (idle →
connecting → live → reconnecting → ended/failed) as data-driven state machines with full headless
tests: backoff ladder, attempt cap, healthy-interval reset, user-stop precedence, the
one-notice-per-episode TTS rule.

**P2 — Wiring + multi-destination.** Drive `BroadcastService` from P1's machine; add
`ParallelBroadcastCoordinator` holding per-destination `RTMPConnection`/`RTMPStream` pairs (cap 4
extra), each fed frame copies off the existing relay subscription. Settings: additional-destination
list behind the existing broadcast settings surface. Device smoke deferred: real RTMP endpoint drop
tests (kill Wi-Fi mid-stream) are the P2 exit gate, run manually.

**P3 — Caption-burned evidentiary export.** For Field Assist / Medical sessions: an export path that
renders the session's caption track into the recorded frames, preserving **true source timing** —
per-frame `CMTime` computed from capture timestamps, never re-stamped at the encoder's nominal rate
(a low-fps glasses stream must not export as a time-lapse). Pure core: a `CaptionBurnPlan`
(frame timestamps + caption spans → per-frame overlay text and presentation times) that is
fully testable without AVFoundation; the `AVAssetWriter` edge consumes the plan. Export lives next to
the existing recordings UI; HIPAA export rules from Plan DL apply unchanged.
