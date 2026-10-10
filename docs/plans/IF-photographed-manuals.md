# Plan IF — Photographed Manuals (the binder on the bench becomes a manual the phone can read)

**Status:** 📝 Drafted 2026-10-10 — nothing implemented. A technician at an older unit photographs
the pages of the paper manual that came with it; the phone recognises the text on each page on
device, makes the pages answerable in the same job, attaches them to the job in text and image
form, and sends them to Avenkin Office, where the organisation decides whether they join the pool
of manuals every technician gets. The pool itself, and the review that gates it, live in the office
(private plan, proposed FX23); the phone never publishes to the pool directly.
**Reviewed:** 2026-10-11 against worktree `if-photographed-manuals`, `7410e1c6` (build 494).
The design and acceptance gates below incorporate the review; nothing is implemented. This is
the photographed-manual draft formerly headed HW. Plan HW remains glasses stream integrity.
**Track:** Field Assist (B2B).
**Related:** Plan [EF](EF-scanned-manual-import.md) (per-page recognition, confidence counts, the
"recognised from a scan" provenance line, the Mac extractor's "Page N" Markdown), Plan
[FP](FP-team-learnings.md) (the sibling-namespace pattern, the `DeliveryRequest` payload seam,
redaction at capture, review at base), Plan [HO](HO-office-delivery-phone-half.md) (reports and
outbound signed `records` evidence and inbound `bulk`), Plan [FX](FX-desktop-office-and-device-sync.md)
(manual assignment office → phone), Plan [EG](EG-vault-packs.md) (the redistribution question, now
answered for this case), Plan [H](H-custom-vault-import.md) (the importer and Custom Vaults),
Plan [T](T-offline-field-queue-and-sync.md) (the queue), Plan [EM](EM-work-record-and-parts.md) (the work
record), Plan [FO](FO-guided-job-flow-and-job-tab.md) (job media), Plan [CT](CT-org-configuration-profiles.md) (an
organisation can pin the feature off).
**Origin:** Owner's idea, 2026-10-10. Technicians who look after older equipment are handed a
paper manual, or find one in a plastic sleeve taped inside the cabinet, and there is no PDF of it
anywhere. Plan EF made scanned PDFs first-class; this plan makes the paper itself first-class, in
the field, with nothing but the phone. Today the manual pool and its import pipeline exist only in
Avenkin Office; the phone has a one-shot `scan_document` tool that returns text to the
conversation and keeps nothing.
**Priority:** P2 for the Field Assist commercial track. Reuses FP's shipped capture/retrieval
patterns and HO's opt-in signed report/evidence route; the capture wire extension is contract-first.
**Surfaces:** Phone capture and retrieval, the job record and its delivery, one new contract and
explicit extensions to the report and vault provenance contracts.
Office intake is the private plan. No glasses capture: a page is photographed with the phone.

---

## Decisions recorded

- **Copyright is the organisation's decision (owner, 2026-10-10).** A photographed OEM manual is
  the organisation's data, captured by its technician on its job; whether it may be kept and
  shared across the crew is for the organisation to decide, not the app. The app's part is to make
  the decision explicit and attributable: nothing reaches the pool without a named reviewer in the
  office approving it, the approval is recorded with the manual, and an organisation profile can
  pin the whole feature off. Plan EG's redistribution question stays as it is for *vendor* packs;
  this plan does not change it.
- **Later use on this phone is keyed by model token (2026-10-10).** A serial-level key would hide
  the book from the identical unit in the next plant room, which is where a photographed manual
  is most useful. The serial is recorded in the manifest for the office, not used as the key; a
  wrong revision answering for a sibling unit is covered by the citation naming the book and by
  the office's reviewed copy superseding the local one.
- **A capture may leave for the office before the job report (2026-10-10).** The office needs the
  job to *review*, not to *receive*: intake shows the capture as awaiting its job until the report
  lands, then beside it. Waiting would hold a forty-page bundle behind a report finished an hour
  later on a channel that may have changed.
- **Everyone may photograph on a `jobOnly` organisation (2026-10-10).** Capture is the technician's
  own benefit on that job; withholding it from some people only produces a phone photo with no
  recognition. The pool route is what the organisation controls, and the profile key already hides
  it. Per-technician allowances, if ever wanted, belong to the pool decision in the office.
- **Recognition language is the device language plus English (2026-10-10)** until the vault
  manifest carries a language field (EF's open question), at which point the capture inherits the
  active vault's languages and still appends English. Implementation must resolve these to the
  Vision request's supported language identifiers, deduplicate them, and disclose unsupported
  preferences. Device language is a preference, not a guarantee about a manual's language.
- **The profile key's default follows the licence (2026-10-10):** `reviewToPool` for team and
  enterprise, `jobOnly` for solo. A solo subscriber has no office reviewer, so the pool route
  cannot complete, and the key says so rather than queueing something that never leaves.

## Product promise

"Photograph the pages. Ask about them straight away. They go with the job, and if the office
says so, every technician gets them next time."

## Verified starting point (build 494, reviewed 2026-10-11)

- **Recognition is on device and page-shaped already.** `ScannedPageReader` (one method: page
  image in, `ScannedPageText` with text and mean confidence out) has a Vision-backed production
  reader over `OCRService` and a table-driven fake for tests. `VaultDocumentExtractor.Extracted`
  carries `ocrPages` / `lowConfidencePages`, and `VaultRetriever` already attaches the
  "text recognised from a scan; verify figures against the printed page" note to passages from
  recognised pages (`Passage.recognisedFromScan` / `provenanceNote`).
- **"Page N" Markdown is already a manual format.** Plan EF's Mac extractor writes Markdown with
  `Page N` markers. The existing parser also recognises printed footer/header numbers and can
  collapse adjacent empty pages; it is not sufficient for authoritative capture-order numbering.
  `DocumentStore.ingest(name:…)`, `query(… namespace:)`, and `forget(documentId:inNamespace:)`
  exist. IF adds explicit page-aware ingestion rather than assuming an export's markers suffice.
- **The sibling-namespace pattern and shared factory are built.** FP's
  `FieldSessionService.retrievalNamespaces`, `makeRetriever` and `retrievableCorpus` serve the
  per-turn prompt, `manual_lookup` and equipment lookup. IF extends this one factory, its corpus
  gates, title filters, availability checks and evidence-source rules; a fourth retriever is not
  needed. FP's learning-only disclosure must remain reserved for team learnings.
- **The delivery seam is open.** `DeliveryRequest.Payload` has `workRecord` and `learningBundle`; the composer
  and both unattended-route enqueues read only the envelope and `payload.queuedOp()`.
  `Attachment.Kind` has `pdf`, `json`, `video`, `transcriptPDF`, each with a MIME type and UTI.
  `AttachmentBudget` decides per channel what fits (email, Messages, share sheet, endpoint,
  WhatsApp, Telegram) before the composer opens. `QueuedOp.OpKind` is where a new durable op goes.
- **Outbound report evidence is built in the opt-in office transport build.**
  `OfficeReportService`, `OfficeReportSink` and `OfficeReportEvidenceStore` publish signed reports
  and exact attachment bytes under `records`, and advance delivery on signed office receipts
  ([office report contract](../../Contracts/office-reports.md)). Their closed kinds, roles and
  media types do not yet accept a captured-manual operation or Markdown. IF must extend both
  Swift and Go validators and queue dispatch. Physical phone/office validation remains owed.
- **`bulk` is office → phone only.** HO P4's manual/job attachment downloads are built, but
  [office folders](../../Contracts/office-folders.md) and
  [office bulk](../../Contracts/office-bulk.md) prohibit the phone serving that folder. IF v1
  uses outbound `records/attachments/<sha256>`; it does not invent a reverse `bulk` direction.
- **VisionKit is already linked.** `VaultLinkViews` uses `DataScannerViewController` for vault
  links, so `VNDocumentCameraViewController` (edge detection, perspective correction, glare
  retake, multi-page in one sheet) costs no new dependency and no new Info.plist key beyond the
  camera string that is already there.
- **Job media exists.** `JobMediaItem` (photo, clip; sources `photoLog`, `photoLibrary`,
  `clipRecord`) is how a job carries pictures today, with `ClipDeliveryPlan` deciding what
  travels. A photographed page is *not* a job photo: it is a document, and it is retrievable.
- **Gates exist.** `FieldAssistCapability` (`bundledVaults`, `ownVaults`, `auditedExport`,
  `orgConfiguration`, `everyVaultPack`, `teamLearnings`) is checked in the service layer; `Config.hipaaDisabledTools`
  withholds tools on a clinical site; `SecretPatterns.redact` is FP's floor at capture;
  `SensitiveStore` registration and the erasure walk are inventoried in FP P0.
- **Equipment identity is in force during a job.** `EquipmentIdentity` (recognised model, stated
  model, `vaultMatch`, `recognisedAt`) is what a captured manual binds to. `unitKey` preserves
  the stated model; `modelToken` can instead name a near-matching vault section. Serial lives on
  the session's `VisitedUnit`, not on `EquipmentIdentity`.
- **Page viewing and office import need extensions.** Citation resolution and the manual-page
  sheet currently find vault ledger/baseline files and label PDFs as the manufacturer's document.
  `OfficeManualAssignment` identifies an archive, not a source capture. Plain Markdown import
  does not retain OCR provenance. None of these provides photographed-page lookup or safe
  supersession without the additional source metadata below.

## Design

### 1 · Capture: the phone camera, in a sheet, by voice or by tap

A technician says *"photograph the manual"* (or taps **Photograph a manual** on the job) and the
phone opens VisionKit's document camera. The sheet handles edge detection, perspective
correction, the glare retake and page order; the technician photographs the pages they need —
the whole book or the wiring section — and taps Save. Pages come back dewarped at camera
resolution; the app downscales to a long edge of about 2,200 px (Plan EF's 200 dpi equivalent for
a letter page) before recognition and storage, so a page is a few hundred kilobytes, not several
megabytes.

Not the glasses. The glasses' still is uncorrected, low-resolution for small type, and framed by
the head; a page wants the phone held over it. Hands-free comes from the voice entry and the
read-back, not from the capture.

A `manual_capture` native tool (`start` / `status` / `list` / `discard`) stages a
`ManualCaptureRequest` on the session the way a job report is staged: the tool publishes it, the
app root subscribes and opens the sheet. Nothing is captured by the tool itself. It self-gates on
`Config.fieldAssistActive` like its siblings, joins `Config.hipaaDisabledTools`, and the
entitlement is checked in the service layer where `VaultImporter` and `SessionExporter` check
theirs: `FieldAssistCapability.ownVaults` to capture/use locally, and a dedicated
`capturedManualReview` capability for a pool-review submission. The latter follows the existing
team/enterprise organisation-evidence mapping; callers do not compare licence tiers directly.

Before presenting the sheet, freeze the capture id, original session id, job reference, office
job id/revision when present, active unit id, equipment and serial snapshot, title and ownership
scope in the request. A callback never reads whichever job happens to be active later. Only one
capture sheet may be pending; duplicate starts return its status. Cancel, camera denial,
unsupported document camera and scanner error each settle the request with an honest result.
A job switch or session end cancels a sheet that has not saved. A saved capture can finish
recognition against its original job; deletion of that job cancels and erases its unfinished
capture. Equipment correction during capture does not silently relabel the book.

HIPAA and `capturedManualsPolicy: off` gate tap, tool and direct service calls, recovery,
retrieval and delivery, not just tool registration. Check again before presentation, committing
a result and executing a queued send. `off` suppresses existing captured namespaces without
silently deleting the saved record; forgetting remains available. `jobOnly` permits capture and
ordinary job evidence, but never requests pool review. Capture-time policy and pool intent are
persisted, and a later policy may only narrow what a pending operation may send.
Narrowing suspends/withdraws a pending pool operation, or creates a new immutable manifest and
operation for permitted job-only evidence; it never rewrites a published intent or digest.

Before the sheet opens, a dedupe hint: if the equipment identity in force already matches a vault
manual, the tool says so (*"the SLP99 service manual is already in your vault — photograph
anyway?"*). It never refuses; the printed book may be the revision that matches the unit.

### 2 · Recognise: per page, on device, counted

Each saved page goes through the injected `ScannedPageReader` with the device language plus
English as the recogniser's languages (the active vault's languages, plus English, once the
manifest carries them). Extend the reader/configuration seam explicitly: today it accepts only
an image and `OCRService` enables automatic language detection. Resolve supported language
identifiers, preserve preference order, deduplicate English and record the actual list used;
retain a documented automatic-detection fallback for unsupported preferences. See Apple's
[recognition languages](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/recognitionlanguages)
and [supported languages](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/supportedrecognitionlanguages())
APIs. No language change is imposed on unrelated callers of `OCRService`.

Persist the ordered, downscaled page images before recognition, under protected staging owned
by `CapturedManualStore`; release full-resolution images page by page. Recognition, image
conversion, PDF writing and hashing run off the main actor; UI progress returns to `@MainActor`.
Yield and check cancellation between pages, reuse `ScanRenderPolicy` under thermal pressure,
and enforce injected limits on page count, pixels, total stored bytes and free-space reserve.
Do not keep a second book's worth of decoded bitmaps in memory. P3 measures and fixes the
shipping limits on the oldest supported phone; exceeding a limit produces a recoverable result,
not a half-published manual.

Checkpoint each recognised page by capture id **and ordered image digests/settings**, using
EF's `OCRCheckpoint` shape but redacting before persistence. The checkpoint holds only redacted
text, confidence, printed-page metadata and redaction pattern names/counts, never matched secret
values. Source images and checkpoints survive a phone call, lock or process restart; recovery
never depends on the in-memory VisionKit scan. A changed/reordered page invalidates its
checkpoint. Staging is protected and excluded from backup; cancelled captures are removed.
Final bundles and local linkage/journals use the same store protection and backup policy.
Low-confidence pages are kept and counted, exactly as EF does. Page numbers are **capture order**, not the
printed page number: the technician photographed pages 40–52, and the citation says "page 3 of 13
photographed" plus the printed number when recognition finds one at the top or bottom of the page
(a small pure `PrintedPageNumberFinder` over the first and last text lines; `nil` when unsure,
never a guess).

`SecretPatterns.redact` runs before any recognised text is written to a checkpoint, export or
index. The page image is not altered. The sheet says the standing rule once ("photograph
the manual, not the service log or the customer's paperwork"), and review in the office is where
a page that should not have been photographed is actually caught.

### 3 · One bundle, no new document format

A capture owns immutable revision folders,
`Documents/CapturedManuals/<captureId>/<captureRevision>/`, each containing:

- `text.md` — the recognised text with `Page N` markers, the form Plan EF's Mac extractor emits
  for a readable/exportable artefact;
- `pages.pdf` — the page images, one per page, in capture order, images only (a text layer in the
  PDF is a later nicety, not a requirement, because `text.md` *is* the text layer);
- `manifest.json` — `CapturedManualManifest`: schema version, capture id, positive source
  `captureRevision`, `sessionId`, `jobReference`, the
  office job id/revision when present, vault id and ownership scope (organisation/enrolment, or
  personal), active unit id, safe equipment snapshot and `VisitedUnit` serial, title (spoken,
  or the confirmed model), page count, `ocrPages`, `lowConfidencePages`, per-page confidence and
  printed-page numbers, actual recognition languages, author display name, `capturedAt`,
  redaction pattern names/counts, effective capture policy and explicit pool-review intent.
  A bounded per-page map records each capture index and its redacted body's UTF-8 byte range in
  exact `text.md` bytes, excluding generated `Page N` furniture. Ranges are ordered,
  nonoverlapping, within bounds and on UTF-8 character boundaries; empty pages have zero-length
  ranges, and the map's indices/count agree with `pageCount` and PDF pages. Both files have
  SHA-256 digests and byte counts.

The equipment snapshot is an allow-list, not a serialization of raw `nameplateText`. Serial is
explicit metadata for the office, never prompt text or a retrieval key. Redact human-entered
metadata where appropriate before persistence; a manifest's redaction report names patterns,
not what they matched.

The contract fixes the manifest's canonical bytes. The **bundle digest** is the SHA-256 of those
bytes, binding metadata, page mapping and both file digests without a self-referential hash
field. The text digest is only a similarity/dedupe hint: two different wiring diagrams may have
identical OCR text. Intake checks both files' sizes/digests and page-map bounds before accepting
a complete bundle. A queued/published revision holds immutable bytes; a retake is a new revision,
never a file rewritten under an existing digest.
Persist current-revision selection locally. A committed retake retracts the prior revision
from live retrieval but retains its immutable files and document/page mapping for historical
citations. Capture revision describes source bytes; office-report delivery revision describes
a send/resend and is a separate counter.

Pin image/PDF encoder settings and metadata to the capture revision (including timestamps from
`capturedAt`); reuse persisted PDF bytes on recovery. Restarting recognition cannot change the
image bundle or its digest merely because the clock or default encoder settings changed.

Index through a small page-aware `DocumentStore`/chunker seam using the assembler's ordered
page text and explicit capture indices, recoverable from the manifest's byte ranges. Printed
`Page 41`/`— 41 —` OCR lines cannot become structural markers. Empty/failed pages produce no
evidence chunks but keep their physical indices. Flush chunks and clear overlap at every capture
page boundary, including at production chunk sizes; a short second page must not be cited as
page 1. The export stays Markdown, but indexing no longer guesses pagination from its body.

`CapturedManualStore` owns the folder, is registered in `SensitiveStore`, and is walked by
subject erasure. It is never the vault overlay and never a pack: a pack update, a vault re-import
and an FN manual removal leave it alone.

Persist the capture/revision/digest ↔ ingested document id ↔ originating job ↔ queued/report operation linkage
in local store metadata; queue entries naming only a digest cannot be found by a text search.
Discard/forget/subject erasure first tombstone the capture and cancel/join its assembler, then
retract its namespace and invalidate page/citation caches, revoke staged exports, cancel unsent
operations and withdraw published local evidence where supported, and remove source/staging
files. A late callback cannot recreate the folder or index. Cover document id, original
conversation/job and searchable person text/metadata; images with no indexed subject cannot
be claimed erased by a name search alone. Office copies require an explicit withdrawal/erasure
contract or an unsupported/remote-pending receipt; deleting mailbox files is not remote erasure.

Organisation departure is separate from vault removal: suppress that scope's retrieval
immediately, cancel capture UI/work, include standalone capture reports in outstanding counts
by their originating session, then erase captures/indexes/queue/evidence under the existing
departure settlement rules. Bytes still owed may be retained only for the old authorised
delivery, and cannot answer a later employer's job. Personal captures use their own scope.

### 4 · Use it now: a sibling namespace, with provenance that cannot be lost

On save, `text.md` is ingested into `DocumentStore` under
`"captured:<captureId>:<captureRevision>"`, one document per sealed revision,
name `"Photographed manual · <confirmed model or title> · <date>"`, through the explicit page
map above. The shared retriever factory merges **eligible** capture namespaces with the vault's
and FP's learning namespace, and the passage carries
`source: .capturedManual` beside FP's `.manual | .teamLearning`. Two things are said every time
such a passage is used, and the prompt rules hold the model to them:

- EF's recognised-from-scan note — figures want checking against the page; and
- that it is a locally photographed, unreviewed manual, with its **original** job/date, so a
  technician reading a torque value back knows which book it came from. A later job never claims
  the book was photographed there.

The citation renders the document name and the capture-order page, with the printed page number
when one was found. The HUD line and the work record say the same.

Extend `retrievableCorpus`, `manual_lookup`'s initial gate and title/document filters,
equipment-scope coverage, and all three factory routes. A job with no vault manuals but an
eligible capture must still retrieve it, including for an out-of-vault model. A title-filtered
query keeps only the named eligible documents, rather than dropping every non-`.manual` source.
Eligibility is enforced before semantic and exact-token queries and checked again just before
publishing a passage; another model's capture is excluded, not merely down-ranked.

Update the evidence policy and bounded-prompt policy explicitly: `.manual` and
`.capturedManual` are reference documents; approved `.teamLearning` alone retains its existing
learning-only outcome. A captured-only result can pass the usual measured evidence gate with
both disclosures, and can never be relabelled as a crew finding. Only the current, eligible,
unsuperseded revision's namespace is searched. OCR provenance includes
captured references in both prompt and tool-result rendering. `AnswerEvidence`, HUD/badge and
work-record rendering preserve the source even when the prompt budget keeps only a capture.

**Scope of use.** The capture answers in the session it was made in, and in any later session on
this phone whose confirmed model identity matches, within the same ownership/vault scope
(decided model-level reuse; serial is recorded, not keyed on). Use the normalised stated model
(`EquipmentIdentity.unitKey`), or an explicitly confirmed exact alias. A near/partial vault
match does not silently replace the stated model: `modelToken` can already name the wrong
section in that case. Without a confirmed model, the capture stays on its originating
session/unit and does not enter later-job lookup. Switching unit within a multi-unit job also
recomputes eligibility. The directory's global capture id does not grant cross-scope access.

The office's reviewed copy supersedes a local capture only after its signed archive is
verified, installed and indexed to Ready, and authenticated per-document metadata explicitly
names that capture id **and bundle digest**. A title/model/text-digest match or receipt of an
assignment is not enough. Retakes and office merges list the exact originating revisions they
replace; failed imports and unrelated books retract nothing. Supersession is idempotent and
persists its source-revision/lineage state before retracting the local namespace, so restart or
reindex cannot recreate it from a retained folder. The folder, job record and historical
citations stay.
A technician can also forget a capture from Custom Vaults › Photographed manuals.

Add citation identity bound to capture id, source revision/bundle digest and capture-order page,
and capture-aware resolution to the existing figure/page flow:
resolve through the saved capture/document mapping to `CapturedManualStore.pages.pdf`, not
through the vault baseline. The sheet says **Photographed manual · page N of M photographed**,
with a detected printed number as supplementary metadata, and checks the saved PDF digest.
It never labels this PDF "Manufacturer's document". Historical citations can still open the
retained photographed page after supersession; forget/erasure returns an unavailable result.

### 5 · Attach to the job

The work record gains a line — *Manual photographed: SLP99UH090XV60CK, 13 pages (2 low
confidence)* — with its actual standing appended: local, queued, evidence pending, or office
accepted. Capture completion never says "sent to the office". The delivery decision distinguishes
job evidence from a submission for pool review:

- two new `Attachment.Kind`s, `capturedManualPDF` and `capturedManualText`, so the confirmation,
  the audit line and a test can tell them from the work order;
- a pure manual attachment partition extends `AttachmentBudget`, using measured file sizes and
  space already reserved for the work order, JSON, transcript and other evidence. Email carries
  both when they fit, text only when the PDF does not, or neither when neither fits. Messages
  offers text only when attachments are supported and the text fits. WhatsApp, Telegram and
  the generic HTTP endpoint currently carry no files; the body names what stayed behind. A share
  offer provides the omitted files without claiming they were sent. Office records use their
  own validated limits/receipt policy. The partition is decided before presentation and drives
  the composer, audit and work-record wording consistently;
- captures are office-audience evidence by default. A customer-facing report does not include
  the images, recognised text, serial or internal manifest automatically; a separate deliberate
  sharing choice can supply the manual files. Channel attachment support is not audience consent;
- The job report is the usual vehicle. A capture also leaves on its own before the job ends
  (decided) — a new `QueuedOp.OpKind.capturedManual`, like a parts request — so a forty-page book
  can travel while the job continues. Give it a real `DeliveryRequest.Payload` and durable
  manifest/file references, not just an enum case. The standalone send is for a configured,
  authorised office and retains the original job linkage. Without that destination it stays
  local/awaiting configuration; it does not fall through to an unrelated endpoint or a local
  sink that returns `.done`. The office's intake holds it as awaiting its job until the report
  arrives.

On the office route, reuse the signed report/evidence protocol in **`records`**. A standalone
`capturedManual` record uses the capture id as its stable record id and the manifest as record
bytes; PDF and text are required evidence for a whole capture. The signed envelope binds its
operation/revision, organisation/enrolment and original office job id/revision where known.
Its delivery revision is distinct from the manifest's source `captureRevision`; retries of the
same operation reuse its signed bytes, while a new send obtains a new delivery revision.
`OfficeReport.RecordKind`, attachment roles, Markdown media type, Swift/Go validators,
`OfficeReportSink` dispatch and outstanding-record accounting all gain explicit support.
Older peers reject unknown kinds; availability of this extension must be negotiated or kept
behind the opt-in route until a compatible peer is selected. Unknown capture operations wait
or fail explicitly, never become locally delivered.

Freeze exact evidence bytes in `OfficeReportEvidenceStore` (or shared immutable references)
until the matching signed receipt accounts for every required file. Missing files cannot be
regenerated from new OCR/settings under a published digest. Retry is idempotent. The capture's
standing advances from the signed receipt, not transport completion. A job report references
the capture id, bundle digest and known delivery standing; a separately queued book does not
become required report evidence or prevent acceptance of the ordinary job report. References
and attachments are reconciled by capture identity, so an early send and later report are not
two intake items. A deliberate attachment send can reuse the same content-addressed bytes.

Write `Contracts/captured-manual.md` **before the durable sender**, with canonical manifest
bytes, file bounds/digests, ownership, page map, job correlation, policy/pool intent, revisions,
retry/receipt semantics and golden fixtures. Extend `Contracts/office-reports.md` and its Swift
and Go portable checks in the same contract phase. The contract asserts requirements on the
office, never an office implementation that has not been built. Independent pausing of large
outbound content would require another transport design; inbound `bulk` supplies no such seam.

### 6 · The office promotes; the phone never does

Office side, private plan **FX23 — Photographed manuals: intake, review and the pool** (proposed;
numbered after FX22):

- an intake queue of captured manuals arriving with jobs, each with technician, job, model,
  page thumbnails, recognised text, confidence counts and the redaction hits;
- idempotent intake by capture id/revision and bundle digest. Model identity plus text digest is
  only a review hint for "same book, better pages?"; identical labels or empty OCR never discard
  different page images. A merge records all originating capture ids/digests;
- a review that a named office user completes — **approve into the pool**, **keep with the job
  only**, or **discard** — recorded on the manual with who and when; a per-organisation setting
  (and the CT profile key `capturedManualsPolicy`: `off` / `jobOnly` / `reviewToPool`, defaulting
  to `reviewToPool` on team and enterprise licences and `jobOnly` on solo) above it. On `jobOnly`
  every technician may still photograph. Ordinary job delivery carries `poolIntent: jobOnly`;
  the office must not treat it as a pool submission. A `reviewToPool` submission needs
  the dedicated capability and an explicit review intent. Current policy is checked again on
  both sides; a capture-time permission never overrides a later restriction;
- on approval the manual becomes a vault document in the organisation's vault (source type
  `vault_document_ocr`, provenance "photographed by <technician> at job <ref> on <date>; approved
  by <reviewer>") and reaches every phone by manual assignment. Extend the signed vault archive's
  per-document metadata with captured origin ids/bundle digests, OCR counts/provenance, capture
  and printed page mapping, and approval identity/time. The importer, ledger and retriever must
  preserve that metadata: merely importing `text.md` currently produces a non-OCR document and
  loses the scan warning. An older archive remains valid without the new optional metadata;
  it cannot claim capture supersession. The capturing phone supersedes only at Ready (§4), and
  a second phone retains the office attribution and recognised-from-scan warning.

Nothing in this plan builds the office half; it names the contract the office will read.

### 7 · Honest limits

- Recognition is text only. A wiring diagram's labels are recognised; the diagram is a picture in
  `pages.pdf` the office can look at and a phone can show through the capture-aware page sheet,
  not something the model understands.
- Handwriting, stamps and pencil annotations are mostly noise and are counted as low confidence.
- A page the technician should not have photographed is caught by the standing rule and by
  review, not by the app.
- The dedupe hint is by model token; a different revision of the same book is still worth
  photographing, and the hint says so.

## Build order (one PR each)

- **P0 — contracts and lifecycle inventory, headless.** `Contracts/captured-manual.md`, golden
  fixtures and portable checks; explicit proposed extensions to office-report kinds/roles/media
  types and signed vault document provenance. Fix canonical bytes, file bounds, page mapping,
  original job/unit/ownership, policy intent, receipts, supersession lineage and peer
  compatibility before building queue producers. Inventory erasure, departure, page lookup and
  all retrieval gates against build 494. This phase defines interfaces; no phone sender or
  office implementation is claimed.
- **P1 — durable capture core, headless.** Manifest/store/assembler, ordered image staging,
  protected/no-backup checkpointing, injectable languages/limits/thermal policy, redaction before
  persistence, printed-number finder, byte-stable `text.md`/PDF, page map and bundle digests.
  Add capture/document/job linkage, tombstone/cancellation and SensitiveStore/subject/departure
  erasure seams. Test interrupted recovery, filesystem failures and late callbacks. Nothing is
  indexed or queued until a complete validated revision commits atomically.
- **P2 — retrieval, evidence and page core, headless.** Explicit page-aware ingest/retract,
  eligible namespaces in the existing FP factory, captured-only corpus/title/equipment gates,
  reference-evidence classification, both provenance notes, source-aware HUD/work-record
  evidence, capture citation/page models, and the pure supersession state machine. Add capability
  and HIPAA/profile checks across services. Production-default pagination and captured-only
  retrieval tests are gates, not just a happy-path fixture.
- **P3 — phone capture and local-use surfaces.** Frozen single-flight request, VisionKit sheet,
  `manual_capture`, job action, progress/recovery, photographed-page routing and Custom Vaults
  list/view/forget. Check a real binder on the oldest supported phone: glare, forty pages,
  cancellation/lock/relaunch, memory/thermal behaviour and time to answerable; set shipping
  limits and record results in the vault guide. This phase delivers local use, without claiming
  the office can receive a capture.
- **P4 — delivery through signed records.** The new payload/op, measured attachment partition,
  audience separation, immutable queue/evidence storage, `OfficeReportSink` interception and
  compatible Swift/Go report validators, signed receipts, original-job correlation and departure
  outstanding counts. Queue paths never fall through to local success. Validate an early capture
  and later ordinary job report with the opt-in office test peer. Pool-review submission remains
  disabled until the provenance round trip in P5 is supported; `jobOnly` evidence can still travel.
- **P5 — reviewed-copy import, supersession and pilot.** Preserve signed per-document origin,
  OCR/page metadata and approval attribution through archive installation/indexing; activate
  the P2 supersession state machine only on Ready. Verify a pilot crew: one technician
  photographs, the office approves, and a second phone answers with the scan warning and office
  provenance. The office intake/review/pool is FX23 in the private repository; until that peer
  exists, record the owed pass and keep the pool route unavailable.

## Tests

- Assembler over a fake reader: three pages → three `Page N` sections in capture order; a
  low-confidence page kept and counted; a reader failure on one page yields an empty page and a
  count, never an abort. Interruption after page 2 and process restart resume from persisted
  images/redacted checkpoint to byte-identical text, PDF and manifest for the same sealed
  revision. Changed/reordered pages invalidate the right checkpoint; write/disk-full failures
  leave no index or sendable bundle. Limits, cancellation and thermal steps are deterministic.
- `PrintedPageNumberFinder`: "— 41 —", "Page 41", "41" alone at the foot → 41; a part number or a
  year in the footer → `nil`.
- Chunking and citation at production defaults: two short pages never share a chunk; empty
  first/middle pages retain later indices; OCR footers `Page 41`/`— 41 —` cannot reset capture
  numbering; overlap never crosses a page. Citation head and original-job/date disclosure are
  exact, with/without a printed number and on a later job. Page-map recovery reproduces indices.
- Retrieval through per-turn, manual and equipment routes: a captured-only corpus works with no
  imported vault manual, including an out-of-vault model and a title filter. Captured-only and
  capture-plus-learning results retain document evidence and both notes after prompt bounding;
  learning-only remains learning-only. Ordinary vault provenance stays as before.
- Identity/scoping: another model or organisation cannot query the namespace; a near/partial
  match cannot turn a stated model into the vault's sibling model. Confirmed exact aliases work;
  another unit of the same confirmed model can reuse it within scope, while unbound captures
  stay session/unit-local. Serial/nameplate text never enters retrieval prompts.
- Pages: voice/tap opens the cited capture PDF at the same physical page with a photographed
  label and digest check; retained citations work after supersession; forgotten files return
  unavailable. A retake cannot change an old citation's PDF or page. A failed/empty OCR page is
  still viewable without fabricated text evidence.
- Redaction: final text, persisted checkpoints and human-entered metadata are redacted; reports
  contain pattern names/counts only, never matched secrets. Normalised image bytes are unchanged
  by redaction and match the digests that bind the PDF.
- Delivery: MIME/UTI and payload/queue round trip; both/text-only/neither email partitions with
  reserved report bytes; oversized text/no Messages attachments; no files on unsupported
  channels; omitted files are named truthfully. Customer reports omit internal captures by
  default. Missing evidence, unavailable/old office peer and unknown op dispatch never mark a
  capture delivered. The signed matching receipt alone advances its office standing.
- Early delivery: retry/restart freezes bytes and revision; receipt for another capture/revision
  is refused. Capture arrives before its job, later report correlates to that same capture, and
  pending large files do not block ordinary job acceptance. Duplicated references do not create
  duplicated intake. `jobOnly` evidence is never silently promoted to a pool submission.
- Gates: HIPAA/off withhold tool, tap, direct-service capture, recovered work, namespaces and
  queued sends. Local `ownVaults` alone grants no pool submission; the dedicated capability
  resolves from live evidence and the policy default follows the decided licence mapping.
  On `jobOnly` capture and ordinary job evidence work with `poolIntent: jobOnly`; policy narrowing
  while queued prevents a formerly permitted pool send. An incompatible peer keeps it pending.
- Languages: preferred device language plus English, supported-ID mapping, no duplicate English,
  unsupported preference fallback and production adapter propagation. Future vault languages
  precede English without changing unrelated OCR callers.
- Stores/lifecycle: registry and erasure walk cover final/staging/index/export/queue copies.
  Document-id and original-thread erasure find linked captures; person matching examines text
  and metadata instead of only the queue JSON. Erasure while assembly yields cannot resurrect
  anything; remote copies get an honest unsupported/pending receipt. Departure suppresses
  lookup, counts capture reports through their original sessions, and erases them under its
  settlement rules; a later organisation cannot inherit them.
- Request lifecycle: duplicate start, cancel/error/unsupported camera, job switch, session end,
  equipment correction and job deletion while the sheet/OCR is active cannot attach pages to
  the new job or leave a stuck request.
- Contract: golden manifests and Swift/Go checks agree on exact bytes and bounds; altered PDF,
  text, metadata, overlapping/misaligned page offsets or inconsistent counts are refused.
  Same OCR text with different diagram images
  has different bundle identity and is not auto-deduplicated.
- Approved round trip: signed archive metadata retains OCR warning, approval attribution and
  page mapping on a second phone. Only an exact origin id/digest supersedes the capture after
  Ready; replay is idempotent, unrelated books/failed indexing retract nothing, and re-import
  cannot resurrect a forgotten or superseded capture revision, including after process restart.

## Non-goals

- Glasses capture of pages. Diagram understanding. Handwriting.
- Cloud recognition — on device or it does not ship; the pages are the customer's property.
- In-app correction of recognised text beyond retaking the page. The office fixes a bad page by
  asking for a better photograph.
- Automatic publication to the pool. Review is the point.
- A searchable-PDF text layer. `text.md` is the text; a PDF text layer can be added at the office
  when it publishes, if a customer wants one.

## Open questions

The owner decisions from 2026-10-10 remain recorded above. The 2026-10-11 review adds the
implementation constraints and acceptance gates, rather than reopening model-level reuse,
early send, `jobOnly` capture or preferred recognition languages. No new owner decision blocks
P0. Shipping page/storage limits and the opt-in physical/office passes are measured release
gates, and the private office review/pool is an external dependency, not implemented here.
