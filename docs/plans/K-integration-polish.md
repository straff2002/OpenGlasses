# Plan K — Integration & Polish

Three smaller items that **finish or wire up** capabilities already in the codebase. Low risk, each independently shippable. Grouped because none warrants its own plan.

---

## K1. A3 Assistive Mode → main HUD + live transcription routing

**State today:** `AssistiveModeToggleView` exists and works, but is surfaced only in Accessibility settings. `AssistiveRouter` can route Scene vs Social, but `AssistiveModeService.noteTranscription(_:)` is never called from the live transcript path, so **Social mode never triggers in practice**.

**Work:**
- Place `AssistiveModeToggleView` in the main HUD bottom bar (the capsule/StatusIndicator area in `OpenGlassesApp`'s ContentView). Keep the existing capsule + StatusIndicator (per UI-style preference) — add the toggle alongside, don't replace.
- Feed finalized user transcriptions into `AssistiveModeService.shared.noteTranscription(...)` while assistive mode is active (hook in the transcription handler / `handleBargeIn` path) so the router can pick Social mode when the user asks about a person.

**Effort:** ~half day. **Risk:** touches the main HUD layout — verify in the running app, not just tests.

---

## K2. Field Assist Phase 5 — live expert escalation over WebRTC

**State today:** `EscalationCoordinator` runs the full state machine; `ExpertBridge` is a protocol with a `PendingExpertBridge` stub (`connect` throws `.notImplemented`). `WebRTCStreamingService` already streams the glasses camera to a browser viewer.

**Work:**
- `WebRTCExpertBridge: ExpertBridge` backed by `WebRTCStreamingService` — outbound glasses camera + mic, inbound expert audio; `connect`/`disconnect`/`isConnected`.
- Swap `EscalationCoordinator.bridge` from `PendingExpertBridge` to `WebRTCExpertBridge` (one line; the seam was built for this).
- A real `ExpertNotifier` (push / Slack / email) replacing `StubExpertNotifier`, plus an expert-side join surface (reuse the existing WebRTC web viewer).
- Record expert id + connection span in the session audit (already modeled in `SessionExport.escalations`).

**Effort:** ~1 week (real-time infra + expert-side client). **Revenue:** unlocks the "Human+AI" Field Assist Pro tier.

---

## K3. CarPlay heading smoothing with OneEuroFilter

**State today:** `OneEuroFilter` shipped (Plan D1) with a wrap-safe `filterAngle`. `CarPlaySceneDelegate` exists and CarPlay is a first-class feature.

**Work:**
- Where CarPlay (or any UI) consumes a compass/`CLHeading`, run the value through a `OneEuroFilter` (`filterAngle`) instance to kill jitter while staying responsive on turns.
- Single filter instance per consumer; `reset()` on heading-source restart.

**Effort:** ~half day. **Risk:** minimal — pure utility already unit-tested; just a call-site wiring + on-device feel check.

---

## Build order

Independent; suggested by value/ease: **K1** (completes a shipped feature) → **K3** (trivial, improves a first-class feature) → **K2** (largest, but highest B2B payoff).

## Dependencies

- K1: A3 (shipped). K2: `EscalationCoordinator`/`ExpertBridge` (shipped) + `WebRTCStreamingService` (existing). K3: `OneEuroFilter` (shipped) + `CarPlaySceneDelegate` (existing).
