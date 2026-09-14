# Plan EZ — Adaptive Camera Capture

**Status: 📝 Drafted 2026-09-12; not scheduled.** One PR for the pure decision core and
capability-gated backend adoption; device results govern rollout.

## Gap and existing coverage

[AT](frame-dedup-change-gate.md) reduces frames forwarded to the model; its default-on
motion check is already tracked there. It does not lower the camera's capture rate.
[BV](BV-power-policy.md) stretches forwarding intervals under power pressure.
[EO](EO-hevc-glasses-stream.md) owns codec negotiation and measured delivered rates.
EZ addresses sensor work on static scenes, without claiming transmission savings prove sensor savings.

## Scope and build order

1. Audit the installed camera backend/SDK's supported FPS and resolution values, whether they
   can change while streaming, and restart cost. Do not assume runtime FPS mutation exists. The
   pinned DAT SDK (0.9.0) sets codec, resolution and frame rate through `StreamConfiguration` at
   `addCamera(config:)`, its interface exposes no runtime mutation API, and re-adding the camera
   before the previous `Camera` reaches `CameraState.stopped` throws `capabilityAlreadyActive` —
   so any source change is a stop-and-re-add at a session boundary until the `.swiftinterface`
   shows otherwise.
2. Build a pure capture-budget policy with injected time, scene-change evidence, user FPS/resolution
   ceilings, BV posture and active consumer requirements. Static dwell lowers the target; motion
   restores it within ceilings. Use hysteresis/minimum dwell to avoid repeated reconfiguration.
   Reuse AT's scene evidence; no second high-frequency image-processing loop.
3. Apply changes only through supported backend operations. Where a restart is required, use a safe
   session boundary and generation guard; where unsupported, retain forwarding-only adaptation and
   report source adaptation unavailable. A fresh-question frame still bypasses the transmission gate.
4. Route a fine-detail request through the existing sharp-still path when it can satisfy the request,
   rather than raising sustained stream quality. Preserve the existing filtered capture boundaries.

## Acceptance

Tests cover static-to-motion transitions, noisy scene changes, missing evidence, ceiling changes,
reserve posture, pause/stop/warm-up, delayed callbacks and unsupported backends. Recording,
broadcasting, navigation and other continuous consumers contribute explicit minimum requirements;
never silently reduce their quality because the conversational model sees a static frame.
Effective capture FPS and forwarded FPS are separate measurements. User-started continuous vision
remains explicit; adaptive capture cannot start a camera for a voice-only request.

## Dependencies and rollout

Reuse camera claims from [DI](DI-photo-library-hygiene.md), lifecycle fixes from
[EW](EW-session-resource-cleanup.md), and the shared policy inputs from BV. EO's device codec/FPS
results are required before enabling source changes by default. Test static scenes, fine text,
rapid head motion and concurrent recording; measure actual delivered FPS, cold-start/restart
latency, audio continuity and battery/thermals. Feed optional measurements to
[EY](EY-power-controls-and-diagnostics.md). Unsupported runtime control is an explicit capability
result, not a reason to simulate savings by only changing a displayed FPS value.
