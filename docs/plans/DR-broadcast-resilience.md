# Plan DR — Broadcast Resilience and Evidentiary Recording

**Status:** 📝 Drafted (2026-08-27)
**Origin:** 2026-08-27 ecosystem review — verified gap: a dropped RTMP connection mid-broadcast dies silently.
**Priority:** P1 is the user-visible bug ("my stream just stopped"); P2/P3 are capability growth.

**Note (2026-09-08): partially superseded.** [Plan CY](CY-broadcast-resilience-and-quality.md)
([#337](https://github.com/straff2002/OpenGlasses/pull/337), merged 2026-08-25 — two days before
this plan was drafted) already shipped the reconnect/backoff/session-state core this plan's P1 asked
for: `BroadcastSessionMachine` (idle→connecting→live→reconnecting(attempt:)→failed, exactly the
state machine proposed below) and `BroadcastReconnectPolicy` (1/2/4…60s capped exponential backoff,
stable-reset, give-up budget) in
`OpenGlasses/Sources/Services/BroadcastResilience.swift`, plus adaptive bitrate this plan didn't even
ask for. What's still genuinely missing from P1: a **spoken TTS notice** on first drop / give-up —
CY's reconnect path logs and calls `PrivacyLog` but never speaks. P2 (multi-destination fan-out) and
P3 (caption-burned evidentiary export) remain entirely unbuilt.

`BroadcastService` ([BroadcastService.swift](../../OpenGlasses/Sources/Services/BroadcastService.swift))
previously had no reconnect, retry, or backoff anywhere — that gap is now closed by CY, above.
`StreamRecoveryPolicy` looks adjacent but is Plan BR's
*camera*-stream recovery — it restores frames from the glasses to the phone, distinct from the
phone-to-RTMP leg CY's `BroadcastReconnectPolicy` now covers. A network blip during a live broadcast
now reconnects rather than ending the broadcast silently; the remaining gap is that it does so
without telling the wearer.

---

## Relevant seams

- `OpenGlasses/Sources/Services/BroadcastService.swift` (HaishinKit `RTMPConnection`/`RTMPStream` wiring)
- `OpenGlasses/Sources/Services/BroadcastSupport.swift`
- `OpenGlasses/Sources/Services/StreamRecoveryPolicy.swift` (pattern precedent only — camera leg, do not extend)
- `OpenGlasses/Sources/Services/SessionRecorderController.swift`, `RecordedSessionStore.swift` (P3)
- `OutboundFrameRelay` (privacy chokepoint — any new outbound consumer subscribes here, never to
  `cameraService.framePublisher`; see CLAUDE.md Privacy Filter scope)

## Decisions and invariants

1. ~~**Reconnect is policy, not wiring.** A pure `BroadcastRecoveryPolicy` decides, from
   `(consecutiveFailures, elapsedSinceLastHealthy, userStopped)`, one of
   `reconnect(delay:)` / `giveUp(reason:)`. Exponential backoff 2 s → 30 s cap, bounded attempts
   (default 5), reset on a healthy interval. Testable as a table, no network.~~ **Already exists,**
   shipped by Plan CY as `BroadcastReconnectPolicy` (1/2/4…60s capped exponential backoff, stable-reset,
   give-up budget) driving `BroadcastSessionMachine`. This plan's P1 scope reduces to the one thing CY
   didn't build: a spoken TTS notice on first drop and on give-up (one-notice-per-episode).
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

---

## Amendment 2026-10-10: P1 grows a phone-camera fallback

From the [October 2026 ecosystem review](../ecosystem-review-2026-10.md) (section 4 row "Spoken
broadcast drop and recovery, automatic phone fallback"; section 5 confirms CY's reconnect is done).
Status unchanged: 📝 drafted, nothing of P1 built. Re-checked on `main` at `48bcae0c`:
`BroadcastService` still never speaks and nothing in `App/` observes its session state; source
switching is manual through `BroadcastSourceSelector` (`Services/BroadcastSupport.swift:69-87`,
1 s debounce); and glasses frames that stop arriving surface only as `BroadcastStallPolicy`'s 8 s
"nothing on the wire" verdict (`Services/BroadcastResilience.swift:480-500`), which watches bytes
sent, not the glasses.

P1 is now two pure policies and their wiring, one PR:

1. **`BroadcastNoticePolicy`** (the spoken notice this plan always meant). Input: the
   `BroadcastSessionMachine` state, seconds since the episode began, whether the user stopped it,
   and what has been said this episode. Output: a line or nothing. Drop: "Your stream has dropped;
   reconnecting." Still down: one reminder each at 30, 60 and 120 s, then silence until recovery or
   give-up. Recovered: "Your stream is back." once. Give-up: "The stream couldn't reconnect and has
   stopped." A user stop is silent. The time-based reminders are a deliberate change from
   invariant 2's "first drop and give-up only": invariant 2 rejected a reminder *per attempt*,
   which a wearer cannot act on; three reminders over two minutes tell a streamer who is talking to
   an audience that they are still not live, and then stop. Spoken through the normal speech path,
   never over the assistant.
2. **`BroadcastAutoSourcePolicy`.** Input: seconds since the last glasses frame reached the relay,
   seconds of fresh glasses frames since they resumed, the active source, whether the user pinned a
   source, and whether the phone camera is available. Output: `.stay`, `.switchToPhone` or
   `.switchToGlasses`. Glasses frames stale for 2 s switch to the phone's back camera; about 5 s
   of fresh glasses frames switch back; a user-pinned source is never overridden; at most one
   switch per 5 s beyond the selector's own debounce. Switching goes through
   `BroadcastService.switchSource`, so the RTMP session is untouched, and phone frames already pass
   `OutboundFrameRelay`, so the privacy filter scope is unchanged (no new roster entry). Each
   automatic switch is said once ("Switched to the phone camera" / "Back to the glasses").

**Tests:** `BroadcastNoticePolicyTests` (drop, reminders at 30/60/120 only, recovery once, user stop
silent, give-up) and `BroadcastAutoSourcePolicyTests` (2 s stale switches, 1.9 s does not, return
after 5 s fresh, pinned source never moves, no phone camera means stay). Device pass owed: pull the
glasses' battery mid-broadcast and hear the switch; drop Wi-Fi and hear the notices.

Frame pacing on the same file (a 24 fps setting sending about 15) is item 2 of Plan
[ID](ID-ecosystem-review-hardening-bundle.md), independent of this phase.
