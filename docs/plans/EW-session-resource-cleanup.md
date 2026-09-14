# Plan EW — Session Resource Cleanup

**Status: 📝 Drafted 2026-09-12; not scheduled.** One implementation PR: deterministic
ownership/exit tests first, then missing teardown calls; hardware evidence recorded separately.

## Gap and existing coverage

Realtime managers already stop tools, timers, audio capture, sockets and observers.
[BR](BR-realtime-and-stream-hardening.md) owns stream recovery and stale connection callbacks;
[AS](audio-session-lease-coordinator.md) owns audio leases;
[AJ](additional-capabilities.md) owns shared device-session adoption;
[DI](DI-photo-library-hygiene.md) owns smart-camera claims. None establishes an exhaustive
resource-by-exit audit. Existing cleanup functions are evidence of mechanisms, not completeness.

## Scope and build order

1. Inventory acquisition/release sites for camera claims, microphone/recognition leases,
   sockets, subscriptions, timers, frame buffers, inference tasks and retry tasks across
   Direct, offline live, Gemini Live, OpenAI Realtime and remote-agent routes. Record each
   owner, shared consumers, permitted background lifetime and release hook in an audit table.
   Start the inventory with `CameraService`, `WakeWordService`, `AudioSessionCoordinator`,
   `GeminiLiveSessionManager`, `OpenAIRealtimeSessionManager`, `LiveSessionTurnLoop`,
   `OutboundFrameRelay` and `LookCloselyTool`.
2. Use injected clocks and fake resource handles to test an exit/ownership policy before
   changing live code. Reuse existing claims and generation gates rather than introduce
   another app-wide session owner.
3. Wire missing releases and invalidate stale completions. Include the stop-during-warmup
   race recorded by [EO](EO-hevc-glasses-stream.md): a late start must not resurrect a
   cancelled stream. Wait for observable SDK stop before dropping resources that need it.
4. Exercise real interruption/disconnection paths and record residual resource counts.

## Acceptance

For each applicable mode, cover success, cancellation, barge-in, inactivity timeout,
mid-request error, background/lock transition, glasses disconnect and exhausted network retries.
A completed turn releases its turn-owned resources; an intentional live conversation, recording,
broadcast or background listening session retains only its documented claims. Barge-in cancels
old output/inference without tearing down the microphone needed for the next turn. SDK pause
retains the paused session and never triggers a competing restart.

Repeated stop is harmless; late callbacks cannot reacquire a released resource; bounded retry
work ends when its owner ends; retained buffers have a documented bounded lifetime. Tests must
inspect real manager effects through fakes, not only a policy table. Keep a justified exception
for every intentionally retained resource. Device smoke covers network flap, folded glasses,
background/lock and stop during cold start, including a simultaneous recording or HUD consumer.

## Dependencies and boundary

Build the inventory and headless tests now. Coordinate fixes with AS/AJ/DI/BR instead of
reimplementing their owners. [BV](BV-power-policy.md) sets idle/power exit decisions;
EW proves those exits release the right resources. [EY](EY-power-controls-and-diagnostics.md)
may display audit counters but is not required for correctness. No blanket shutdown on every
background transition; the app deliberately supports background work.
