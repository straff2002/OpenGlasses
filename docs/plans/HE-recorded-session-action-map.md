# Plan HE — Recorded Job and Sync to the Office

**Status:** 🚧 P0, P1, P2's sync and the blur pass built 2026-10-05, in the opt-in office transport
build; device checks owed. **P1 (2026-10-05):** "Record this job" on the open job's page records
the glasses' raw frames and the microphone into the job's own folder, on one clock, behind a
recording consent, and seals the bundle when it stops; the sync service P2 built is now started
from the app and sends it (see "P1 as built"). The default build has no office transport and so
offers no recording. **The blur pass (2026-10-05):** where an organisation requires faces blurred,
a job can now be recorded — each recorded part is put through the app's face blur on the phone
before the bundle is sealed, a picture the blur cannot process is dropped and counted, and the
manifest says `blurred: true` with the count (see "The blur pass, as built"). It has run only over
a small movie made in a test, with a stand-in for the blur: **no real recording has been blurred,
and how long it takes on a phone is not known.** P0 is the pure core and the contract's fixtures;
the two signed messages — the bundle manifest and the office's receipt — have a reference
implementation and golden fixtures in `Transport/mobile-core/recordingbundle`, and the phone's own
Swift for them writes and reads the same bytes (see "P0 as built"). **P3 is mostly there already**,
built with P2: the office's later statuses are verified and kept, and the job's page says when a
procedure was published — without its title, and with no words for *reviewed* or *rejected* (see
P3 below). **Outside the job's page (2026-10-05):** a recording the office has not confirmed is
now among what is owed on the Jobs list and the job-day card, with the reason it waits and nothing
once the office has confirmed it; a recording that is not sealed yet can be deleted, after being
asked, with any pass that is preparing it stopped first; and the job's log is written a line when
the office's verified receipt is taken in, when the media is trimmed, and when a recording is
deleted (see "Outside the job's page, as built"). Still unbuilt: starting, stopping and marking a
recording by voice (left out on purpose — see that section), a setting to allow mobile data, the
rest of P3, and P4. No bundle has left a physical phone. Drafted 2026-10-02 and
**revised the same day:**
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
  traffic. Returns a reason in plain words when not eligible. `evaluateMedia` asks one thing
  more of the video alone: a connection straight to the office, never a relay (decision 8).
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
- **`RecordingConsent`** — the six points the sheet makes, the line shown at each start, and
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
connection's poll, after reports, and every half minute a look for recordings still to be sealed
(off the poll's own path, so the office's other traffic never waits on a transcription); "Record this job" on the open job's page with the consent
sheet, pause, mark, stop, and the line saying where the recording stands, also on a finished
job's page; deleting a recording asks first and says when the office has not received it.

**Choices made in P1.**

- **Where blur is required, no job is recorded** — as P1 was built, with no blur pass. Rather
  than record and hold, or record and send, "Record this job" was shown unavailable with the
  reason. *Since the blur pass (below) a job is recorded under the rule and blurred before it
  is sealed; the refusal remains only for an app with no blur pass.* A bundle sealed unblurred
  before the organisation turned the rule on is kept and not sent, and says why.
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

**Still owed after P1:** starting and marking by voice (not built — no tool was added, and why
is under "Outside the job's page, as built"); a setting to allow mobile data; a live phone-camera
session; the rest of P3; P4. (`BundleBlurPass` and the owed item on the Jobs list and the job-day
card were owed here and are built — see below.)

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

**Still owed for P2:** every device check of the blur pass, listed at the end of the next
section. The owed item on the Jobs list and the job-day card was owed here and is built (see
"Outside the job's page, as built") — "Open Avenkin to prepare the recording" is now read there
as well as on the job's page. It is still read only *in* the app: nothing tells a technician
whose app is closed that a recording is waiting for it to be opened.
Done with P1 (2026-10-05): the service is started from the app with real conditions, the job's
page shows where the recording stands and has the delete control (which asks first, and says
when the office has not received the recording), and a phone leaving its organisation owes an
unacknowledged recording as it owes an undelivered report.

**The blur pass, as built (2026-10-05)** — in the opt-in office transport build.

*What it is.* `BundleBlurPass` (`Services/FieldAssist/Job/`, AVFoundation) reads one recorded
part and writes a new file beside it. Every frame is decoded and handed to the filter, and only
what the filter hands back is encoded: there is one place a picture is written, and it is fed
only from the filter's answer. A frame the filter refuses, one it hands back at another size,
and one that cannot be decoded are dropped and counted. The sound's packets are copied across
as they are — not decoded and encoded again — and every picture keeps the time it had. A part
with a second video track is refused. Before it says it succeeded it reads its own output back:
as many pictures as it encoded, as many packets of sound as the recorded part held, and a file
the system says plays. It never touches the recorded part.

*The filter* is a seam of two closures: "can the blur run now" and "blur this picture". In the
app it is the one chokepoint, `StillImageFiltering.filteredOrUnavailable`, under a new scope,
`PrivacyFilterScope.officeRecordingBlur`. **That scope is blurred whatever the app's face-blur
setting says** (`isMandatory`): every other filtered scope hands a picture straight back while
the wearer's setting is off, and here that would have put unblurred frames into a bundle marked
blurred. On the roster it is `jobRecordingBlurPass` — reads the job's folder, filters at the
chokepoint, is not an exit.

*Joined to sealing* (`JobRecordingCoordinator`). When the organisation requires blur, a stopped
recording's parts go through the pass before anything else is done with it. The bundle is then
made only of parts the journal names as blurred, from their blurred files and never from the
recorder's own; it is not sealed while any unblurred part is still in the folder; the manifest
says `blurred: true` and carries the total `droppedFrames`. Where blur is not required nothing
changes: no pass, `blurred: false`, `droppedFrames: 0`.
`JobRecordingAvailability.Facts.blurPassAvailable` is true wherever the coordinator has a pass
wired — in the app, always — so an organisation that requires blur can record; an app with no
pass still refuses, and never seals anything recorded under the rule.

*Only in the foreground.* The pass runs while the app is in front and the blur says it can be
relied on (both are asked). When it cannot run, the recording waits: the job's page and the note
left at the stop say "Open Avenkin to prepare the recording", and it is prepared when the app
next comes to the front (and on the office connection's half-minute pass). While it runs the
phone is kept from locking itself, and the job's page shows how far it has got.

*Safe to stop and repeat.* A name says what a file is and is never reused: `part-N.mp4` is only
ever what the recorder wrote; `part-N.blurring.mp4` is a blurred part being made, and is removed
wherever it is found; `part-N.blurred.mp4` is a finished one, and is *the part* only once the
journal says so. One part at a time: the pass writes the new file; it takes the blurred part's
name and the journal records it; only then is the unblurred part removed. Stopped anywhere, the
next pass puts it right — a blurred file the journal does not name is removed and made again; an
unblurred part still beside a replacement the journal does name is removed; any other file the
journal does not name is removed, never sealed. A part the pass was
interrupted in starts again from its first frame; parts already done are not done twice.

*What a sealed, unblurred bundle can do.* Nothing but wait or be deleted. A bundle sealed before
the organisation turned the rule on cannot be blurred — its manifest is signed — so
`SyncEligibility` holds it for as long as the rule stands (unchanged), and whether a bundle is
blurred is now read from its own signed manifest, bundle by bundle, rather than assumed. The
job's page says "This recording is held on this phone. … It stays on this phone and isn't sent.
You can delete it." and has the delete control, which asks first.

**Choices made for the blur pass.**

- **Sound: carried over untouched.** The same packets, in step. Only the first sound track; a
  recorder writes one.
- **Dropped frames are counted, and a long run of them is a gap.** The frames either side keep
  their times, so a dropped frame leaves the one before it showing a little longer. A run of a
  second or more is written on the timeline as a `filter` gap on the video, *inside* the part
  (the timeline's own `clearSpans` already cuts gaps out of parts, and the office's rules treat
  a gap as "no video here"). A shorter run is counted and not written: one lost frame should not
  cut a twenty-second action in two. The second is a choice, `BlurredPart.gapThreshold`. In the
  contract (§4).
- **A part with every frame refused keeps its sound and no pictures**: it is listed as sound
  (`track: audio`), and the whole of its video is one `filter` gap. With no sound either there
  is no part; a recording left with no part at all leaves nothing behind.
- **A rule that changes while a recording waits.** Blurred if the rule is on at any moment from
  the start of the recording to its being prepared — written into the journal when it is seen,
  and never unwritten. So a recording made without the rule and prepared under it is blurred,
  and one made under the rule is blurred even if the rule has since gone: the people in it were
  recorded on that understanding. The rule is asked once more just before signing; if it came in
  while the words were being read, the recording is not sealed and the next pass blurs it.
- **The temporary output is beside the recorded part**, in the capture folder that is already
  registered (`SensitiveStore.jobRecordingCapture`), `completeUnlessOpen` and out of backup; the
  finished file's protection is also set by name. No new store, no `tmp/`.
- **Room is checked first**: the blurred copy is about as large as the part, so the pass does
  not start without the part's size and a margin free. For that moment a part is on the phone
  twice, as it is again while sealing.
- **A decoder that delivers fewer frames than the part holds** has those counted as dropped too:
  they are not in the output either.
- **The technician is told** when pictures were left out: the note at sealing says so.
- **Each frame is blurred on its own.** The chokepoint finds faces one picture at a time and
  carries nothing from one frame to the next — unlike the camera-rate relay, which holds the
  last faces it found so that one missed for a single frame does not flash through. So
  `blurred: true` says every picture went through the blur; it does not say no face can be
  seen. How often a face is missed on real footage is device check 3 below, and if it matters
  the carrying-over belongs in the chokepoint, not in a second blur here.

**Tested, and not.** `BundleBlurPassTests` makes a one-second movie in the test — twenty-four
numbered frames, with and without sound — and runs the real pass over it with a stand-in filter
that marks each frame it is handed: every frame through the filter once and in order, every
frame in the output marked and where it was, refused frames absent and counted, the sound's
bytes identical, an interrupted pass leaving the part and no output. So **the decode and encode
really ran, in the simulator's test process; the app's face blur did not run over a movie** —
the one test with the real blur is of it refusing every frame with the setting off and the blur
unable to run. `JobRecordingCoordinatorTests` covers the joining with a fake pass. One thing the
test's movie turned up: the simulator's encoder refuses the sound settings the recorder itself
uses (AAC, 16 kHz, one channel, 64 kbps), so the test's movie is made at 44.1 kHz. The pass
copies packets and does not care, but that a recording starts on a phone with those settings is
check 1 of P1's own list and has not been seen here.

**What only a phone can show for the blur pass (owed):**

1. Time and heat for twenty minutes of video — the plan's own check. Nothing here says whether
   that is two minutes or twenty.
2. **The screen while it runs.** The blur is asked on the main thread, one frame at a time, as
   every other still is. That is tens of thousands of short stops in a row; whether the app
   stays usable meanwhile has to be seen, and if it does not the blur needs a way to be asked
   off the main thread.
3. That faces in a real recording are in fact blurred in the bundle, and how many frames the
   blur drops on real footage.
4. That the phone stays awake for a long part with the app open, and what locking it or leaving
   the app part-way does: the part should start again, and nothing unblurred be sealed.
5. A long single part: an interruption starts that part from its first frame, so an hour's
   recording in one part needs an hour's worth of blurring in one sitting. If that is too much
   to ask, the pass needs to keep what it has done within a part.
6. That a recorded part from real glasses — hardware encoder, frame reordering — reads back with
   the frame counts the pass checks, and that the blurred part plays in step with its sound.
7. Free space: a part and its blurred copy together, then the bundle's chunks.
8. A recording stopped with the phone locked in a pocket, then the app opened.
9. Memory over a long part: a frame is decoded, copied, blurred and encoded tens of thousands of
   times in a row.
10. What a player at the office shows where the first frames of a part were dropped: in the
    test's decoder that stretch reads back as one black picture before the first kept frame.

**Outside the job's page, as built (2026-10-05)** — in the opt-in office transport build. In the
default build neither recording service exists, nothing is gathered, and the Jobs list and the
job-day card are exactly as they were; the same is true of a job that was never recorded.

*The owed item.* `JobDayComposer.owed` — the one rule the job-day card and the Jobs list's badges
share — takes the recordings the office has not confirmed. `JobRecordingOwed` gathers them from
the two services that know: the sync service's rows for a sealed recording, and the coordinator's
`unsealedRecordings()` for one that has stopped and is not sealed. One row a job, under
"Still to do" on the card and in the day view, and a badge on that job's row in the Jobs list
carrying the title and the reason in one line. What it says:

| Where the recording is | Title | Reason |
|---|---|---|
| Stopped, being prepared now | Recording waiting to sync | Preparing the recording. |
| Stopped, faces to be blurred, app not in front | Recording waiting to sync | Open Avenkin to prepare the recording. |
| Stopped, to be prepared on a later pass | Recording waiting to sync | The recording is saved on this phone, and will be prepared for the office later. |
| The app was closed while it ran, job still open | Recording waiting to sync | A recording of this job was interrupted. What had been recorded is saved. |
| Sealed, no pass yet | Recording waiting to sync | — |
| Sealed, the moment is wrong | Recording waiting to sync | `SyncEligibility.Reason.explanation`: Wi-Fi, power, the office not in reach, reports first, the profile, licence or pairing, a medical privacy mode; or, with the rest of the recording already going, the video waiting for a direct connection |
| On its way | Sending the recording to the office | 25% of 1.2 GB. |
| Every file served | Recording sent | Waiting for the office to confirm it. |
| The office's verified receipt taken in | *nothing* | |
| Refused by the office, 30 days unconfirmed, or held unblurred under the blur rule | Recording needs attention | the job page's own sentence for it |

Every reason is a sentence one of the services already produced; the four titles are the only new
words, and `JobRecordingSyncService.words` now builds the job page's sentences from the same
titles so the three places cannot drift. A test holds every owed state to never saying
"received".

**Choices made for the owed item.**

- **Nothing once the office has confirmed it.** §4 lists "Recording received by the office" as
  a third stage of the owed item. It is not owed any more, so it is not among what is owed; the
  job's page still says it, on the receipt.
- **Not scoped to today.** The card's other admin is today's. A recording is the only copy until
  the office confirms it, so it stays on the card and on its job's row whichever day the job
  was — including one held under the blur rule, which stays until it is deleted or the rule goes.
- **A recording that is running is not owed.** It is owed from the moment it stops.
- **Two kinds, last in the strip.** One that needs the technician — refused, unconfirmed for
  thirty days, or held — is a warning, as a failed send is, and comes before one that only waits.
  Both come after the admin a technician can act on now; the card shows two to-dos and says how
  many more there are.
- **"Sending the recording to the office"** is a title of its own rather than "waiting to sync"
  with a percentage under it.
- **A job the phone no longer knows** (it should not happen) is still shown, as "No job number".

*Delete for a recording that is not sealed.* The job's page now has **Delete recording** beside
an interrupted recording, one waiting to be prepared and one being prepared. The coordinator
hands over the question (`askToDeleteUnsealed`: "The office hasn't received this recording yet.
Deleting it removes the only copy." — always, since an unsealed recording has never left the
phone) and `deleteUnsealed` takes that question and nothing else, so there is no call that
deletes without having asked. It removes the capture folder — the recorded parts, blurred or
not, and the journal — and the `recording` folder when nothing else is in it; a sealed bundle
beside it and everything else of the job are left. A recording that is running is not deleted:
it is stopped first.

*Stopping a pass safely.* Sealing now runs as a task of its own for each recording, so deleting
can cancel exactly that pass and wait for it before anything is removed. The pass asks whether
it has been cancelled after every wait: the blur pass stops at its next frame and removes what
it had written (and whatever it reports, nothing more is written); the on-device transcriber
stops at its next window; the signer is not asked; and if the signer had already been asked,
the seal finishes, the bundle it made is taken back out of the office's folder and removed, and
nothing is told of it. Nothing else about sealing changed.

*The job log* (§5). `recording_sync_acknowledged` — the manifest's digest, the receipt's digest,
the number of chunks and the bytes — is written when the office's verified receipt has been
taken in *and kept*, so a receipt that could not be kept is written down on the pass that keeps
it, once. `recording_trimmed` — the manifest's digest, the chunks and the media bytes removed —
is written when the media goes at seven days. Both are written by `JobRecordingSyncService`
through a seam, as the coordinator writes its own.

**Choices made there.**

- **A third line, `recording_deleted`**, which §5 does not list: a deleted recording would
  otherwise end in the log at `recording_stopped` or `recording_bundle_sealed` with nothing to
  say where it went. Whether it had been sealed, whether the office had it, and the bytes — for
  both deletes, the sealed one included.
- **Written after the record is saved**, not before: a line can be missed if the app dies in
  that instant, and cannot be written twice.

**Voice: not built, on purpose.** "Record this job", "stop recording" and "mark that" would be
one small tool over `JobRecordingCoordinator.start()`, `stop()` and `mark()` — and `start()`
already refuses without the on-screen consent, so the rule that voice never starts a first
recording unasked is met by construction. What is not small is everything a new tool has to be
entered in, each with a guard test and the first two a decision rather than a mechanical entry:
the outbound-frame roster, where a recording started by a tool is a consumer of its own and the
standing rule is that such a recording is fed from the blur relay — a raw one needs its own
argued entry; its effect class (starting a recording that leaves the phone for the office is
not obviously a plain local write, and the class decides whether a turn stops to ask); and then
its offline and phone-camera policies and the field tool profile. It is left for a change of
its own.

**Tested, and not.** The wording in every state, the scoping and the order are composer tests;
deleting — at rest, interrupted, with a journal that cannot be read, during the blur, during the
words, at the moment of signing — is tested against the fake recorder and a fake pass; the three
log lines are tested against the in-memory transport. **Not tested:** the joining in the app —
`AppState.owedRecordings`, the publisher that tells the two feeds something moved, and the
feeds taking them — is compiled and nothing more, and the Delete button and its dialog are
SwiftUI with no test.

**Still owed here:** the wording of the four titles and of the owed reasons has not been read by
anyone but its author; nothing has been seen on a phone — the badge's length on a narrow screen
(the reason for a held recording is four sentences), a row appearing and going as a recording
moves, deleting a long recording part-way through its blur. A delete waits for the pass it
stopped: one stuck in something that never returns would leave the delete waiting with it, and
there is no time limit on that wait. Voice, as above.

**P3 — Office feedback on the phone.** Signed status messages, the job's "what came of it" line,
the published procedure arriving as a vault. Tests: `RecordingStatusMessageTests`,
`JobRecordingOutcomeTests`.

**P3, as it stands (checked 2026-10-05) — mostly built by P0 and P2, never as a phase of its own.**

- *Built:* the office's later statuses — `reviewed`, `published`, `rejected` — are read and
  verified like a receipt (`OfficeRecordingReceipt`, against the binding held and the phone's
  record of the manifest it sealed), acted on once, kept exactly as the office sent them, and
  held as the recording's outcome with the vault's id and version (`JobRecordingSyncService`).
  The job's page says "Recording received by the office. A procedure was published from it."
  The procedure itself arrives as any assigned manual does, through the manual-assignment path
  Plan HO built.
- *Not built:* the procedure's title on that line (§6 has "— ⟨title⟩"); any words for
  *reviewed* or *rejected* — both are kept and neither is shown; anything joining the installed
  vault to the recording it came from; a job whose media has been trimmed still saying what
  came of it is untested.
- *Tests:* the two classes named above do not exist. What they would hold is in
  `OfficeRecordingReceiptTests` (the three golden receipts, and what is refused) and
  `JobRecordingSyncServiceTests` (a status under another status's name changes nothing; a
  published status is kept and shown).

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

## Answered by Greig (2026-10-05)

On the open points raised as the phases were built: **keep each as built.**

1. **Agreement (contract §7.3) stays as written**: one shared content word within five seconds
   of an event confirms it, and a low-confidence event still counts as an event near a step.
   The fixtures are the reference. A stricter rule is a change to the contract, not to the code.
2. **The transcript stays on the phone after the media is trimmed**, with the timeline, the
   manifest and the receipts.
3. **Consent is per phone**, asked again when the wording or the organisation changes. A shared
   phone does not ask a second technician.
4. **Transcription is on the phone only.** The cloud transcriber is not used for a recorded job,
   whatever keys are set; with no on-device model the transcript is empty.
5. **A part whose every frame the blur refuses is kept as sound only, and the unblurred part is
   removed.** Closed for privacy first; the dropped-frame count, the gap on the timeline and the
   note at sealing are the record of it.
6. **Each frame is blurred on its own.** `blurred: true` means every picture went through the
   blur. Carrying a face forward from frame to frame belongs in the blur itself, later.

7. **A recording waits for Wi-Fi — any Wi-Fi — and never uses mobile data.** It does not have
   to be the office's own network: a recording made on a Friday goes from the technician's home,
   across the internet, straight to the office where the office can be reached that way and
   through a relay where it cannot. Still end to end encrypted and pinned to the office either
   way. A relay is shared and can be slow, so a large recording may take hours from home; the
   two-chunks-ahead rule and resuming where it stopped are what make that tolerable.
   (For a few hours on 2026-10-05 the rule was the office's own network only — a misreading of
   "save for Wi-Fi" — and was put right the same day. The transport still reports whether the
   office connection is direct and local, `observedConnectionLocal`; nothing holds a recording
   on it.)
8. **Video never goes through a relay; everything else may.** A relay is somebody else's
   server, lent for small traffic: it sees no content, but a recording is gigabytes. So of a
   recording, the signed manifest, the timeline and the transcript go by any route, as reports,
   receipts and updates do, and the media chunks go only on a connection straight to the office
   (TCP or QUIC, on its network or across the internet). The rule is by what the file is, not by
   size: there is no threshold to tune. It is held in two places. The transport's guard refuses
   a request for `recordings/<bundle>/media/<digest>.chunk` on any connection that is not
   direct — a relay, or a kind it cannot read — before the engine or the disk is touched, and
   counts it (`relayRequestsDenied`). The app offers no further chunk while the route is a
   relay (`SyncEligibility.evaluateMedia`) and says so: "The video is waiting for a direct
   connection to the office. Video is never sent through a relay." What this costs: where the
   office can only ever be reached through a relay — no port open to it from outside — the
   transcript arrives from the technician's home and the video waits until the phone is on the
   office's network. *Requirement on the office:* a bundle whose manifest and transcript have
   arrived and whose media has not is on its way, not failed, for as long as the phone says so.

Still limits rather than decisions: sealing needs the recording's size again in free space;
there is no resume inside a part being blurred; the blur runs on the main thread. Each is a
device check under P4.

## Out of scope

Everything the office does (contract); any video analysis on the phone; sharing or exporting the
recording from the phone; live phone-camera sessions; Gemini Live / OpenAI Realtime turn timing
(v1 timelines cover Direct mode); customer-facing action evidence.

**Solo users without the office app** are not served in v1. A later, optional phase could analyse
on the phone instead: a handful of sampled, blurred frames per candidate span sent to the active
image-capable provider with a forced schema, on a person's yes, under a small budget — using the
same action-event schema, validator and agreement rules as the contract. It needs its own egress
scope, cost ceiling and review surface, and is not designed here.
