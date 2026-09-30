# Plan GQ — Rolling Video Memory (opt-in, on the phone)

**Status:** 📝 Drafted (not scheduled), 2026-10-01 — nothing built.
**Extends:** Memory Rewind (`Services/MemoryRewindService.swift`, `Services/Memory/RewindRingBuffer.swift`
— audio only today) to pictures.
**Related:** Plan [CP](CP-outbound-frame-privacy.md) and W04.1 (`OutboundFrameConsumer` roster),
Plan [AV](visual-state-memory.md) (keyframe *descriptions* for the live agent — text, not pixels),
Plan [DA](DA-recording-persistence.md) (`RecordingFiler`), Plan BV / `PowerPolicy`, Plan
[EO](EO-hevc-glasses-stream.md) (compressed glasses stream), Plan [GJ](GJ-remappable-temple-gestures.md)
(a "forget the last minutes" tap), Plan [GG](GG-readable-memory.md).

---

## Trigger

"What was the number on that bus?", "Where did I put my keys?", "Save the last minute — that was
my daughter's first goal." The moment has already passed when the wearer thinks to ask. Memory
Rewind answers this for sound; nothing answers it for sight. The glasses camera can feed a short
rolling window on the phone that is thrown away continuously unless the wearer asks for it.

## Outcome

- **Off by default.** Turned on only from the phone (Settings → Glasses → Video Memory), after a
  one-time explanation sheet. Voice can pause/resume it once enabled, never enable it first.
- While on, the last *N* minutes (default 5) of glasses video are kept **only on the phone**; older
  video is deleted continuously.
- "What did I just see?", "What was on that sign a minute ago?" → frames from the window are
  described. "Save the last 30 seconds" → a clip is filed like a recording. "Forget the last few
  minutes" → the window is deleted at once.
- Nothing leaves the phone unless the wearer asks to describe, save or send, and every such exit
  goes through the privacy chokepoint.
- Visible whenever it runs: a status pill on the phone's home card and in the Live Activity, and the
  glasses' own capture light (the camera is streaming).
- Hard-disabled in HIPAA / Medical Compliance mode.

## What exists today (verified 2026-10-01)

- `MemoryRewindService`: an **in-RAM** `RewindRingBuffer` of 16-bit PCM fed from
  `WakeWordService.addAudioBufferConsumer(id: "memory_rewind")`, default 10 min, started and stopped
  by the `memory_rewind` tool (voice) — no persisted setting, no visible indicator, nothing on disk
  except a short-lived transcription temp WAV.
- `VideoRecordingService`: `AVAssetWriter` H.264 MP4 from a `PassthroughSubject<UIImage, Never>`,
  bitrate from `VideoBitratePolicy`, `storageVerdict` (refuse < 200 MB, warn < 2 GB), stall
  auto-stop, in-progress files in `ComplianceFileProtection.inProgressDirectory`, filed by
  `RecordingFiler` into `Documents/Recordings/`.
- Camera frames reach consumers as decoded `UIImage`s (`GlassesFramePipeline`, Plan EO decodes the
  HEVC glasses stream on the phone). Stream ownership is ref-counted by `CameraStreamClaims`
  (owners `sceneNarration`, `fingerspelling`, `liveSession`, `readinessCheck`, `jobClip`, …).
- **Correction to the brief:** recording does *not* store raw frames. `videoRecording`,
  `videoRecordingTool` and `jobClipRecording` are roster entries with tap `outboundRelay`, mechanism
  `relay`, scope `.recording` (`isFiltered == true`). When the privacy filter is on, the relay blurs
  them — and when the filter is on but unavailable (backgrounded, transitioning, protected data
  locked; `PrivacyFilterAvailability`) the relay **drops** frames. The filter defaults off
  (`Config.privacyFilterEnabled`), in which case the relay is a passthrough.
- `StillImageFiltering.filteredOrUnavailable(_:for:)` is the chokepoint for a consumer that already
  holds its own pixels (`dwellCaptureSave`, `jobPhoneEvidence` use it; tap `heldImage`).
- `PowerPolicy` fuses phone/glasses battery and thermals into `PowerPosture` `.normal/.conserve/
  .reserve` (`reserve`: camera only on explicit request).
- `DataStoreRegistry` (with `recordings`, `recordedSessions`), `SubjectErasureCoordinator`,
  `HIPAAComplianceService` (retention purge, protected recording artefacts).

## Design

### Where the pixels come from — and whether local storage is egress

Two shapes were considered:

- **(A) Relay-fed ring** (scope `.recording`, like a recording). Simple to argue, but with the filter
  on, the relay drops every frame while the phone is locked — the normal state in a pocket — so the
  memory would be empty exactly when it is wanted, and a blur baked in at write time can never be
  undone for an on-device answer.
- **(B, recommended) Raw local ring, filtered on every exit.** The ring subscribes to the raw camera
  publisher and writes to app-private storage. **Local ring storage is not treated as egress**: the
  files are never visible in Files, Photos, the Recordings list or backups, are readable by no
  consumer except the three exits below, and expire on their own. This is the same argument that
  exempts `faceRecognition`'s local store and `onDevicePreview`. Every path *out* of the ring is an
  egress and is filtered.

Roster changes (`OutboundFrameConsumer`, `PrivacyFilterScope`), so `OutboundFrameConsumerTests`
fails until they are argued in the file:
- New scope **`.videoMemoryRing`** — `isFiltered == false`, `usesOutboundRelay == false`, doc comment
  carrying the argument above.
- `videoMemoryRing` — owner `VideoMemoryService`, tap `rawCameraPublisher`, mechanism
  `exemptByScope`, scope `.videoMemoryRing`.
- `videoMemoryDescribe` — owner `VideoMemoryReader`, tap `heldImage`, mechanism `chokepoint`, scope
  `.directModelTurn` (frames decoded from the ring pass `filteredOrUnavailable` before a model sees
  them; `nil` → "I can't prepare those pictures right now", never the raw frame).
- `videoMemorySave` — owner `VideoMemoryClipExporter`, tap `heldImage`, mechanism `chokepoint`, scope
  `.recording` (the saved clip is re-encoded frame by frame through the filter, then filed by
  `RecordingFiler`; from there, Photos and sharing are the existing recording paths).
- "Send" is not a separate exit: the wearer saves, then shares the saved recording.

With the filter off (the default) every exit passes pixels through unchanged, exactly as recording
does today. With it on and unavailable (locked phone), describe/save wait for foreground and say so.

### Storage format

- **Segments**, not one file: `AVAssetWriter` HEVC (`.hevc`) MP4 segments of 10 s at the stream's
  resolution, 10 fps (frames decimated from the stream rate), bitrate from `VideoBitratePolicy` with
  a new `.memory` profile (~1 Mbps at 720×1280 → ~7.5 MB/min; 5 min ≈ 38 MB, 10 min ≈ 75 MB).
- **Stills fallback**: when the hardware encoder is unavailable (a backgrounded app may lose
  VideoToolbox encode — device-unverified), or under `PowerPosture.conserve`, the ring writes 1 fps
  JPEG stills (~5 MB/min) into the same segment timeline. Readers handle both kinds.
- Location: `Library/Application Support/VideoMemory/` (not `Documents`), `isExcludedFromBackup`,
  file protection `completeUnlessOpen` (writable while locked, sealed at rest), a small manifest of
  `{segmentID, kind, start, end, bytes}`.
- No audio track: sound is Memory Rewind's job (and its own opt-in). A describe may combine both
  when both are on.

### Pure core

- **`VideoMemoryWindowPolicy`**: given segments, `now`, window length → which to delete; guarantees
  no segment ending before `now − window` survives a sweep; total bytes ≤ cap.
- **`VideoMemoryBudget`**: window, fps, resolution, bitrate → bytes; storage verdict (refuse to
  start < 1 GB free, stop and delete < 500 MB), mirroring `VideoRecordingService.storageVerdict`.
- **`VideoMemoryPowerPolicy`**: `PowerPosture` + glasses thermal → `.video`, `.stills`, `.paused`
  (reserve or serious glasses thermals pause, spoken once: "Video memory is paused to save power").
- **`VideoMemoryFramePicker`**: for "the last N seconds/minutes" picks up to 8 frames spread over the
  range, preferring scene changes (reusing `FrameGate`'s change score where available) — the frames
  a describe sends.
- **`VideoMemoryRetentionTriggers`**: which events delete everything — disable, HIPAA on, "forget",
  storage floor, app launch (stale ring from a killed process), sign-out/erasure.

### Services and tool

- `VideoMemoryService` (`@MainActor`): owns `CameraStreamClaims` owner `videoMemory`, subscribes to
  the raw publisher, feeds a `SegmentWriter` on a background queue, runs the sweep on every segment
  close and on a 30 s timer. Injected seams: frame source, writer factory, clock, file store,
  filter — no `.shared` camera in tests.
- `video_memory` native tool: `status`, `describe(seconds|minutes, question)`, `save(seconds)`,
  `forget`, `pause`, `resume`. `describe` sends the picked, filtered frames with the wearer's question
  through the normal model path (Medical Local Only already routes/refuses there); on-device VLM is
  used only in the foreground (MLX cannot run backgrounded). `save` asks for confirmation through
  `HighImpactToolPolicy` only when the clip is longer than 2 min (storage), otherwise just does it.
- Settings row under the **glasses section** (it needs the glasses camera; phone-only users never
  see a dead switch): enable, window (1 / 3 / 5 / 10 min), quality (video / stills only), "forget
  now". Copy never mentions plan letters.
- Indicator: home status pill "Video memory · 5 min" (tap → settings), Live Activity line while
  active, and a HUD glyph when a display is connected.
- Brain: raw video is never ingested. A **saved** clip adds one `BrainStore.shared.ingest` event
  ("Saved a 30-second clip, 14:02, Ponsonby") so "when did I save that clip?" works.
- `DataStoreRegistry` gains `videoMemoryRing` (protection class and backup exclusion asserted by
  `DataStoreRegistryTests`); `SubjectErasureCoordinator` wipes it.

### Retention guarantees (what the settings sheet promises)

1. While running, nothing older than the window plus one segment (10 s) is kept.
2. Reads never return a segment older than the window, even if a sweep has not run.
3. If the app is suspended or killed, leftover segments stay encrypted and are **deleted at the next
   launch or foreground**, before anything else can read them. (iOS gives no timer while suspended;
   the sheet says this plainly.)
4. Turning it off, "forget", HIPAA on, or low storage deletes everything immediately.

### Modes

- **HIPAA / Medical Compliance:** hard-disabled (like cloud diarization): the row shows why,
  `start` refuses, enabling HIPAA stops and deletes. Org profiles (Plan CT) can lock it off.
- Not agentic, no Agent Mode gate. CarPlay: nothing extra; describe answers are spoken only.
- Bystanders: the glasses capture light is on while the camera streams (maker behaviour; confirm on
  device that it stays lit for the whole session). The enable sheet tells the wearer they are
  responsible for local recording laws and that "forget" is always one sentence away.

## Phases (one PR each)

**P0 — Pure core.** Window, budget, power, frame-picker, retention-trigger policies and the segment
manifest. Tests: `VideoMemoryWindowPolicyTests` (boundary at exactly `now − window`, clock jumps
backwards, cap by bytes), `VideoMemoryBudgetTests`, `VideoMemoryPowerPolicyTests`,
`VideoMemoryFramePickerTests`, `VideoMemoryRetentionTriggersTests`, `VideoMemoryManifestTests`.

**P1 — Ring service, roster, storage.** `VideoMemoryService`, `SegmentWriter` (HEVC + stills),
stream claim, sweeps, registry/erasure entries, the new scope and roster cases. Tests:
`VideoMemoryServiceTests` (fake frames and clock: rolls over, sweeps, stops on HIPAA, deletes stale
ring at launch), `OutboundFrameConsumerTests` and `DataStoreRegistryTests` updates,
`SegmentWriterTests` (simulator encode of a few synthetic frames; stills fallback path).

**P2 — Exits and tool.** `VideoMemoryReader` (describe), `VideoMemoryClipExporter` (save through the
filter to `RecordingFiler`), `video_memory` tool, brain event on save. Tests:
`VideoMemoryReaderTests` (filter nil → unavailable answer, never raw), `VideoMemoryClipExporterTests`
(every exported frame passed the fake filter), `VideoMemoryToolTests`.

**P3 — Settings, indicator, device pass.** Settings row, sheet, home pill, Live Activity line, HUD
glyph, GJ action "forget video memory". Device checks (owed): 30 min in a pocket with the phone
locked (does HEVC encode continue, or does the stills fallback take over?), battery and thermal cost
on phone and glasses, capture-light behaviour, HFP voice quality while streaming (EO), storage
growth, relaunch-after-kill sweep.

## Risks

- **Glasses battery and heat.** A continuous camera stream is the most expensive thing the glasses
  do; the window may be the least of the costs. P3 must publish a measured cost per hour.
- **Background encode** may not be available; the stills fallback keeps the feature honest but
  lower quality.
- **Social risk.** Always-on capture is sensitive even when local; off by default, visible, and
  hard-disabled in clinical settings.

## Decisions for Greig

1. **Ring shape: (B) raw local ring with filtered exits (recommended) or (A) relay-fed.** B adds a
   new exempt scope with the "local, private, expiring storage is not egress" argument; A is simpler
   but blank while locked when the filter is on.
2. **Default window** 5 min (recommended) and maximum 10 min.
3. **Voice enable**: never (recommended) vs allowed after the phone opt-in.
4. **Describe scope**: filtered as `.directModelTurn` always (recommended), or unfiltered when the
   foreground on-device VLM answers (the `.sceneNarration` argument).
5. **Compressed passthrough** (tap EO's HEVC samples before decode, no re-encode) as a later
   optimisation — cheaper, but a new tap below `CameraService`. *Recommend only if P3 shows the
   re-encode cost matters.*

## Out of scope

Continuous cloud upload, searching the window by text, keeping video beyond the window except by
saving, audio in the ring, face recognition over the ring, and phone-camera video memory.
