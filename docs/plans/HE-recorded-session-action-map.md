# Plan HE — Recorded Job and Sync to the Office

**Status:** 🚧 P0, P1 and the headless part of P2 built 2026-10-05, in the opt-in office transport
build; device checks owed. **P1 (2026-10-05):** "Record this job" on the open job's page records
the glasses' raw frames and the microphone into the job's own folder, on one clock, behind a
recording consent, and seals the bundle when it stops; the sync service P2 built is now started
from the app and sends it (see "P1 as built"). The default build has no office transport and so
offers no recording. **Where an organisation requires blur, no job is recorded at all**: the blur
pass is not built. P0 is the pure core and the contract's fixtures; the two signed messages — the
bundle manifest and the office's receipt — have a reference implementation and golden fixtures in
`Transport/mobile-core/recordingbundle`, and the phone's own Swift for them writes and reads the
same bytes (see "P0 as built"). Still unbuilt: `BundleBlurPass`, the owed item on the Jobs list
and the job-day card, starting a recording by voice, P3 and P4. No bundle has left a physical
phone. Drafted 2026-10-02 and **revised the same day:**
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

**The signed messages, as built (2026-10-05).** `BundleManifest` lists a bundle from the two JSON
files and each part's `ChunkPlan`, checks the contract's rules, and writes the manifest's **one
spelling** — the exact bytes the phone application key signs; it reads back only that spelling.
`OfficePhoneIdentity.signRecordingManifest` signs nothing else. `OfficeRecordingReceipt` reads
the office's receipt and later status against the office application key of the binding held
and the phone's own record of the manifest it sealed. `BundleManifestTests` holds the phone's
bytes to the golden manifest the reference implementation signed, byte for byte;
`OfficeRecordingReceiptTests` reads the three golden receipts and refuses what is not one.
Nothing calls any of it yet: `BundleSyncState` is still handed a receipt someone else has
verified, and joining the two is P2. The `PowerPosture` flag `defersBulkTransfer` is P1;
`SyncEligibility` takes it as a plain input.

Choices made for the signed messages, now in the contract (§3, §6):

- **The manifest has one spelling** rather than being a flat object, because it holds lists:
  members in the contract's order, no white space, no text that needs an escape. A verifier
  writes it again and compares bytes.
- **`phoneTransportID` is in the manifest and the receipt**, as in every other phone message.
- **The generation is the one the bundle was sealed under.** A bundle may take days to arrive
  and the binding may be renewed meanwhile: the office accepts an earlier generation it issued,
  and a receipt names the manifest's generation, not the binding's current one.
- **One file per status** (`control/recordings/<bundleID>.<status>.envelope.json`), so a
  published name keeps its bytes. `reason` and the published vault are members of the receipt.
- **Identical chunks are one file** in the bundle, as within a part.

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
  the one named is the first of: medical mode, the organisation's blur rule (added in P1),
  profile, licence, pairing, network, power, office reachable, smaller traffic first.
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

**P1 as built (2026-10-05)** — in the opt-in office transport build. The default build links no
office transport, so it has no office and offers no recording.

*Pure, in `JobRecording/` (and in the portable check):*

- **`RecordingTimebase`** — what a recorder says about a part when it stops: for each track, the
  host clock's reading at its first sample and how long it ran. `placed(partID:on:endedBy:)` puts
  it on the `SessionClock`; `tracksAndGaps` writes the timeline's tracks and, between one part and
  the next, a gap with the reason the earlier part ended.
- **`RecordingConsent`** — the six points the sheet makes, the line said at each start, and
  whether an acknowledgement still stands: for this wording and for this organisation.
- **`JobRecordingAvailability`** — the one decision about whether recording is offered and may
  run. *Not offered* (nothing is shown): no office transport in the build, Field Assist not
  unlocked, or no pairing that verifies now. *Unavailable*, with a sentence: Medical Compliance
  on, Medical Local Only refusing the route, the organisation forbidding it, **the organisation
  requiring blur**, no open job, the job already recorded, too much waiting to be sent. The same
  rules stop a recording that is already running.
- **`RecordedJobAssembly`** — puts the timeline and transcript together when a recording stops:
  the placed parts and their gaps; what was noted as it happened; the job log's turns, photographs
  and procedure steps placed through the wall clock, technician turns then moved by `TurnAligner`;
  each part's words shifted to where its sound begins; and the candidate markers.
- `SyncEligibility` gained `blurRequired` (named after medical mode): an unblurred recording is
  not sent where the organisation requires blur. `PowerPosture.defersBulkTransfer` is true from
  `conserve` up.

*Capture:*

- **`VideoRecordingService`** takes a `destination` and a `source`. `.file(URL)` writes the part
  where it will stay and does nothing else with it — no `RecordingFiler`, no chosen folder, no
  Photos, no transcript files (`filingPlan`, which the code follows). `.rawForOfficeRecording`
  is refused for the library before anything is created (`checkPairing`). It reports
  `lastTimebase` on stop. Every existing caller passes neither and behaves as before.
- **`PrivacyFilterScope.officeRecording`** — unfiltered at capture, and the one unfiltered scope
  that leaves the device (`leavesTheDevice`). Roster: `jobRecordingCapture` (raw tap, justified
  exemption, owned by `JobRecordingCoordinator`) and `jobRecordingOfficeSync` (the bundle, a new
  `organisationExit` mechanism reading a new `jobRecordingFolder` tap, owned by
  `JobRecordingSyncService`). `JobRecordingExitTests` reads the sources: the files that hold a
  recorded job call nothing that shares, exports, files or saves one, and only the two stores
  build a path into a job's `recording` folder.
- **`JobRecordingCoordinator`** — starts, pauses, carries on and stops a recording of the open
  job, against seams. One recording a job; a stall, a pause or carrying on after the app was
  closed begins a new part. It claims the glasses stream as a clip does. Each second it asks
  whether the job is still open, whether the rules still allow it, and whether the recording has
  reached the size limit — stopping, saving and saying so when not. On stop it transcribes each
  part, assembles the two files and calls `JobRecordingBundleStore.seal`; nothing is sealed or
  signed on a pairing that does not verify at that moment, and the recording then waits on the
  phone and is sealed on a later pass. Changes to the recorder — start, pause, carry on, stop —
  happen one at a time; sealing is not one of them, so a stop never waits behind a transcription
  and another job can be recorded while the last is being prepared.
- **`JobRecordingCaptureStore`** — the parts before sealing, in
  `Documents/FieldSessions/{id}/recording/capture/`, with a journal of the recording so far.
  Registered as `SensitiveStore.jobRecordingCapture` and accounted for in subject erasure.
- **`TimedTranscriptSource`** — on-device: the part's sound read in ten-second windows, each an
  utterance.

*Policy:* `organizationForbidsJobRecording`, `organizationRequiresBlurBeforeOfficeSync` and
`organizationForbidsRecordingSyncOnCellular` are `SettingKey` ceilings pinned on, read through
`PolicyEnvelope` like every other. `NetworkRoute.jobRecordingOfficeSync` (frames, audio,
transcript; blocked in Local Only) is asked by the sync service where it publishes.

*In the app:* `AppState.jobRecordings` and `officeJobRecordings`; a sweep on the office
connection's poll, after reports; "Record this job" on the open job's page with the consent
sheet, pause, mark, stop, and the line saying where the recording stands, also on a finished
job's page; deleting a recording asks first and says when the office has not received it.

**Choices made in P1.**

- **Where blur is required, no job is recorded.** `BundleBlurPass` is not built, so the rule
  cannot be met. Rather than record and hold, or record and send, "Record this job" is shown
  unavailable with the reason. A recording made before the organisation turned the rule on is
  kept and not sent, and says why.
- **One file a part, sound and pictures together.** The recorder writes one MP4 holding both.
  The manifest lists it once, as `video`/`mp4`; the timeline's `audio` track names the same
  `partID` with the sound's own `tZero` and `duration`. Inside the file each track starts at
  zero at its own first sample, so the two are offset by the difference of their `tZero`s — the
  recorder's existing behaviour, now written down instead of lost. In the contract (§4).
- **Raw frames come from the camera's publisher, taken in one named place**
  (`JobRecordingCoordinator.rawFrames(from:)`), by a recorder of its own — a second
  `VideoRecordingService` with its own microphone handler — so a job's recording and the
  wearer's ordinary recording never share a writer or a destination.
- **Unsealed parts live in the job's folder, never `tmp/`.** The folder is made
  `completeUnlessOpen` and excluded from backup before the recorder creates a file in it; a
  finished part's protection is also set by name.
- **Consent is three plain values in the app's settings** — when, which wording, which
  organisation — acknowledged once, cleared on leaving the organisation, and asked again when
  the wording or the organisation changes. Its time is the manifest's `consentAt`. The
  compliance audit log is handed a `consentChanged` event, **but that log records only in
  Medical Compliance mode, where job recording is disabled** — so in practice the record of
  consent is the stored acknowledgement and a `recording_consent` line in the job's own log.
- **The three keys are read where they bind:** forbids and requires-blur by
  `JobRecordingAvailability` at the button, at the start and every second of a recording;
  requires-blur and forbids-cellular by `SyncEligibility` on every sync pass.
- **Transcription is on-device only.** The plan allowed the cloud transcriber when a key is set;
  the consent names one destination, the office, so a transcription vendor is not used. With no
  on-device model the recording is sealed with an empty transcript and coarse turn times.
- **Events from the job log are placed to the second**: the log writes whole-second stamps.
  What is noted live — microphone, assistant speaking, capture silenced, tool calls, markers — is
  to the millisecond. A turn the log gave no id is `log-N`; a photograph's `ref` is its file name.
- **A recording survives the app being closed.** Finished parts and what was noted are in the
  journal. While the job is open it can be carried on (a `restart` gap; the new parts join the
  old zero through the wall clock, since the monotonic clock restarts with the phone) or
  finished as it is; once the job has closed it is sealed from what it had. The part being
  written when the app closed has no index, does not play, and is removed.
- **A recording that could not be sealed is kept and tried again** — at once when the reason
  was the pairing, after fifteen minutes otherwise (each try transcribes it from the start).
  Sealing cuts the parts into chunks before the parts are removed, so for that moment a
  recording is on the phone twice; one that does not fit stays as parts and says it is waiting.
- **Mobile data is never used.** There is no setting yet for a technician to allow it, so a
  recording waits for Wi-Fi whatever the organisation says. A link the system calls expensive
  counts as mobile data.
- **Leaving the organisation:** an unacknowledged recording is owed like an undelivered report,
  and is withdrawn from the office's folder when its job is erased.
- **Nothing deletes a job from a screen today**, so `unacknowledgedDeletionWarning` has no
  caller; the same rule is on the recording's own delete.

**Still owed after P1:** `BundleBlurPass`; starting and marking by voice (not built — no tool was
added); the owed item on the Jobs list and the job-day card; a setting to allow mobile data;
a live phone-camera session; P3; P4.

**What only a phone and glasses can show (owed):**

1. That a recording starts, runs with a conversation going, and plays back with sound.
2. The offset between sound and pictures inside a part, against the two `tZero`s.
3. Capture with the phone locked in a pocket: that frames keep arriving on the raw path, that a
   new part can begin while locked, and that stopping while locked leaves the recording waiting
   and sealed once unlocked.
4. A stall: glasses out of range and back, the part boundary and the gap.
5. The on-device transcriber reading the sound out of a recorded MP4.
6. Size on disk per minute against the 2 GB limit, and free space while sealing (the parts and
   their chunks are both on disk until the seal finishes).
7. The capture light, and the assistant's replies on the recording through the glasses and
   through the phone speaker.
8. A bundle sealed on a phone, taken by a real office, acknowledged and trimmed.

**P2 — Bundle and sync.** `BundleBuilder`, `BundleBlurPass`, the sync service over an injected
transport seam, acknowledgement verification, retention, the owed item and job-page status.
**Blocked on FX items 1–4**; the seam lets everything but the live transfer be tested. Tests:
`BundleBuilderTests`, `BundleBlurPassTests` (synthetic MP4, every frame filtered, drops counted),
`BundleSyncServiceTests` (fake transport: interruption, resume, office away, refused manifest),
`RecordingReceiptTests`, `JobDayComposerTests` (owed wording).

**P2, the headless part, as built (2026-10-05)** — in the opt-in office transport build; nothing
in the app starts it yet, because nothing records until P1.

- **Transport** (`Transport/mobile-core/managed_recordings.go`). `PublishManagedRecordingManifest`
  checks a manifest and its signature as the office will and publishes it with the timeline and
  transcript it lists, under `records/recordings/<bundleID>/`; the same manifest again publishes
  nothing new and another under the same bundle is refused. `PublishManagedRecordingChunk`
  publishes one chunk the manifest lists, only as its exact bytes, **linked** into the folder so
  a recording is not held twice (copied where a link is not possible). `ManagedRecordingProgress`
  says how much is in the folder and how much of that the office no longer needs — progress,
  never acknowledgement. `ManagedRecordingStatuses` lists the office's statuses that verify for a
  bundle this phone published, including one sealed before a renewal. `WithdrawManagedRecording`
  takes a bundle out of the folder and, unless told to forget it, keeps listening for what the
  office says later. The outbound guard serves a bundle's manifest and the files published for
  it, and nothing else.
- **`JobRecordingBundleStore`**. Sealing cuts each recorded part into chunk files named by
  digest, reading the part in pieces; lists exactly those files in a `BundleManifest`; has the
  phone application key sign it; and writes the phone's record of the bundle, under the job's own
  folder (`Documents/FieldSessions/{id}/recording/bundle/`). The recorder's part files are removed
  once the bundle is sealed: the chunks are the recording from then on. Half a bundle is no
  bundle. Registered in `DataStoreRegistry`, `completeUnlessOpen` and out of backup.
- **`JobRecordingSyncService`**. Each pass, for each bundle: while `SyncEligibility` says the
  moment is wrong it says why and publishes nothing more; otherwise, through the pairing gate, it
  publishes the manifest and then chunks **two ahead of what the office has taken**, so a route
  that stops being a good one has at most that much exposed to it. Every office status is
  verified with `OfficeRecordingReceipt` against the binding held and the record of the manifest
  sealed, and acted on once. *Received* acknowledges, keeps the receipt, and takes the bundle out
  of the folder; a week later the media is trimmed and nothing else. *Refused* keeps everything
  and stops; thirty days without a receipt keeps everything and stops; either waits for the
  technician's *keep waiting* or *delete*. What the office says later — reviewed, published,
  rejected — is kept as the recording's outcome.

As tests: `JobRecordingSyncServiceTests` seals the fixture recording as the golden bundle byte for
byte; shows nothing is published on mobile data, without power or on a pairing that does not
verify; that only two chunks go ahead; that everything served is *sent* and never *received*; that
only the office's own receipt for this manifest acknowledges; that the media goes at seven days
and only the media; that a refusal and an expiry remove nothing. The transport's own tests cover
what it publishes, serves and lists.

Choices made:

- **Chunks are linked, not copied**, into the office's folder: a 2 GB recording is on the phone
  once.
- **Two chunks ahead.** Eligibility cannot pause a folder that also carries reports, so a
  recording is fed to it a little at a time instead.
- **An acknowledged bundle leaves the folder at once** and is still listened for.
- **`completeUnlessOpen`**, as this plan says: a chunk being read when the phone locks can be
  finished, and nothing new can be opened. Whether a transfer survives a locked phone is P4's
  question.
- **The transcript stays after the trim**, with the timeline, manifest and receipts.

**Still owed for P2:** `BundleBlurPass`; the owed item on the Jobs list and the job-day card.
Done with P1 (2026-10-05): the service is started from the app with real conditions, the job's
page shows where the recording stands and has the delete control (which asks first, and says
when the office has not received the recording), and a phone leaving its organisation owes an
unacknowledged recording as it owes an undelivered report.

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
