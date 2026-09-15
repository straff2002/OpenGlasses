# Plan EW — Session Resource Cleanup

**Status: 🚧 Core shipped 2026-09-15** — the audit table, the headless exit tests and the missing
releases are in; device smoke is owed and listed below. The inventory is
[EW — Session Resource Audit](EW-resource-audit.md).

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

## Evidence

### Verified

The audit is [EW — Session Resource Audit](EW-resource-audit.md): 40 rows, one per acquired
resource, each with its acquisition site, its release hook and the exits that reach it — 24
verified, 8 exempt with a written justification, 7 gaps closed here, 1 gap recorded out of scope.

Headless, through fakes that record what was acquired and released in order
(`OpenGlassesTests/SessionResourceExitTests.swift`, 15 tests):

- `StreamStartGeneration` — the stop/start ordering rule on its own: repeated stops are harmless,
  every start outstanding when a stop lands is abandoned, a start begun after a stop is unaffected.
- `CameraService` driven through a backend whose cold start suspends on demand — stop during the
  cold start, teardown during the cold start, a claim whose cold start was superseded, restart
  after a cancelled start, a failed cold start, and repeated stop. The four race tests were
  committed first and shown failing on the unfixed code (9 assertion failures across 13 tests).
- A live session releasing the camera it started, and leaving alone one the wearer started.

Already covered and still green: `CameraStreamClaimsTests` (claim arithmetic),
`CameraServiceCoordinatorTests` (the coordinator's other behaviours),
`AudioSessionLedgerTests`/`AudioSessionCoordinatorTests` (lease rollback on a failed activation and
suppression of a superseded deactivation), and the turn loop's own tests for barge-in cancelling
inference without stopping the microphone.

### Gaps closed

- `Services/Camera/StreamStartGeneration.swift` — new: the rule as a pure value type.
- `Services/CameraService.swift:229-250` — a superseded start releases the stream and reports it;
  `:297` a claim whose cold start was superseded is abandoned rather than held.
- `Services/Camera/MetaCameraBackend.swift:847-872` — the same gate at the device layer, so the
  DAT stream is taken back without ever being published as running; `:918` the stop is recorded
  before the `isStreaming` guard that swallowed it; `:1161` `tearDown()` cancels a pending idle
  teardown.
- `Services/GeminiLive/GeminiLiveSessionManager.swift:384, 405, 416` and
  `Services/OpenAIRealtime/OpenAIRealtimeSessionManager.swift:269, 285, 295` — all three failure
  returns run the real `stopSession()`, which was unreachable from the app once they set
  `isActive = false` themselves.
- `GeminiLiveSessionManager.swift:486` / `OpenAIRealtimeSessionManager.swift:342` and
  `App/OpenGlassesApp.swift:1429-1454` — a live session claims the camera stream and gives the
  claim back on every exit, instead of starting the camera outright and relying on the app to
  stop it.

### Exempt, with reasons

Seven process-lifetime resources are held deliberately: the wake-word engine and its baseline
audio-session ownership (always-on listening is the feature), its self-clearing session observers,
the DAT devices listener, and the outbound frame relay's chokepoint subscription, queue and Metal
context. Each row in the audit carries its reason.

### Out of scope, recorded

- `VisualStateService`'s JPEG thumbnails are written to the temp directory and never deleted. A
  disk-hygiene question, owned by [DI](DI-photo-library-hygiene.md), not a session resource.
- A stall recovery that exhausts its tiers is not picked up by the reconnect ladder. Traced: this
  is a missing *decision* about what follows the last tier, not a missing release —
  `scheduleReconnect()` refuses to run under `isRecoveringFromStall` on purpose, because two
  rebuilders racing for one process-wide camera capability is how a dropped stream becomes
  `capabilityAlreadyActive`. Stream-recovery policy, so
  [BR](BR-realtime-and-stream-hardening.md)'s.

### Owed on device

Both realtime managers construct a `RealtimeAudioEngine` at init and are not constructible in a
unit-test process, so their exit rows are reasoned from the code and owed a hardware run. None of
the following is claimed:

- Network flap mid-conversation, and again after the reconnect budget is exhausted.
- Folding the glasses, and doffing them, during a live session and during a recording.
- Background and lock transitions with each of: wake word only, an ambient caption session, a
  recording, a broadcast.
- A stop issued during a cold start, with a simultaneous recording or HUD consumer attached.
- A live session whose connect is refused, confirming the glasses stop streaming.
- Residual counts after each: no camera capability held, no audio-session lease held, no socket
  open, no timer left armed.
