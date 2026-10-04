# Managed office folders contract — draft v1 (design; `control` and `records` built for managed jobs and for check-in, renewal and removal, in the transport and the opt-in phone build)

Drafted 2026-10-04 for Plan [FX](../docs/plans/FX-desktop-office-and-device-sync.md). This is
the agreement between the phone app and Avenkin Office about the synchronised folders that
carry signed messages between one enrolled phone and its office: which folders exist, when,
what each side may put in them, what each side may serve from them, and what the names are. It
is self-contained so it can be carried into the office repository.

**It asserts nothing about the office app's internals.** Statements about the office are
requirements or marked *Assumption*. No fixture or code exists yet; where this says "fixture" it
names a file to be added to `Contracts/fixtures/`, with portable checks in `Contracts/tests/`.

**Built so far (2026-10-04), in the phone transport (`Transport/mobile-core`):**
`StartManagedOfficeFolders` opens the managed connection with the `control` and `records`
folders named as §2 says; managed jobs under `control/jobs/` are verified against the binding the
caller hands over, taken lowest sequence first, and committed to private storage; the receipt is
offered to the caller to sign and published at `records/receipts/<messageID>.envelope.json`; and
the outbound guard serves only receipts this phone published. **The opt-in office transport
build of the app now calls it** (Plan HO P0): `OfficePairingService.openFoldersWithApprovedOffice`
starts the folders with a binding it has verified at that moment and closes them if the approval
changes while they start; `OfficeManagedJobIntake` hands each committed job to the job-file
import and its review and signs the receipt with the phone application key. This is tested
against an in-memory stand-in for the transport, not yet on a physical phone against an office.
**Updates on a job** (Plan HO P3): the transport lists `control/updates/`, publishes the
phone's receipt at `records/updates/<updateID>.envelope.json` once the phone application key has
signed it, serves it, and lets it go once the office has taken the update away.
**Check-in, renewal and removal use the same two folders** (Plan HO P1): the transport reads
`control/checkin/` and `control/removal/`, publishes `records/checkin/<challengeID>.envelope.json`
and `records/removal/<removalID>.envelope.json` once the phone application key has signed them,
and the outbound guard serves those and published job receipts and nothing else. A check-in is
withdrawn — removed from `records` and from the outbound list — when its challenge expires, when
a later challenge is answered, or when the folders start under a newer generation. The binding
object the caller hands over now also names the profile, the administrator key and the digest
of the binding held; a caller that hands over the earlier seven-field form gets managed jobs
only. The default app build links no transport and opens no folder. `bulk`, and every other
path in §3, is not built.

**What this is not.** It is not a message format. Every file in these folders is defined by its
own contract — the [managed job](README.md), the [manual assignment](README.md), the
[recorded session](recorded-session.md), [team learning](team-learning.md) — and is verified by
that contract's rules whatever folder it arrived in. A folder grants nothing: a file is
authorised by its own signature and binding, never by where it was found. The Device Lab's
`avenkin-fx0-…` folders and the preview pairing are a separate feasibility protocol and are not
this contract.

## 1. When folders exist

- **None before a verified binding.** The managed connection that exists today is
  handshake-only: one pinned peer, no folder. That stays the state until both sides have
  rechecked the current profile, licence, lease and administrator-signed binding (FX "Phone
  enrolment and pairing", step 4).
- **Only for the bound pair.** Each folder is shared between exactly two devices: the phone's
  transport identity and the office's, as the binding names them. No introducer, no
  auto-accepted folder, no default folder, no folder shared with a second phone.
- **Gone when the binding is.** On revocation, a lapsed lease, removal of the enrolment, or
  replacement by another office, each side removes the peer from every managed folder and stops
  serving them. Records the phone has not had receipted stay in the phone's own queue, not in
  the folder, and are published again under a new binding. The one exception is an orderly
  removal: the office keeps `control`, holding only the removal, and `records` until the phone
  has acknowledged it or the last binding ends ([check-in contract](office-check-in.md) §8).
- A newer binding **generation** for the same office keeps the same folders. A different office
  has a different `officeID` and therefore different folders (§2).

## 2. The folders

Three per enrolment. Each has one direction; the engine type enforces it for writes and the
outbound guard (§5) for reads.

| Role | Carries | Phone | Office |
|---|---|---|---|
| `control` | Small signed messages from the office | receive-only | send-only |
| `records` | Signed messages and evidence from the phone | send-only | receive-only |
| `bulk` | Large immutable content the office has assigned | receive-only | send-only |

`bulk` is separate from `control` so that a paused or policy-deferred download never holds up a
job or a receipt, and so a phone can leave `bulk` paused on a metered network (§7).

**Folder identifier.** Both sides compute the same identifier and neither accepts one from the
other:

```
avenkin-<role>-<first 32 lowercase hex of SHA-256(
    "Avenkin.ManagedFolder.v1" 0x00 organizationID 0x00 enrolmentID 0x00 officeID 0x00 role )>
```

The identifier names nobody: it carries no organisation, technician or device name. `role` is
the lowercase word in the table. The folder label, where an engine shows one, is the role word
only.

## 3. What goes where

Paths are fixed names built from identifiers and digests the messages already carry. **A
peer-supplied name never selects a path**, and a file at any path not listed here is ignored:
never opened, never imported, never served, and counted for diagnostics.

**`control` (office → phone)**

| Path | Contents | Defined by |
|---|---|---|
| `jobs/<messageID>.envelope.json` | Managed-job envelope | Managed job transport reference |
| `jobs/<jobSHA256>.ogjob` | The exact job-file bytes that envelope names | same |
| `updates/<updateID>.envelope.json` | An update on a job the phone already has | [Job updates](job-updates.md) §3 |
| `assignments/<assignmentID>.envelope.json` | Manual assignment | Manual assignment contract |
| `publishers/<grantID>.envelope.json` | Administrator-signed grant of the organisation's own publishing key | [Bulk content](office-bulk.md) §3 |
| `receipts/<reportID>.pending.envelope.json`, `….record.envelope.json`, `….full.envelope.json` | The office's receipts for a report, one file per outcome | [Reports](office-reports.md) §8 |
| `recordings/<bundleID>.status.envelope.json` | Recording acknowledgement and status | Recorded session §6 |
| `learning/set.envelope.json` | The current learning set | Team learning §5 |
| `learning/status/<candidateID>-<revision>.envelope.json` | Candidate status | Team learning §4 |
| `checkin/<challengeID>.challenge.envelope.json` | Check-in challenge | [Check-in](office-check-in.md) §4.1 |
| `checkin/<challengeID>.result.envelope.json` | Check-in result, carrying the renewed binding | Check-in §4.3 |
| `removal/<removalID>.envelope.json` | Administrator-signed removal | Check-in §8 |

**`records` (phone → office)**

| Path | Contents | Defined by |
|---|---|---|
| `reports/<reportID>.envelope.json` | The signed report for one queued record; `reportID` is the SHA-256 of its operation identifier | [Reports](office-reports.md) §4 |
| `reports/<recordSHA256>.record.json` | The exact record bytes that report names | same |
| `reports/<manifestSHA256>.manifest.json` | The attachment manifest that report names | Reports §5 |
| `attachments/<sha256>` | Evidence named by a report's attachment manifest | same |
| `receipts/<messageID>.envelope.json` | The phone's receipt for a managed job | Managed job receipt |
| `updates/<updateID>.envelope.json` | The phone's receipt for a job update | [Job updates](job-updates.md) §6 |
| `assignments/<assignmentID>.received.envelope.json`, `….installed.envelope.json` | The phone's receipts for a manual assignment, one file per outcome | [Bulk content](office-bulk.md) §4 |
| `recordings/<bundleID>/…` | A recorded-session bundle, laid out as its contract says | Recorded session §3 |
| `learning/candidates/<candidateID>-<revision>.envelope.json` | A learning candidate | Team learning §3 |
| `checkin/<challengeID>.envelope.json` | The phone's check-in | Check-in §4.2 |
| `removal/<removalID>.envelope.json` | The phone's removal receipt | Check-in §8 |

**`bulk` (office → phone)**

| Path | Contents | Defined by |
|---|---|---|
| `vaults/<archiveSHA256>.zip` | A vault archive a manual assignment names | Manual assignment contract |
| `attachments/<sha256>` | A file a job this phone holds names by digest | [Bulk content](office-bulk.md) §5 |

Path rules: components are lowercase hexadecimal digests, the identifiers their contracts
define, or the fixed words above; at most four components; no component is `.`, `..` or empty;
no component begins with a dot. `learning/set.envelope.json` is the one path whose content
changes; every other path, once published, always holds the same bytes.

## 4. Publishing and taking in

- **Publish atomically.** The sender writes a file outside the folder, syncs it, and moves it
  into place complete. A reader never sees a partial file under a final name.
- **A published name is immutable** (with the one exception in §3). Sending the same message
  again produces the same file.
- **Take in by copy.** The receiver copies a file out of the folder into its own private
  staging, within the byte cap of the file's contract, before parsing it. It never parses in
  place, follows a link, or executes anything.
- **Verify, then commit, then acknowledge.** The file is verified by its own contract against
  the freshly rechecked binding, committed durably to the receiver's private store, and only
  then acknowledged with that contract's signed receipt or status. The engine reporting a file
  as synchronised is not delivery and produces no acknowledgement.
- **A companion file may arrive first or last.** An envelope whose companion (`.ogjob`, a vault
  archive, an attachment, a recording chunk) is not yet complete waits; it is not a failure.
- **The folder is a mailbox, not the record.** A sender removes a file only after the signed
  acknowledgement for it, or when the message has expired or been withdrawn by its own
  contract. A file disappearing from a folder never deletes anything the receiver has already
  committed.
- **Malformed or refused input** is left where it is, recorded once with a bounded reason, and
  not retried until its bytes change.

## 5. What each side may serve

A receive-only folder does not stop a peer from *requesting* bytes; the engine would answer.
Each side therefore has a mandatory outbound guard in front of the engine, and a build without
it does not ship.

- **The phone serves only from `records`,** and only the exact paths in its sealed outbound
  list: the files the app itself has published and not yet withdrawn. Every other request —
  another folder, an unlisted path, a temporary or partial file — is refused before any file is
  read. In particular the phone never serves a manual, a job or anything else it received.
- **The office serves only from that enrolment's `control` and `bulk`,** and only paths it
  published for that enrolment. *Assumption:* the office engine also holds other phones'
  folders; one phone's identity must be unable to list or fetch another's, and nothing outside
  the managed folders (the office's own data, keys or backups) is ever in an index a phone
  receives.

## 6. Order and what a sequence means

File arrival order means nothing. Each contract's own sequence or revision decides order:
out-of-order control messages are held or superseded exactly as that contract says. Transfers
are prioritised `control` and `records` messages first, then evidence and recordings, then
`bulk`.

## 7. Networks, pausing and space

- `control` and the message files of `records` are small and travel on any route the signed
  transport policy allows.
- `bulk`, recording media and large evidence follow the organisation's content and network
  policy and the phone's own setting; a phone may keep `bulk` paused, and neither side treats a
  paused or deferred transfer as an error. Starting a large transfer on a metered or relayed
  route is the person's explicit choice.
- Each side checks free space before taking a file in and reports "not enough space" as a
  state of its own; staging is kept so a transfer resumes.

## 8. Fixtures to add

`office-folders-v1.json`: folder identifiers for a fictional binding (three roles, and the same
enrolment under a second office); path cases that are accepted with the kind they resolve to;
path cases that are ignored (unknown folder word, a fifth component, an upper-case digest, a
leading dot, `..`, a temporary name); and outbound-guard cases (a listed `records` path served,
the same name in `control` refused, an unlisted `records` path refused, a temporary file
refused).

## 9. Open points

1. **Reports over the folder.** The signed report, its attachment manifest and the office's
   receipts have their contract ([office-reports.md](office-reports.md), draft v1). The phone
   transport publishes a report, its record, its manifest and its attachments under `records`,
   serves exactly those, and lists the office's receipts; the opt-in phone build sends job
   records and stock checks that way, and the office app reads none of it yet.
2. **The phone's receipt for an assignment** is specified
   ([bulk content](office-bulk.md) §4), with the organisation's own publisher and how a job
   names what follows it. The phone transport opens `bulk` — paused, receive-only, taking only
   what the app has asked for — and the opt-in phone build installs an assigned manual through
   it. Job attachments in `bulk` are not built, and the office side of `bulk` is not built.
3. **Deletion.** Whether receivers should also set the engine's ignore-deletes on their
   receive-only folders, or rely on §4's rule that a committed record is independent of the
   folder.
4. **Background execution.** Nothing here makes iOS run the engine in the background. A phone
   exchanges files when the app is allowed to run; both sides must show waiting as waiting.
5. **Scale.** Three folders per phone is simple and keeps indexes separate. An office with
   hundreds of phones holds hundreds of folders; whether that needs a different shape is
   unmeasured.
6. **Administrator overlay** (Plan FX control payloads) will take paths under `control` and
   `records` when its contract exists. Check-in, renewal and removal now have theirs
   ([office-check-in.md](office-check-in.md)) and the paths in §3, built on the phone side.
