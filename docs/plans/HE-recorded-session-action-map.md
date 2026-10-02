# Plan HE — Recorded Session and the Action Map

**Status:** 📝 Drafted (not scheduled) 2026-10-02 — nothing implemented.
**Track:** Field Assist (B2B).
**Related:** Plan [GY](GY-procedure-from-narrated-recording.md) (procedure drafted from a narrated
recording — this plan builds on it and does not change it), Plan [GX](GX-photo-checked-procedure-steps.md)
(spot checks on a step), Plan [GQ](GQ-rolling-video-memory.md) (the "is local storage egress?"
decision this plan shares), Plan [DA](DA-recording-persistence.md) (`RecordingFiler`), Plan
[AD](structured-vision-assessment.md) (schema-forced vision), Plan [CP](CP-outbound-frame-privacy.md)
/ W04.1 (the privacy chokepoint and roster), Plan [FO](FO-guided-job-flow-and-job-tab.md) (job
evidence, `record_clip`), Plan [HD](HD-report-transcript-audience.md) (who may receive what), Plan
[CT](CT-org-configuration-profiles.md) / [HA](HA-settings-hub-and-org-lockdown.md) (organisation
policy), Plan [BV](BV-power-policy.md), Plan [AU](llm-cost-usage-tracker.md), Plan
[GU](GU-wake-word-audio-and-power.md) (who holds the mic), Plan [GV](GV-phone-camera-tools.md).

---

## Trigger

Greig, 2026-10-02: start a recorded session — video recorded while the technician keeps talking to
Avenkin — and, if a procedure is found in the transcript, send the video to a model that can map
the actions, tie them to the transcript, and be cross-referenced.

GY turns what an expert **said** into a draft procedure. It cannot see a step nobody narrated, and
it cannot say whether what was said was done. This plan adds what was **seen**, on the same clock.

## Outcome

- **A recorded session is one timeline.** Video, microphone audio, the technician's and the
  assistant's turns, tool calls and procedure steps share one clock, written to a small manifest
  beside the recording.
- **Transcript first, video second.** A deterministic pass over the timed transcript proposes
  whether a procedure happened and where its steps fall. Only those spans of video — sampled,
  downscaled, face-blurred, capped — go to a model, and only when a person says so.
- **An action map**: schema-validated action events, each tied to the frames that show it and the
  words that match it, labelled *confirmed by speech*, *seen, not said* or *said, not seen*.
- **A cross-reference index**: step ↔ words ↔ video span ↔ keyframe. A reviewer taps a step and
  watches its clip beside what was said.
- First consumer: GY's draft. Second: an internal "what was observed" record on the job. Compliance
  checking against the procedure that ran is designed here and deliberately **not** in v1.

## What exists today (verified against main @ f479d0ab, build 455)

- **Video + mic recording.** `VideoRecordingService.startRecording(from:bitrate:outputSize:frameRate:)`
  writes H.264 + AAC from `outboundFrames.publisher` (`AppState.toggleRecording`, the remote-invoke
  bridge, `VideoRecordingTool`). It has no length limit and files through `RecordingFiler` into
  `Documents/Recordings/` and, by default (`Config.recordingSaveToPhotos`), Photos — the Photos
  choice is read from `Config` inside `fileFinishedRecording`; there is no per-recording override,
  though `recordingsDirectory` is injectable.
- **The file has no clock anyone else can use.** `appendFrame` and `appendAudioBuffer` each take
  `CMClockGetHostTimeClock()` at their *own* first sample (`videoStartTime`, `audioStartTime`) and
  start their track at zero, so the two tracks are offset from each other by whatever separated the
  first frame from the first buffer, and neither host time is kept. `recordingStartDate` is a wall
  `Date()` taken before either. A stalled stream auto-stops the file (`shouldAutoStop`).
- **Recording and a conversation can run together — by design.** The recorder's audio comes from
  `CaptureAudioRouter` (the wake listener's shared tap, or `StandaloneMicTapService` when listening
  is off), which is a wearer-voice consumer in `WakeListenPolicy.wearerAudioConsumerIDs`, and
  `video_recording` is itself started inside a conversation. Device confirmation is owed by GU
  (its check 12). One consequence matters here: `AssistantAudioGate` zero-fills capture buffers
  while a reply plays from the **phone speaker** (unless `Config.captureIncludesAssistantVoice`),
  and replies into the glasses never reach the mic — so the assistant's words are **not** reliably
  in the audio track.
- **The job log has wall-clock stamps, taken late.** `SessionLogger.Event.timestamp` is `Date()`
  at the moment of logging: `FieldSessionService.recordConversationTurn` (after the utterance was
  transcribed, classified by `TranscriptOriginClassifier`), `recordAssistantReply` (the reply
  text, Direct mode), `ProcedureRunner` (`procedure_started` / `procedure_step` /
  `procedure_completed`), tool calls, photos, clips. None carries when the words *began*.
  `JobTranscriptExport` and `TurnTrace` read the same stamps.
- **Nothing links a recording to a job.** No `FieldAssist` type references `VideoRecordingService`.
  `record_clip` (`JobClipRecorder`) is the job's own recorder and is silent and length-capped by
  design.
- **`RecordedSession` is taken.** `RecordedSessionStore` / `SessionRecorderController` are the
  audio-only meeting recorder. This plan's types must not reuse the name.
- **Transcription discards timings.** `RecordingTranscriber.transcribe(fileURL:)` returns text
  (Deepgram when a key is set and HIPAA mode is off, else on-device in 30 s chunks). `SpeakerTurn`
  has optional `start`/`end`. GY P0/P1 define `TimedTranscript` and `TimedTranscriptSource`; neither
  is built.
- **No phone-camera recording.** `PhoneVideoSource` (continuous phone frames) is wired only into
  `BroadcastService`; `PhoneCapturePolicy` lists `video_recording` and `record_clip` as
  `.glassesOnly`.
- **No video ever goes to a model.** `LLMService.analyzeFrameStructured` sends **one** JPEG
  (`inlineData` for Gemini and Vertex with `responseSchema` via `GeminiSchemaTranslator`; forced
  tool for Anthropic; forced function for OpenAI-compatible; nil for local and Apple on-device).
  `GeminiLiveService.sendVideoFrame` sends JPEG stills over the socket. No video MIME type, no file
  upload endpoint and no multi-image structured call exist in `OpenGlasses/Sources`.
- **On-device vision** takes one image per turn and refuses to run in the background
  (`LocalLLMService`, `LocalLLMError.backgrounded`).
- **Privacy.** `PrivacyFilterScope.recording` is relay-fed: blurred when `Config.privacyFilterEnabled`
  is on (default **off**), and with it on the relay **drops** frames whenever the blur cannot run
  — backgrounded, transitioning, locked (`PrivacyFilterAvailability`). A recording made in a pocket
  with the blur on therefore has holes. `StillImageFiltering.filteredOrUnavailable(_:for:)` is the
  chokepoint for pixels a consumer already holds (roster tap `heldImage`).
- **Policy and accounting.** `SettingKey.privacyFilterEnabled` is already a profile ceiling;
  `PolicyEnvelope` clamps on read. `MedicalEgressGuard` decides per `NetworkRoute`.
  `UsageTracker.record(…fieldSessionId:)` prices a call against a job; `SpendCapPolicy` holds the
  caps. `PowerPosture` exposes consumer flags. `AuditEventKind` has `recordingStarted`,
  `recordingStopped`, `consentChanged`. There is no recording-consent type or sheet.

## Assessment of the proposed shape

Sound, with five corrections the code forces:

1. **The job log cannot place words in time.** Turns are stamped after transcription. Spoken words
   must be timed from the audio track (GY's `TimedTranscript`); logged turns are then *matched* to
   utterances by text. The assistant's lines come from the log, never from the audio.
2. **"Send the video" should not mean the recorded file.** The file is blurred only if the switch
   was on at capture, and has holes if it was. What leaves is always re-derived: frames or a
   re-encoded span, each through the chokepoint.
3. **Automatic detection, never automatic upload.** Detection is local and free; sending pictures
   of a customer's site is a person's decision.
4. **Compliance is the weakest consumer.** A head-mounted camera misses what the hands do below
   frame. "Not observed" is not "not done", and v1 should not print a verdict.
5. **Sampled frames first.** Every integrated cloud provider already takes images with a forced
   schema; native video needs a new request path whose limits are unverified.

## Design

### 1. The timeline (`SessionTimeline`, `timeline.json`)

- **`SessionClock`** — captured once at start: a wall `Date` and a monotonic reading, as a pair.
  Session time `t` is seconds since that monotonic zero. Wall-stamped events map through the pair;
  a wall-clock jump shows up as a mismatch and is corrected, not trusted.
- **Tracks** — each a list of *parts* (a stall, pause or re-start begins a new part):
  `video` and `audio` parts carry `{file, tZero, duration, filteredAtCapture}`. `tZero` is the
  host time of that track's first sample minus the clock's zero — the two values
  `VideoRecordingService` already holds privately and must now report on stop
  (`RecordingTimebase`). Gaps between parts are explicit.
- **Events** — written as they happen with `t`: turn started (mic live), turn logged (with the job
  log's `source_id`), assistant speaking began/ended (`CaptureAudioRouter.setAssistantSpeaking`
  already sees both), tool call, photo, `procedure_step`, capture gate silenced/passed, user
  marker.
- **`TurnAligner`** (pure) — matches each logged technician turn to utterances in the timed
  transcript inside the window before its log stamp, by normalised token overlap; unmatched turns
  keep the log time with `precision: coarse`.

Capture wiring: a `SessionCaptureCoordinator` starts `VideoRecordingService` with a per-recording
destination (the session folder, **not** Photos — a new parameter beside `recordingsDirectory`)
and writes the manifest. Glasses camera first. With no glasses: **import a phone video** (GY's
route) in v1; a live phone-camera session needs `PhoneVideoSource` fed through the relay and stays
foreground-only until a device check says otherwise (device-pending).

### 2. Transcript first

`ProcedureCandidateDetector` (pure) runs over GY's `WalkthroughSegmenter` output plus timeline
events and returns spans with a reason and score:

- **certain** — a `procedure_started … procedure_completed` run, or a user marker (voice: "that
  was a procedure" / "map that"; a button on the session screen);
- **likely** — three or more consecutive step-like segments (sequence markers, action verbs) within
  a bounded window;
- nothing otherwise.

An optional text-only refinement (`ProcedureSpanRefiner`, a model seam; on-device capable, stub in
tests) may merge or trim spans; it cannot create one.

**Trigger — both, in one shape.** The detector's result is a *suggestion* shown once, when the
recording stops or the job closes: "This looks like a procedure, 14:02–14:19 — map the video?"
Nothing is sent until the technician says yes on that screen, where the count of pictures, the
provider and the estimate are shown. Dismissing marks the span "not a procedure" so it is not
offered again. No mid-job prompts.

**`SegmentPlanner`** (pure) turns accepted spans into what is actually sent, under an
`AnalysisBudget` — defaults: 12 segments, 90 s each, 10 minutes in total, 16 frames per segment,
768 px long edge. Over budget, it keeps the spans whose steps have the least speech (where video
adds most) and says what it left out.

### 3. The provider seam (`VideoActionAnalyzer`)

`analyze(_ request: SegmentRequest) async throws -> RawActionMap`, with the transcript slice
(utterance ids, times, text) always in the prompt.

- **`SampledFramesAnalyzer` (P1, the default).** GY's keyframe picking generalised: uniform samples
  across the segment, extra samples around utterance boundaries, near-duplicates removed with
  `PerceptualHash`, the sharpest kept by `ImageQualityProbe`. Each frame is numbered and carries
  its `t`. Needs one addition to `LLMService`: a multi-image sibling of `analyzeFrameStructured`
  (same three provider branches). Works with Anthropic, Gemini (AI Studio and Vertex) and the
  OpenAI-compatible providers. Per-request image-count limits: **verify at implementation**.
- **`NativeVideoAnalyzer` (P2).** For a provider with video input — Gemini is the only one the app
  integrates that is expected to qualify. Inline versus file upload, size and duration limits, and
  whether Vertex and AI Studio agree: **verify at implementation**; none is asserted here. It sends
  a `SegmentExporter` re-encode (frames decoded, blurred, downscaled, low frame rate, **no audio
  track** — the words go as text), never a slice of the original file.
- **On-device: no.** The local vision model takes one image per turn and cannot run backgrounded;
  captioning frames one by one is neither action recognition nor affordable on a phone mid-job.
  Revisit if a real on-device video model ships.

`VideoAnalysisCapability` is one table (provider → frames / native / none); a provider with
neither is refused in plain words.

### 4. The action map and the index

Schema (a new `AssessmentSchema`-style contract, forced exactly as plan AD forces a card):

```
action_events: [{ id, start_t, end_t, action, object, tool,
                  evidence_frames: [frame id], transcript_spans: [utterance id], confidence }]
view_limitations, partial_view            // the standing "say what you could not see" fragment
```

- **`ActionMapValidator`** (pure): times inside the segment and ordered; every evidence frame id
  was one we sent; every utterance id exists; confidence in 0…1; text capped; an event with no
  evidence frame is dropped; below the floor an event is kept and marked low-confidence.
- **`AgreementClassifier`** (pure) recomputes agreement instead of trusting the model's links:
  time overlap with an utterance (± a window) plus token overlap between action/object and the
  words → `confirmedBySpeech`; an event with none → `seenNotSaid`; a step-like utterance with no
  overlapping event → `saidNotSeen`. Negation-aware, as GY's safety audit is.
- **`CrossReferenceIndex`** (`index.json`, built purely): rows of
  `{step?, utterances, video part + range, keyframe ids, action event ids, agreement}`.

**Storage.** With a job open: `Documents/FieldSessions/{id}/recording/` (deleted with the job,
already covered by `SensitiveStore.fieldSessionLogs`). Without one: `Documents/SessionTimelines/{id}/`
(a new `SensitiveStore` case, `completeUnlessOpen`, excluded from backup, wiped by
`SubjectErasureCoordinator`). Contents: `timeline.json`, `transcript.json`, `actions.json`,
`index.json`, `keyframes/` (the blurred frames that were analysed), and the media parts.
Budget: derived files under 5 MB a session (a cap, not a measurement).

**Surviving the video.** The index refers to media by part id and range, and holds its own
keyframes. Each part has `media: present | exported(to) | removed(at)`. Deleting the video or moving
it to Photos leaves steps, words, keyframes and agreement intact; the reviewer loses playback and is
told why.

### 5. Consumers

| Consumer | v1? | Rule |
|---|---|---|
| **Authoring** — hand-off to GY's draft pipeline | Yes (P2) | Adds un-narrated steps, better keyframes, timings. A video-only step is labelled "Seen, not said" and must be edited or confirmed before approval. **Safety content never comes from video** — GY's rule stands: the expert's words or the vault's safety file. A draft is never live. |
| **Job evidence** — "what was observed" | Yes (P3), internal | An `observed_actions` block in the JSON for an **office** audience only (`ReportTranscriptPolicy.audience`), each with its agreement label and confidence. Nothing in the work-order PDF; nothing for a customer. |
| **Procedure compliance** — did each step happen, in order | No (P3, behind a flag, advisory) | Compares `procedure_step` events with the map. Three answers only: *observed*, *not observed*, *unclear*. Never "failed", never blocks a job, never printed for a customer, never used for a safety-critical step (GX's rule). Shown to a reviewer as prompts. |

### 6. Guardrails

- **Consent (shared with GY).** One `RecordingConsent` type and sheet for both plans: sound and
  pictures are recorded; the assistant's replies may be heard; tell the people nearby; where it is
  kept and for how long; analysis is a separate, later question. Acknowledged once
  (`consentChanged` audit entry), one-line reminder at each start, capture light on. Analysis
  consent is per send, on the suggestion screen.
- **Bystanders.** A new `PrivacyFilterScope.videoAnalysis` whose blur is **required regardless of
  the global switch**: every frame and every re-encoded frame passes
  `filteredOrUnavailable(_:for:)`; `nil` drops the frame and the count is reported. The blur
  covers faces only, so hands, tools and gauges are untouched — the cost to action recognition is
  expected to be small (measure in P4). Roster entries: `actionMapFrame` and `actionMapSegment`
  (tap `heldImage`, mechanism `chokepoint`). Because analysis is user-started it runs in the
  foreground, where the blur is available.
- **Capture holes with the blur on.** Raised, not solved here: it is GQ's Decision 1 (raw private
  storage with filtered exits, versus relay-fed). v1 uses the relay-fed recorder as it is, records
  the holes in the timeline, and follows GQ's answer when it is made.
- **Organisation policy.** New keys: `organizationForbidsCloudVideoAnalysis` (ceiling, pinned
  true), `organizationVideoAnalysisProviders` (profile-owned list; empty = any configured). The
  existing `privacyFilterEnabled` ceiling already covers capture. Closed by name under
  `ManagedLockdown` like the other Field Assist controls. Region is a property of the configured
  provider endpoint (Vertex) — whether a profile should pin it is left to CT.
- **Medical.** A new `NetworkRoute` for the analysis call. Local Only refuses it; HIPAA mode
  hard-disables cloud video analysis in v1, as it does cloud transcription. Recording still works.
- **Retention.** Raw media: kept with the job, with an optional "delete video after N days" for
  the session folder (default: keep). Derived files live as long as the job. Delete-with-job
  removes everything.
- **Cost.** Estimate shown before sending (pictures, bytes, provider); the call goes through
  `SpendCapPolicy` and lands on `UsageTracker` with the `fieldSessionId`. A per-session ceiling is
  the `AnalysisBudget`.
- **Power.** New `PowerPosture` flag `defersBulkAnalysis` (conserve and reserve): queue until
  normal posture or charging. Recording itself follows today's rules.
- **Offline.** `ActionAnalysisQueue` in the manifest (`suggested → accepted → running → done |
  failed`); retried on reconnect; never blocks close, sign-off or the report.
- **Audit without content.** Job log `action_map_requested` / `action_map_built` (segments,
  frames, bytes, provider, model, dropped frames); the same counts to the audit chain.
- **Gating.** `FieldAssistEntitlement`. Not agentic. Should unattended analysis ever be added, it
  goes behind `agentModeEnabled`.

## Phases (one PR each)

**P0 — Deterministic core (headless).** `SessionClock`, `SessionTimeline` + codec, `TurnAligner`,
`ProcedureCandidateDetector`, `SegmentPlanner` + `AnalysisBudget`, frame-sampling plan
(`FrameSamplePlanner`, timestamps only), the action schema, `ActionMapValidator`,
`AgreementClassifier`, `CrossReferenceIndex`, `VideoAnalysisCapability`, a `StubActionAnalyzer`.
Synthetic fixtures: a narrated filter change; a silent stretch with three un-narrated actions; a
job chat with no procedure; a stalled recording in two parts; a wall-clock jump mid-session.
Tests: `SessionClockTests`, `SessionTimelineCodingTests`, `TurnAlignerTests`,
`ProcedureCandidateDetectorTests` (certain / likely / none / dismissed), `SegmentPlannerTests`
(budget, gaps, what was left out), `FrameSamplePlannerTests`, `ActionMapValidatorTests` (unknown
frame id, reversed times, no evidence), `AgreementClassifierTests` (all three labels, negation),
`CrossReferenceIndexTests` (media removed keeps rows), `ActionMapPipelineTests` (fixture → stub →
index).

**P1 — Capture, consent, sampled frames.** `RecordingTimebase` out of `VideoRecordingService` and
the per-recording destination; `SessionCaptureCoordinator`; timeline events from the turn flow;
`RecordingConsent`; `TimedTranscriptSource` (see below); frame extraction through the chokepoint;
`SampledFramesAnalyzer` + the multi-image structured call; queue, budget, usage, the two org keys,
the route, the scope and roster entries; the suggestion screen. Tests:
`RecordingTimebaseTests`, `SessionCaptureCoordinatorTests` (fake recorder and clock),
`ActionFrameExtractorTests` (filter `nil` drops), `SampledFramesAnalyzerTests` (request bodies per
provider, parsed fixtures), `ActionAnalysisQueueTests`, `OutboundFrameConsumerTests`,
`SettingKeyTests`, `MedicalEgressGuardTests`.

**P2 — Native video, reviewer, authoring.** `SegmentExporter`, `NativeVideoAnalyzer`; the review
screen (step ↔ words ↔ clip, agreement badges, playback of a part range); hand-off into GY's
draft with provenance. Tests: `SegmentExporterTests` (synthetic MP4: no audio track, every frame
filtered), `NativeVideoAnalyzerTests`, `ActionMapDraftHandOffTests` (video-only step labelled;
safety line from video refused).

**P3 — Evidence and compliance.** `observed_actions` in the office JSON under HD's audience;
`ProcedureComplianceReport` behind a flag. Tests: `ObservedActionsExportTests` (customer audience
gets none), `ProcedureComplianceReportTests` (never "failed"; unclear on low confidence or a gap).

**P4 — Device checks (owed).** A 20-minute recorded job with a conversation running: A/V and turn
alignment error; recording while locked, blur on and off; the assistant's voice on speaker versus
glasses; analysis accuracy on a real task with and without blur; battery and heat.

**Dependency on GY.** HE needs GY P0's `TimedTranscript` and `WalkthroughSegmenter`, GY P1's
`TimedTranscriptSource`, and — for the authoring hand-off only — GY P3's draft store and review.
If GY is not built first, **HE P0 and P1 carry those three types exactly as GY specifies them**, and
GY adopts them. HE P2's hand-off waits for GY; its reviewer does not.

## Risks

- **Accuracy.** First-person video of hands at the edge of frame, sampled at a low rate, will miss
  and invent actions. Everything downstream is labelled, reviewable and advisory for that reason.
- **Alignment drift** between the audio transcript and logged turns in noisy rooms; `coarse`
  precision is shown rather than hidden.
- **A customer's premises in a cloud request.** Per-send consent, forced blur, budget, org ceiling.
- **Storage.** An hour of video per job fills a phone; the storage guard exists, retention is new.

## Open questions for Greig

1. **Which provider first for video?** *Recommended:* none natively — ship sampled frames on
   whatever provider is active (P1), then Gemini native video (P2) once its limits are verified.
2. **Own mode or an option on a job?** *Recommended:* an option on a job ("Record this job"),
   stored with the job; outside a job the same recorder serves GY's walkthrough. No new mode.
3. **Compliance in v1?** *Recommended:* no. Authoring and internal evidence first; compliance in P3
   behind a flag, advisory, after P4 shows what accuracy is real.
4. **Automatic or user-initiated?** *Recommended:* detection automatic and local; sending always a
   person's yes, once, at the end.
5. **Blur for cloud video analysis?** *Recommended:* always on for this egress, whatever the global
   switch says, with no off switch in v1.
6. **Raw capture with filtered exits** (GQ Decision 1) — adopt the same answer here?
   *Recommended:* yes; otherwise a blurred pocket recording has holes.
7. **Send the audio track with native video?** *Recommended:* no — words go as text.

## Out of scope

Live (during-the-job) action recognition or coaching; analysis of remote-expert sessions; on-device
video models; automatic publication of anything derived; a desktop review surface; customer-facing
action evidence; training or fine-tuning on recordings; Gemini Live / OpenAI Realtime turn timing
(v1 timelines cover Direct mode; live modes keep what they log today).
