# Bulk content contract — draft v1: manuals and job attachments (messages, fixtures, and the phone's half in the opt-in build)

Drafted 2026-10-05 for Plan [HO](../docs/plans/HO-office-delivery-phone-half.md) P4. This is the
agreement between the phone app and Avenkin Office about the large things an office sends a
phone: the organisation's own manuals, and the files that go with a job. It says who may publish
a manual for an organisation, how the phone says an assignment has arrived and is installed, how
a job names what follows it, and how the `bulk` folder is used. It is self-contained so it can
be carried into the office repository.

**It asserts nothing about the office app's internals.** Statements about the office are
requirements or marked *Assumption*.

**Built so far.** `Transport/mobile-core/officebulk` implements the publisher grant and the
assignment receipt — signing, the two-step signing a phone needs, and each side's checks —
`jobfile.ReadNeeds` reads what a job names, and the golden fixtures are in §9.

**The phone's half for manuals is built, in the opt-in office transport build only** (Plan
[HO](../docs/plans/HO-office-delivery-phone-half.md) P4, first part, 2026-10-05). The phone
transport opens the `bulk` folder paused and ignoring everything, takes only the files it has
been asked for and only as a checked private copy, lists the grants and assignments in
`control`, and publishes assignment receipts. In Swift, `OfficeBulk` is the verifier;
`OfficeManualService` keeps grants by sequence, commits an assignment that moves its set
forward, asks for exactly its archive, runs the existing import preflight with the
organisation's granted publisher, hands the result to the existing installer, and receipts
*received* and *installed*. That is tested headless against the golden fixtures and an
in-memory stand-in for the transport. **No manual has reached a physical phone from an office.**

**The phone's half for what a job names is built** (Plan HO P4, second part, 2026-10-05). In
every build the job-file validator reads the §5 members of a format-2 job and refuses them in
format 1, and the job keeps what it named — ahead, and once started. In the opt-in build
`OfficeJobAttachmentStore` asks `bulk` for the attachments of the **signed** jobs this phone
holds, through `OfficeManualService` (the one owner of the folder's list, attachments before
archives), checks each file's size and digest again, and keeps it under its digest and the
extension of its stated type. The job's screen says *ready*, *still downloading*, *waiting for
Wi-Fi*, *waiting for the office* or *not enough space* for each attachment, and *ready*, *on
its way* or *not yet available* for each manual set. Tested headless against the golden job and
the in-memory stand-in. **No attachment has reached a physical phone from an office.**

**Not built on the phone:** a person's choice to start `bulk` on a metered or relayed route,
and a free-space check before a manual archive. The default app build links no transport and
opens no `bulk` folder: there a job shows what it names and fetches nothing.

**Builds on, unchanged:** the [manual assignment](README.md) (which phone may receive which
archive), the vault archive and its publisher signature, the administrator key the vendor-signed
profile names, the [job file](job-file.md), and the [managed folders](office-folders.md).

## 1. What travels in `bulk`, and what authorises it

| Content | Path in `bulk` | What makes the phone take it |
|---|---|---|
| A vault archive | `vaults/<archiveSHA256>.zip` | A verified **assignment** naming exactly that archive for this phone, **and** the archive's own publisher signature |
| A job attachment | `attachments/<sha256>` | A **job this phone holds** naming exactly that digest and size |

Nothing else in `bulk` is opened. A file there grants nothing: the folder is how bytes arrive,
never why they are accepted. The phone serves nothing from `bulk`, ever
([folders](office-folders.md) §5).

A job is in `control` and is usable the moment it arrives. What it names follows in `bulk` and
is shown on the job as *still downloading*, *waiting for Wi-Fi* or *ready* — never as missing,
and never holding the job back.

## 2. Signed bytes

The same envelope and rules as the other contracts: `payload` and `signature`, standard padded
base64; Ed25519 over the UTF-8 bytes of the domain, one zero byte, then the exact decoded
payload bytes; closed, flat JSON objects with every listed field present exactly once.
Identifiers are 1–80 ASCII letters, digits, dot, underscore or hyphen, excluding `.` and `..`.

| Message | Domain | Signed by | Size cap |
|---|---|---|---|
| Publisher grant | `Avenkin.OrganisationPublisher.v1` | **Administrator key** | 4,096 bytes |
| Assignment receipt | `Avenkin.ManualAssignmentReceipt.v1` | Phone application key | 4,096 bytes |

## 3. An organisation's own publishing key

A vault archive is signed by its publisher. Until now a phone knew publishers only from the
vendor's signed catalogue, so an organisation could not publish manuals of its own. A **publisher
grant** is the administrator's statement that one key signs this organisation's vaults. The
chain is the one a peer binding already has: the vendor signs the profile, the profile names the
administrator key, the administrator signs the grant.

**Path:** `control/publishers/<grantID>.envelope.json`, `grantID` 32 lowercase hexadecimal
characters.

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.organisation-publisher` |
| `grantID` | As in the file's name |
| `organizationID`, `profileID` | The organisation, and the vendor-signed profile it is granted under |
| `publisherID` | `org.` followed by `organizationID`, alone or followed by a dot and a name of the organisation's own |
| `publisherName` | What the phone shows as the publisher: 1–120 printable ASCII characters that need no JSON escape |
| `publisherKey` | The Ed25519 public key, base64 |
| `sequence` | Positive, and higher for each later grant for the same `publisherID` |
| `status` | `active` or `revoked` |
| `issuedAt`, `expiresAt` | Valid while `issuedAt <= now < expiresAt`; at most 400 days, and never relied on past the profile's `policyExpiry` |

**The phone** accepts a grant only when it is signed by the administrator key from its own
vendor-verified profile and names its own organisation and profile. It keeps, per `publisherID`,
the highest `sequence` it has accepted and the digest of that payload: a higher sequence
replaces it, the same sequence with the same bytes changes nothing, a lower one is refused, and
other bytes at the same sequence are a conflict. A `revoked` grant is read whenever it arrives,
whatever its dates.

**What a grant allows, and nothing more.** The granted key verifies an archive **only** when a
verified assignment from this organisation's office names that archive and that `publisherID`
for this phone. The organisation's publisher is never added to the phone's general list of
publishers: an archive it signed that arrives any other way — a link, a file — is from an
unknown publisher, as before.

**The prefix is the boundary.** An organisation can grant only identifiers under its own
`org.<organizationID>`. *Requirement on the vendor:* its catalogue never lists a publisher whose
identifier begins `org.`. So a grant can never stand in for a catalogue publisher, and one
organisation's grant can never name another's.

**After a revocation** the phone installs nothing further from that publisher. A vault already
installed is flagged and kept — a technician may be standing in a plant room depending on it —
exactly as for a revoked catalogue publisher.

## 4. The assignment, and the phone's receipts

The office assigns an archive with the existing [manual assignment](README.md), unchanged, at
`control/assignments/<assignmentID>.envelope.json`. It is signed by the office application key
and names the phone, the set, the sequence, the archive's digest and size, and the
`publisherID`.

**The phone,** for an assignment that verifies against its freshly rechecked binding:

1. commits it durably and publishes the **received** receipt;
2. fetches `bulk/vaults/<archiveSHA256>.zip` when its network rule allows (§6);
3. checks the archive is exactly the bytes assigned, then the publisher's signature — under the
   vendor's catalogue, or under a live grant for that `publisherID` (§3) — then the archive's
   own contents, as the existing import does;
4. installs it, keeping the previous version of that vault until the new one is committed;
5. publishes the **installed** receipt.

A failure at 3 or 4 installs nothing and publishes nothing further; the archive is left where
it is and recorded once with a bounded reason. An assignment whose archive never arrives stays
at *received*, which is what the office sees.

**Receipt paths:** `records/assignments/<assignmentID>.received.envelope.json` and
`records/assignments/<assignmentID>.installed.envelope.json`. One file per outcome, because a
published name never changes.

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.manual-assignment-receipt` |
| `assignmentID`, `assignmentSHA256` | The assignment, and the SHA-256 of its decoded payload bytes |
| `organizationID`, `enrolmentID`, `officeID`, `generation` | The binding it was received under |
| `phoneTransportID` | This phone |
| `setID`, `sequence`, `archiveSHA256` | Echoed from the assignment |
| `outcome` | `received` or `installed` |
| `at` | Phone clock when that outcome was reached |

**The office** accepts a receipt only when it is signed by the phone application key in the
binding it holds and is for exactly the assignment it sent. It keeps the archive in `bulk` until
the *installed* receipt, or until the assignment expires or is superseded by a higher sequence
for the same set. *Installed* means the archive is on the phone and verified; it does not mean
anyone has opened a manual.

An assignment names the binding's `generation`, as a managed job does: one the phone has not
committed when a renewal arrives is refused under the new generation, and the office issues it
again.

## 5. What a job names

A [format-2 job](job-file.md) may name what follows it. Two additions to the job's members:

**`attachments`** — as before, up to 10 objects with a `name` and an optional `reference`. An
attachment that travels has three more members, all or none:

| Member | Meaning |
|---|---|
| `sha256` | The file's digest, 64 lowercase hexadecimal characters; no two attachments share one |
| `bytes` | Its size, a positive integer in plain decimal |
| `media_type` | `application/pdf`, `image/jpeg` or `image/png` |

An attachment without them is only named, as in format 1: the phone shows the name and fetches
nothing.

**`manuals`** — up to 10 objects, each exactly `{"set_id": "<identifier>"}`, no set twice. It
says the job needs that manual set.

**Naming is all a job does.** An attachment is accepted because a job this phone holds names
its exact bytes. A manual is never authorised by a job: *Requirement on the office:* when it
sends a job that names a set the phone does not hold, it also publishes an assignment for that
set, and the phone installs under the assignment and the publisher's signature, exactly as §4
says. A job that names a set nobody assigns shows that manual as *not yet available*.

The phone opens an attachment only after checking its size and digest, treats it as untrusted
content of the stated type, and never executes it. An attachment belongs to the job that named
it: it is removed with the job, and it is never sent anywhere by the phone.

As built on the phone:

- **Only a signed job fetches.** A format-2 file the organisation's key did not sign is shown
  with what it names, and asks the folder for nothing: its digest is only a claim.
- **"With the job" means while it is ahead or open.** An attachment is kept while a job that
  names it is ahead of the technician or started and not finished, and removed on the next
  pass after that; leaving the organisation removes them all.
- **The phone has its own ceiling**, 50 MiB an attachment, which no job raises, and it leaves
  100 MiB free: an attachment over either is shown as *too large* or *not enough space* and is
  not asked for.
- **The file's name on the phone is its digest** and the extension of its stated type. The
  job's `name` is shown and is never a path.

## 6. Networks, pausing and space

`bulk` is separate from `control` so that a large download never holds up a job or a receipt.

- On Wi-Fi to the office's own network, `bulk` transfers as soon as there is something to take.
- On a metered or relayed route `bulk` is **paused by default**. The phone shows what is
  waiting and how large it is; starting it there is the person's explicit choice, or the
  organisation's content policy.
- A paused or deferred transfer is a state, never an error, and never a receipt.
- The phone checks free space before taking a file and says "not enough space" as its own
  state. A partial transfer is kept so it resumes.
- Small things first: within `bulk`, a job's attachments before a manual archive.

## 7. Replay, order and removal

- **Order means nothing.** An archive may arrive before its assignment, a grant after the
  assignment that needs it, an attachment before its job. Each waits for what authorises it; a
  file nothing authorises is never opened.
- **A set only moves forward.** The phone keeps the highest assignment sequence per set, as the
  assignment contract says, and it keeps that mark after a vault is removed: a removed manual is
  not restored by an old assignment.
- **A technician may remove a manual** they were assigned. *Requirement on the office:* it does
  not treat that as a failure; a higher sequence installs again.
- **On removal of the phone** ([check-in](office-check-in.md) §8) the organisation's vaults are
  handled by the existing leaving rules, and nothing further is fetched.

## 8. Deliberately left out

1. **A refusal outcome.** An assignment the phone will not install gets no further receipt.
2. **Removing a manual from the office.** An assignment installs; nothing here uninstalls.
3. **Attachments from the phone to the office** travel as report evidence
   ([reports](office-reports.md)), not here.
4. **Deltas.** A new version of a vault is a whole new archive.
5. **A publisher shared between organisations.** Each organisation grants its own key.

## 9. Fixtures

In `Contracts/fixtures/`, made by `officebulk.Fixtures()` and `jobfile.Fixtures()` and kept
current by those packages' tests, with the check-in fixtures' fictional office, phone and
administrator keys, a fictional publishing key (seed: SHA-256 of
`Avenkin public fixture organisation publisher key v1`) and the clock at 1800000000:

- `office-publisher-grant-v1.json` — `org.fixture-organisation`, active, sequence 1;
- `office-bulk-vault-v1.zip` — a small fictional vault that key signed;
- `office-bulk-assignment-v1.json` — the office assigning it to the fixture phone;
- `office-bulk-assignment-receipt-received-v1.json`, `…-installed-v1.json`;
- `job-file-v2-needs.ogjob` — a job naming one attachment by digest (its bytes are the public
  sentence `Avenkin public fixture job attachment v1`), one by name only, and the manual set
  `fixture-manuals`.

```
go -C Transport/mobile-core test -tags noassets ./officebulk/ ./jobfile/
BULK_WRITE_FIXTURES=1 JOBFILE_WRITE_FIXTURES=1 go -C Transport/mobile-core test -tags noassets ./officebulk/ ./jobfile/   # regenerate
```

Negative cases, covered in the Go tests and, for the grant, the receipt and the assignment
intake, in the phone's tests (`OfficeBulkTests` in the portable checks, `OfficeManualServiceTests`
in the app's); the job-file cases are still to be covered on the phone: a grant
signed by the office application key or by the publisher itself; a grant for another
organisation or profile; a `publisherID` outside the organisation's own prefix, including one
that only looks like it; a revoked grant relied on, and an older grant after a revocation; other
bytes at a sequence already held; a receipt signed by another key, for another assignment,
phone, generation, set, sequence or archive; an attachment with a digest and no size or type, an
unlisted type, one digest twice, or a member not listed; a manual entry that names an archive or
a key; each message under another message's domain; and extra, missing, duplicate, nested and
fractional fields.

## 10. Open points

1. **Who decides "metered".** The phone knows whether a route is cellular or relayed; whether an
   organisation may force `bulk` over either is a content-policy field that does not exist yet.
2. **How large.** No cap on an attachment or an archive is set here beyond the assignment's own
   byte ceiling. The folder holds every phone's pending content on the office side.
3. **An attachment the technician should not keep** after the job: removal with the job is the
   rule here; an organisation that wants attachments erased sooner needs a field to say so.
4. **A grant's reach.** One key per organisation signs every vault it assigns. Narrowing a key
   to named vaults or sets is not designed.
