# Plan GY — Procedure Drafted from a Narrated Recording

**Status:** 📝 Drafted 2026-10-02 — nothing implemented.
**Track:** Field Assist (B2B). One of three gaps found when Field Assist was compared feature by
feature against industrial remote-assistance products (with [GX](GX-photo-checked-procedure-steps.md)
and [GZ](GZ-expert-annotations.md)).
**Related:** Plan [F](F-field-assist.md) (procedure format), Plan [H](H-custom-vault-import.md)
(validator and importer), Plan [Q](Q-vault-and-skills-library-management.md) (overlay editing; it
explicitly left an in-app procedure editor out), Plan [DA](DA-recording-persistence.md) (recording
filing), Plan [FP](FP-team-learnings.md) (review before anything reaches a technician), Plan
[FO](FO-guided-job-flow-and-job-tab.md) (`record_clip`), Plan [GX](GX-photo-checked-procedure-steps.md)
(checks a draft may propose), Plan [CP](CP-outbound-frame-privacy.md) / W04.1 (privacy chokepoint),
Plan [FX](FX-desktop-office-and-device-sync.md) (the desktop office app, for the richer review later).

---

## Trigger

A service company's best procedures live in its senior technicians' hands. Writing them down as
branching JSON is the step nobody does: the vault guide calls procedures optional and tells a new
customer to skip them. Remote-assist products in this market let an expert record themselves doing
the job and get a draft procedure out of it. Avenkin already records, transcribes, takes stills and
has a procedure format with a validator — what is missing is the path from one to the other, and a
place on the phone to review the result.

## Outcome

- An expert records a **narrated walkthrough** — talking through the job as they do it — on the
  glasses (camera + mic) or imports a video recorded on the phone.
- The app transcribes it with timestamps, splits it into steps, picks a keyframe per step, and a
  language model drafts a procedure **in the existing procedure JSON format**.
- The draft is validated by **the same validator the vault importer uses**. It is stored as a
  draft, outside every vault: **a draft is never live** — `procedure_runner` cannot list or start it.
- A person reviews it on the phone: each step beside its keyframe and the words it came from, with
  edit, reorder, delete, merge/split, and an Approve that writes it into a chosen vault.
- **Safety content is held to its sources.** A safety note in a draft must be something the expert
  said (linked to the transcript span) or a citation of the vault's safety file. Anything else is
  flagged and blocks approval until the reviewer removes it or rewrites it as their own.

## What exists today (verified against main @ build 447)

- **Procedure format.** `Services/FieldAssist/Procedure.swift` (see Plan GX for the field list).
  `Step.init(from:)` is tolerant; the top-level `Procedure` uses the synthesized decoder, so a draft
  must always emit `safety_notes` (possibly empty) or it will not decode.
- **One validator.** `Vault/VaultValidator.validateProcedureGraph(_:)` — entry exists, targets
  resolve, no non-terminal dead end, a terminal is reachable. `validate(directory:)` runs it over a
  pack's `procedures/` before `Vault/VaultImporter.swift` installs.
- **Live loading has no gate.** `FieldAssist/ProcedureLibrary.swift` loads every decodable `.json`
  in the bundle's and the `Documents/Vaults/{id}/` overlay's procedures folder, overlay winning by
  file name, **without** validation. So writing a draft into an overlay `procedures/` folder makes it
  live immediately — drafts must live somewhere else.
- **Overlay writes.** `VaultStore` merges the overlay over the bundle; `VaultExporter` copies an
  overlay `procedures/` dir. Plan Q's `VaultFilesEditorView` edits Markdown only, and Q's "Out of
  scope" says *procedure authoring UI stays out* — there is no procedure editor today.
- **Recording.** `VideoRecordingService` records glasses video **with microphone audio** off
  `OutboundFrameRelay` (filtered as `.recording` when the blur is on) and `RecordingFiler` files it to
  `Documents/Recordings/` and, by default (`Config.recordingSaveToPhotos` = true), to Photos.
  `SessionRecorderController` records **audio only** (meetings) and transcribes afterwards.
  `record_clip` (`NativeTools/RecordClipTool.swift`, `Job/JobClipRecorder.swift`) is **silent and
  length-capped** by design, so it cannot carry narration.
- **Transcription.** `RecordingTranscriber.transcribe(fileURL:)` prefers Deepgram (when a key is set
  and HIPAA mode is off), else on-device SenseVoice in 30 s chunks. **Correction to the brief:** it
  returns a plain `String` — the timings are discarded. Deepgram's `SpeakerTurn` has `start`/`end`;
  the SenseVoice path knows only each 30 s chunk's offset. `MemoryRewindService` uses
  `SFSpeechURLRecognitionRequest`, whose segments carry timestamps.
- **Pixels already held.** `StillImageFiltering.filteredOrUnavailable(_:for:)` is the chokepoint for
  a consumer holding its own image (`dwellCaptureSave`, `jobPhoneEvidence` use it; roster tap
  `heldImage`). `Config.privacyFilterEnabled` defaults **off**.
- **Safety file.** Bundled vaults keep their safety rules in `safety.md`, cited by procedures
  (`server_hot_swap.json`, `leak_check.json`). It is a convention: `VaultManifest` has no field that
  names a safety file.
- **Consent.** There is no recording-consent type or sheet in the app today.
- **Review precedent.** Plan FP (team learnings: capture → review → publish) is drafted, not built;
  this plan does not depend on it but uses the same rule — nothing unreviewed reaches a technician.

## Design

### The pipeline (pure where it can be)

```
recording ──► TimedTranscript ──► WalkthroughSegmenter ──► segments ──► KeyframePicker
                                                              │
                         ProcedureDraftPrompt ◄───────────────┘
                                   │  (ProcedureDraftModel: LLM, or a stub in tests)
                                   ▼
                         ProcedureDraftParser ──► ProcedureDraft (procedure + provenance)
                                   │
              VaultValidator.validateProcedureGraph + GX check validator + DraftSafetyAudit
                                   ▼
                         review on the phone ──► ProcedureDraftDiff ──► Approve → vault overlay
```

- **`TimedTranscript`** — `[Utterance(start, end, text, speaker?)]`. Built by a
  `TimedTranscriptSource` seam: Deepgram turns as-is; Apple Speech segments; SenseVoice chunked at
  10 s for walkthroughs so a step boundary is never off by more than that.
- **`WalkthroughSegmenter`** — deterministic: splits on spoken markers ("first", "next", "step
  three", "now I'm going to", "once that's done", "then"), on silences longer than a threshold, and on
  the explicit voice marker "new step" the recorder offers. Merges fragments under a minimum length;
  never splits inside a sentence. Output: segments with time ranges and their text.
- **`KeyframePicker`** — per segment, the frame nearest a "photo" voice marker if one was said, else
  the sharpest of three candidates (start + 2 s, middle, end − 2 s) by `ImageQualityProbe`'s
  sharpness. One keyframe per step, at most 40 per draft.
- **`ProcedureDraftPrompt`** — the segments (text + times), the target vault's id, the list of its
  files, its safety file's lines, and the procedure JSON contract with one bundled example. The model
  is told: one step per segment unless two are plainly one action; `branches` only where the expert
  said "if … then …"; `safety_note` only quoting the expert or citing a safety-file line by file and
  quote; propose a GX `check` only where the expert read a value or checked a label aloud; every step
  carries `source_segments`. Keyframes go to the model only as optional context (Decision 3).
- **`ProcedureDraftParser`** — tolerant JSON → `Procedure` plus a sidecar `DraftProvenance`
  (per-step segment ids, keyframe ids, per-safety-line source). Forces `safety_notes` present, slug
  ids, unique step ids, `version` `0.1.0`; a parse failure is a "couldn't draft" result, not a crash.
- **`DraftSafetyAudit`** — deterministic, per safety line: `said` (the cited segment's text contains
  the line's key tokens — negation-aware, so "don't lock out" never supports "lock out"), `vault` (the
  cited file exists in the vault and contains the quoted sentence after normalisation), else
  `unsupported`. Also a **hazard prompt**: hazard words in the transcript (isolate, lock out,
  refrigerant, gas, mains, live, pressure, hot) with no safety line on that step → a reviewer
  warning, never an auto-inserted note.
- **Validation** — `VaultValidator.validateProcedureGraph` and Plan GX's `ProcedureCheckValidator`,
  unchanged, plus draft-only rules: no step without a source segment, no `unsupported` safety line at
  approval, at most one `requires_confirmation` terminal.
- **`ProcedureDraftDiff`** — step-level diff (added, removed, moved, text changed, safety changed)
  between the model's draft and the reviewed version, and between the reviewed version and an
  existing procedure with the same id when approval would replace one. Shown before Approve and kept
  in the provenance.

### Capture

Two routes, both ending in the same draft input (an audio track + timed stills):

1. **Import a video** (P2 first): from Files, Photos or `Documents/Recordings/`. Audio track →
   transcript; keyframes extracted with `AVAssetImageGenerator` at the picked times. This covers the
   phone camera, a tripod, and a glasses recording made with `video_recording`.
2. **Live walkthrough on the glasses**: "Record a walkthrough" starts audio through the existing
   capture-audio path and a **stills cadence** — one `filteredStill(for: .toolPhotoCapture, source:
   .cachedFrameOnly)` every 3 s plus one on each "photo" marker — rather than a full video encode
   (cheaper in battery and storage; the draft needs stills, not motion). Spoken markers "new step",
   "photo", "pause", "stop recording" are handled locally. Stills are stored as taken (already
   filtered), so nothing raw is kept.

Every imported keyframe passes `StillImageFiltering.filteredOrUnavailable(_:for: .toolPhotoCapture)`
before it is stored or shown to a model; `nil` drops that frame and says how many were dropped.
Roster entries: `walkthroughStill` (owner `WalkthroughRecorder`, tap `filteredStill`, mechanism
`chokepoint`, scope `.toolPhotoCapture`) and `procedureDraftKeyframe` (owner
`ProcedureDraftKeyframeExtractor`, tap `heldImage`, mechanism `chokepoint`, scope
`.toolPhotoCapture`). Neither writes to Photos.

**Consent.** Before the first recording, a one-time sheet: sound and pictures are recorded, faces
are blurred only if face blur is on, tell the people nearby, and the recording stays on this phone
until deleted. Each walkthrough start shows a one-line reminder; the glasses' capture light is on
throughout. The acknowledgement time is kept in the draft's provenance.

### Storage — drafts are not procedures

`Documents/ProcedureDrafts/{draftId}/` (`draft.json`, `provenance.json`, `transcript.json`,
`keyframes/`, the audio, optionally the source video reference), file protection
`completeUnlessOpen`, excluded from backup, registered in `DataStoreRegistry` and wiped by
`SubjectErasureCoordinator`. Never under `Documents/Vaults/`, so `ProcedureLibrary` cannot see it.
Discarding a draft deletes the folder; approving keeps the folder for 30 days as the audit trail,
then deletes the audio and keyframes and keeps the provenance.

### Review on the phone (minimal by design)

Field Assist settings → Procedures → **Drafts**. A draft screen lists steps; each row shows the
keyframe, title, instruction, any safety line with its source badge (Said / From the safety file /
Needs a source), and a "Play" control that plays that step's audio span. Editing:

- edit title, instruction, expected input and safety text; remove a proposed check;
- reorder, delete, merge with next, split at a sentence;
- branches: edit condition text and retarget from a picker; adding a new branch is out of v1;
- a safety line the reviewer types becomes source `reviewer` with their name — allowed, and visible.

**Approve** requires: validator clean, no `unsupported` safety lines, a target vault whose manifest
declares `procedures_dir`, an approver name, and the diff seen. It writes
`{overlay}/{procedures_dir}/{id}.json` and the procedure is live on the next library refresh. The
approved JSON carries an optional top-level `provenance` (`source: "recording"`, drafted/approved
dates, approver, draft id) — decoded with `decodeIfPresent`, so old builds ignore it.

The richer review — side-by-side video, branch authoring, multi-reviewer sign-off — belongs in the
desktop office app (Plan FX) and needs a draft contract alongside the job and manual contracts in
`Contracts/`. Not this plan.

### Model, modes, cost

- `ProcedureDraftModel` protocol; the production conformer is one forced-schema text call through
  `LLMService` with the active provider. Medical Local Only routes it on-device, which only runs in
  the foreground — drafting is started from the phone screen anyway. HIPAA mode: cloud transcription
  is already off in `RecordingTranscriber`; cloud drafting follows the existing medical routing.
- One draft ≈ one long-context call; the cost lands on the usage tracker like any turn.
- Field-Assist-gated (`FieldAssistEntitlement`). Not agentic: no Agent Mode gate.

## Phases (one PR each)

**P0 — Deterministic core (headless).** `TimedTranscript`, `WalkthroughSegmenter`, `KeyframePicker`
(over timestamps + injected sharpness), `ProcedureDraftPrompt`, `ProcedureDraftParser`,
`DraftProvenance`, `DraftSafetyAudit`, draft validation, `ProcedureDraftDiff`, a `StubDraftModel`.
Tests with fixture transcripts (a furnace no-heat walkthrough, a server hot-swap, a rambling one
with a long silence, one with "if it's bubbling then…"): `WalkthroughSegmenterTests`,
`KeyframePickerTests`, `ProcedureDraftParserTests` (missing `safety_notes`, duplicate ids, junk
JSON), `DraftSafetyAuditTests` (said / vault / unsupported / negation / hazard prompt),
`ProcedureDraftValidationTests` (the same `validateProcedureGraph` issues the importer reports),
`ProcedureDraftDiffTests`, `ProcedureDraftPipelineTests` (fixture → stub model → valid draft).

**P1 — Timed transcription, store, drafting service.** `TimedTranscriptSource` (Deepgram turns,
Apple Speech segments, SenseVoice 10 s chunks) beside `RecordingTranscriber` without changing its
string API; `ProcedureDraftStore` + registry/erasure entries; `ProcedureDraftService` over the model
seam. Tests: `TimedTranscriptSourceTests` (parsed fixtures), `ProcedureDraftStoreTests` (never
under a vault path; protection and backup flags), `ProcedureLibraryTests` (a draft folder is
invisible), `DataStoreRegistryTests`.

**P2 — Capture.** Video import + `ProcedureDraftKeyframeExtractor`; `WalkthroughRecorder` (audio +
stills cadence + voice markers); consent sheet; roster entries. Tests: `KeyframeExtractorTests`
(synthetic MP4 in the simulator; filter `nil` drops the frame), `WalkthroughRecorderTests` (fake
clock, still provider and audio sink), `OutboundFrameConsumerTests`.

**P3 — Review and approve.** Drafts list, draft screen, editing operations as pure mutations on the
draft (`ProcedureDraftEditor`, tested headless), approve writer, `provenance` field on `Procedure`.
Tests: `ProcedureDraftEditorTests`, `ProcedureApprovalTests` (blocked by validator issues, by an
unsupported safety line, by a vault without `procedures_dir`; writes exactly one overlay file;
`procedure_runner list` shows it after refresh), `ProcedureCodingTests` (`provenance` optional,
bundled procedures unchanged).

**P4 — Device checks (owed).** A ten-minute glasses walkthrough in a plant room (battery, heat,
stills cadence, marker recognition in noise); a phone video import; a draft reviewed and approved on
the phone and then run with `procedure_runner`; Deepgram and on-device transcription both.

## Risks

- **Narration quality** drives everything. The recorder's start sheet coaches: say what you are
  about to do, say readings aloud, say "new step".
- **A plausible but wrong draft** approved in a hurry. Mitigations: per-step source playback, the
  diff, the safety audit, and the approver's name on the procedure.
- **Bystanders and customer premises** in keyframes when the blur is off. Drafts stay on the phone,
  never in Photos, and expire.

## Open decisions for Greig

1. **Who may approve?** Recommended: anyone with Field Assist on the device, name recorded (as
   overlay edits are today); an organisation-profile reviewer role later with Plan FP's decision.
2. **Live glasses capture: stills cadence (recommended) or full video** through
   `VideoRecordingService` (heavier, and it files to Photos by default unless a flag is added).
3. **Send keyframes to the drafting model?** Recommended: off by default — text-only drafting keeps
   pictures of the customer's site on the phone; an "include pictures" switch per draft.
4. **Keep per-step provenance in the vault JSON?** Recommended: only the small top-level
   `provenance`; segment spans and keyframes stay in the draft store.
5. **Name the safety file in the manifest** (`safety_file`, default `safety.md` when present)?
   Recommended yes, optional and backward compatible, so the audit is not guessing.
6. **Draft retention** after approval: 30 days for audio and keyframes (recommended), or keep.

## Out of scope

A full in-app procedure editor (branch authoring, new procedures from scratch); drafting from a
live remote-expert session; step images inside procedure JSON; translation of drafts; automatic
publication to other technicians' phones (vault packs and the office app do distribution); the
desktop review surface itself (Plan FX).

---

## Amendment 2026-10-10: a draft from a PDF or pasted text

From the [October 2026 ecosystem review](../ecosystem-review-2026-10.md) (section 4 row "Procedure
draft from PDF or pasted text"). The manuals technicians already carry are the cheapest source of a
first draft, and today this plan drafts only from a recording (`Capture` above).

**Status check.** The Status line above says nothing is implemented. Verified 2026-10-10 against
`main` at `48bcae0c`: `TimedTranscript` and `WalkthroughSegmenter` now exist in
`Services/FieldAssist/JobRecording/`, built under Plan HE's recorded-job core (`5cbeed68`), and
`WalkthroughSegmenter`'s own header says it is this plan's pipeline. GY P0 should adopt them rather
than write its own; the remaining P0 types (`KeyframePicker`, `ProcedureDraftPrompt`,
`ProcedureDraftParser`, `DraftSafetyAudit`, `ProcedureDraftDiff`) are still unbuilt. The Status line
is left as drafted because none of GY's own phases has shipped.

**A third capture route: a document.**

- **Import.** "Draft from a document" accepts a PDF, EPUB, Markdown or text file from Files, or
  pasted text. Files go through the existing `VaultDocumentExtractor.extract(from:)`
  (`Services/Vault/VaultDocumentExtractor.swift`), which already reads PDFs page by page with
  PDFKit, falls back per page to `ScannedPageReader` recognition for scanned pages, and joins pages
  with a form feed, so every step can cite its page. No new PDF or OCR code.
- **`NumberedStepSplitter` (pure).** Finds a numbered procedure in the extracted text: a run of
  lines numbered consecutively from 1 ("1.", "1)", "Step 1"), at least two steps; a line that
  continues the previous step (wrapped text, or a measurement such as "2.5 mm" or "3.2 bar" at a
  line start) is joined, not read as a new number; nested "a)" or "2.1" items stay inside their
  step. Several runs in one document are offered as a list to pick from.
- **Fallback.** When no numbered run is found, the selected section (or the whole pasted text) goes
  to the drafting model once, with `ProcedureDraftPrompt` given document segments (text plus page)
  in place of timed segments, and the same JSON contract.
- **Validation and review are GY's.** The draft passes `VaultValidator.validateProcedureGraph` and
  the draft-only rules, lands in `ProcedureDraftStore`, and is reviewed and approved exactly as a
  recorded draft is. Provenance records the document's file name, its SHA-256 and each step's page.
- **Safety lines.** `DraftSafetyAudit` treats the step's own text in the document as the "said"
  source: a safety note must quote that step's words or cite a safety-file line. A warning printed
  elsewhere in the manual is not attached to a step automatically; the hazard prompt flags it for
  the reviewer instead.
- **Size.** Over the extractor's cap (or above the model's input budget for the fallback) the
  import is refused with the reason, never truncated: a procedure missing its last steps is worse
  than none.
- **Privacy.** A document is text the user chose; no pixels, so no roster entry. Under Medical
  Local Only the model fallback is unavailable and only the deterministic splitter runs.

**Phase.** A new **P1b**, after P1 (it needs the store and the drafting service) and before P2 (it
needs no capture): `NumberedStepSplitter`, the document route into `ProcedureDraftPrompt`, the
import sheet. **Tests:** `NumberedStepSplitterTests` (a manual's numbered list; wrapped lines;
"2.5 mm" continuation; nested items; a list starting at 3 rejected; two runs offered; a single
item rejected), a document-route `ProcedureDraftPipelineTests` case (fixture PDF text to a valid
draft with page provenance), and an oversize refusal test.
