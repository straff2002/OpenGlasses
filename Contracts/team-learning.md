# Team-learning contract — draft v1 (design, nothing implemented)

Drafted 2026-10-04 for Plan [FP](../docs/plans/FP-team-learnings.md). This is the agreement
between the phone app and Avenkin Office about team learnings when an organisation runs an
office: what a phone sends when a technician files a finding, what the office answers, and how
the approved set comes back to every phone. It is self-contained so it can be carried into the
office repository.

**It asserts nothing about the office app's internals.** Statements about the office are
requirements or marked *Assumption*. No fixture, key or code exists yet; where this says
"fixture" it names a file to be added to `Contracts/fixtures/`, with portable checks in
`Contracts/tests/`, the same way the manual-assignment and managed-job contracts are held.

**Scope.** Plan FP's loop is capture → review → publish → retrieve. FP P1–P3 run it with no
office at all: a supervisor reviews on their own device and bundles travel by email or share
sheet, unsigned, because a crew has no key. This contract is the other case — the reviewer works
in Avenkin Office — where the administrator-signed binding already gives each side a key for the
other, so a candidate and a published set can be attributed as well as read (FP open question
5). It does not replace FP's unsigned bundle for organisations without an office.

## 1. Roles

| | Phone | Office |
|---|---|---|
| Captures a candidate during a job; redacts at capture; keeps it out of every prompt | ✔ | |
| Sends the candidate; shows the author what became of it | ✔ | |
| Verifies, stores, acknowledges | | ✔ |
| Hosts review: edit, approve, merge, reject, retract, supersede | | ✔ |
| Publishes the approved set | | ✔ |
| Ingests the set into the learnings namespace; cites entries as team learnings | ✔ | |

A candidate never answers anybody's question, on any device, until an approved entry made from
it arrives in a published set.

## 2. Trust and transport

- Messages travel over the managed connection Plan FX defines, between a phone and the one
  office named in its current administrator-signed binding. This contract adds no transport.
- *Assumption (FX, not built):* a phone → office managed folder for candidates, and the office →
  phone control direction for status and the published set.
- Authority is never taken from a message. The office verifies a candidate with the phone
  application key it holds from the binding; the phone verifies office messages with the office
  application key from the same binding. Both recheck the binding generation.
- A message that verifies is still **data, not instruction** (Plan R). Its text is shown and
  retrieved as literal text; nothing in it is executed, followed as a link or allowed to change
  a setting.

**Envelope, all three kinds.** Two base64 strings, `payload` and `signature`; Ed25519 over the
UTF-8 bytes of the kind's domain, one zero byte, then the exact decoded payload bytes. No JSON
re-encoding at verification. Closed objects: duplicate or unknown keys and non-integer numeric
spellings are refused. Integers are positive and ≤ 2^53 − 1. Identifiers named `…ID` below that
are not otherwise specified use the manual-assignment contract's identifier rule.

| Kind | Domain | Signed by | Envelope cap |
|---|---|---|---|
| Candidate | `Avenkin.LearningCandidate.v1` | Phone application key | 32 KiB |
| Candidate status | `Avenkin.LearningCandidateStatus.v1` | Office application key | 8 KiB |
| Learning set | `Avenkin.LearningSet.v1` | Office application key | 2 MiB |

## 3. Candidate (phone → office)

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.learning-candidate` |
| `candidateID` | 32 lowercase hex; stable across revisions of the same candidate |
| `revision` | Starts at 1; a higher revision replaces a lower one for the same `candidateID` |
| `withdrawn` | `true` when the author withdrew it; the text fields are then empty |
| `organizationID`, `enrolmentID`, `officeID`, `generation` | The binding this candidate is sent under |
| `jobSessionID`, `jobNumber?`, `taskID?` | The job, and the task, it was filed during |
| `createdAt` | Unix UTC seconds |
| `author` | The technician's display name as the phone holds it; 1–120 characters |
| `vaultID` | The vault active when it was filed |
| `modelToken?` | The equipment identity in force, resolved through the vault's model index |
| `spokenModel?` | What the technician called the machine when no identity was resolved |
| `finding` | What was worked out; 1–2,000 characters |
| `symptom?`, `fix?` | Up to 500 characters each |
| `evidence` | `{ pagesVerified: [string], citationsOpened: [string], readings: n, photos: n }` — names and counts only; no photo, reading value or nameplate text |
| `redactions` | Names of the redaction patterns that fired at capture, without the matched text |

Text fields are plain text: no control characters except a line feed inside `finding`. A
candidate carries no customer name, site address, location or transcript; the phone's capture
rule says so to the technician and review is where a slip is caught (§8).

The phone keeps a candidate until the office's `received` status for that `candidateID` and
`revision` arrives, and retries without limit while the office is unreachable; an absent office
is not a failed send.

## 4. Candidate status (office → phone)

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.learning-candidate-status` |
| `candidateID`, `revision` | The exact candidate this answers |
| `organizationID`, `enrolmentID`, `officeID`, `generation` | The binding |
| `status` | `received`, `approved`, `merged`, `not_taken_up` |
| `entryID?` | Present for `approved` and `merged`: the published entry it became or was merged into |
| `reason?` | Present for `not_taken_up`: the reviewer's words for the author, up to 500 characters |
| `issuedAt` | Unix UTC seconds |

- `received` is sent only after the candidate is committed durably at the office. A repeated or
  replayed candidate yields the same `received`.
- `approved`, `merged` and `not_taken_up` are final for that candidate. The author's session
  shows *filed*, *sent*, then *approved* or *not taken up* with the reason (FP §2).
- A status is not publication. An approved candidate answers nothing until its entry arrives in
  a learning set.

## 5. Learning set (office → phone)

The office publishes **the whole current set**, not a change list. A phone that applies set
*n* holds exactly what set *n* says, whatever it held before, so two phones that have applied
the same sequence are identical and a missed set costs nothing once a later one arrives.

| Field | Meaning |
|---|---|
| `version`, `kind` | `1`, `avenkin.learning-set` |
| `organizationID`, `officeID`, `generation` | The publishing office under the current binding |
| `sequence` | Increases with every published set; a phone refuses a set that is not newer than the one it holds |
| `issuedAt` | Unix UTC seconds |
| `entries[]` | Every approved entry, below |
| `retracted[]` | `{ entryID, retractedAt, reason }` for entries withdrawn after publication — kept so a phone can say why an answer it once gave is gone |

**Entry.**

| Field | Meaning |
|---|---|
| `entryID` | 32 lowercase hex; never reused |
| `subject` | `{ kind: "model", modelToken, manufacturer?, equipmentType? }` or `{ kind: "practice", topic }` |
| `vaultIDs` | The vaults whose answers may use this entry; empty means every vault of the organisation (§10.1) |
| `finding` | As approved — which may differ from the text as captured; 1–2,000 characters |
| `symptom?`, `fix?` | Up to 500 characters each |
| `approvedAt` | Unix UTC seconds |
| `approvedByRole` | The approver's role as the organisation names it, for the citation; 1–80 characters |
| `authorIsApprover` | `true` when the person who wrote it also approved it |
| `contradictsSafetyNote` | `true` when the reviewer confirmed, twice, an entry that departs from a safety note (§7.3) |
| `supersedes?` | The `entryID` this entry replaces |
| `candidateID?` | The candidate it came from, when it came from one |

**Site notes are not in the set.** What an organisation knows about a customer's site — access,
hazards, who to ask — names people and places. It reaches a technician only as notes on a job
for that site, through the job the office dispatches, never as a standing corpus on every phone.

## 6. What the phone does with a set

- Verify, check the binding and `sequence`, then replace the learnings namespace
  (`learning:<vaultId>` in FP §3) atomically: one document per entry for each vault it applies
  to; documents for entries no longer present are forgotten.
- An unrecognised `version` is refused whole, never applied in part.
- Published learnings stay readable on a lapsed licence (FP §5); a revoked binding stops new
  sets and leaves the held one in place until the organisation's data is removed.
- The candidate store, the namespace and the held set all join the subject-erasure walk.

## 7. Rules both sides compute the same way

Each rule gets a golden fixture; both sides must produce the same result.

### 7.1 Citation name

`Team learning · <subject> · <date> · approved by <role>` where `<subject>` is the entry's
`modelToken` or `topic`, `<date>` is `approvedAt` as `YYYY-MM-DD` in UTC, and `<role>` is
`approvedByRole`. This is the name the phone cites and the name the office shows beside the
entry, so a technician quoting an answer and a supervisor looking it up read the same words.

### 7.2 Model match

An entry applies to a session by **identity**: its `modelToken` equals the session's resolved
equipment token after trimming and case-folding. Prose is not scanned. An entry whose token the
target vault's model index does not know is flagged at review and is not published to that
vault.

### 7.3 Safety

An entry never overrides a safety note. The office flags an entry that collides with the
vault's safety file and publishes it only after a second confirmation, recorded as
`contradictsSafetyNote: true`. The phone's standing rule and disclosure (FP §5) apply to every
entry and are not relaxed by this flag; the flag exists so the answer can say the crew's finding
departs from the manual's safety text.

### 7.4 Text

Plain text; a line feed is allowed inside `finding` only. A message with any other control
character, or over a length limit, is refused whole. Neither side interprets the text as
markup.

## 8. Privacy duties

- The phone redacts at capture and tells the technician the standing rule. Redaction is a
  floor: it will not catch a customer's name.
- The office reviewer removes any customer, site or personal detail before approving. An
  approved entry is read on every phone in the organisation.
- The team-learning tool is unavailable in HIPAA mode (FP §1); a phone in that mode sends no
  candidates.
- Candidates and entries are internal to the organisation. Neither side puts one in a customer's
  work order or any customer-facing report. The job record notes that an observation was filed,
  and, when an answer rested on a learning alone, the entry's id and approver (FP §5).

## 9. Fixtures to add

`learning-candidate-v1.json`, `learning-candidate-status-v1.json`, `learning-set-v1.json`,
`learning-fixture-keys.json` (fictional keys, as the other fixture key files are), and
`learning-rules-v1.json` holding the §7 cases: citation names, model matches and misses, and
text that must be refused.

## 10. Open points

1. **One corpus per vault or per organisation** (FP open question 3). `vaultIDs` carries either
   answer; the default is the owner's to decide.
2. **How the reviewer's role is named** (FP open question 1). `approvedByRole` is free text set
   at the office. Whether the organisation profile should name the reviewer is undecided.
3. **Does an unapproved candidate help its own author?** FP's draft says no; this contract
   follows it.
4. **Expiry** (FP open question 6). Nothing here ages an entry out. A `lastConfirmedAt` on the
   entry would let both sides show how stale it is; left out until the owner decides.
5. **Set size.** A whole-set message is simple and convergent. At the 2 MiB cap it holds a few
   thousand entries; an organisation beyond that needs a chunked form like the recorded-session
   bundle.
6. **Organisations without an office** keep FP's unsigned reviewed bundle. Whether a phone
   should ever accept both routes at once is undecided; v1 assumes one or the other.
7. **Delta versus whole set.** FP P3's unsigned decisions bundle is applied as a delta (nothing
   absent is removed; only a retraction withdraws), while the learning set here replaces the
   namespace whole (§6). A phone on both routes would need a rule for which wins.
