# EW — Session Resource Audit

Companion table to [EW — Session Resource Cleanup](EW-session-resource-cleanup.md). One row per
*acquired* resource: something that, once taken, keeps costing the wearer battery, a hardware
capability, a microphone, a socket or memory until somebody gives it back.

Built by reading the code, not by asking the owners what they intended. Every `file:line` below was
read at the commit this table landed on; line numbers drift, the claims do not.

## How to read a row

**Permitted background lifetime** is the honest answer to "how long may this outlive the thing that
asked for it?" — `turn` (one request/response), `session` (a live conversation, a recording, a
broadcast), `process` (taken once at launch, given back at exit), or `none`.

**Verdict:**

- **verified** — every exit listed reaches the release, and I traced each one.
- **gap** — at least one exit does not. Closed gaps say so and name the commit's fix.
- **exempt (justified)** — deliberately retained, with the reason written down. An exemption
  without a reason is a gap with better manners.

**Exits** are the eight the plan names: success (S), cancellation (C), barge-in (B), inactivity
timeout (I), mid-request error (E), background/lock (K), glasses disconnect (D), exhausted network
retries (R). A row lists only the exits that can actually reach that owner.

---

## 1. Glasses camera — `CameraService` / `MetaCameraBackend`

| # | Owner | Resource | Lifetime | Acquired | Released | Exits reaching release | Verdict |
|---|---|---|---|---|---|---|---|
| 1.1 | `MetaCameraBackend` | DAT `Camera` capability (process-wide) | session | `ensureSession()` via `addCamera(config:)` | `resetSession()` `MetaCameraBackend.swift:1137-1140` — `camera.stop()` then `awaitCameraStopped(camera)` before dropping the reference | S, E, I (`scheduleIdleTeardown` :762-771), D, R, K (mode switch → `tearDown()` :1158) | verified — waits for the observable `CameraState.stopped` before releasing, which is what the capability's process-wide lifetime requires |
| 1.2 | `MetaCameraBackend` | DAT `Stream` (video) | session | `startStreaming()` :806-859 | `stopStreaming()` :910-932 (`session.stop()`), `teardownStreamOnly()`, `resetSession()` :1137 | S, C, E, D, R | **gap → closed.** A stop landing during the cold start was lost: `stopStreaming()` guarded on `isStreaming`, which a warm-up has not yet set, and the late start then claimed the stream anyway. Fixed with `StreamStartGeneration` — see §6 |
| 1.3 | `CameraService` | published streaming state + the wearer-visible notice | session | `handle(_:)` `CameraService.swift:131-162` | same event stream (`.streamingChanged(false)`, `.frame(nil)`) | all | **gap → closed** by the same fix: the resurrected stream published `isStreaming == true` after the app had stopped it |
| 1.4 | `CameraService` | stream claims (`CameraStreamClaims`) | session | `claimStream(for:)` :285-303 | `releaseStream(for:)` :307-313; `tearDown()` resets :264 | S, C, E, D | **gap → closed.** A claim whose cold start was superseded stayed held — a claim on a stream that never came up makes every later release think it has something to give back. `claimStream` now abandons on a superseded start |
| 1.5 | `MetaCameraBackend` | `stallDetectionTask` (0.5 s poll) | session | `startStallDetection()` :1010 | `stopStallDetection()` :1054-1057 | S, C, E, D, R | verified — started only alongside `isStreaming`, stopped by `stopStreaming()` :920 and by `recoverFromStall` |
| 1.6 | `MetaCameraBackend` | `reconnectTask` (bounded ladder) | session | `scheduleReconnect()` :939 | `cancelReconnect()` :999-1003; `finishReconnect()` :985 | S, C, E, D, R (`StreamRecoveryPolicy.reconnectDelay` returns nil at the budget, :942-951) | verified — bounded by a written budget and cleared by `stopStreaming()` :914 *before* the `isStreaming` guard, so a stop during warm-up already killed the ladder even before this plan |
| 1.7 | `MetaCameraBackend` | `idleTeardownTask` (session idle grace) | session | `scheduleIdleTeardown()` :763 | `idleTeardownTask?.cancel()` :591, :763, :809 | S, C | **gap → closed.** `tearDown()` did not cancel a pending idle teardown, so the task outlived its owner and could re-enter `resetSession()` on a backend that had already released everything. Now cancelled first thing in `tearDown()` |
| 1.8 | `MetaCameraBackend` | `sessionErrorTask` (DAT `errorStream()` loop) | session | :370 | :366, :1134-1135 (`resetSession()`) | S, E, D | verified — and the SDK's own `errorStream()` finishes on `.stopped` (DAT 0.9.0), so the loop also exits on its own |
| 1.9 | `MetaCameraBackend` | four DAT listener tokens (state, frame, photo, error) | session | `.store(in: streamListenerBag)` :452, :482, :488, :517 | `streamListenerBag.cancelAll()` :1105, :1143 | S, E, D, R | verified — aggregated deliberately so they die together |
| 1.10 | `MetaCameraBackend` | `photoContinuation` | turn | `capturePhoto()` :674 | :679, :695, :778 | S, E, I (capture timeout) | verified — cleared on every arm of the capture race |
| 1.11 | `MetaCameraBackend` | cached `latestFrame` (one still) | session | frame callback | `resetSession()` :1150-1151, `stopStreaming()` :926-927, `CameraService.tearDown()` :263 | S, C, E, D | verified — and enforced twice on purpose: the cache clear, plus a freshness gate that refuses a stale frame as a photo fallback |
| 1.12 | `MetaCameraBackend` | `Wearables.addDevicesListener` token | process | :238 | never | — | exempt (justified) — one listener, taken once, on a backend that lives for the process. Releasing it would mean re-adding it on the next capture, and the SDK's device list is the thing that tells us a pair of glasses exists at all |
| 1.13 | `CameraService` | iPhone `AVCaptureSession` (fallback stills) | turn | `PhoneCameraSource.capturePhoto()` | inside the same call | S, E | verified — the phone source builds and tears down its session per capture; nothing is held between captures |

## 2. Microphone, speech recognition and the audio session

| # | Owner | Resource | Lifetime | Acquired | Released | Exits reaching release | Verdict |
|---|---|---|---|---|---|---|---|
| 2.1 | `WakeWordService` | `AVAudioEngine` + input tap | process (background listening is the product) | `createAndStartAudioEngine()` `WakeWordService.swift:675`, tap :696, start :703 | `cleanupAudioEngine()` :604-608 | S, C, E, D (route change :375/:386/:410), K | exempt (justified) — always-on wake word is a shipped feature and the app declares the background audio mode for it. The engine is still torn down on every route change and every explicit `stopListening()` :479-482 |
| 2.2 | `WakeWordService` | `SFSpeechAudioBufferRecognitionRequest` + `SFSpeechRecognitionTask` | turn | `startRecognition()` :618, :667 | `cleanupAudioEngine()` :600-603, `pauseRecognition()` :910-913, `pauseRecognitionForSharedEngine()` :541-544 | S, C, B, I, E, D | verified — recognition is restarted per utterance and every pause path clears both handles before re-arming |
| 2.3 | `WakeWordService` | `AudioSessionLease` (baseline ownership) | process | `configureAudioSession()` :243 (`assumeOwnership(.wakeWord)`) | `deactivateAudioSession()` :490-496 | K (CarPlay dismiss) | exempt (justified) — wake word is the documented baseline owner (:68-70), so a live session supersedes it through the ledger rather than by it letting go. `stopListening()` deliberately idles the mic without surrendering ownership |
| 2.4 | `WakeWordService` | interruption + route-change observers | process | `installSessionObservers()` :295, :300 | `removeSessionObservers()` :308-311, called first inside `installSessionObservers()` :294 | re-registration only | exempt (justified) — self-clearing before each re-register, so the pair can never accumulate; the owner is a process-lifetime service |
| 2.5 | `AudioSessionCoordinator` | `AVAudioSession` activation lease | session | `acquire` :104-112 / `acquireOffMain` :134-139 | `release(_:)` :189-219; `rollBack(_:)` :233-238 on a failed activation | S, C, E, K | verified — the lease is registered *before* activation and rolled back in the `catch`, and the deactivation re-checks `ledger.current == nil` on the IO queue so a lease superseded between decision and execution cannot deactivate somebody else's session |
| 2.6 | `RealtimeAudioEngine` | `AudioSessionLease` for a live session | session | `:200` (`acquireOffMain`) | `stopCapture()` :603-606 | S, C, E, D | **gap → closed.** `deinit` :173-175 released observers but not the lease, and both realtime managers had an exit that returned without calling `stopCapture()` — see §3 |
| 2.7 | `AmbientCaptionService` | recognition request/task, named buffer consumer, diarizer, translators, silence timer, endpoint-commit task | session | `startRecognitionSession()` :229-241, :235; `startDiarizedSession()` :382-395 | `stopRecognitionSession()` :402-422 — one teardown for all seven | S, C, I, E, K (`suspendForPresence()` :163) | verified — every exit routes through the single teardown, and it holds no audio-session lease of its own (it rides the wake-word engine's buffer fan-out) |
| 2.8 | `ProactiveAlertService` | repeating `Timer` | process | `start()` :64-66, `resumeAlerts()` :90-92 | `stop()` :72-73, `pauseAlerts()` :82-83, **`deinit` :281-283** | S, C, K | verified — the only owner in this audit with a `deinit` safety net, and it is the right shape |
| 2.9 | `MemoryRewindService` | rolling PCM ring + buffer consumer + duration timer | session | `start()` :50-56; ring lazily in `ingest()` :139-142 | `stop()` :63-69 (`removeAudioBufferConsumer`, `invalidate()`, `ring?.reset()`) | S, C | verified, bounded — `RewindRingBuffer` is fixed-capacity (`maxBufferMinutes`, default 10) and overwrites oldest-first, so the buffer has a written ceiling rather than a growth curve. Cleared only by `stop()`; documented as such |
| 2.10 | `MemoryRewindService` | temp WAV for a transcription | turn | `transcribeAudio(_:)` :155-158 | `defer { removeItem }` :159 | S, E | verified — the `defer` covers the throwing path, which is the one that matters |

## 3. Live sessions — Gemini Live and OpenAI Realtime

Both managers have the same shape, so the rows apply to both; `GeminiLiveSessionManager.swift`
lines are given first, `OpenAIRealtimeSessionManager.swift` second.

| # | Owner | Resource | Lifetime | Acquired | Released | Exits reaching release | Verdict |
|---|---|---|---|---|---|---|---|
| 3.1 | both managers | WebSocket to the provider | session | `connect()` :390 / :271 | `stopSession()` :471 / :331, plus both `startSession()` error returns | S, C, E, D, R | verified — the socket was already closed on every exit, including the two failure returns |
| 3.2 | both managers | `stateObservation` poll task | session | :331 / :230 | `stopSession()` :472-473 / :332-333; reached on every failure return via `stopSession()` | S, C, E, D | verified |
| 3.3 | both managers | `frameTimer` (frame capture loop) | session | `startFrameCapture()` :633 / :385 | `stopSession()` :468-469 / :328-329 | S, C, E, D | verified for the stop path; see 3.5 for the exit that never reached it |
| 3.4 | Gemini only | `ToolCallRouter` and its in-flight tool tasks / ack timers | session | `startSession()` :292 | `stopSession()` :465 (`cancelAll()`) | S, C, E, D | **gap → closed** — see 3.5 |
| 3.5 | both managers | *everything above*, on a failed start | session | `startSession()` | `stopSession()` | E only, and it did not get there | **gap → closed.** Both managers hand-rolled a partial teardown at their two failure returns (audio setup :379-386 / :263-272; connect refused :399-409 / :279-289; microphone capture failed :412-419 / :292-299) and set `isActive = false` on the way out. Every teardown call site in the app is `if isActive { stopSession() }`, so the manager's own `stopSession()` then became unreachable and the tool router, the frame timer, the audio capture and the microphone lease were never released. Both failure returns now run the real `stopSession()` and restore the error message afterwards |
| 3.6 | both managers | the glasses camera, started for the session | session | `onRequestStartCamera` :134-141 / :90-93 | `stopSession()` :486 / :342, through `AppState`'s release handler `OpenGlassesApp.swift:1448-1450` | S, D | **gap → closed.** A live session that failed to start left the camera it had just started streaming to nobody, until the wearer changed mode. The start handler now takes a `CameraStreamClaims.Owner.liveSession` claim and `stopSession()` gives it back, so the session releases exactly the camera it started and never one the wearer opened themselves |
| 3.7 | `LiveSessionTurnLoop` | — | — | — | — | B | verified by construction — barge-in returns `[.cancelInference]` (:76-79) or `[.cancelSpeech]` (:80-83) and never `.stopListening`, so the microphone survives into the next turn. Pure value type: it owns no mic, no camera, no model, no clock |
| 3.8 | `VisualStateMemory` | keyframe ring | session | `add(_:)` | eviction at `maxKeyframes` :22-27; `reset()` :40 from `VisualStateService.reset()` :91-96 | S (session start) | verified, bounded — fixed capacity with oldest-first eviction. Cleared at the *start* of each live session rather than at its end; the ceiling, not the clear, is what bounds it |
| 3.9 | `VisualStateService` | JPEG thumbnails written to the temp directory | session | `persistThumbnail(_:)` :96-102 | nothing deletes them | — | **gap — out of scope, recorded.** A disk resource, not a session resource, and only written when `Config.visualStateInjectThumbnails` is on. It belongs with the photo-library and cache hygiene owner ([DI](DI-photo-library-hygiene.md)), not here; fixing it inside EW would mean inventing a cache-eviction policy this plan has no mandate for |

## 4. Frames out of the app

| # | Owner | Resource | Lifetime | Acquired | Released | Exits | Verdict |
|---|---|---|---|---|---|---|---|
| 4.1 | `OutboundFrameRelay` | upstream subscription to `CameraService.framePublisher` | process | `attach(to:)` :83-87, called once at launch (`OpenGlassesApp.swift:1803`) | `detach()` :89-93, called nowhere | — | exempt (justified) — the relay is the single blur chokepoint every outbound consumer shares, built to live for the process. It costs one subscription on a publisher that emits nothing while the camera is stopped. Reference-counting its consumers would buy nothing and risk dropping the chokepoint while a consumer still needs it |
| 4.2 | `OutboundFrameRelay` | serial queue, Metal `CIContext` | process | init :64, :67 | — | — | exempt (justified) — process-lifetime by design; every queued block is `[weak self]`, so in-flight work after dealloc is a no-op |
| 4.3 | `LookCloselyTool` | timeout task group | turn | `withTimeout` :112-121 | `group.cancelAll()` :119 on the success path; structured concurrency cancels and awaits the rest on any throw | S, I, E | verified — the explicit `cancelAll()` is success-path only, but `withThrowingTaskGroup` cancels its children when the scope unwinds by throw, so the sibling sleep is not leaked. The tool holds no stream: it takes one still through an injected capture closure |

## 5. Remote agent, inference and gateway

| # | Owner | Resource | Lifetime | Acquired | Released | Exits | Verdict |
|---|---|---|---|---|---|---|---|
| 5.1 | `RemoteCommandExecutor` | — | — | — | — | — | verified — a pure dispatcher over injected main-actor closures. It owns no socket, task or timer; the resources live in the services behind those closures, which are rows elsewhere in this table |
| 5.2 | `OpenClawEventClient` | gateway WebSocket | process (agent mode) | `establishConnection()` :103-104 | `disconnect()` :61-62 (`socket?.cancel()`) | S, C, E, D, R | verified |
| 5.3 | `OpenClawEventClient` | receive loop task | process (agent mode) | `startReceiving(on:)` :178-193 | not cancelled directly; the loop's `self.socket === socket` guard :180 fails once `disconnect()` nils the socket, and `receive()` throws when the socket is cancelled | S, C, E, D | exempt (justified) — the loop's exit is the socket's cancellation, which is the release in 5.2. Recorded rather than "fixed" because storing and cancelling the task would add a second way to end a loop that already ends |
| 5.4 | `OpenClawEventClient` | reconnect backoff block | process (agent mode) | `scheduleReconnect()` :402-414 | neutralised, not cancelled: `disconnect()` clears `shouldReconnect` :57 and the fired block returns early :410 | C, R | verified — a `DispatchQueue.asyncAfter` block cannot be cancelled, so guarding it is the available shape. Bounded by the backoff ladder |
| 5.5 | `LocalInferenceCoordinator` | resident model (memory + Metal) | session | `load(_:configuration:)` :78-80 | `unloadResident()` :140-143, from `unload()` :126-131 and from `load()`'s pre-evict :75 | S, C, E, K | verified — and `unloadResident()` cancels generation :140 before unloading :141, so a model is never dropped out from under a running decode |
| 5.6 | `LocalInferenceCoordinator` | in-flight generation | turn | `generate(_:expecting:)` :102-116 | `cancelGeneration()` :120-123 | S, C, B, I, E | verified — barge-in cancels the decode without touching residency, which is the split the acceptance criteria ask for: cancel the answer, keep the model warm for the next turn |

## 6. The stop-during-warm-up race, in detail

Recorded by [EO](EO-hevc-glasses-stream.md) and left out of scope there.

The glasses camera cold-starts in up to 20 s — a session, then a stream, then the first frame. A
stop arriving inside that window was lost, because `stopStreaming()` asks "is a stream running"
and during a warm-up the answer is no. The start still climbing then finished and declared the
stream up: a cancelled stream came back holding the process-wide camera capability with nothing
consuming its frames. Only programmatic stops reach that window — the camera button is disabled
while a start is in flight — so in the field it took two shapes: backgrounding with no glasses
attached, and a live session ending on top of its own warm-up.

`StreamStartGeneration` (`OpenGlasses/Sources/Services/Camera/StreamStartGeneration.swift`) is the
rule as a pure value type. A start takes a token; a stop invalidates every token outstanding; a
start whose token no longer matches must release what its cold start acquired instead of claiming
the stream. It is applied in two places, because two owners hold two different resources:

- `CameraService.startStreaming()` — owns the published state and the claims, and is the seam the
  fifty-odd consumers go through. Tested directly, through a fake backend whose cold start suspends
  on demand (`CameraServiceExitTests`).
- `MetaCameraBackend.startStreaming()` — owns the DAT stream itself, and releases it without ever
  publishing it as running, so the coordinator never sees the flicker.

### Not fixed: a stall recovery that fails is not picked up by the reconnect ladder

Also named in EO's out-of-scope list. Traced here: this is not a missing release or a confused
owner. `recoverFromStall()` runs under `isRecoveringFromStall`, and `scheduleReconnect()`
deliberately refuses to schedule while that flag is set (:940-941) — two rebuilders racing for one
process-wide camera capability is how a dropped stream becomes `capabilityAlreadyActive`. What is
missing is a *decision* about what should happen after the last recovery tier fails, which is
stream-recovery policy and belongs to [BR](BR-realtime-and-stream-hardening.md), not to a resource
audit. Recorded, not fixed.

---

## Totals

| Verdict | Rows |
|---|---|
| verified | 24 |
| gap → closed in this PR | 7 |
| gap → recorded, out of scope | 1 |
| exempt (justified) | 8 |
| **total** | **40** |

## What is proven where

**Proven by headless test.** The camera exit rules (1.2, 1.3, 1.4, 6): stop during the cold start,
teardown during the cold start, a claim whose cold start was superseded, restart after a cancelled
start, repeated stop, and a failed cold start — all driven through a fake backend that records what
it acquired and released, in order (`OpenGlassesTests/SessionResourceExitTests.swift`). The claim
arithmetic underneath (1.4, 3.6) in `CameraStreamClaimsTests`; the audio lease ledger (2.5) in
`AudioSessionLedgerTests` and `AudioSessionCoordinatorTests`; barge-in keeping the microphone (3.7)
in the turn loop's own tests.

**Justified exemption, not tested.** Rows 1.12, 2.1, 2.3, 2.4, 4.1, 4.2, 5.3 — each is a
process-lifetime resource whose reason for being held is written in the row.

**Owed on device.** The realtime managers (§3) construct a `RealtimeAudioEngine` at init and are
not constructible in a unit-test process, so 3.5 and 3.6 are reasoned from the code and owed a
hardware run. The device smoke list is in the plan.
