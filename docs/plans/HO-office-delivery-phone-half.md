# Plan HO — Office Delivery on the Phone (jobs, updates, manuals out; reports, transcripts back)

**Status:** 🚧 P0 and P1 built 2026-10-04 (opt-in office transport build only; both headless
exits met, the physical-phone runs are owed). P0b (job-file format 2) built 2026-10-05, in every
build: contract, reference implementation, fixture and the phone's import; headless exit met.
P2 (reports back) built 2026-10-05 in the opt-in build, tested headless: the contract, the
transport, the report service and a sink that waits, and the app's wiring — a phone that joined
an office sends each job's record there with its work order, audit export and transcript, and
counts it delivered only on the office's receipt. What P2 still owes is listed under it. P4
(the `bulk` folder) built 2026-10-05 in the opt-in build, tested headless: an assigned manual
is verified under the organisation's own granted publisher, installed and receipted, and an
attachment a signed job names by digest follows it and opens from the job. What P4 still owes
is listed under it. P3, P5 and P6 are planned. A build order, not a new design:
nothing else in it is built beyond what the table under *Where each flow stands* marks as
existing.
**Track:** Field Assist (B2B), phone half.
**Related:** Plan [FX](FX-desktop-office-and-device-sync.md) (the signed office connection; this
plan is its phone backlog), Plan [HN](HN-job-updates-and-several-open-jobs.md) (job updates and
notes from the office), Plan [HE](HE-recorded-session-action-map.md) (recorded jobs), Plan
[HD](HD-report-transcript-audience.md) (who may read a transcript), Plan
[T](T-offline-field-queue-and-sync.md) (the offline queue), Plan
[CT](CT-org-configuration-profiles.md) (lease, leaving the firm), Plan
[EM](EM-work-record-and-parts.md) (the work record). Contracts:
[`Contracts/README.md`](../../Contracts/README.md) (binding, managed job and receipt, manual
assignment), [`office-folders.md`](../../Contracts/office-folders.md),
[`office-check-in.md`](../../Contracts/office-check-in.md),
[`commissioning.md`](../../Contracts/commissioning.md).

---

## Trigger

Greig, 2026-10-04: "how near are we to sending jobs, notes and manuals to phones, and job reports
and transcripts back to the office from the device?" The pieces exist as contracts, a Go
transport and verifiers, but they are spread over several plans and none of them reaches a
technician yet. This plan puts them in one order, says what each step needs before it can start,
and stops each step at something a test can prove.

## Where each flow stands (checked 2026-10-04)

One fact sits under every row: **the default phone build has no managed folder.** The transport
is only in the opt-in `AVENKIN_OFFICE_TRANSPORT` build. Since P0 that build opens the `control`
and `records` folders for a paired phone and takes a managed job to the job review, and since P1
it answers the office's check-in challenge, renews its binding and lease from the result, and
acts on a removal; none of it has yet been run on a physical phone against an office. Everything
else in the table is as it was: a joined phone can receive a job, stay joined and be removed,
and nothing more.

| Flow | Contract | Go transport | Swift | Missing |
|---|---|---|---|---|
| Join an office by its code | v1, fixtures | built | built (opt-in build) | a run on a physical phone against the office |
| Stay joined: check-in and renewal | draft v1, fixtures | messages, the office key holder's operations, and the phone's folder handling | **P1 built** (opt-in build): the challenge answered once, the result through the pairing gate, the lease renewed, the folders restarted under the new generation | a phone renewed by a real office, and one left unreachable past a challenge then renewed on return. The office app does not yet call the key holder's operations |
| Removal by the office | same contract | messages, and the phone's folder handling | **P1 built** (opt-in build): a removal revokes as a signed revocation does and is receipted | a removal delivered to a physical phone and its receipt reaching the office |
| Job to the phone | managed job + receipt, fixtures; [job file](../../Contracts/job-file.md) format 2, fixture | intake, durable commit, receipt offered for signing; job-file format 2 reference | **P0 built** (opt-in build): the folders open through the pairing gate, the job goes to the job review, the receipt is signed and published. **P0b built** (every build): a format-2 job keeps the office's identifier and revision; a later revision revises the job, the same one twice is one job | one signed format-2 job to a physical phone and its receipt accepted by the office |
| Update or note on a job the phone holds | none (Plan HN) | none | none | HN's contract, then P3 |
| Attachments with a job | [bulk content](../../Contracts/office-bulk.md) §5: a job names them by digest and they follow in `bulk` | `jobfile.ReadNeeds` | **P4 second part built**: the validator reads them in format 2, the job keeps them, and (opt-in build) an attachment a signed job names is taken from `bulk`, checked and opened from the job | an attachment from a real office to a physical phone |
| Manual to the phone | assignment + preflight, fixtures; [bulk content](../../Contracts/office-bulk.md) draft v1 (publisher grant, assignment receipt), fixtures | verifier, the grant and receipt messages, and the phone's `bulk` folder | **P4 first part built** (opt-in build): a grant kept, an assignment committed and receipted, its archive taken from `bulk` when the route allows, verified under the organisation's granted publisher and handed to the installer | a manual from a real office to a physical phone; the office side of `bulk` |
| Report and parts request to the office | [office reports](../../Contracts/office-reports.md), draft v1, fixtures | messages, and the phone's publishing, receipts and outbound list | **P2 built** (opt-in build): a phone that joined an office sends job records and stock checks there, waits rather than counting attempts, and treats a record as delivered only on the office's receipt | a report from a physical phone to a real office; the office reading one; photographs and clips as their own attachments; the report composer offering the office |
| Transcript to the office | travels with the report, under HD's audience rule | an attachment like any other | **P2 built**: its own document for the office only, and inside the audit export, unless the organisation's rule is *never* — then the report says *omitted* | the same physical run |
| Recorded job to the office | recorded-session draft, no fixtures | none | none | Plan HE |
| Team learning both ways | design only | none | none | its own plan |

What works today without any of it: a technician emails the report, the work-order PDF and the
transcript, and the office imports them by hand.

## Order

Each phase is one PR, pure core first, and ends at its exit test. A phase marked *contract first*
does not start in Swift until its contract and fixtures are merged in `Contracts/`.

**Sequence (decided by Greig, 2026-10-04).** The phase letters are kept so other documents'
references stay true; the order of work is:

1. **P0** — built.
2. **P0b** — job-file format 2, **before** P0's run on a physical phone, so the first real job
   already carries the office's job identifier and revision. Built 2026-10-05.
3. **P2** — reports and transcripts back. Second by decision: until it lands every report is
   emailed and imported by hand. Its contract is written first.
4. **P4** — the `bulk` folder, job attachments and manuals. Brought forward: attachments travel
   in `bulk`, and a job must be able to bring a manual the phone does not have.
5. **P1** — check-in, renewal and removal: built 2026-10-04, ahead of this order.
6. **P3**, **P5**, **P6** as below.

### P0 — The managed folders in the app, and a job arriving

The smallest thing that makes the connection carry something.

- A seam over the transport's managed-folder functions (`StartManagedOfficeFolders`, the pending
  jobs, the job file, publishing a receipt), with the real implementation in the opt-in build and
  an in-memory one for tests — the pattern `OfficeCommissionTransport` already uses.
- The binding handed to the transport comes only from `OfficePairingService.currentApprovedPeer()`
  at that moment: profile, licence, lease, binding, keys and high-water mark all rechecked. A
  change during start-up stops the folders, as it stops the connection today.
- A pure `OfficeManagedJobIntake`: for each job the transport has committed, hand its exact bytes
  to the existing job-file import and its review (`JobFileService`, `JobFileImportPolicy`) — the
  office's signature does not skip the technician's review — then sign the receipt payload with
  the phone application key and publish it. A job is offered once; an exact repeat gets the same
  receipt; a refused job file is recorded and gets no receipt.
- Shown as it is: *waiting for the office*, *job received*, never "sent" or "delivered" from a
  finished transfer.

**Exit:** with the in-memory transport, a fixture job reaches the job review and its receipt
verifies against the golden receipt's rules; a foreign binding, a lapsed lease and a changed
profile each leave the folders closed. Release build green. **Owed after it:** one signed job to
a physical phone and its receipt accepted by the office.

**As built (2026-10-04).** In `OpenGlasses/Sources/Services/OfficeSync/`:

- `OfficeManagedFolderTransport` is the seam over `StartManagedOfficeFolders`,
  `ManagedJobsPending`, `ManagedJobFile`, `PublishManagedJobReceipt` and `Stop`.
  `OfficeManagedFolderMobilecoreTransport` is the real one, in the opt-in build only; the tests
  use an in-memory one that behaves as the Go transport does at the seam.
- `OfficePairingService.openFoldersWithApprovedOffice` is the only caller of the start function.
  The binding object is built privately from `currentApprovedPeer()` at that moment, the approval
  is verified again once the engine has started, and the folders are closed if it no longer
  verifies or is no longer the same one. `OfficeFieldConnection` now starts the connection this
  way and asks for what has arrived on every poll while the engine runs. The pairing sheet's
  connection test is still the handshake with no folder.
- `OfficeManagedJobIntake` takes each committed job's exact bytes to `JobFileService`: the same
  validation, signature rule and import policy as a file opened from Mail, and the same review
  with its one tap. A file the import refuses is recorded with a reason of at most 200
  characters and gets no receipt. One it would offer is recorded, then its receipt payload is
  signed (`OfficePhoneIdentity.signManagedJobReceipt`, which signs nothing but a closed receipt
  payload) and published. `OfficeManagedJobReceipt` is the Swift form of the receipt contract,
  checked against the Go golden receipt.
- Shown under Field Assist settings, beside the connection's own line: *Job received* while a
  job is on the phone waiting for its review, or that a job could not be added and why.
  *Waiting for the office* remains the connection's line. Nothing says sent, delivered or
  accepted.

Choices made where the plan left room:

- **The receipt does not wait for the technician.** The review shows one file at a time. A job is
  receipted as soon as the import would offer it and the offer is recorded; its review is raised
  when the review is free, lowest sequence first. That is the receipt contract's meaning
  ("committed … ready for the technician's review").
- **"Offered once" survives a relaunch.** The intake keeps its own record
  (`Application Support/AvenkinOffice/managed-jobs.json`) with the receipt signature, so a job
  the transport lists again gets the same receipt, byte for byte, and no second review. A review
  that was never answered before the app closed is raised again from the committed bytes: the
  same offer, not a new one.
- **The job file's own signature rule is unchanged.** The office's signature on the transport
  message says who sent the bytes; it does not sign the job file. Under an organisation or
  medical rule that requires signed job files, an unsigned job from the office is refused, as
  the managed job contract already says.

**Still owed for P0:**

- The physical run: the opt-in build on a phone, one signed job from the office, its receipt
  accepted there. Nothing in this phase was run against the Go engine from Swift. The opt-in
  app itself has since been built (with P1, 2026-10-04): a Debug simulator build and a Release
  device build, installed and launched on a phone that is not paired with an office. No bridge
  call has yet run against an office.
- A job whose review the technician puts aside is not offered again, though the office holds its
  receipt. Reopening a received job from the phone is not built.
- The review does not yet say that a job came over the office connection; it shows the file name
  `office-job-<sequence>.ogjob` and the job file's own signature state.
- A refused job stays listed by the transport as pending with no receipt. The office sees it as
  not received; nothing tells the office why.

### P0b — Job-file format 2 (*contract first*)

Decided 2026-10-04: before P0's run on a physical phone.

- **Contract:** format version 2 of the job file — an office-assigned stable job identifier and
  a revision, a domain-separated signature over the exact file bytes, and a signed golden
  fixture. Version 1 stays readable; a version-1 file is never upgraded in place.
- **Phone:** the import, the review and the job record keep the identifier and revision; a later
  revision of a job the phone holds is shown as a revision of that job, not a second job; a
  report names the identifier and revision it was written against, so the office matches by
  identifier and not by digest alone.
- A job that arrives twice — the same identifier and revision under two managed messages, as
  can happen when the office issues a job again after a binding renewal — is one job.

**Exit:** the golden fixture imports, reviews and round-trips; a version-1 file still imports;
the same identifier and revision twice is one job; an older revision never replaces a newer one.

**Contract (2026-10-05):** [`Contracts/job-file.md`](../../Contracts/job-file.md), with
`Transport/mobile-core/jobfile` as its reference implementation and the signed golden fixture
`job-file-v2.ogjob`. What the contract settled:

- **The file wraps the job's exact bytes.** A signature cannot cover a file it sits inside, so a
  format-2 file is `format`, `format_version`, `job` (the job's bytes, base64) and `signature`,
  and the signature is over `Avenkin.JobFile.v2`, a zero byte and those bytes. A format-1 reader
  still sees a job file at a version it cannot read.
- **`job_id` and `revision` are required members of the job.** The rest are format 1's fields
  with format 1's limits.
- **Same identifier and revision: the same bytes are one job, other bytes are a conflict.** A
  higher revision is a revision of that job; a lower one is refused.
- **An unsigned file never revises a job that arrived signed.** Otherwise the unsigned rule is
  format 1's.
- **The report names the job.** The report contract gained `jobID` and `jobRevision` (empty and
  0 for a job that began any other way), and its fixtures were regenerated.

Open in the contract (its §9): attachments still only named; what a revision does to a job in
progress (Plan HN); whether format 2 should always be signed; no signed cancellation.

**As built on the phone (2026-10-05).** In every build — a job file opens from Mail or Files
whether or not the office transport is linked:

- `JobFileValidator` reads format 2: the closed outer file, the job's exact bytes, `job_id` and
  `revision`, and then format 1's own content rules on the job. Exact bytes are what the
  signature covers, so a member named twice at any depth is refused (`JobFileJSON`), as it now
  is in the Go reference. Format 1 is read exactly as before.
- `JobFileSignatureCheck` verifies a format-2 signature over `Avenkin.JobFile.v2`, a zero byte
  and the job's bytes, with the organisation's job-signing key from its profile.
- `JobFileProvenance` gained `job_id`, `revision` and `job_sha256`. It is what the job ahead
  keeps and what a started job's session and work record carry (`job_file`), so the identifier
  and revision are in the record a report will be built from. A record written before they
  existed still reads.
- `JobFileService` applies the contract's §5 before it raises a review: a higher revision of a
  job ahead is offered as a revision of that job and replaces it in place, whatever is tapped;
  the same revision with the same job bytes is the job the phone has (*already on this phone*,
  nothing added); a lower revision, and other bytes at the same revision, are refused; an
  unsigned or uncheckable file never revises a job that arrived signed. It also looks at jobs
  already started, from the session history.
- `OfficeManagedJobIntake`: the same job under a second managed message is receipted — it is on
  this phone — and raises no second review.

**Still owed for P0b:**

- A format-2 file opened on a physical phone, and one written by an office. The phone's own
  `Scripts/make-job-file.swift` still writes format 1 only.
- The review of a revision shows the whole new revision and which one it replaces; it does not
  pick out what changed.
- A revision of a job already started is refused with a sentence; it is not shown as
  information on that job (Plan HN).
- Nothing sends the identifier and revision back yet: the record carries them, and the report
  that names them is P2's phone half.

### P1 — Check-in, renewal and removal on the phone

Without it every paired phone stops receiving 30 days after pairing.

- Transport: read `control/checkin/` and `control/removal/`, offer the check-in payload and the
  removal receipt for signing, publish them under `records/`, and extend the outbound guard to
  exactly those published files.
- Swift: answer the live challenge once (keep the exact bytes and the nonce); take a result
  through the pairing gate in the contract's order — generation high-water mark, saved binding,
  then `lastRenewedAt` — and restart the folders under the new generation; treat a removal as the
  signed revocation the leaving rules already handle, sign its receipt, and open no further
  connection for that enrolment.
- The contract's negative cases (§11) in the portable Swift checks, against the golden fixtures.

**Exit:** the fixture exchange renews a lease and a binding in a headless test; a replayed or
foreign result changes nothing; a removal revokes and is receipted. **Owed:** a phone left
unreachable past a challenge, then renewed on return.

**As built (2026-10-04).**

- **Transport** (`Transport/mobile-core/managed_checkin.go`, beside the managed inbox). Each pass
  reads `control/checkin/` and `control/removal/` by the contract's names only and lists what
  verifies with the reference `checkin` package: the one live challenge with the latest
  `issuedAt` set under exactly the binding handed over, the result for the check-in this phone
  published, and removals naming this enrolment. `ManagedCheckInPayload` builds the check-in once
  per challenge, with its own nonce, and returns the same bytes when asked again;
  `PublishManagedCheckIn` and `PublishManagedRemovalReceipt` publish only under a signature the
  binding's phone application key made over the right domain, staged outside the folders and
  moved into place. The outbound guard serves `records/checkin/<challengeID>.envelope.json` and
  `records/removal/<removalID>.envelope.json` only while they are published, beside job receipts.
  A check-in is withdrawn when its challenge expires, a later one is answered, or the folders
  start under a newer generation.
- **`OfficeCheckIn`** is the phone's verifier for the five messages: closed flat objects, the
  signature over the exact payload bytes under the key the caller supplies (the office or phone
  application key from the binding, the administrator key from the vendor-verified profile), the
  field rules, and that a message names this binding, phone and exchange. A removal that
  verifies is the only value the revoking code accepts.
- **`OfficePhoneIdentity.signCheckIn` / `signRemovalReceipt`** sign nothing but a closed payload
  of their own kind, under their own domain.
- **`OfficePairingService.renew(withResult:waiting:)`** is contract §7 in its order: the
  result's signature and identity, the one check-in waited on, the carried binding through the
  existing binding verifier against this phone's own keys and the saved office identities with a
  higher generation, profile, licence and lease rechecked, then the high-water mark, the saved
  binding (keeping the route hint), and last `OrgProfileManager.renewLease(officeBinding:)`,
  which sets `lastRenewedAt` to the phone's clock. `remove(withRemoval:)` verifies a removal and
  calls `OrgProfileManager.revoke(officeRemoval:)`, which is the existing signed-revocation path:
  rules lift, content stays locked, the leaving rules take over what is owed.
- **`OfficeCheckInService`** drives it from the connection's poll, before the job intake:
  removal first, then the result for the check-in waited on, then the live challenge. It keeps
  the check-in's exact bytes, nonce and signature (`Application Support/AvenkinOffice/
  check-in.json`) until a result arrives or the challenge expires, publishes the same bytes
  again rather than a second check-in, forgets the nonce after a renewal, and records a file
  that does not verify once, with a bounded reason. After a renewal it tells
  `OfficeFieldConnection`, which checks the approval on its next poll and starts the folders
  again under the new generation.
- **Shown** under Field Assist settings only when the office has removed the phone: *Removed by
  your organisation*, with one sentence that differs for `removed` and `revoked`. A check-in and
  a renewal show nothing; the managed row already shows the lease's date.

Choices made where the plan and contract left room:

- **The transport is handed more of the binding.** To verify a result or a removal the
  transport needs the administrator key, the profile identifier and the digest of the binding
  held, which the managed-job binding object did not carry. `StartManagedOfficeFolders` now
  takes those three as well; all three or none, and a caller that hands over the earlier form
  (the transport's own stand-in phone does) gets managed jobs and no check-in. In Swift the
  binding's check-in functions are spelled `managedCheck(inPending:)`,
  `managedCheck(inPayload:…)` and `publishManagedCheck(in:…)`: the importer splits the names at
  "In". Only the opt-in build shows that, which is how it was found. The transport's
  check is a first filter only: the phone commits or revokes on its own verification.
- **The same result with the same check-in is a repair, not a replay.** The contract repairs a
  crash between the commit steps by taking the same result in again. The gate cannot tell that
  from a repeat while the caller still holds the check-in, so it allows it, and what stops a
  stored result renewing a lease later is the service forgetting the check-in — as §7 says.
- **A removal's receipt leaves on the connection that brought it.** The phone revokes, then
  signs and publishes the receipt; nothing reopens a connection for that enrolment, and the
  running one stops at its next approval check, at most 30 seconds later and possibly a few.
  Whether the receipt has reached the office by then is not checked.
- **A removal record does not follow the phone into a new enrolment.** The record names the
  enrolment it ended; a phone that joins again starts clean.

**Still owed for P1:**

- The physical runs: a phone renewed by a real office; one left unreachable past a challenge and
  renewed on return; a removal delivered and its receipt accepted. The opt-in app builds, and
  launches on a phone, but nothing here was run against the Go engine from Swift, and the office
  app does not yet set challenges or renew.
- A check-in the office never answers is not shown; the technician sees the lease date on the
  managed row and nothing about the office having gone quiet.
- A managed job signed under the old generation and not yet committed is refused after a
  renewal, as the contract says; the office has to issue it again. Not exercised end to end.
- If the transport loses its own record of a check-in the phone already signed, that challenge
  is not answered again; the office sets a new one when it expires.

### P2 — Reports back to the office (*contract first*)

- **Contract:** a signed report envelope for the queued operations the phone already has (work
  record, parts request, addendum), an attachment manifest (digest, bytes, required or optional,
  audience), and the office's signed receipt with *record accepted*, *evidence pending* and
  *fully accepted* as distinct outcomes. The paths are already reserved in the folders contract.
- **Phone:** an office sink beside the endpoint and email sinks, which **waits** while the office
  is unreachable rather than counting failed attempts; the office set as the report destination
  when a phone joins by code; a sealed outbound list so only published records are ever served;
  deliver-then-erase only on *fully accepted*.
- The transcript goes as an attachment under HD's audience rule, or is named as omitted.

**Exit:** fixture round trip; a lost receipt is asked for again and matches; an unreachable
office leaves the queue intact past the old retry limit.

**Contract drafted (2026-10-04):** [`Contracts/office-reports.md`](../../Contracts/office-reports.md),
with `Transport/mobile-core/officereport` as its reference implementation and golden fixtures.
The phone half has not started. What the contract settled, and what the phone half now has to
build because of it:

- **A report is flat and names its record and manifest by digest**, as a managed job names its
  job file. The record is the bytes the phone already produces; the contract does not look
  inside it.
- **Every send is a new operation; a record has a stable identifier and a rising revision.** The
  queue mints a new operation identifier each time a job's record is sent (end of job, report,
  addendum) and has no revision. The phone half needs a durable revision per record.
- **An addendum is a record kind**, not a queued operation kind today: the same job's record
  again, with the addendum document attached.
- **Three receipts, one file each**, because a published name never changes:
  evidence pending → record accepted (every required attachment in) → fully accepted.
  `recordAccepted` counts as delivered; erasure waits for `fullyAccepted`.
- **No generation in a report**, so a report published before a renewal is receipted after it
  without being signed again.
- **The phone must keep the exact attachment bytes it named.** The work-order document is
  rendered on demand and photographs carry no digest today; a report's attachments have to be
  stored, with their digests, until they are receipted.
- **The transcript** is an attachment for the office only, or the report says `omitted` or
  `none`; the existing audience rule decides which.

Open in the contract (its §11), for a decision before or during the phone half: whether a
refusal needs a signed outcome; whether `recordAccepted` or only `fullyAccepted` releases a
leaving phone; records owed at removal; and whether large evidence wants its own pausable
folder.

**Phone half, first part — as built (2026-10-05).** Everything up to the app's own wiring,
ending at the plan's exit tests. Nothing here is reachable by a technician yet.

- **Transport** (`Transport/mobile-core/managed_reports.go`). `PublishManagedReport` takes the
  report payload, the phone's signature, the record and the manifest, checks them with the
  reference `officereport` package exactly as the office will — the binding's phone key, this
  pairing's identities, the record's and manifest's digests, a canonical manifest — and
  publishes the three files, companions first. `PublishManagedReportAttachment` copies in one
  attachment a published report names, from a file in the app's storage, only when its size and
  digest are the manifest's. `ManagedReportReceipts` lists the office's receipts that verify for
  a published report under the name their outcome has. `WithdrawManagedReport` removes a report
  and whatever no other published report names. The outbound guard serves exactly those files.
  A report published under one generation is still the same report after a renewal.
- **`OfficeReport`** writes the report payload and the manifest in their one spelling — the
  golden fixtures, byte for byte — and reads a report and a receipt under the binding's keys.
  `OfficePhoneIdentity.signOfficeReport` signs nothing but a closed report payload.
- **`OfficeReportService`** takes one record with its evidence: it gives the record the next
  revision, keeps the report's exact bytes before anything is signed, signs once, publishes, and
  publishes each attachment (one that is not there yet is tried on the next pass; the rest still
  go). A report's standing moves only on a receipt that verifies for exactly the envelope in
  the folder, and only upwards. A later send of the same record withdraws an earlier one the
  office has not accepted. A fully accepted report is withdrawn. Its record is
  `Application Support/AvenkinOffice/reports.json`.
- **`OfficeReportSink`** sits where the endpoint sink does. A work record or a stock check goes
  to the report service when the office is the phone's destination; everything else goes where
  it went before. `SyncOutcome` gained `waiting`: the operation stays queued and **no attempt is
  counted** while the office is out of reach, the pairing does not verify, or the office has not
  answered. The operation is delivered on *record accepted*. A record that can never be a report
  (over the size cap, no identity) fails with a reason rather than waiting for ever.

Exit, as tests (`OfficeReportServiceTests`, `OfficeReportTests`): the fixture record is
published as the golden report and is delivered only on the office's receipt; a phone that
lost its own record of a report sends it again as the same bytes and the office's receipt still
fits; an unreachable office, a pairing that does not verify, and an office that does not answer
each leave the operation queued with no attempt counted, three times past the old limit.

Choices made where the contract left room:

- **The phone writes the report's bytes; the transport verifies them.** One bridge call takes
  the payload, the signature, the record and the manifest. The transport builds nothing, so the
  only bytes signed are bytes Swift wrote and tests pin to the fixtures.
- **The published envelope is kept.** A receipt names the digest of the envelope as published;
  the service keeps those bytes rather than reconstructing them.
- **A superseded operation is released.** When a later revision is published first, the earlier
  operation leaves the queue as done: its record is in the later one.
- **At most 64 reports wait in the folder at once**, a bound on the transport's own state.

**Phone half, second part — as built (2026-10-05).** Switched on, in the opt-in build:

- **The office is the destination for a phone that joined one.** `OfficeReportSink` is first in
  the app's sync chain. A phone enrolled from an office, and not removed, sends its job records
  and stock checks there; any other phone, and any build without the transport, sends as it did
  before. Nothing has to be configured: joining by code is what sets it.
- **The documents go with the record, as exact bytes.** `OfficeReportDocuments` decides which:
  the work order (the one document the office may pass on to a customer) and the audit export
  always; the transcript as its own document, for the office only, unless the organisation's
  rule is *never* — then the report says *omitted* — and *none* when nothing was said.
  `OfficeReportEvidenceStore` renders them once per queued operation and keeps those bytes under
  their digests (`Application Support/AvenkinOffice/report-evidence/`, excluded from backup)
  until the office has them, because two renderings of one work order are not the same bytes.
- **Receipts are read on the connection's poll.** `OfficeReportPump` runs after check-in and
  the job intake: it reads the office's receipts, flushes the queue when one changed a report's
  standing or when records are waiting (at most once a minute otherwise), and lets go of
  documents the office now has.
- **A leaving phone erases only what the office fully has.** The departure rule's "delivered"
  now also requires every report for those jobs to be *fully accepted*; *record accepted* is
  delivered and is not yet a reason to erase.
- **Shown** under Field Assist settings: how many records are still for the office, or that the
  office has them and their documents are on the way. Nothing says sent or delivered.
- **The data-store inventory lists the office's stores**: the engine's folders, the job intake,
  check-in, reports and report evidence. The first three were added by earlier phases and had
  not been listed.

**Still owed for P2:**

- A report from a physical phone to a real office, and the office reading one at all.
- Photographs and clips as their own attachments. The chosen photographs are inside the work
  order; the originals, and any clip, do not travel yet. Clips are large, and whether large
  evidence wants its own pausable folder is open in the contract.
- The addendum as a record kind. A later send of a job is a later revision of its work record,
  which carries the debrief; nothing marks it as an addendum or attaches the addendum document.
- The report composer does not offer the office. The record goes when the job ends and whenever
  a record is queued; a technician cannot choose "send to the office" as they choose email.
- A phone without the audited-export capability, or whose job is no longer on it, sends the
  record with no documents and says there is no transcript.
- If a report's stored documents are lost while it is waiting, it stays at *evidence pending*:
  nothing re-renders them under a new revision.
- Once a phone has been removed, records the office has not fully accepted do not travel
  ([check-in](../../Contracts/office-check-in.md) §8); they are erased at the erase-by date.

### P3 — Updates and notes on a job (*contract first*, Plan HN)

HN owns the design. This phase is its message contract and the intake beside P0's: a signed
update on a job the phone holds, information only, shown when the technician opens the job.

### P4 — The `bulk` folder: job attachments and manuals (*contract first* for three pieces)

Decided 2026-10-04: attachments travel in `bulk`, and a job can bring a manual with it.

- **A job names what it needs.** The job arrives first, in `control`, and is usable at once. Its
  attachments, and any manual it needs that the phone does not hold, follow in `bulk` and are
  shown on the job as *still downloading*, *waiting for Wi-Fi* or *ready* — never as missing.
  The contract piece: how a job names an attachment (digest, bytes, name) and a manual set it
  needs, and that the office then publishes a manual assignment for it. A job never authorises
  a manual by itself; the assignment and the publisher's signature still do.

- Trust for an organisation's own publishing key, reaching the phone through the vendor-rooted
  chain and accepted only for vaults that organisation's office assigned to its own phones.
- The phone's signed receipt for an assignment.
- The `bulk` folder in the transport, paused by default on a metered or relayed route; durable
  per-set high-water and install state; the previous vault kept until the new one is committed;
  the outbound guard proving no manual byte is ever served.

**Exit:** a fixture vault assigned, verified, installed and receipted in a headless test; a
paused or unassigned archive is not fetched.

**Contract drafted (2026-10-05):** [`Contracts/office-bulk.md`](../../Contracts/office-bulk.md),
with `Transport/mobile-core/officebulk` and `jobfile.ReadNeeds` as its reference implementation
and golden fixtures (a grant, a vault the granted key signed, its assignment and both receipts,
and a job that names an attachment and a manual set). The phone half has not started. What the
contract settled:

- **The organisation's publisher is granted by the administrator**, not listed by the vendor:
  vendor signs the profile, the profile names the administrator key, the administrator signs
  the grant. Its identifier is `org.<organizationID>`, a prefix the vendor's catalogue never
  uses, so a grant cannot stand in for a catalogue publisher or for another organisation.
- **A grant verifies an archive only under an assignment** from that organisation's office for
  this phone. The organisation's publisher is never added to the phone's general list.
- **Two assignment receipts, one file each:** *received* (the assignment is committed) and
  *installed* (the archive is verified and installed). No refusal outcome.
- **A job names; it never authorises.** An attachment travels because a job the phone holds
  names its exact bytes. A manual set a job names is installed only under its own assignment
  and its publisher's signature.
- **These are additions to format 2's job, not a format 3**, because no office has written a
  format-2 file and no released phone reads one. The phone's validator refuses them until the
  phone half is built.

Open in the contract (its §10): who decides a route is metered; size caps; erasing a job's
attachments before the job goes; narrowing a publishing key to named vaults.

**Phone half, first part — manuals, as built (2026-10-05).** In the opt-in build:

- **Transport** (`Transport/mobile-core/managed_bulk.go`). The managed connection now has a
  third folder, `bulk`: receive-only, **paused when it starts**, and ignoring everything.
  `SetManagedBulkWanted` names exactly the files it may take, by kind, digest and size;
  `ManagedBulkStatus` says whether each is *ready*, *offered* by the office or *waiting*, and a
  file is ready only as a private copy whose size and digest were checked; `ManagedBulkFile`
  hands over that copy's path; `SetManagedBulkPaused` resumes or pauses the folder.
  `ManagedBulkPending` lists the grants and assignments in `control`. The assignment receipt is
  offered as exact bytes and published under `records/assignments/`, which the outbound guard
  serves; nothing in `bulk` is ever served.
- **`OfficeBulk`** reads a grant under the administrator key of the phone's own vendor-verified
  profile, and the assignment receipt. `OfficePhoneIdentity.signAssignmentReceipt` signs
  nothing else.
- **`OfficeManualService`**, on the connection's poll: keeps a grant per publisher by sequence
  (a revocation replaces a grant and the grant never comes back); commits an assignment that
  verifies against the binding and moves its set forward, and receipts it *received*; asks the
  folder for exactly that archive; resumes the folder only on a direct route over a network the
  system does not call expensive. When the archive is ready it verifies the kept assignment
  again, runs the existing import preflight with the vendor's catalogue plus — only for a
  publisher under this organisation's own `org.` prefix — the live grant, hands the result to
  the existing installer, and receipts it *installed*. An archive nothing assigned is never
  asked for. A manual that cannot be installed is recorded once with a reason and gets no
  further receipt. Its record is `Application Support/AvenkinOffice/manuals.json`, apart from
  the installed vaults, so removing a manual does not let an old assignment bring it back.
- **Shown** under Field Assist settings, one line per assigned manual: *Waiting for the office
  to send it*, *Waiting for Wi-Fi*, *Still downloading*, *Ready*, or why it was not installed.

Exit, as tests (`OfficeManualServiceTests`): the fixture vault is assigned, verified under the
granted publisher, handed to the installer and receipted, with both golden receipts byte for
byte; while the folder is paused nothing is fetched; an archive with no assignment is never
asked for.

Choices made where the contract left room:

- **The installer is the existing one.** The service stops at the vault installer's own
  request; keeping the previous version of a vault until the new one is committed is that
  installer's behaviour, not something added here.
- **An install that fails is not retried.** It is recorded once; the office assigns again
  under a higher sequence.
- **"Metered" is the system's word.** A relayed route, or a network iOS calls expensive, keeps
  `bulk` paused. Nothing lets a person start it there yet.

**Phone half, second part — what a job names, as built (2026-10-05).**

- **The job file** (every build). `JobFileValidator` reads an attachment's `sha256`, `bytes`
  and `media_type` — all three or none, no digest twice, one of three types — and a `manuals`
  list of up to ten sets, in format 2 only; format 1 still refuses them. `JobNeeds` is what the
  job named. It is kept on the job ahead (`UpcomingJob.needs`) and on the job once started
  (`FieldSession.jobNeeds`). The review says which attachments follow from the office, which
  are only named, and which manuals it needs.
- **`OfficeJobAttachmentStore`** (opt-in build). The attachments wanted are those named by
  signed jobs this phone holds — ahead, or started and not finished — that are not here yet.
  `OfficeManualService` stays the one owner of the folder's list: it asks for them alongside
  the archives it wants, attachments first, and tells the store where each is. A file the
  folder took is checked again for size and digest, then kept as
  `Application Support/AvenkinOffice/job-attachments/<sha256>.<ext>`, out of backup. A file no
  held job names is removed on the next pass, and all of them when the phone leaves.
- **Shown on the job**, ahead and open, under *From the office*: each attachment *Ready* (it
  opens when tapped), *Still downloading*, *Waiting for Wi-Fi*, *Waiting for the office to
  send it*, *Not enough space on this phone* or *Too large to keep on this phone*; each manual
  set *Ready*, *On its way from the office* or *Not yet available*. In a build without the
  transport the names are shown and nothing is fetched.

As tests (`OfficeJobAttachmentTests`): the golden job's needs import, review and persist; the
closed forms are refused; the fixture attachment is asked for by digest and size, stays paused
on a route that does not allow it, arrives, is checked and opens, and goes when its job goes;
other bytes under the right name are never kept; an unsigned job fetches nothing.

Choices made where the contract left room:

- **Only a signed job fetches.** The contract says a job the phone holds; an unsigned format-2
  file is a claim, so it shows what it names and asks for nothing.
- **Kept while the job is ahead or open.** A finished job's attachments are removed; the
  record of the visit does not carry them.
- **A ceiling and a margin of the phone's own**: 50 MiB an attachment, 100 MiB left free.
- **A manual set is matched by its set identifier** in the phone's assignment record: installed
  is *ready*, committed is *on its way*, anything else *not yet available*.

**Still owed for P4:**

- An attachment from a real office to a physical phone.
- A person's explicit choice to download on a metered or relayed route.
- A free-space check before a manual archive is taken; attachments have one.
- The headless install test stops at the installer's request; the installer itself runs only
  in the app. A manual from a real office to a physical phone is owed.
- A revoked publisher's already-installed vaults are not yet flagged.

### P5 — Recorded jobs

Plan HE, unchanged; listed so the order is whole.

### P6 — Physical evidence

One phone, one office: join, a job and its receipt, a renewal after time away, a report and a
transcript back with the office switched off in between, a manual, a removal. Screen lock,
relaunch and a route change in the middle of each.

## What this plan does not do

- It does not make the transport part of the default build. That is a size, licence-notice and
  review decision taken when P0–P2 have run on a device.
- It promises no background delivery: a phone exchanges files when the app is allowed to run.
- It does not design the office side; requirements on the office are in the contracts.

## Decisions (Greig, 2026-10-04)

1. **Job attachments travel in `bulk`,** after the job. Manuals must be able to come with a job
   when the phone does not already hold them, so the `bulk` folder and manuals are brought
   forward (P4).
2. **Reports back (P2) come second,** ahead of check-in and renewal (P1).
3. **Job-file format 2 comes before P0's run on a physical phone** (P0b).
