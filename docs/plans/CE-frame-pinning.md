# Plan CE — Frame Pinning ("this" means this)

**Status: ✅ P1+P2 shipped (2026-08-01)** — `FramePin` / `FramePinGate` (immediate sharp-inject
on pin credited against the heartbeat via `notePinnedPushed`; suppress until heartbeat; unpin
clears) / `FramePinReleaseTrigger`+`FramePinReleasePolicy` (allCases-walked test so new triggers
must decide consciously; expiry off by default), wired at all three chokepoints behind
`Config.framePinEnabled` (default on): push gate with sharp-inject resends bypassing the
throttler, poll substitution, Direct-mode photo reuse in `currentVisionFrameDataIfAvailable`
(pin works even with the camera stopped). Release triggers wired: mode switch, session stop
(glasses disconnect + stop-everything), camera teardown on backgrounding. Unpin resets both
session managers' `FrameThrottler` dedup gates so the first live frame is a keyframe. Surfaces:
`LivePreviewView` long-press pin + `PinnedFrameCard` overlay (tap to release, haptics),
`pin_frame` NativeTool (pin/unpin/status via `AppStateProvider`), HUD `flash` cues on
pin/release (a persistent HUD indicator would fight the caption surface — revisit with P3).
**P3 (device validation) remains deferred** — heartbeat sufficiency under live suppression,
gesture-to-frame latency, launcher quick action.

Let the user **pin the current camera frame** so that "this" stays stable. Pointing at the
world and saying "what's this?" fails the moment the camera moves — and on glasses the camera
*is* the user's head, so it always moves. Pinning freezes what the model sees: the screen shows
the pinned frame as a card over the still-live preview, the model receives nothing newer, and
the user and the model provably agree on what "this" refers to. Unpin (tap, or voice) and the
conversation moves on live.

## Why this matters more on glasses

A phone can at least be held still. Glasses cannot: between the user saying "this" and the
model answering, the wearer has looked at the person they're talking to, down at their hands,
back up. In Gemini Live / OpenAI Realtime modes the session receives a continuous frame feed,
so the model's referent silently drifts; in Direct mode each query captures a *new* photo, so
follow-up questions ("and what's the part number on it?") re-shoot a different scene. Pinning
fixes both with one concept.

## What exists today (the seams are already there)

The model-facing frame path is narrow and already runs through three chokepoints, all in
`OpenGlassesApp.swift` AppState wiring:

- **Push:** `cameraService.onVideoFrame = { image in session.submitVideoFrame(image) }` —
  direct push into whichever live session is active.
- **Poll:** `geminiLiveSession.onRequestVideoFrame` / `openAIRealtimeSession.onRequestVideoFrame`
  both return `cameraService.latestFrame`.
- **Direct-mode photo:** the photo-analysis path captures via `capturePhoto` with a
  `latestFrameAsJPEG()` fallback.

Crucially, the *other* `framePublisher` consumers (`BroadcastService`, `WebRTCStreamingService`,
`FaceRecognitionService`, `ReadingCompanionService`, expert-stream transports,
`VideoRecordingTool`) must keep receiving live frames — a pin freezes **what the model sees**,
never the recording, broadcast, or safety pipelines. That rules out gating inside
`CameraService` itself; the pin gate belongs at the model-facing chokepoints only.

## Pure core (the testable half)

- **`FramePin`** (pure state): `pinnedFrame: UIImage?`, `pinnedAt: Date?`, `pin(frame:at:)`,
  `unpin()`, `isPinned`. Single source of truth, owned by AppState.
- **`FramePinGate`** (pure policy): given `(isPinned, now, lastModelSend)` decides per incoming
  frame — `.deliverLive` (not pinned), `.suppress` (pinned, model already has the pinned frame),
  or `.resendPinned` (pinned + heartbeat interval elapsed — keeps long-lived realtime sessions
  from treating the feed as dead; cadence mirrors the `FrameGate` heartbeat from Plan AT).
  On `pin()`, the gate's first decision is always `.resendPinned` — the exact pinned frame is
  pushed to the session *immediately*, so the model's referent is the on-screen frame, not
  whatever the throttler last sampled. (A continuous-feed design that merely mutes the video
  leaves the model's copy trailing by up to one sampling interval; because our push path is
  direct, we can hand the model the precise frame and dodge that coarseness entirely.)
- **Unpin triggers** (pure policy, tested): explicit unpin, session stop, mode switch, camera
  teardown, and an optional max-age auto-expiry (default off; a pin is an explicit act).
- **Interplay with Plan AT's `FrameGate`:** while pinned, the throttler/dedup gate is bypassed
  (no frames are being evaluated); on unpin the gate resets so the first live frame is always
  sent as a keyframe.

All headless-testable: feed synthetic frames, assert delivery decisions, heartbeat cadence,
poll-path substitution, and unpin-resume behavior. No device, no session.

## Wiring (thin, mechanical)

- `onVideoFrame` closure consults the gate: pinned → suppress/resend per decision.
- `onRequestVideoFrame` closures return `framePin.pinnedFrame ?? cameraService.latestFrame`.
- Direct-mode photo analysis uses the pinned frame when one is held (skip capture, use the pin) —
  this is what makes multi-turn "and the label? and the connector?" interrogation of one scene
  work in Direct mode.

## UI + voice edge

- **Pin gestures:** long-press on `LivePreviewView` (and the phone-camera preview) pins the
  current frame; the pinned frame renders as a card floating over the still-live preview
  (the user can see both "what the model sees" and "what the camera sees" — the disagreement
  *is* the feature). Tap the card (or anywhere) to unpin. Success haptic on pin, light impact
  on release, matching the existing `UINotificationFeedbackGenerator` conventions.
- **Voice:** a `pin_frame` NativeTool (`pin` / `unpin` / `status`) — "pin this", "hold that
  thought", "let go" — registered in `NativeToolRegistry`; description feeds the prompt via
  `SystemPromptBuilder` as usual. Voice is the primary interface on glasses, where there is no
  screen to long-press.
- **HUD:** a small "📌 PINNED" indicator on the glasses HUD while a pin is held (via the
  existing display path), so the wearer never wonders why the assistant is ignoring what they're
  looking at now.

## Phases

- **P1 — pure core:** `FramePin` + `FramePinGate` + unpin-trigger policy + AT-gate interplay,
  wired through the three chokepoints behind a `Config.framePinEnabled` flag (default on —
  inert until a pin is taken). Named tests for every decision above.
- **P2 — surfaces:** preview long-press + pinned-card overlay + haptics; `pin_frame` tool;
  Direct-mode photo integration; HUD indicator.
- **P3 — device validation (deferred):** live Gemini/OpenAI behavior under suppression
  (heartbeat sufficiency), glasses-camera latency between gesture and pinned frame, and whether
  a pin should also be offered from the launcher (Plan Y) quick actions.

## Open questions

- Should a pin survive a live-session reconnect (Plan CF's redial)? Leaning yes — re-push the
  pinned frame into the new session on connect; the referent is the user's intent, not the
  session's lifetime.
- Multi-pin (a small tray of pinned frames, "compare this with the first one") is deliberately
  out of scope for v1 — it's a different feature (visual state memory, Plan AT's foundation)
  wearing this one's clothes.
