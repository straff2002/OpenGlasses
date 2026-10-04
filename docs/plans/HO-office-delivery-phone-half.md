# Plan HO — Office Delivery on the Phone (jobs, updates, manuals out; reports, transcripts back)

**Status:** 📋 Planned 2026-10-04 — a build order, not a new design. Nothing in it is built beyond
what the table under *Where each flow stands* marks as existing.
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

One fact sits under every row: **no phone build has a managed folder.** The Go transport can open
the `control` and `records` folders, but no Swift code calls it, and the transport is only in the
opt-in `AVENKIN_OFFICE_TRANSPORT` build. A phone that has joined an office holds a pinned
connection with nothing on it.

| Flow | Contract | Go transport | Swift | Missing |
|---|---|---|---|---|
| Join an office by its code | v1, fixtures | built | built (opt-in build) | a run on a physical phone against the office |
| Stay joined: check-in and renewal | draft v1, fixtures | messages and the office key holder's operations; **not** the phone's folder handling | none | P1 below. Until then a binding ends 30 days after pairing and the lease `leaseDays` after it |
| Removal by the office | same contract | messages only | none | P1 |
| Job to the phone | managed job + receipt, fixtures | intake, durable commit, receipt offered for signing | verifier only; no caller | **P0** |
| Update or note on a job the phone holds | none (Plan HN) | none | none | HN's contract, then P3 |
| Attachments with a job | a job file names them, does not carry them | — | — | undecided: carried in `control`, or in `bulk` |
| Manual to the phone | assignment + preflight, fixtures | verifier; `bulk` folder not built | preflight to the vault installer | organisation publisher trust, the phone's assignment receipt, `bulk`, durable install state — P4 |
| Report and parts request to the office | **none for an office**: only the HTTP endpoint envelope and email | none | queue sends to an endpoint or by email | a signed report envelope, attachment manifest and office receipt — P2 |
| Transcript to the office | travels with the report, under HD's audience rule | — | — | P2 |
| Recorded job to the office | recorded-session draft, no fixtures | none | none | Plan HE |
| Team learning both ways | design only | none | none | its own plan |

What works today without any of it: a technician emails the report, the work-order PDF and the
transcript, and the office imports them by hand.

## Order

Each phase is one PR, pure core first, and ends at its exit test. A phase marked *contract first*
does not start in Swift until its contract and fixtures are merged in `Contracts/`.

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

### P3 — Updates and notes on a job (*contract first*, Plan HN)

HN owns the design. This phase is its message contract and the intake beside P0's: a signed
update on a job the phone holds, information only, shown when the technician opens the job.

### P4 — Manuals (*contract first* for two pieces)

- Trust for an organisation's own publishing key, reaching the phone through the vendor-rooted
  chain and accepted only for vaults that organisation's office assigned to its own phones.
- The phone's signed receipt for an assignment.
- The `bulk` folder in the transport, paused by default on a metered or relayed route; durable
  per-set high-water and install state; the previous vault kept until the new one is committed;
  the outbound guard proving no manual byte is ever served.

**Exit:** a fixture vault assigned, verified, installed and receipted in a headless test; a
paused or unassigned archive is not fetched.

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

## Decisions wanted

1. Whether job attachments travel in `control` (small, with the job) or `bulk` (pausable).
2. Whether P2 or P1 comes second if a pilot is shorter than 30 days. This plan puts P1 second:
   a phone that silently stops receiving is worse than a report that is emailed.
3. Job-file format 2 (an office-assigned job identifier and revision) before or after P0's
   device run.
