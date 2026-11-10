# Plan LB — Instant Replay (keep the last 30 seconds the glasses already saw, only while the camera is already on)

**Status:** 🚧 Built 2026-11-10, P0–P2 in one branch ([As built](#as-built-2026-11-10)), headless. Owed:
P0's small device pass (the frame-cadence reading at high and medium, in a live session and in a recording,
and whether the capture light is lit for each), P3's device pass, and the catalog sync. Every
[decision](#decisions-for-greig-open) below was taken as recommended.
**Track:** Everyday and Field Assist. Off by default.
**Builds on:** `CameraService` and `MetaCameraBackend`, Plan [CP](CP-outbound-frame-privacy.md)
(`OutboundFrameRelay`, the `OutboundFrameConsumer` roster, `PrivacyFilterScope.recording`), Plan
[EO](EO-hevc-glasses-stream.md) (`GlassesFramePipeline`, the decoded HEVC stream), `VideoRecordingService`,
`RecordingFiler` and `RecordingsView`, `VideoBitratePolicy`, `StreamConfigPolicy`, Plan
[FO](FO-guided-job-flow-and-job-tab.md) (`JobClipRecorder`, `JobClipFiling`), `MemoryRewindService` and
`RewindRingBuffer` (the audio counterpart), Plan [BV](BV-power-policy.md) (`PowerPolicyService`), Plan
[ET](ET-iso27701-privacy.md) (`SensitiveStore` in `DataStoreRegistry`, `SubjectErasureCoordinator`),
`TempleAction`, `App/Intents/CaptureIntents.swift`.
**Sits beside:** `video_recording` (a recording the wearer starts on purpose and stops), `record_clip` (a job clip
recorded from now on). Instant Replay is the one that looks backwards.

---

## Trigger

The moment worth keeping has usually just happened. A compressor that short-cycled once, a child's first
steps, a fault light that blinked and stopped. By the time the wearer says "record", it's over. Surveying
adjacent wearable-assistant work turned up rolling-buffer capture as a feature wearers ask for by name.

Avenkin already has the hard parts: the glasses stream, the blurred relay every recorder must use, an H.264
writer, the Recordings folder and a job clip filer. What it lacks is a short buffer that runs only while the
camera is already streaming for something else, and a way to keep it.

## Outcome

- With **Instant Replay** on (Settings › Devices & Privacy › Glasses, off by default), and the glasses camera
  already streaming (a live session with the camera, a recording, a broadcast, Live Coach), the app keeps the
  last minute of filtered video on the phone. A small "Replay" mark shows on the status card while it does.
- "Keep the last 30 seconds." or "Save the replay." → a 30-second clip is filed. The wearer hears "Saved the
  last 30 seconds to Recordings."
- "Save the last minute." → 60 seconds, if the buffer holds that much; otherwise "I only have the last 40
  seconds; saved those."
- With a job open: "Save the replay to the job." files it on the job as a clip, like `record_clip`'s, and
  "Saved the last 30 seconds to the job."
- "Save the replay to Photos." also writes it to the Photos library. Nothing goes to Photos unless asked.
- A temple-tap action, **Save Instant Replay**, and a Shortcut, **Save Glasses Replay**, do the same as the
  first sentence.
- When the camera stops, the buffer is deleted. With no stream there is no buffer, and Instant Replay never
  starts the camera.

## What exists, and what doesn't

**Exists (verified against `main` at 900808c64):**
- `CameraService.framePublisher` is a `PassthroughSubject<UIImage, Never>` (`Services/CameraService.swift`), fed
  from `MetaCameraBackend`'s `videoFramePublisher.listen`, through `GlassesFramePipeline.picture(for:)`. That
  function receives the SDK's `VideoFrame` and its `sampleBuffer` (a `CMSampleBuffer`, which carries a
  presentation timestamp); **what it publishes is a `UIImage` only.** `CameraService` publishes `isStreaming`
  and `streamingStatus`.
- The stream is configured in `MetaCameraBackend` with `MWDATCamera.StreamConfiguration(videoCodec:resolution:frameRate:)`:
  - frame rate `Config.cameraFrameRate`, default **15**;
  - resolution `Config.cameraResolution`, default **"high"**;
  - codec HEVC by default (`StreamCodecPolicy`), decoded in-process.
  `StreamConfigPolicy.encodedSize(for:)` (`Services/StreamRecoveryPolicy.swift`) gives low 360×640, medium
  504×896, high 720×1280, and its comment says the logged `tierResolved` sizes are the truth.
  `StreamConfigPolicy.effectiveResolution` floors "low" to "medium" when glasses voice runs alongside.
- `OutboundFrameRelay` (`Services/Vision/OutboundFrameRelay.swift`): one blur pass, `publisher` is a
  `PassthroughSubject<UIImage, Never>`. With the filter off it passes frames straight through. With it on it
  coalesces, composites and counts `droppedFrameCount` / `privacyDroppedFrameCount`.
- `OutboundFrameConsumer` (`Services/Vision/OutboundFrameConsumer.swift`) is the roster. Each case has
  `owningType`, `scope`, `tap` and `mechanism`. `OutboundFrameConsumerTests` fails on any unlisted frame
  subscriber. The recorders are `.videoRecording` (`VideoRecordingService`), `.videoRecordingTool` and
  `.jobClipRecording` (`JobClipRecorder`): scope `.recording`, tap `.outboundRelay`, mechanism `.relay`.
  `PrivacyFilterScope.recording` is filtered and uses the relay.
- `VideoRecordingService`:
  - writes MP4 with `AVAssetWriter` into `ComplianceFileProtection.inProgressDirectory(complianceMode:)`;
  - files finished recordings through `RecordingFiler` into Documents/Recordings, plus Photos when "Also Save
    to Photos" is on;
  - takes its bitrate from `VideoBitratePolicy.bitrate(…, profile: .disk)`;
  - **stamps each frame with the host clock at the moment it is appended** (`CMClockGetTime(CMClockGetHostTimeClock())`
    in `appendFrame`).
- `JobClipRecorder` (`Services/FieldAssist/Job/JobClipRecorder.swift`):
  - records from the relay, **video only, deliberately** (its header explains the bystander-speech consent
    reason);
  - capped at `Config.jobClipDefaultSeconds` (30) and `jobClipMaximumSeconds` (60);
  - files through `JobClipFiling.attachClip(_:posterJPEG:caption:durationSeconds:filterWasOn:cutShort:)`,
    which `FieldSessionService` implements;
  - its `AVAssetClipWriter` stamps frames with seconds since the clip started, taken **on arrival**.
- `BroadcastService` builds each sample buffer with `presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock())`,
  also on arrival.
- `VideoBitratePolicy.Profile.disk`: 0.29 bits per pixel per frame quoted at 30 fps, square-root scaled for frame
  rate, clamped 1–12 Mbps.
- `MemoryRewindService` (`Services/MemoryRewindService.swift`): a 10-minute rolling buffer of 16-bit PCM in a
  `RewindRingBuffer` (`Services/Memory/RewindRingBuffer.swift`, fixed-capacity, lock-guarded, O(appended)),
  fed by `WakeWordService.addAudioBufferConsumer(id: "memory_rewind")`, held in memory only, reset on `stop()`.
  The ring holds bytes with no timestamps; only `bufferStartTime` marks time.
- `VisualStateMemory` (`Services/Vision/VisualStateMemory.swift`): a pure fixed-capacity ring of `Keyframe`s that
  evicts the oldest. A pattern, not a video store.
- `PowerPolicyService` (`Services/Power/PowerPolicyService.swift`) publishes a `PowerPosture` fused from phone
  battery, phone thermal and glasses thermal.
- `SensitiveStore` (`Services/Privacy/DataStoreRegistry.swift`) has `.recordings` (media, third-party subject,
  `.completeUnlessOpenInComplianceMode`, backed up, deleted individually), `.recordedSessions`,
  `.capturedPhotos`. `DataStoreRegistryTests` scrapes the sources for anything that writes into the app container
  and fails on an unregistered owner.
- `TempleAction` (`Services/Triggers/TempleAction.swift`) includes `toggleRecording`, `photoToCameraRoll`,
  `quickAction(String)`. `CaptureIntents.swift` has `CaptureGlassesPhotoIntent` and `RecordGlassesVideoIntent`
  (`openAppWhenRun = true`).
- The DAT conventions forbid the glasses' camera audio (`StreamConfiguration.audioCodec`,
  `Stream.audioFramePublisher`): experimental, never in a store build.
- `DebriefReviewState.savePhrases` already includes "save that" and "save it" (a job debrief's review).

**Doesn't exist:**
- Any buffer of video, or any way to keep frames from before a request.
- Any record of when the glasses captured a frame. Every writer uses arrival time.
- **Not verified:** whether the glasses' own capture light is lit for every stream the app runs (it is the
  bystander's only signal on the glasses). P0's device pass checks it; the plan assumes nothing.

## Design

### 1 · When the buffer may exist (`ReplayBufferPolicy`, pure)

The buffer runs only when **all** of these hold, and is deleted the moment one stops holding:

- the setting is on, and no organisation profile pins it off;
- the glasses camera is streaming for something else (`CameraService.isStreaming`, glasses source). Instant
  Replay never starts, keeps alive or restarts a stream. When the stream's owner stops it, the buffer goes;
- Medical Compliance (HIPAA) mode is off. Turning HIPAA on deletes any buffer;
- the posture allows it: `PowerPolicyService` at its normal level. At a raised posture the buffer stops and is
  deleted, and the status mark says why;
- free storage is above twice the buffer's size plus the recorder's own low-storage line;
- the relay is delivering frames. If the privacy filter is required and failing, the relay delivers nothing, and
  the buffer simply has a gap; it is never fed raw frames instead.

Output: `.run(ReplayBufferPlan)` or `.off(reason)`. The reason feeds the status mark and the settings footer.

### 2 · Through the privacy relay, on the roster

- **The only tap is `OutboundFrameRelay.publisher`.** A new roster case `instantReplayBuffer`: owning type
  `ReplayBufferService`, scope `.recording` (frames written to a file on this device, which is what the scope
  means), tap `.outboundRelay`, mechanism `.relay`. `OutboundFrameConsumerTests` covers it with no exemption.
- With the filter on, the buffer holds blurred frames and a saved clip is blurred. With it off, the buffer
  holds what the relay passes, as every recording does.
- **Rejected: buffering the glasses' compressed HEVC before decode.** It would be cheaper, but those are raw
  pixels before the blur. It would be a raw-tap consumer, and a clip saved from it would undo the filter.

### 3 · Disk, in short encoded segments

**Memory is out.** One decoded 720×1280 frame is about 3.7 MB (BGRA). Thirty seconds at 15 fps is 450 frames,
about 1.7 GB. Even JPEG at around 100 KB a frame is 45 MB for 30 seconds, and a JPEG encode for every frame.

**Disk, as H.264 segments** from the same encoder settings `VideoRecordingService` uses, with
`VideoBitratePolicy`'s `.disk` profile at the delivered size and `Config.cameraFrameRate`:

- **2-second segments**, each starting on a keyframe (GOP = segment), written one after another into a
  buffer directory. The oldest segment file is deleted when a new one closes and the ring is full.
- **Candidate writer:** `AVAssetWriter` producing fragmented MPEG-4 segments (`outputFileTypeProfile`
  `.mpeg4AppleHLS`, `preferredOutputSegmentInterval`, the segment delegate). The alternative is one short
  `AVAssetWriter` per segment. P1 picks one after measuring the encode cost on the phone; both use the hardware
  encoder.
- **Saving** composes the segments that cover the asked span (`AVMutableComposition`) and exports them
  **passthrough**, with no re-encode, into the destination. The cut lands on a segment's keyframe, so a
  30-second ask yields 30–32 seconds. The wearer hears "the last 30 seconds"; the file's real length is
  recorded.
- **Sizes**, worked from `VideoBitratePolicy.disk` at 15 fps (√(15/30) × 0.29 bpp × 30):

| Stream (`StreamConfigPolicy`) | Bitrate | 30 s | 60 s (default buffer) | 2 min |
|---|---|---|---|---|
| high 720×1280 (default) | ~5.7 Mbps | ~21 MB | ~43 MB | ~86 MB |
| medium 504×896 | ~2.8 Mbps | ~10.5 MB | ~21 MB | ~42 MB |
| low 360×640 | ~1.4 Mbps | ~5.3 MB | ~10.6 MB | ~21 MB |

  Add one segment (2 s) of overhead. The table is computed in P0 by a pure `ReplayBufferPlan` from the
  **delivered** frame size (the relay's frames), never assumed, and the Settings footer shows the figure for the
  current stream: "Keeps up to about 43 MB on the phone while the camera is on."
- **Files.** A dedicated directory in Application Support. Protection `.completeUnlessOpen` (new segments can
  still be written while the phone is locked during a stream). Excluded from backup. Deleted on stream stop,
  setting off, HIPAA on, a raised posture, app launch (leftovers from a crash) and subject erasure.
- **`DataStoreRegistry`:** a new `SensitiveStore.instantReplayBuffer`: media, third-party subject (bystanders),
  `.completeUnlessOpen`, backup excluded, retention "while the camera streams, at most the buffer length", delete
  all = "stop the stream or turn the setting off". `DataStoreRegistryTests` reads the protection and backup
  attributes back off a real segment written in a temporary directory.

### 4 · The ring (`ReplaySegmentRing`, pure)

The pure index over segment files, modelled on `RewindRingBuffer`'s fixed capacity and on `VisualStateMemory`'s
oldest-first eviction:

- each entry: file name, first and last frame timestamp, frame count, and whether frames were dropped in it
  (from the relay's counters);
- `capacity` from the plan (buffer seconds / segment seconds + 1);
- `segments(coveringLast: seconds, now:)` returns the newest run of contiguous segments, oldest first, and the
  span they actually cover;
- **a gap is a boundary.** If the stream stalled or the relay dropped frames for longer than one segment, the
  answer stops at the gap. "Save the last minute" after a stall saves what follows the stall and says how much.
- Time is passed in. No I/O.

### 5 · Audio: video only

The glasses' camera audio is a DAT Experimental API and is never used. The choice is between a silent clip and
pairing it with the phone or glasses microphone that Memory Rewind already listens to.

**Recommend video only** (decision 3), for `JobClipRecorder`'s reason: a clip kept from the last 30 seconds is
of a moment nobody agreed to record. Adding the voices of the people in it, with no blur equivalent, is a consent
question Avenkin hasn't answered. And `RewindRingBuffer` holds bytes with no timestamps, so lining the two up
would be an estimate. If the owner wants sound later, it is its own phase: only while Memory Rewind is already
on, a timestamped ring, and spoken consent at save time.

### 6 · Keeping a clip (`ReplaySaveRequest`, pure)

- **Words.** A native tool `instant_replay` (`save`, `status`) with a self-contained description for
  `SystemPromptBuilder`: seconds (default 30, at most the buffer), destination (`recordings`, `job`, `photos`),
  caption. It does not claim the bare phrase "save that", which a job debrief already uses
  (`DebriefReviewState.savePhrases`). The tool's description names "replay", "keep the last…" and "save the
  last…".
- **Where it goes.**
  - **Recordings** (default) through `RecordingFiler`, as an ordinary recording with a "Replay" label, so
    `RecordingsView` lists it.
  - **The job**, when one is open (`JobClipFiling.isOpenForEvidence`) and the wearer says so, through
    `JobClipFiling.attachClip`, with `filterWasOn` from the relay and `cutShort` when the buffer held less than
    asked. A job clip is capped at `jobClipMaximumSeconds` (60). A longer ask is cut to 60 and says so
    (decision 5).
  - **Photos** only when asked in the same request. The "Also Save to Photos" recording switch does not apply.
- **Replies.** "Saved the last 30 seconds to Recordings." / "…to the job." / "I only have the last 40
  seconds; saved those." / "Instant Replay isn't running: the camera's off." / "…it's off in Medical
  Compliance mode."
- **After saving.** The saved span stays in the ring until it ages out, so "save the last minute" straight
  after "save the last 30 seconds" still works. Segments are never moved, only copied into the composition.
- **Other entry points.** `TempleAction.saveReplay` (with `TempleEarcon.recordingStopped`'s pair as its
  acknowledgement, or a new pair if the tour says it is confusable), and `SaveGlassesReplayIntent` in
  `CaptureIntents.swift` (opens the app, as `RecordGlassesVideoIntent` does).

### 7 · Bystanders and consent

- **It only exists while the camera already streams**, for a purpose the wearer started and can see. Nothing
  about Instant Replay makes the camera run longer.
- **It is visible.** A "Replay" mark on the status card and in the Live Activity while the buffer runs. P0's
  device pass checks that the glasses' capture light is lit for the streams that can carry a buffer; if any
  stream runs without it, the buffer is not allowed for that stream.
- **It is never uploaded.** The buffer has no network route. A saved clip goes where its destination goes: a
  Recording stays on the phone unless shared, and a job clip leaves with the job only the way job clips already
  do.
- **It is never fed to a model,** to face recognition or to search. A saved clip is an ordinary recording.
- **HIPAA mode off** (§1). An organisation profile can pin it off.
- **Off by default** (decision 1). The setting's footer says what it keeps, for how long and how big it gets.

### 8 · The measurement folded into P0: do frames arrive in bursts?

Every writer in the app timestamps a frame when it **arrives**. If the glasses deliver frames in bursts
(several together, then a gap of 100 ms or more), a clip written by arrival time plays unevenly. The bunched
frames flash past and then the picture freezes. That would be true today of `VideoRecordingService`,
`JobClipRecorder` and `BroadcastService`, not only of this plan.

- **Log it.** In `GlassesFramePipeline.picture(for:)`, for a 60-second window per stream (a Developer-panel
  switch, off by default), record each frame's arrival time (`CACurrentMediaTime()`) and its sample's presentation
  timestamp (`CMSampleBufferGetPresentationTimeStamp`). Write it to the transport probe log, not the support
  trace.
- **Judge it** with a pure `FrameCadenceAnalyzer`. Its inputs are the arrival and presentation pairs. Its
  outputs are the inter-arrival gaps (median, p95, max), bursts (≥3 frames within 20 ms followed by a gap
  ≥100 ms), how far arrival lags presentation (jitter), and whether presentation times themselves are even.
  Headless tests run on synthetic series: even, bursty, stalled, and reordered.
- **If frames do burst:**
  - every writer should stamp frames by **capture time**. The relay would publish a timed frame (image plus
    presentation time) beside today's `UIImage` publisher, so consumers move one at a time;
  - the live preview may need a small playout delay (around 150 ms) to show bursts evenly;
  - Instant Replay's segments use capture time from the start.
  That is a change to the existing recorders, owed in its own follow-up and named in this plan's index row.
- **If they don't:** arrival time is kept everywhere, and the analyser stays as a check that can be re-run on
  each glasses firmware.

## Decisions for Greig (open)

Recommendations first.

1. **Off by default**, under Settings › Devices & Privacy › Glasses, since it keeps video of other people
   without a fresh request each time.
2. **Buffer length 60 seconds** by default, with 30 s and 2 min as the other choices; "save the replay" keeps
   30 seconds.
3. **Video only** in v1 (§5).
4. **Recordings by default**; the job only when the wearer names it; Photos only when asked in the same request.
5. **A job clip stays capped at 60 seconds**, so a 2-minute replay to the job is cut to its last 60 and says so.
6. **A raised power posture stops the buffer**, rather than lowering its quality, so it never competes with the
   stream's own purpose.
7. **No "save that".** The tool claims "replay", "keep the last…" and "save the last…", leaving "save that" to the
   debrief.

## Phases (one PR each)

### P0 — the pure core, and the measurement (headless, plus one device pass)

- `ReplayBufferPolicy`, `ReplayBufferPlan` (segment length, capacity, the size table from a delivered frame
  size and rate), `ReplaySegmentRing`, `ReplaySaveRequest` and its replies, `FrameCadenceAnalyzer`.
- The roster case `instantReplayBuffer` and `SensitiveStore.instantReplayBuffer`, with their guard tests green
  (the owning type exists as a stub that subscribes to nothing yet).
- The frame-cadence log switch in `GlassesFramePipeline`.
- **Exit tests:** every policy condition, including HIPAA, posture, storage and a stopped stream; sizes for each
  tier at 15 and 30 fps; the ring's eviction, covering spans, and stopping at a gap; save replies for a short
  buffer and a job cap; the analyser on even, bursty, stalled and reordered series.
- **Device pass (owed, small):** 60 seconds of the cadence log at high and medium, in a live session and in a
  recording; whether the capture light is lit in each. The result decides §8's branch and is written into this
  plan.

### P1 — the buffer (headless, wired)

- `ReplayBufferService` on `OutboundFrameRelay.publisher`, the segment writer chosen by measurement, the ring,
  file protection and backup exclusion, deletion on every stop condition and at launch, the status mark and Live
  Activity line.

### P2 — keeping a clip (headless, wired)

- The composition and passthrough export, Recordings filing through `RecordingFiler`, the job through
  `JobClipFiling`, Photos on request, the `instant_replay` tool, `TempleAction.saveReplay`,
  `SaveGlassesReplayIntent`, the settings row and its size footer.

### P3 — device pass (owed)

- The thermal and battery cost of a continuous encode beside a live session, at each tier, over 20 minutes.
- Writing segments with the phone locked.
- A save at the moment of a stall.
- A blurred clip with a bystander in it.
- The 2-minute buffer's real size against the table.
- If §8 found bursts, the capture-time change to the existing recorders is planned from this pass.

## Acceptance

- No buffer without a stream the wearer started, and none in HIPAA mode. Stopping the stream deletes it.
- Every buffered frame came through the relay, and the roster test covers the new consumer.
- A saved clip is at least the length asked, or says how much it could keep.
- Nothing reaches Photos, a job or the network unless the wearer asked for that destination.
- The cadence measurement is in the plan, with what it means for the existing recorders.

## Risks

- **Heat and battery.** A second hardware encode while the glasses stream and a live session runs. The posture
  rule stops it early; P3 measures it.
- **Storage churn.** About 43 MB rewritten every minute at the default. Segments are small and deleted in
  place. P3 checks that the writes don't slow anything else.
- **Bystander trust.** A camera that "remembers" is the feature people fear most from smart glasses. The
  default-off switch, the visible mark, the camera-already-on rule and the never-uploaded rule are the answer.
  The setting's footer says all four plainly.

## As built (2026-11-10)

P0–P2 in one branch, headless. P0's device pass and P3 are owed; the string catalog sync is owed in its own
PR. Every decision was taken as recommended: off by default; a 60 s buffer (30 s and 2 min offered), "save
the replay" keeps 30 s; video only; Recordings by default, the job or Photos only when named; a job clip
capped at 60 s; a raised posture stops the buffer; no "save that".

**The core (pure, table-tested).** `Services/InstantReplay/`:
- `ReplayBufferPolicy` — the §1 table: an organisation pin, the setting, Medical Compliance, the glasses
  camera streaming, a `.normal` posture, and free space of at least twice the buffer plus the recorder's own
  low-storage line (`VideoRecordingService.lowStorageBytes`, 2 GB; an unknown free figure is not a refusal).
  `.run(plan)` or `.off(ReplayOffReason)`, each reason with its spoken and status line.
- `ReplayBufferPlan` — 2 s segments, capacity buffer/segment + 1, `VideoBitratePolicy.disk` at the size and
  rate, the size line for the footer. Estimated from the tier (`StreamConfigPolicy.encodedSize`) until the
  first frame, then worked from the delivered size.
- `ReplaySegmentRing` — fixed capacity, oldest-first eviction (the evicted segments are handed back for
  deletion), out-of-order refusal, and `span(coveringLast:now:)`: the newest contiguous run, stopping at a gap
  longer than a segment, at a size change, or once it reaches the window's start.
- `ReplaySaveRequest` / `ReplaySaveDecision` / `ReplaySaveOutcome` — the arguments, the decision (held to the
  buffer; the job needs an open job and is capped at `jobClipMaximumSeconds`), and every reply.
  `ReplayCompositionPlan` — the passthrough timeline.
- `FrameCadenceAnalyzer` (§8) — inter-arrival median/p95/max, bursts (≥3 frames within 20 ms then ≥100 ms),
  stalls (≥500 ms), arrival lag beyond the smallest lag (p95/max), presentation evenness and reorders, a
  verdict (`even`, `bursty`, `stalled`, `insufficient`) and a recommended playout delay (zero when even;
  otherwise the lag spread rounded up to 10 ms, capped at 300 ms). `FrameCadenceRecorder` keeps one stream's
  first 60 s and reports once.

**Wired.**
- `ReplayBufferService` (`@MainActor`) is fed only by `OutboundFrameRelay.publisher`
  (`AppState.connectInstantReplay()`, roster case `OutboundFrameConsumer.instantReplayBuffer`: owner
  `ReplayBufferService`, scope `.recording`, tap `.outboundRelay`, mechanism `.relay`). It reads
  `cameraService.isStreaming` and never starts, claims or keeps a stream. It reconciles on the stream flag,
  the power posture, the setting row and a one-second tick while running (Medical Compliance, the
  organisation pin and free space change without an event). Every stop deletes every segment; so do launch
  (`removeLeftovers()`), a changed length and a subject erasure.
- Segments: `AVReplaySegmentWriter`, H.264 in MP4, the encode on its own serial queue, keyframe interval the
  segment length, `Application Support/InstantReplay/segment-{n}.mp4`, `completeUnlessOpen` and excluded
  from backup on each file and on the directory.
- Saving: the segment being written is closed first, so the last second is in; the span's files are pinned
  while the passthrough composition (`AVReplayClipComposer`: `AVMutableComposition`, `AVAssetExportSession`
  passthrough) reads them, and a segment evicted meanwhile is deleted when the save ends. Recordings through
  `RecordingFiler` as `Replay_{date}.mp4` (the list labels it Replay); Photos through
  `GlassesPhotoAlbum.saveVideo` only for `destination: photos`; the job through `JobClipFiling.attachClip` with
  a poster frame, `filterWasOn` (the blur on for every segment) and `cutShort` (the buffer held less).
- `instant_replay` (`save`, `status`; seconds, destination, caption), registered outside the phone-only
  build; classified `.local(.notCancellable)`, offline `.local`, `PhoneCapturePolicy` `.glassesOnly`, titled
  "Kept a replay for you". `TempleAction.saveReplay` ("Save Instant Replay"; refused with "Instant Replay
  isn't running." while off; acknowledged with the recording-stopped pair, then the spoken result).
  `SaveGlassesReplayIntent` ("Save Glasses Replay") in `CaptureIntents.swift`, opens the app.
- Settings › Devices & Privacy › Glasses › Instant Replay: the switch, the length, what it is doing now, and
  the footer with the size for the current stream. `SettingKey.instantReplayEnabled`, an off-ceiling, always
  shown. A Replay mark on the session card and a Replay label on the Live Activity's Lock Screen view
  (`ContentState.instantReplayRunning`, optional so an older state still decodes).
- `SensitiveStore.instantReplayBuffer` (media, third-party, `completeUnlessOpen`, backup excluded, delete-all
  and subject delete `ReplayBufferService.deleteAll()`), in the ET matrix and the erasure walk.
- The cadence measurement: `GlassesFramePipeline.picture(helperImage:sampleBuffer:)` hands every delivered
  sample's arrival (`CACurrentMediaTime()`) and presentation timestamp to `FrameCadenceRecorder` before
  anything is decided about it, behind the Developer panel's **Measure frame cadence** switch (off by
  default, `frameCadenceLoggingEnabled`).

**Sizes as built** (`VideoBitratePolicy.disk`, 15 fps; the buffer column includes one 2 s segment):

| Stream | Bitrate | A 30 s save | 30 s buffer | 60 s buffer (default) | 2 min buffer |
|---|---|---|---|---|---|
| high 720×1280 | 5.7 Mbps | 21.4 MB | 22.8 MB | 44.2 MB | 86.9 MB |
| medium 504×896 | 2.8 Mbps | 10.5 MB | 11.2 MB | 21.7 MB | 42.7 MB |
| low 360×640 | 1.4 Mbps | 5.3 MB | 5.6 MB | 10.9 MB | 21.4 MB |

At 30 fps high is 8.0 Mbps and medium 3.9 Mbps. The footer for the default reads "Keeps up to about 44 MB on
the phone while the camera is on."

**Running the P0 device pass.** Settings › Advanced & Support › Advanced › Developer › Frame Cadence: turn
on **Measure frame cadence**, then start a stream (a live session with the camera, then a recording) and keep
it running for a minute. The reading appears under the switch and in the camera log as one line,
`[capture] camera source=glasses event=frameCadence verdict=… count=… frameRate=… gapMedian=…ms gapP95=…ms
gapMax=…ms bursts=… stalls=… lagP95=…ms lagMax=…ms presentationEven=… reordered=… playoutDelay=…ms
width=… height=…`. Each new stream is measured again from its first frame. Repeat at high and medium, and
note whether the glasses' capture light is lit in each. `bursty` with a non-zero `playoutDelay` is §8's
"frames burst" branch; `even` is the other.

**Deviations.**
- **One `AVAssetWriter` per segment, not fragmented MPEG-4.** Chosen without the on-phone encode measurement
  P1 named (that is P3's now): each segment is a self-contained MP4 that starts on a keyframe by construction
  and survives the next writer failing, and the composition reads it with no special handling. A writer that
  cannot be made is retried after one segment, not once a frame.
- **Frames are stamped on arrival**, as every recorder still is: the relay publishes a `UIImage` and no
  capture time. Capture-time stamping waits on the cadence reading, as §8 says.
- **The cadence reading goes to the camera log** (the `PrivacyLog` channel the transport-level line uses) and
  to the Developer panel, not a separate probe file, and never to the support report.
- **A change of frame size is a boundary**, beside a gap: two sizes cannot be joined passthrough.
- **A subject erasure clears the whole buffer** (`deleteSubject` is `deleteAll()`): a segment is not indexed
  by who appears in it, and the buffer is at most two minutes.
- **Recordings only, no chosen-folder copy**: a kept replay is filed into the Recordings folder and is not
  copied to the wearer's chosen recordings folder or Photos unless the request named Photos.
- **A job replay is filed as a clip** with the `record_clip` origin, the only clip origin there is.
- **The capture-light rule** ("if any stream runs without it, the buffer is not allowed for that stream")
  waits on P0's device pass; nothing in the build can read the light.
- **The Live Activity** shows the Replay label on the Lock Screen view; the Dynamic Island is unchanged.
- **The Shortcut** is a Shortcuts action, not an App Shortcut (the provider is at its cap), and has no Siri
  exposure switch of its own; it refuses with the same spoken reason when the buffer is off.
- The settings switch is drawn disabled in Medical Compliance mode and under an organisation pin.

