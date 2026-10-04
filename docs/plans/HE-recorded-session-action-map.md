# Plan HE — Recorded Job and Sync to the Office

**Status:** 🚧 P0 built 2026-10-05 — the pure core and the contract's fixtures, headless; nothing
is wired into the app, and nothing records, stores or sends. Two things P0 lists are **not** in it:
the signed bundle manifest and the office's receipt, which are being written separately as a
reference implementation with golden fixtures (see "P0 as built"). P1–P4 are unbuilt, and P2 is
still blocked on Plan FX. Drafted 2026-10-02 and **revised the same day:**
Greig moved the video analysis and the review surface to Avenkin Office. This plan is now the
phone half — record, timeline, bundle, sync; the office half is specified in
[`Contracts/recorded-session.md`](../../Contracts/recorded-session.md).
**Track:** Field Assist (B2B).
**Related:** Plan [FX](FX-desktop-office-and-device-sync.md) (the phone's connection to the office
— this plan's transport and its main dependency), Plan [GY](GY-procedure-from-narrated-recording.md)
(procedure drafted from a narrated recording — built on, not edited), Plan
[GQ](GQ-rolling-video-memory.md) (Decision 1: raw private capture with filtered exits), Plan
[DA](DA-recording-persistence.md) (`RecordingFiler`), Plan [CP](CP-outbound-frame-privacy.md) /
W04.1 (chokepoint and roster), Plan [FO](FO-guided-job-flow-and-job-tab.md) (job evidence,
`record_clip`), Plan [HC](HC-jobs-list.md) (Jobs list, what is owed), Plan
[HD](HD-report-transcript-audience.md) (office versus customer), Plan
[CT](CT-org-configuration-profiles.md) / [HA](HA-settings-hub-and-org-lockdown.md) (organisation
policy), Plan [BV](BV-power-policy.md), Plan [GU](GU-wake-word-audio-and-power.md).

---

## Trigger

Greig, 2026-10-02: start a recorded session — video recorded while the technician keeps talking to
Avenkin — and, if a procedure is found in the transcript, have a model map the actions in the
video, tie them to the transcript, and cross-reference them. Later the same day: the analysis and
the review belong in the office app; the phone records and delivers.

## Outcome

- **"Record this job"** — an option on a job. The recording is stored with the job, deleted with
  it, and never goes to Photos.
- **One timeline.** Video, microphone audio, the technician's and assistant's turns, tool calls
  and procedure steps on one clock, with gaps written down, in `timeline.json`.
- **A timed transcript**, and local, advisory **candidate markers** — "a procedure probably
  happened here" — that tell the office where to look. Nothing is analysed on the phone.
- **A recorded-session bundle** synced to the organisation's own Avenkin Office over the FX
  connection: Wi-Fi and power by default, resumable, hash-verified, size-capped, and **kept on the
  phone until the office acknowledges it**.
- **The office** runs the video model, builds the action map and the step ↔ words ↔ clip index,
  hosts the review, and publishes an approved procedure back as a vault — per the contract. The
  phone later shows what came of the recording.

## What exists today (verified against main @ f479d0ab, build 455)

**Recording**

- `VideoRecordingService.startRecording(from:…)` writes H.264 + AAC from `outboundFrames.publisher`
  (`AppState.toggleRecording`, the remote-invoke bridge, `VideoRecordingTool`), with no length
  limit, and files through `RecordingFiler` into `Documents/Recordings/` and, by default
  (`Config.recordingSaveToPhotos`), Photos. The Photos choice is read from `Config` inside
  `fileFinishedRecording`; `recordingsDirectory` is injectable, the Photos choice is not.
- **No shared clock.** `appendFrame` and `appendAudioBuffer` each take the host clock at their own
  first sample (`videoStartTime`, `audioStartTime`) and start at zero; neither value is kept.
  `recordingStartDate` is a wall `Date()` taken before either. A stalled stream auto-stops the
  file (`shouldAutoStop`).
- **Recording and a conversation run together by design.** Audio comes from `CaptureAudioRouter`
  (the listener's shared tap, or `StandaloneMicTapService`), a wearer-voice consumer in
  `WakeListenPolicy.wearerAudioConsumerIDs`. Device confirmation is owed by GU (check 12).
  `AssistantAudioGate` zero-fills capture while a reply plays from the phone speaker, and replies
  into the glasses never reach the mic — the assistant's words are not reliably in the audio.
- **The relay has holes.** `PrivacyFilterScope.recording` is relay-fed: with
  `Config.privacyFilterEnabled` on (default off) the relay drops every frame while the blur cannot
  run — backgrounded, transitioning, locked (`PrivacyFilterAvailability`). A pocketed phone is a
  locked phone.
- **Nothing links a recording to a job.** `record_clip` (`JobClipRecorder`) is silent and
  length-capped by design. `RecordedSession` / `RecordedSessionStore` are the audio-only meeting
  recorder — the name is taken. `PhoneVideoSource` feeds only `BroadcastService`;
  `PhoneCapturePolicy` marks `video_recording` and `record_clip` `.glassesOnly`.
- **The job log stamps late.** `SessionLogger.Event.timestamp` is `Date()` when logged
  (`FieldSessionService.recordConversationTurn` after transcription, `recordAssistantReply`,
  `ProcedureRunner`'s `procedure_started/step/completed`). Nothing records when words began.
- **Transcription discards timings.** `RecordingTranscriber.transcribe(fileURL:)` returns text.
  GY's `TimedTranscript` / `TimedTranscriptSource` are specified, not built.
- **No consent type or sheet.** `AuditEventKind` has `recordingStarted`, `recordingStopped`,
  `consentChanged`.

**Sync to the office (Plan FX as built)**

- The phone verifies a vendor-signed profile and licence, an administrator-signed peer binding
  (`OfficePairingService`, `OfficePeerBinding`, `OfficeApprovedPeerStore`,
  `OfficePeerHighWaterStore`), and holds its own application key and transport identity
  (`OfficePhoneIdentity`, `OfficeTransportIdentity`).
- The managed connection is **handshake-only**: certificate-pinned, private LAN, no listener,
  **no shared folders**. The default main-app build does not embed the transport; an opt-in build
  links it from `Transport/`.
- Contracts exist for office → phone only: signed manual assignments and managed jobs
  (`OfficeManualAssignment`, `OfficeManagedJob`; `Contracts/README.md`, fixtures in
  `Contracts/fixtures/`, portable tests in `Contracts/tests/`). They are verification contracts;
  no production caller delivers anything.
- **Phone → office is closed.** The embedded engine's outbound request guard refuses every file
  request; the lab preview allows exactly one synthetic `receipt.json`
  (`Contracts/office-preview.md`). The preview's size limits are 16 MiB per file, 128 MiB in total.
- FX states that transfer limits, network policy, background execution and screen-lock recovery
  "remain to be specified and tested", and that a relay is not an offline inbox.
- Job reports reach an office today by a different road — Mail, the share sheet, or the HTTP
  endpoint queue (`JobSendService`, `DeliveryQueue`, `AttachmentBudget`'s megabytes). None can
  carry hundreds of megabytes.

## Assessment

The revised split is right. The phone is the wrong place for a video model, a per-frame cost
ceiling and a side-by-side reviewer; the office has the screen, the power and the organisation's
policy. Three things the code forces:

1. **The transport is the real work, and it is not there yet.** FX has no phone → office file
   flow at all. This plan does not invent a second transport; it states what FX must provide
   (below) and builds the pure parts that do not wait for it.
2. **Unblurred footage for the office means a raw capture path.** A relay-fed recording is raw
   only when the blur switch is off, and holed when it is on. Recording for the office therefore
   takes GQ Decision 1's answer: raw frames into private storage, filtering at the exits.
3. **Words are timed from the audio, not the job log** — logged turns are matched to utterances
   afterwards; the assistant's lines come from the log.

## Design

### 1. Capture — "Record this job"

- Offered on the open job (Jobs tab and by voice). Starting needs the recording consent (below).
  One recording per job at a time; a stall, pause or restart begins a new *part*.
- `JobRecordingCoordinator` drives `VideoRecordingService` with two new inputs: a destination
  (`Documents/FieldSessions/{id}/recording/`, never Photos) and a frame source.
- **Frame source: raw.** A new `PrivacyFilterScope.officeRecording`, unfiltered at capture, with
  the same argument GQ makes: private, protected storage on the phone is not egress. Its exits
  are the only ways the pixels leave the folder, and each is listed on the roster
  (`OutboundFrameConsumer`): `jobRecordingCapture` (raw tap, justified exemption),
  `jobRecordingOfficeSync` (the bundle — raw by default, blurred when policy requires),
  and **no other exit**: the recording cannot be shared, saved to Photos or attached to a report
  from the phone. A clip for a report stays `record_clip`'s job.
- **Blur when required.** `BundleBlurPass` re-encodes the parts through
  `StillImageFiltering.filteredOrUnavailable` before the bundle is sealed. It runs in the
  foreground (where the blur is available), so a bundle that needs it waits as "Open Avenkin to
  prepare the recording". Because capture was raw there are no holes; a frame the filter cannot
  process is dropped and counted in the manifest.
- Glasses camera in v1. A live phone-camera session is later (device-pending: background capture).
- Storage guard as today (`storageVerdict`), plus the caps in §4.

### 2. Clock and timeline

- **`SessionClock`** — a wall `Date` and a monotonic reading captured together at start. Session
  time `t` is seconds from that zero. Wall-stamped job-log events map through the pair.
- **`RecordingTimebase`** — the recorder reports each track's first-sample host time on stop, so
  every part has `tZero` and `duration`. Gaps are explicit entries.
- **Events** with `t`: turn started (mic live), turn logged (the job log's `source_id`), assistant
  speaking began/ended (`CaptureAudioRouter.setAssistantSpeaking` sees both), tool call, photo,
  `procedure_step`, capture gate silenced/passed, user marker ("mark that").
- **`TurnAligner`** (pure) matches each logged technician turn to utterances in the window before
  its stamp by token overlap; unmatched turns keep the log time with `precision: coarse`.
- **Timed transcript** — GY's `TimedTranscript` via `TimedTranscriptSource`, produced on the
  phone after the recording stops (on-device by default; the existing cloud transcriber when a key
  is set and HIPAA mode is off).
- **Candidate markers** — `ProcedureCandidateDetector` (pure) over GY's `WalkthroughSegmenter`
  output and the events: `certain` (a `procedure_started…completed` run, or a user marker),
  `likely` (three or more consecutive step-like segments in a bounded window). Written into the
  timeline as advisory metadata. The phone acts on them in no way.

### 3. The bundle

Specified in the contract; in short: a signed `manifest.json` (bundle id, job and session ids,
phone identity, schema versions, `blurred: true|false`, dropped-frame count, every file's path,
byte length and SHA-256), `timeline.json`, `transcript.json`, and media split into fixed-size
**chunks** named by digest. `BundleBuilder` and `ChunkPlan` are pure. The manifest is signed with
the phone's application key under its own signature domain, following the exact-bytes rule the
existing contracts use.

### 4. Sync

**What FX must provide (dependency — not built here, not replaced):**

1. the transport embedded in the shipping app, not only the opt-in build;
2. a production **phone → office managed folder**, send-only on the phone, opened only after the
   binding recheck FX already requires;
3. an outbound guard allowlist that serves exactly the files named in a sealed manifest, by digest;
4. an office → phone path for a signed **acknowledgement** (the managed-job folder's direction);
5. evidence for background and locked-phone transfer. Until it exists, sync is specified as
   foreground-capable and opportunistic in the background.

Chunking does not depend on the engine: whatever resumption the transport gives within a file,
a finished chunk is never sent twice and progress is countable.

**Phone-side design (pure where stated):**

- **`SyncEligibility`** (pure): network (Wi-Fi by default; cellular only if the user allows and
  the organisation does not forbid), power (charging, or battery above a floor and posture
  normal — a new `PowerPosture` flag `defersBulkTransfer`), policy (profile, lease and binding
  current), medical mode, and "job reports and receipts first" — a bundle never starves small
  traffic. Returns a reason in plain words when not eligible.
- **`BundleSyncState`** (pure state machine):
  `recording → preparing (transcript, blur pass if required) → sealed → waiting(reason) →
  transferring(sent/total) → delivered (all chunks served) → acknowledged → trimmed`, with
  `failed(reason)` and `expired`. Transport completion alone is **not** acknowledgement.
- **Acknowledgement.** The office verifies every digest and the manifest signature, commits the
  bundle durably, then signs a receipt naming the bundle id and manifest digest. Only a verified
  receipt moves the state to `acknowledged`. A replayed receipt is harmless.
- **Caps** (defaults are open questions): per session 2 GB, total unsynced on the phone 8 GB.
  At the session cap the recording stops, is saved and says so; at the total cap a new recording
  is refused with the reason and what to do (connect to the office network and power).
- **`RetentionDecision`** (pure): until acknowledged — keep everything, never auto-delete. After
  acknowledgement — media deleted after 7 days; `timeline.json`, the manifest and the receipt
  stay with the job. Deleting the job deletes everything; deleting a job with an unacknowledged
  recording asks first. Leaving the organisation (`OrgDeparture`) follows CT's rule for job data.
- **Expiry.** 30 days unacknowledged → `expired`: nothing is deleted, the job is flagged, and the
  technician chooses keep waiting or delete. A manifest refused by the office (`failed`) says why
  and offers the same choice.
- **What the technician sees.** The Jobs list and the job-day card gain an owed item through
  `JobDayComposer.owed`: "Recording waiting to sync" with the reason (waiting for Wi-Fi, waiting
  for power, open Avenkin to prepare, office not reachable), then "Recording sent", then
  "Recording received by the office". The job page shows size, progress and the delete control.

### 5. Privacy, consent, policy

- **Consent (shared with GY).** One `RecordingConsent` type and sheet: sound and pictures are
  recorded, the assistant's replies may be heard, **the recording goes to your organisation's
  office**, faces are not blurred unless your organisation requires it, tell the people nearby,
  how long it stays on the phone. Acknowledged once (`consentChanged`), a one-line reminder at
  each start, capture light on.
- **Unblurred to the office by default.** An internal destination, and better analysis.
  `organizationRequiresBlurBeforeOfficeSync` (ceiling, pinned true) forces `BundleBlurPass`.
  The existing `privacyFilterEnabled` setting does **not** blur this recording by itself —
  the sheet says so. (Open question 2.)
- **The office blurs before any cloud model** — an office-side duty, stated in the contract.
- **Organisation keys:** `organizationForbidsJobRecording`, `organizationRequiresBlurBeforeOfficeSync`
  (both ceilings pinned true), `organizationForbidsRecordingSyncOnCellular` (ceiling). Closed by
  name under `ManagedLockdown` with the other Field Assist controls.
- **Medical.** HIPAA mode: "Record this job" is **disabled** in v1 (as cloud transcription and
  diarisation are). Local Only refuses the route in any case (`MedicalEgressGuard`, a new
  `NetworkRoute`).
- **No office, no recording.** The option appears only with a current office binding. Solo users
  are not served in v1 (see Out of scope).
- **Audit without content.** Job log `recording_started/stopped`, `recording_bundle_sealed`,
  `recording_sync_acknowledged`, `recording_trimmed` with counts and digests only.
- **Storage.** `completeUnlessOpen`, excluded from backup, covered by
  `SensitiveStore.fieldSessionLogs` and `SubjectErasureCoordinator`.
- **Gating.** `FieldAssistEntitlement` and the office entitlement. Not agentic.

### 6. What comes back

The office may send signed status for a bundle (contract §8): received, reviewed, procedure
published (as a vault assignment the existing `OfficeManualAssignment` path installs), rejected.
The phone shows it on the job: "A procedure was published from this recording — ⟨title⟩". No
action events, clips or verdicts are shown on the phone in v1.

## Phases (one PR each)

**P0 — Pure core and contract fixtures (headless).** `SessionClock`, `SessionTimeline` + codec,
`TurnAligner`, `ProcedureCandidateDetector`, `BundleManifest` + codec and signing bytes,
`ChunkPlan`, `BundleSyncState`, `SyncEligibility`, `RetentionDecision`, and the contract's shared
rules as portable reference code with golden fixtures in `Contracts/fixtures/` (bundle manifest,
timeline, action events, agreement cases, index). If GY is not built: `TimedTranscript` and
`WalkthroughSegmenter` exactly as GY specifies. Tests: `SessionClockTests`,
`SessionTimelineCodingTests`, `TurnAlignerTests`, `ProcedureCandidateDetectorTests`,
`BundleManifestTests` (closed schema, signature domain, digest mismatch), `ChunkPlanTests`,
`BundleSyncStateTests` (every transition; delivery is not acknowledgement; replayed receipt),
`SyncEligibilityTests` (network × power × policy × medical table), `RetentionDecisionTests`
(never before acknowledgement), and `Contracts/tests` portable checks over the fixtures.

**P0 as built (2026-10-05).** In `OpenGlasses/Sources/Services/FieldAssist/JobRecording/`, Foundation
only (CryptoKit for SHA-256), no singleton, no disk, no network, no production caller:

- `SessionClock` (with `SessionTime`), `SessionTimeline` and its `timeline.json` codec,
  `TimedTranscript` and its `transcript.json` codec, `WalkthroughSegmenter`, `TurnAligner`,
  `ProcedureCandidateDetector`, `ChunkPlan`, `BundleSyncState`, `SyncEligibility`,
  `RetentionDecision`;
- the contract's shared rules as reference code: `RecordingText` (how words are read),
  `ActionEventValidator` (§7.2), `SpeechAgreement` (§7.3), `CrossReferenceIndex` (§7.4);
- fixtures in `Contracts/fixtures/`: `recorded-session-timeline-v1.json` and
  `recorded-session-transcript-v1.json` (one fictional job, byte for byte as the phone writes it),
  `walkthrough-segments-v1.json`, `action-events-v1.json`, `agreement-v1.json`,
  `cross-reference-v1.json`. Each rules fixture carries its inputs, the expected result of every
  case and a `rules` block; the expected results were worked out by hand from the rules, not taken
  from the code;
- tests, one class a subject: `SessionClockTests`, `SessionTimelineCodingTests`,
  `TimedTranscriptCodingTests`, `WalkthroughSegmenterTests`, `TurnAlignerTests`,
  `ProcedureCandidateDetectorTests`, `ChunkPlanTests`, `BundleSyncStateTests`,
  `SyncEligibilityTests`, `RetentionDecisionTests`, `RecordingTextTests`,
  `ActionEventValidatorTests`, `SpeechAgreementTests`, `CrossReferenceIndexTests`; and the portable
  check `Contracts/tests/test_recorded_session_contracts.py`, which runs all of them outside the app.

**Not in P0.** `BundleManifest` (payload codec, signing bytes, envelope, signature domain),
`BundleManifestTests` and the verification of the office's receipt: written separately, as the
reference implementation and golden fixtures for the two signed messages. Until they land,
`ChunkPlan` gives the digests and lengths a manifest lists for a part and no manifest type exists,
and `BundleSyncState` is handed a receipt that someone else has already verified — it only decides
whether that receipt is about this bundle and this manifest. The `PowerPosture` flag
`defersBulkTransfer` is P1; `SyncEligibility` takes it as a plain input.

**Choices made where this plan, GY or the contract left room.** The ones an office has to match
are also in the fixtures' `rules` blocks.

- *Times.* Held as whole milliseconds; written as a decimal with at most three places; a value
  read with more is rounded to the nearest millisecond, halves away from zero.
- *`timeline.json`.* No version member, as the contract's shape has none — the manifest states
  it. Written with sorted keys and no white space; video before audio; parts, gaps and candidates
  by time; events by `t`, and at the same `t` in the order they were added. `ref` is the job
  log's id on `turn_logged`, the procedure's id on `procedure_started` / `procedure_completed`,
  the step's id on `procedure_step`, the tool's name on `tool_call`; `speaker` is `technician` or
  `assistant`. A reader passes over unknown members and event kinds, a track of an unknown kind
  (with its gaps) and a candidate of an unknown certainty; it keeps a gap whose reason it does
  not know; it refuses a file missing one of the five members or with `monotonicZero` not 0.
- *`transcript.json`.* GY's utterance gains the `id` the contract needs; the phone numbers
  utterances `u1`, `u2`, … in time order. An empty or repeated id is refused.
- *Segmenter (GY gave no numbers).* A silence longer than 4 s opens a segment; a segment under 3
  words is a fragment. Markers are GY's list with only the grammatical variants ("now I am going
  to", "once that is done", "step" with any number), after any fillers ("okay", "and", "so" …),
  and count only at the start of a sentence. A sentence ends at `.`, `!` or `?` followed by white
  space or the end; an utterance that does not end one is taken to carry on into the next. A
  sentence inside an utterance is placed by how far along the text it begins. A fragment joins
  the segment after it — always when it is a marker on its own, otherwise only when no long
  silence lies between. **Step-like** means opened on a marker or on "new step"; a pause alone
  does not make a step.
- *Candidates.* Reasons `procedure_run`, `user_marker`, `step_run`. A run never completed ends at
  its last step. A spoken mark reaches 30 s each way, kept inside the recording. `likely` is
  three or more step-like segments, each beginning within 180 s of the end of the one before,
  other segments passed over; one that lies wholly inside a certain candidate is dropped.
- *`TurnAligner`.* Looks back 60 s from the stamp and allows 1 s after it; an utterance belongs to
  a turn when 60 % of its words are the turn's, and the turn is aligned when the matched
  utterances hold half of its words; an utterance is given to one turn only; the assistant's turns
  are never aligned.
- *`ChunkPlan`.* 32 MiB as proposed (the contract's open point); two chunks with the same bytes
  are one file; a part with no bytes has no plan.
- *`BundleSyncState`.* "Open Avenkin to prepare" is a wait before sealing, so `waiting` has two
  kinds. A verified `received` for this bundle and manifest acknowledges from any phase after
  sealing, including `failed` and `expired`; a `refused` cannot undo an acknowledgement and does
  not answer an expired recording. Keep-waiting returns an expired recording to where it was and
  a refused one to `sealed` with nothing counted as sent.
- *`SyncEligibility`.* Battery floor 50 % when not charging; when several things are in the way
  the one named is the first of: medical mode, profile, licence, pairing, network, power, office
  reachable, smaller traffic first.
- *`RetentionDecision`.* A gigabyte is 10⁹ bytes. Trimming removes media only — the transcript
  stays with the timeline, manifest and receipt (the plan did not say). Choosing to keep waiting
  starts the 30 days again.
- *§7.2.* Rejected, first that applies: not an object, no id (or over 80 characters), id used
  twice, a time missing, `start` not before `end`, outside the analysed span, not wholly on video
  (inside one part and touching no gap — stricter than "both ends inside a part"), `action` empty
  or over 200, `object` or `tool` over 80, no evidence left. Repaired: evidence outside the event
  and utterance ids the transcript lacks are taken out. A confidence that is missing, not a
  number or outside 0…1 is no confidence and the event is low-confidence. Lengths count Unicode
  scalars after trimming. `partial_view` is true unless the model says `false`.
- *§7.3.* Words are runs of a–z and 0–9 (ASCII only; apostrophes dropped); a fixed English
  stop-word list; a small suffix stemmer; a negator reaches to the end of its clause (`. , ; : !
  ?` or "but"); a word said both ways in one utterance counts as said. "Overlaps" is closed:
  exactly 5 s apart counts. `said_not_seen` is per step-like segment, with the same 5 s, and a
  low-confidence event counts as an event near it. Text in another language confirms nothing.
- *§7.4.* One row an event (`e-<id>`), and one for each stretch of clear video under a
  said-not-seen segment (`s-<segment>-<n>`); words said while no video was recorded have no row.
  `step` is the last `procedure_step` at or before the row's start while a procedure is running.
  Ties in `video.from` are broken by the bytes of `rowID`.

**P1 — Capture, consent, timeline.** `RecordingTimebase` and the destination/frame-source inputs
on `VideoRecordingService`; `JobRecordingCoordinator`; the `officeRecording` scope and roster
entries; `RecordingConsent`; timeline events from the turn flow; `TimedTranscriptSource`; caps;
the three organisation keys; HIPAA disable. Tests: `RecordingTimebaseTests`,
`JobRecordingCoordinatorTests` (fake recorder and clock; never Photos), `OutboundFrameConsumerTests`,
`RecordingConsentTests`, `SettingKeyTests`, `MedicalEgressGuardTests`.

**P2 — Bundle and sync.** `BundleBuilder`, `BundleBlurPass`, the sync service over an injected
transport seam, acknowledgement verification, retention, the owed item and job-page status.
**Blocked on FX items 1–4**; the seam lets everything but the live transfer be tested. Tests:
`BundleBuilderTests`, `BundleBlurPassTests` (synthetic MP4, every frame filtered, drops counted),
`BundleSyncServiceTests` (fake transport: interruption, resume, office away, refused manifest),
`RecordingReceiptTests`, `JobDayComposerTests` (owed wording).

**P3 — Office feedback on the phone.** Signed status messages, the job's "what came of it" line,
the published procedure arriving as a vault. Tests: `RecordingStatusMessageTests`,
`JobRecordingOutcomeTests`.

**P4 — Device checks (owed).** A 20-minute recorded job with a conversation running (A/V and turn
alignment error); locked-phone capture on the raw path; blur pass time and heat for 20 minutes of
video; a 1 GB bundle over Wi-Fi with the office asleep mid-transfer, relaunch, and a route change;
background transfer behaviour; acknowledgement and trim.

**Dependency on GY.** HE needs GY P0's `TimedTranscript` and `WalkthroughSegmenter` and GY P1's
`TimedTranscriptSource`, and carries them if GY is not built first. GY's phone review screen and
its on-phone drafting now overlap the office's — see open question 4; GY is not edited here.

## Risks

- **FX is not ready.** P2 can be built and tested against a fake, and cannot ship without it.
- **Background transfer on iOS** may be poor; the honest fallback is "open Avenkin on the office
  Wi-Fi", which the owed item says.
- **Raw footage on a phone.** Mitigated by private protected storage, no other exit, caps and
  trim after acknowledgement — and it is a change in posture that the consent sheet must state.
- **Storage.** An hour of video is large; the caps and the refusal wording matter.

## Answered by Greig (2026-10-02)

1. **Caps and retention defaults:** 2 GB a session, 8 GB unsynced in total, media trimmed 7 days
   after acknowledgement, expiry prompt at 30 days; nothing unacknowledged is ever deleted
   automatically. Proposed numbers, to be measured in P4; organisation-settable later.
2. **Blur at the phone:** off unless the organisation requires it. The global privacy-filter switch
   does not change it either way, and the consent sheet says the footage goes to the office.
3. **HIPAA mode:** job recording is disabled.
4. **GY's phone review screen:** dropped in favour of the office for organisations that have one,
   keeping GY's pure core and draft store. Settled when GY is scheduled; GY is not edited here.
5. **Ownership of the five FX items (§4):** FX owns the transport and the outbound guard; this plan
   owns the bundle contract and the phone's sync state machine.

## Out of scope

Everything the office does (contract); any video analysis on the phone; sharing or exporting the
recording from the phone; live phone-camera sessions; Gemini Live / OpenAI Realtime turn timing
(v1 timelines cover Direct mode); customer-facing action evidence.

**Solo users without the office app** are not served in v1. A later, optional phase could analyse
on the phone instead: a handful of sampled, blurred frames per candidate span sent to the active
image-capable provider with a forced schema, on a person's yes, under a small budget — using the
same action-event schema, validator and agreement rules as the contract. It needs its own egress
scope, cost ceiling and review surface, and is not designed here.
