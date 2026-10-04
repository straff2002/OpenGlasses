# Office report contract — draft v1 (messages, reference implementation and fixtures; no app uses it yet)

Drafted 2026-10-04 for Plan [HO](../docs/plans/HO-office-delivery-phone-half.md) P2. This is the
agreement between the phone app and Avenkin Office about how a technician's record — a work
record, a parts request, a later addendum — travels from an enrolled phone to its office with
its evidence, and how the office says how much of it has arrived. It is self-contained so it can
be carried into the office repository.

**It asserts nothing about the office app's internals.** Statements about the office are
requirements or marked *Assumption*.

**Built so far:** `Transport/mobile-core/officereport` implements every message here — signing,
the two-step signing a phone needs, the manifest's one spelling and each side's checks — and the
golden fixtures in §10. **Neither app uses any of it yet:** the phone transport publishes no
report, no Swift code calls it, and the phone's queue still sends records only to an HTTP
endpoint or by email.

**Builds on, unchanged:** the administrator-signed peer binding and the application keys it
names ([README](README.md), "Office authority and peer binding"), the
[managed office folders](office-folders.md) that carry every file here, and
[check-in and removal](office-check-in.md), which keep the binding current.

## 1. What this replaces, and what it does not

Today a record reaches an office in one of two ways: a person emails the report and its files,
or the phone posts the record's JSON to an organisation's HTTP endpoint, where an HTTP 200 is
taken as delivery and no file travels at all. Neither tells the phone that the office has the
record *and its evidence*.

Over the managed folders:

- the phone signs **what** it is sending — which record, at which revision, with exactly which
  bytes and which evidence;
- the office signs **how much of it** it has committed; and
- only the office's signed statement, never a finished transfer, counts as delivery.

It does not change what a work record contains, who may read a transcript (that rule is the
phone's, §6), or the endpoint and email paths, which stay as they are.

## 2. Signed bytes

The two signed messages are the JSON envelope the other contracts use: two standard-alphabet,
padded base64 strings, `payload` and `signature`. Ed25519 signs the UTF-8 bytes of the message's
domain, one zero byte, then the exact decoded payload bytes; nothing is re-encoded at
verification. Envelope and payload are closed, flat JSON objects: every listed field is present
exactly once; duplicate or unknown keys, nested values, booleans, nulls and fractional or
exponent numbers are refused, as is trailing data. A field with nothing to say is the empty
string, never absent.

Integers are at most 2^53 − 1; times are Unix UTC seconds. Identifiers are 1–80 ASCII letters,
digits, dot, underscore or hyphen, excluding `.` and `..`. A **digest** is the lower-case
hexadecimal SHA-256 of exact bytes; a **message digest** is the digest of an envelope as
published.

| Message | Domain | Signed by | Size cap |
|---|---|---|---|
| Report | `Avenkin.OfficeReport.v1` | Phone application key | 8,192 bytes |
| Receipt | `Avenkin.OfficeReportReceipt.v1` | Office application key | 8,192 bytes |

Each key is the one the current binding names, taken from the binding and never from the
message. A message carries no key of its own, and neither domain is accepted for the other
message.

**No generation.** A report and its receipt name the organisation, enrolment, office and phone
transport identity, and not the binding's generation. A renewal keeps every identity and both
application keys ([check-in](office-check-in.md) §6), so a report published before a renewal is
still the same file, verifies under the same key, and is receipted after it. A different office
has a different `officeID` and different folders; a record still owed is signed again for it.

## 3. The files

A report is flat, so the record and the list of evidence are separate files it names by digest —
the way a managed job names its job file.

**`records` (phone → office)**

| Path | Contents |
|---|---|
| `reports/<reportID>.envelope.json` | The signed report |
| `reports/<recordSHA256>.record.json` | The exact record bytes the report names |
| `reports/<manifestSHA256>.manifest.json` | The attachment manifest the report names |
| `attachments/<sha256>` | One attachment the manifest names |

**`control` (office → phone)**

| Path | Contents |
|---|---|
| `receipts/<reportID>.pending.envelope.json` | Receipt: evidence pending |
| `receipts/<reportID>.record.envelope.json` | Receipt: record accepted |
| `receipts/<reportID>.full.envelope.json` | Receipt: fully accepted |

`reportID` is the digest of the report's `operationID` (64 lower-case hexadecimal characters).
Every name, once published, always holds the same bytes: a later outcome is a new file, never a
rewritten one. A file under a content digest may be named by more than one report and is
published once.

## 4. The report (phone → office)

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.office-report` |
| `reportID` | The digest of `operationID`; as in the file's name |
| `operationID` | The phone's identifier for this send: its queued operation. New for every revision |
| `recordKind` | `workRecord`, `partsRequest` or `addendum` |
| `recordID` | What the record is about, stable across revisions: the job session for a work record or an addendum, the request for a parts request |
| `revision` | Positive, and higher for each later report of the same `recordKind` and `recordID` from this enrolment |
| `organizationID`, `enrolmentID`, `officeID`, `phoneTransportID` | The pairing it is sent under |
| `jobReference` | The job's reference as the technician knows it, or empty. Up to 120 printable ASCII characters that need no JSON escape. For a person; it decides nothing |
| `jobID`, `jobRevision` | The office's own identifier and revision of the job the record was written against, from the [format-2 job file](job-file.md) it was added from; empty and `0` for a job that began any other way. Both or neither |
| `recordSHA256`, `recordBytes` | The record file: 1 to 1,048,576 bytes |
| `manifestSHA256`, `manifestBytes` | The manifest file: at most 131,072 bytes |
| `transcript` | `attached`, `omitted` or `none` (§6) |
| `createdAt` | Phone clock, informational |

**The record is opaque here.** It is the bytes the phone's own record format produces — today
the work record's or the parts request's JSON — and this contract fixes only that they are the
bytes the report names. *Requirement on the office:* it parses a record only after §7's checks,
within its own limits, and treats every value in it as a technician's statement, not as an
instruction.

**Kinds.** A `workRecord` is the job's record. An `addendum` is the same job's record again,
sent after its report, carrying what was added since (today: a debrief) and the addendum
document as an attachment. A `partsRequest` is one request.

**Revisions.** The same job is sent more than once: at the end of the job, again when the
technician sends the report, again with an addendum. Each send is a new operation, a new
`reportID` and a higher `revision`. *Requirement on the office:* it keeps every revision it
accepted, shows the highest as current, and never lets a lower revision arriving later replace a
higher one. A second report at a revision the office already holds for that record, with other
bytes, is a conflict: it is refused and gets no receipt.

## 5. The manifest

The manifest is one JSON object with three members, in this order: `version` (`1`), `kind`
(`avenkin.office-report-manifest`) and `attachments`, an array of at most 256 objects. Each
attachment has exactly these members, in this order:

| Member | Meaning |
|---|---|
| `sha256`, `bytes` | The attachment's digest and size (at least 1 byte) |
| `role` | `workOrder`, `auditExport`, `transcript`, `photo`, `clip`, `clipPoster`, `signature` or `addendum` |
| `mediaType` | `application/pdf`, `application/json`, `image/jpeg`, `image/png`, `video/mp4` or `video/quicktime` |
| `name` | What to call it for a person: 1–120 ASCII letters, digits, dot, underscore or hyphen, not beginning with a dot. **It never selects a path** |
| `requirement` | `required` or `optional` |
| `audience` | `office` (the organisation's own eyes only) or `customer` (may be passed on to the customer the job was for) |

Attachments are in ascending order of `sha256`, so each digest appears once.

**One spelling.** A manifest is not signed; the report signs its digest. So that a digest names
one manifest, the bytes are canonical: members in the order above, no whitespace, integers in
plain decimal, and — because every string is drawn from an alphabet that needs no escape — no
escape sequences. A manifest that is not exactly the canonical bytes of a valid manifest is
refused. A report with no evidence names the empty manifest,
`{"version":1,"kind":"avenkin.office-report-manifest","attachments":[]}`.

**Required and optional** are the phone's statement of what the record needs to be whole. The
work-order document is required; whether photographs and clips are is the organisation's
content policy, applied on the phone. An optional attachment may never arrive — a clip too
large for the route, a phone that was replaced — and the record is still accepted (§7).

## 6. The transcript

Whether a transcript of the job leaves the phone, and to whom, is decided on the phone by its
existing rule: a report to the organisation's office carries the transcript unless the
organisation's signed profile says never; a report that might reach a customer never does.
Everything in these folders goes to the office and only to the office, so here:

- `attached` — the manifest has an attachment with role `transcript`. Its `audience` is always
  `office`; a manifest that gives a transcript the `customer` audience is refused.
- `omitted` — a transcript exists and the organisation's policy keeps it on the phone. The
  manifest has no `transcript` attachment.
- `none` — there is no transcript to send: a parts request, or a job with nothing said.

The report's `transcript` and the manifest must agree. *Requirement on the office:* an
attachment with audience `office` is never included in anything it sends on to a customer.

## 7. What the office does with a report

In this order, stopping at the first failure and committing nothing:

1. The report is signed by the phone application key **in the binding the office holds** for
   that enrolment, names that organisation, enrolment, office and transport identity, and its
   `reportID` is the digest of its `operationID` and the identifier in its file's name.
2. The record and manifest files are the size and digest the report names; the manifest is
   canonical and agrees with `transcript`. A companion that has not arrived yet waits; it is not
   a failure.
3. The enrolment has not been removed, and the revision is not below, or in conflict with, one
   the office already holds for that record (§4).
4. The record, the manifest and the report are committed durably to the office's own store.
5. Each attachment that has arrived and matches its size and digest is committed.
6. The office signs and publishes the receipt for where the report now stands (§8), and again,
   under the next name, each time more of it is committed.

The folder is a mailbox, not the record: nothing the office committed depends on the files
staying in the folder, and a file disappearing from it deletes nothing.

## 8. The receipt (office → phone)

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.office-report-receipt` |
| `reportID`, `reportSHA256` | The report, and the message digest of the envelope the office read |
| `recordSHA256`, `manifestSHA256` | Echoed from the report |
| `organizationID`, `enrolmentID`, `officeID`, `phoneTransportID` | Echoed. The phone refuses a receipt for any other identity |
| `outcome` | `evidencePending`, `recordAccepted` or `fullyAccepted` |
| `attachmentsCommitted`, `attachmentsOutstanding` | Counts over the manifest. They add up to its length |
| `receivedAt` | Office clock when this outcome was reached |

| Outcome | File | Means |
|---|---|---|
| `evidencePending` | `…pending.envelope.json` | The record and manifest are committed. At least one **required** attachment is not |
| `recordAccepted` | `…record.envelope.json` | The record, the manifest and every required attachment are committed. Only optional attachments are outstanding |
| `fullyAccepted` | `…full.envelope.json` | Everything the manifest names is committed. `attachmentsOutstanding` is 0 |

A report moves through them in that order and may skip any: a report with no attachments goes
straight to `fullyAccepted`. An outcome is never withdrawn.

**The phone** accepts a receipt only when it is signed by the office application key its
verified binding names, is for exactly the report it published — the identifier, the message
digest, the record and the manifest — names its own identities, and has counts that are
possible for that manifest. Then:

- `evidencePending` — the record is at the office. The phone shows the report as received with
  evidence still to go, and keeps publishing.
- `recordAccepted` — the record counts as **delivered**. Optional evidence keeps travelling
  while the phone has it.
- `fullyAccepted` — nothing more is owed for this report. The phone withdraws its files (§9).
  Erasing the phone's own copy of a record because an organisation's policy says to, on
  leaving or after delivery, happens only on this outcome.

**A lost receipt.** A receipt file that never reached the phone, or was lost with the phone's
state, is recovered without anything new being signed: the phone's report is still published,
with the same bytes, and the office's receipt for it is the same file. *Requirement on the
office:* it keeps each receipt it issued and publishes the same bytes again for a report it has
already receipted; it does not re-import the record.

**No refusal in v1.** A report the office does not accept gets no receipt. The phone sees a
report still waiting; the office says why on its own screen (§11.1).

## 9. Waiting, withdrawing and what is served

- **Waiting is not failing.** An office that is off, asleep or out of reach leaves the report
  published and the record queued. Nothing counts attempts against it, and a connection alone —
  or the engine reporting a file as synchronised — delivers nothing.
- **What the phone serves.** Only the exact files it has published and not withdrawn: a
  report's envelope, record and manifest, and the attachments its manifest names. Nothing it
  received, and no file under a temporary name.
- **Withdrawing.** The phone removes a report's files from `records` after `fullyAccepted`, or
  when it publishes a higher revision of the same record before the lower one was receipted. An
  attachment another published report still names stays. *Requirement on the office:* it
  removes a receipt from `control` once the report it answers has been withdrawn.
- **Order.** File arrival order means nothing. `revision` orders the reports of one record;
  nothing orders different records.
- **Each side uses its own clock.** `createdAt` and `receivedAt` are information for a screen
  and decide nothing. A report does not expire.
- **Malformed or refused input** is left where it is and recorded once with a bounded reason,
  as the folders contract says.

## 10. Fixtures

In `Contracts/fixtures/`, made by `officereport.Fixtures()` and kept current by that package's
tests, with the check-in fixtures' fictional office and phone keys
(`office-check-in-fixture-keys.json`) and the clock at 1800000000:

- `office-report-v1.json` — a work record at revision 1, written against job `job-2031` at its
  revision 2, transcript attached;
- `office-report-record-v1.json` — the fictional record bytes it names;
- `office-report-manifest-v1.json` — three attachments: a required work order, a required
  transcript for the office only, an optional photograph. The attachments themselves are not in
  the repository; their bytes are the public sentences in `fixtures.go`;
- `office-report-receipt-pending-v1.json`, `…-record-v1.json`, `…-full-v1.json` — the three
  receipts, for nothing, the two required attachments, and all three committed.

```
go -C Transport/mobile-core test -tags noassets ./officereport/
REPORT_WRITE_FIXTURES=1 go -C Transport/mobile-core test -tags noassets ./officereport/   # regenerate
```

Negative cases, covered in the Go tests and to be covered by each app's verifier: a report
signed by a key other than the binding's phone application key; a report for another
organisation, enrolment, office or phone; a `reportID` that is not its operation's digest; a
job identifier without a revision or a revision without an identifier; a
record or manifest that is not the size or digest named; a manifest that is not canonical, names
a digest twice, has a name that is a path, an unlisted role or media type, or a transcript for
the customer; a report and manifest that disagree about the transcript; a receipt signed by a
key other than the office application key; a receipt for another report, another report's bytes,
another record or manifest, or another phone; a receipt whose counts are not the manifest's, or
whose outcome its counts cannot have; each message under the other's domain; and extra, missing,
duplicate, nested and fractional fields.

## 11. Open points

1. **A refusal outcome.** A report the office will not accept — a revision conflict, a record it
   cannot parse, an attachment over its limit — leaves the phone waiting with nothing said.
   Whether v1 needs a signed refusal the phone can show is undecided.
2. **Which outcome releases the phone.** This draft treats `recordAccepted` as delivered and
   reserves erasure for `fullyAccepted`. If an organisation's optional evidence routinely never
   arrives, a phone leaving the organisation holds its records until its erase-by date instead.
3. **Records owed at removal.** A removed phone opens no further connection
   ([check-in](office-check-in.md) §8), so a report not receipted by then does not travel this
   way. Whether an orderly removal should wait for owed reports first is undecided.
4. **The record's own format has no version.** The work record and parts request are sent as the
   bytes the phone produces today, which carry no schema version. The office must read them
   tolerantly until they do.
5. **Which revision is the report.** A job's record is sent at the end of the job and again when
   the technician sends the report; nothing marks one as the one the technician meant. The
   office shows the highest revision.
6. **Large evidence.** A clip is an attachment like any other and travels in `records`. Whether
   large evidence wants its own pausable folder, as manuals have `bulk`, is unmeasured.
7. **Attachment bytes on the phone.** The work-order document is rendered when it is sent and
   photographs are stored without a digest, so the phone has to keep the exact bytes it named
   until they are receipted. That is the phone's to build; nothing here depends on how.
