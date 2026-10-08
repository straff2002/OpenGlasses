# Plan HT — External Job References (a job from another system keeps its identity in and out)

**Status:** 📝 Drafted 2026-10-08 — nothing implemented. The phone half of connecting Avenkin
Office to a field service management system (FSM). The connector itself, ServiceTitan first, is
office plan FX21 (private); Jobber is FX22. This plan is generic: the phone gains no FSM
credentials, no FSM-specific code and no FSM name of its own.
**Track:** Field Assist (B2B).
**Related:** Plan [FO](FO-guided-job-flow-and-job-tab.md) (the job file, its review, the job
ahead), Plan [HC](HC-jobs-list.md) (the Jobs list and the job's page), Plan
[HB](HB-field-assist-mode-and-job-day.md) (the job-day card), Plan
[HN](HN-job-updates-and-several-open-jobs.md) (updates name a job by the office's identifier),
Plan [HO](HO-office-delivery-phone-half.md) (P0b job-file format 2; P2 reports back), Plan
[FX](FX-desktop-office-and-device-sync.md) (the signed office connection), Plan
[HD](HD-report-transcript-audience.md) (who a report is for), Plan
[EM](EM-work-record-and-parts.md) (the work record), Plan [T](T-offline-field-queue-and-sync.md)
(the offline queue), Plan [HU](HU-service-history-and-maintenance-flags.md) (history rides the same
job file), and office plans FX13 (job dispatch), FX12 (report intake), FX21 (FSM connectors).

---

## Trigger

A commercial partner presented Field Assist to an HVAC service business that runs its work in
ServiceTitan. They will pilot with one or two technicians, and the first thing they asked for was
no duplicate data entry: the technician's assigned jobs should reach the phone with the job number
they already use, the visit should run on the existing guidance and recording, and the finished
report should land on the right job in their system. Jobber and Service Fusion customers will ask
the same question next.

The architecture is already decided. The phone never talks to an FSM. Avenkin Office pulls the
job from the FSM, issues it to the phone as a signed job file over the managed folders, takes the
report back over the same connection (or the configured endpoint), and posts the note and the
work order into the FSM. What the phone needs is small: the job has to keep its identity in that
other system on the way in, show the number people know it by, and carry that identity back out
untouched so the office never has to match a report to a job by a customer's name.

## Outcome

- **A job file may carry an `external` block**: which system the job came from, that system's
  identifiers for the job, appointment, location, customer and technician, the job number people
  use, and the system's identifier for each unit by serial. It is signed with the rest of the job.
- **The phone treats it as opaque identity.** It never calls it, never opens it as a link, never
  interprets it, and never looks anything up with it.
- **The technician sees the number they know.** "Job 1007" on the Jobs list, the job's page, the
  car, the watch and the spoken lines, with the source named on a secondary line: "From
  ServiceTitan · signed by Smith Refrigeration Ltd".
- **The block comes back out verbatim** in the work record's JSON, so the office routes the report
  to the right job in the FSM by identifier. The work-order PDF prints the external job number in
  its header. Nothing else about the report changes, and HD's audience rules are untouched.
- **No technician identifier is stored on the phone.** The office binds the enrolment to the FSM
  technician. The phone only echoes what the job file said.

## What exists today (verified against main @ 447d35ec)

- **The job file is strict by design.** `JobFileValidator` refuses any member it does not know
  ("a field this version does not know is refused rather than ignored … A new field is a new
  `format_version`"). Format 1's top-level keys and format 2's job keys (`jobKeysV2`: format 1's
  fields plus `job_id`, `revision`, `manuals`) are closed sets, and nested objects (`site`,
  `equipment`, `attachments`, `manuals`) are checked with `checkKeys` too. `JobFileJSON.members`
  refuses a member named twice at any depth. So a phone that reads format 2 today **refuses** a job
  carrying an unknown `external` member with `.unexpectedField("external")`; it cannot ignore it.
- **Size.** `JobFile.maximumBytes` is 64 KiB for the whole file, and `OfficeManagedJob` caps the
  carried `.ogjob` at `maximumJobBytes = 65_536`. In format 2 the job is base64 inside the file, so
  the job's own bytes are at most about 48 KiB.
- **Format 2 gives a job the office's identity.** `JobFile.Identity` (`jobID`, `revision`,
  `sha256`) is kept on `JobFileProvenance` (`jobID`, `revision`, `jobSHA256`), which travels onto
  the `UpcomingJob`, then onto the session (`FieldSessionService.applyJobAhead` sets
  `session.jobFile = job.provenance`), then into `WorkRecord.jobFile` (JSON key `job_file`).
  `JobListFeed` reads `session.jobFile?.identity?.jobID` into `JobListSession.officeJobID`, which is
  what an office update (HO P3) is matched by.
- **The contract has a versioning rule for exactly this.** `Contracts/job-file.md` §9.1: bulk
  attachments were added to format 2 rather than making a format 3 because no office had written
  format 2 and no released phone read it; "Once either is true, a new member is a new format
  version." Office plan FX13 §7g records that the office has written format 2 since 2026-10-05
  (Send to paired device), while no released phone build reads it.
- **The job number is one field everywhere.** `UpcomingJob.jobReference` and
  `FieldSession.jobReference` drive every label: `UpcomingJob.title` ("Job 1007", else the site,
  else "Upcoming job"), `JobDaySession.label(reference:)`, `CarPlayJobsList`, `JobWatchPayload`,
  `JobTranscriptExport`, the intake (`JobIntakeState`), and `WorkRecord.headerLine` ("Job 1007 —
  vault."). With none, every surface says `JobTabModel.noJobNumber` ("No job number").
- **A job ahead already has a secondary line.** `JobList.Item.note` is
  `UpcomingJobsModel.provenanceLine` ("Signed by …" or "Job file — not signed"); open and finished
  session rows carry `note: nil`. `JobFileReview.make` builds the review sheet's lines.
- **The record already goes out three ways, all from the work record.** `QueuedOp` carries
  `workRecord.json` to `EndpointSyncSink` (the organisation's endpoint) and to the office report
  sink (HO P2, `Contracts/office-reports.md`, whose envelope names the record by digest and carries
  `jobID`/`jobRevision` but treats the record's bytes as opaque). `SessionExport.workRecord` puts
  the same record in the audit JSON beside `transcript_included`. The PDF (`SessionExporter.writePDF`)
  prints `workOrderTitle`, then "vault • Session xxxxxxxx", then `WorkRecord.summaryLines`.
- **Who sees what is decided elsewhere.** `ReportTranscriptPolicy` decides from configuration
  whether a report is the office's or a customer's; `CustomerSummary.lines` is the allow-listed
  customer half. Neither knows anything about job identity.

## Assessment

The office does not strictly need the block back. It issued the job, it knows which FSM job its
own `job_id` maps to, and the office-report envelope already names `jobID`. Echoing `external`
anyway is still worth it, for three reasons: the endpoint route has no envelope and no office
state, so the record is the only place the identity can travel; a report can outlive the office's
own mapping (a re-install, a migration, a second office); and an identity that rides the record is
one an auditor can check without trusting a join. It is cheap because the provenance already
travels.

The real decision is the format. The validator is strict, so "optional within format 2" buys no
compatibility at all: every phone that reads format 2 today refuses the new member either way. The
choice is only between a refusal that names a version ("uses format version 3, which this version
of the app can't read. Update the app") and one that names a field. The contract's own §9.1 rule
says the office writing format 2 makes the next member a new version. **This plan takes format 3**:
format 2's file, signature domain and identity rules unchanged, plus optional `external` (here)
and `history` (Plan HU). The office keeps issuing format 2 to a phone whose build predates format 3
(it already records `appBuild` at commissioning and check-in) and format 3 only where an FSM
connector supplied the block. Open question 1 keeps the cheaper alternative on the table.

## Design

### 1 · The `external` block

One optional member of the job in format 3. All values are plain text under the existing
`checkText` rules (no markup, no control characters), and none may contain `://`, so nothing in it
can be mistaken for a link.

| Member | Required | Meaning |
|---|---|---|
| `system` | yes | An opaque lowercase token naming the system: `[a-z0-9_-]{1,32}`, e.g. `servicetitan`, `jobber`. The phone compares it to nothing |
| `system_name` | no | How people name it, for display: "ServiceTitan". Up to 40 characters. The phone holds no table of names |
| `job_id` | yes | The system's identifier for the job. 1–128 printable ASCII characters, no spaces. Never shown |
| `job_number` | no | The number people use for it. Same limit as `job_reference` (64) |
| `appointment_id`, `location_id`, `customer_id`, `technician_id` | no | The system's identifiers, each 1–128 printable ASCII, no spaces. Echoed, never shown |
| `equipment_ids` | no | An object from serial to the system's equipment identifier. Every key must be a `serial` in the job's `equipment`; at most 10 |

Encoded identifiers from some systems contain `=`, `/` or `+`, which is why the identifier rule is
printable ASCII rather than format 2's `safeIdentifier`. Nothing in the block may be a path the
phone opens, so that is safe. The whole block is bounded at 2 KiB, which leaves the rest of the
job's 48 KiB to the job and to HU's history.

### 2 · Format 3

- `JobFile.formatVersion3 = 3`; `JobFileValidator.validate` routes it through format 2's path with
  `jobKeysV3 = jobKeysV2 ∪ {"external", "history"}`. `format_version` sits in the outer file,
  outside the signed bytes, so a format-2 signature does not say which version the job was written
  for. **Recommended:** a separate `Avenkin.JobFile.v3` domain, so a format-3 job's signature never
  verifies as format 2's and the reverse. It costs one constant (pinned by
  `StorageIdentifierGuardTests`) and one line in the Go writer.
- Format 2 files are read exactly as today. Format 1 never carries `external`.
- `Transport/mobile-core/jobfile` (`jobMembers`) and its fixtures change with it, so the office's
  writer and the phone's reader are tested against one golden file.
- A revision (contract §5) may add, change or drop the block. A job's identity on the phone stays
  its `job_id`; `external.job_id` never decides whether two files are the same job.

### 3 · The model

- `ExternalJobReference: Codable, Equatable, Sendable` with the members above, decoded from the
  validated job.
- Carried as `JobFileProvenance.external` (JSON `external`), optional, absent when the file had
  none. That one choice puts it on the job ahead, the session and `WorkRecord.jobFile` with no new
  plumbing, and every record written before it decodes unchanged.
- `applyJobAhead`'s audit payload gains `external_system` and `external_job_id` beside `job_id`
  and `revision`, so the session log says which FSM job the visit was.

### 4 · Which number is the job number

**Rule: `external.job_number` wins.** When the block gives a job number, `JobFile.upcomingJob`
sets `UpcomingJob.jobReference` to it, and every surface that already follows `jobReference` (list,
page, car, watch, intake, transcript naming, report header, the report envelope's human
`jobReference`) shows the number the technician knows with no per-surface change. When the job's
own `job_reference` is present and different, it is kept as the office's reference and shown on
the review sheet and the job's page as "Office reference", never as the title.

*Requirement on the office:* set `job_reference` to the FSM job number when there is one. The
rule above exists for the case where it does not.

A technician who corrects the number at intake (`set_job_reference`) changes `jobReference` as
today. The block is not edited; the record then carries both, which is the truth.

### 5 · Display

- **Jobs list:** a job ahead's `note` reads "From ServiceTitan · Signed by …" (the system's name,
  else "From another system"); open and finished rows gain the same source line, read from
  `session.jobFile?.external`. `JobListSession` gains `externalSource: String?`; search matches the
  external job number.
- **The job's page and the review sheet:** a "From" row with the system's name and the external job
  number, and "Office reference" when it differs. Identifiers are not shown.
- **Voice:** unchanged. "Switch to job 1007" already matches `jobReference`.
- **No plan letters, no FSM names in app strings.** The only system name the phone ever prints is
  the one the job file supplied.

### 6 · The report

- **JSON:** `work_record.job_file.external` carries the block with the same members and values the
  job file had, in the audit export, in `QueuedOp.workRecord` to the endpoint, and in the record the
  office report names. Re-encoded by `Codable`, so member order and whitespace are not preserved;
  every member and value is, because the validator admitted nothing it does not model.
- **PDF:** the header line under the title becomes "Job 1007 (ServiceTitan) · vault · Session
  xxxxxxxx" when the block has a job number. Only the system's name and the job number are
  printed; no identifier, location, customer or technician id ever reaches the PDF, which HD treats
  as the customer's document.
- **Audience:** `ReportTranscriptPolicy` and `CustomerSummary` are unchanged. The job number is
  already on a customer's work order; nothing new reaches a customer.
- **Unsigned files.** The block is echoed whatever the file's signature, and
  `job_file.signature` says which it was. *Requirement on the office:* route a report by
  `external` only when the record's `job_file` is signed, and otherwise by its own `jobID` match;
  an unsigned file's block is only a claim, as its `job_id` already is (contract §5).
- **Offline queue:** nothing new. The queued op already carries the record.

### 7 · What the phone deliberately does not do

- It stores no technician identifier and has no setting for one. The office binds the enrolment
  to the FSM technician (FX21). `technician_id` exists in the block only so an office that issues a
  job to a shared phone can see whose job it was.
- It never filters, sorts or rejects jobs by `external`. A job for another technician is the
  office's error to prevent, not the phone's to detect.
- It makes no call to any address in or derived from the block.

### 8 · The contract

`Contracts/job-file.md` gains §10 "Format 3: external references and service history": the table
above, the format-3 file, the precedence rule, the echo requirement, the routing requirement on
the office, and the unsigned rule. §9.1 is updated to say format 3 was made under it.

## Phases (one PR each)

- **P0 — Contract, model, validator, fixture (headless).** Format 3 in `JobFileValidator`,
  `ExternalJobReference`, `JobFileProvenance.external`, the precedence rule in
  `JobFile.upcomingJob`, the Go `jobfile` package and a signed `job-file-v3-external.ogjob` fixture,
  contract §10. Format 1 and 2 behaviour byte for byte unchanged.
- **P1 — Display.** Review sheet rows, the job's page, Jobs list notes and search, the PDF header
  line. `JobListSession.externalSource`.
- **P2 — Report echo and the log.** `applyJobAhead` payload, the record JSON assertion across the
  three routes (audit JSON, endpoint op, office report record), HD audience tests re-run with a block
  present.
- **Device check owed:** one format-3 job issued by a real office from a sandbox FSM job to a
  physical phone; the technician sees the FSM number; the report returns with the block intact and
  the office posts it to the same FSM job (FX21's acceptance).

## Tests

- `JobFileExternalReferenceTests` — format 3 with a full block validates and decodes; each member's
  type, length, character and `://` rule refuses; `equipment_ids` keys not among the job's serials
  refuse; a member inside `external` the contract does not list refuses; the block over 2 KiB
  refuses; format 2 with `external` refuses with `unexpectedField`; format 1 with it refuses.
- `JobFileFormat3Tests` — the golden fixture verifies under the organisation key; signature domain;
  every format-2 negative case repeated at version 3; a format-2 file still imports unchanged;
  `StorageIdentifierGuardTests` extended for the new domain constant.
- `JobFileExternalPrecedenceTests` — `external.job_number` becomes `jobReference`; a differing
  `job_reference` is kept as the office reference and shown on the review; a block with no number
  leaves `job_reference` as the number; an intake correction leaves the block untouched.
- `JobListComposerTests` (extended) — source line on a job ahead, an open and a finished job;
  search by external number; no identifier appears in any row.
- `WorkRecordTests` (extended) — `job_file.external` round-trips; a record without one encodes byte
  for byte as before.
- `SessionExporterTests` (extended) — PDF header line with and without a block; no identifier, no
  location, customer or technician id in the rendered text.
- `ReportTranscriptPolicyTests` — unchanged expectations with a block present.
- Go `jobfile` tests — the same positive and negative cases, from the same fixture.

## Risks

- **An identifier mistaken for something to act on.** The block is never a URL, never a lookup key
  on the phone, and the validator refuses `://`. A future feature that wants to deep-link into an
  FSM must be its own decision, not a reuse of this block.
- **Two numbers.** If the office ignores the requirement and the two numbers differ, the technician
  sees the FSM number and the office's on the page. Better than a silent choice; still a support
  call. FX21 should make them equal.
- **The wrong job in the FSM.** The office routes by the echoed identity; if it issued the wrong
  identity, the report lands on the wrong job. The phone cannot detect that, and says nothing it
  cannot know.
- **Version skew.** A phone on an older build refuses format 3 with a clear sentence. The office
  must not send format 3 to it, which depends on its build register being current.

## Out of scope

- Any call from the phone to an FSM, any FSM credential, any FSM-specific code path.
- Storing or entering a technician's FSM identifier on the phone.
- Status sync back to the FSM (en route, arrived, done). That is the office's to derive from
  what the phone already sends, and HN's to extend if it ever needs a phone message.
- The connector itself, its polling and its note format: office plans FX21 (ServiceTitan) and
  FX22 (Jobber).

## Open questions

1. **Format 3, or amend format 2?** The only format-2 writer today is the office's own opt-in
   transport build, and no released phone reads format 2. Amending format 2 avoids a version and
   an office-side build check, at the cost of the contract's own §9.1 rule. This plan recommends
   format 3.
2. **A separate signature domain for format 3.** Recommended; confirm in P0.
3. **Show the system's identifiers anywhere?** A support person on the phone may want the FSM job
   id when the number is ambiguous. The plan shows none; a long-press "copy reference" is possible.
4. **Should the office-report envelope carry the block too?** It is closed and treats the record
   as opaque; adding it duplicates the record. Not proposed.
