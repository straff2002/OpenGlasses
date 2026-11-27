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
| `subject` | `{ kind: "model", modelToken, manufacturer?, equipmentType? }` or `{ kind: "practice", topic }`; amended (§11): or `{ kind: "symptom", equipmentType, phrase }` |
| `vaultIDs` | The vaults whose answers may use this entry; empty means every vault of the organisation (§10.1) |
| `finding` | As approved — which may differ from the text as captured; 1–2,000 characters |
| `symptom?`, `fix?` | Up to 500 characters each |
| `approvedAt` | Unix UTC seconds |
| `approvedByRole` | The approver's role as the organisation names it, for the citation; 1–80 characters |
| `authorIsApprover` | `true` when the person who wrote it also approved it |
| `contradictsSafetyNote` | `true` when the reviewer confirmed, twice, an entry that departs from a safety note (§7.3) |
| `supersedes?` | The `entryID` this entry replaces |
| `candidateID?` | The candidate it came from, when it came from one |
| `origin?` | Amended (§11): `spoken`, `report`, `reportReview` or `recollection`; absent reads as `spoken` |
| `faultCode?`, `tried?`, `outcome?` | Amended (§11): the fault code (1–40), what was checked (1–500) and how sure, in words (1–120) |
| `sourceJobIDs?`, `confirmedJobCount?` | Job identifiers only, and how many jobs it was filed on; absent for a `recollection` (read as 0) |

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

Amended (§11): an entry whose `origin` is `recollection` is cited
`Crew experience · <subject> · <date> · approved by <role>`, where `<subject>` is the `modelToken`,
or the `equipmentType` of a symptom subject.

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
   should ever accept both routes at once is undecided; v1 assumes one or the other. Amended (§12.4):
   one route per company, office, then portal, then reviewer device.
7. **Delta versus whole set.** FP P3's unsigned decisions bundle is applied as a delta (nothing
   absent is removed; only a retraction withdraws), while the learning set here replaces the
   namespace whole (§6). A phone on both routes would need a rule for which wins.

## 11. Amendment — crew experience (2026-11-25, Plan NF; additive to v1)

Plan [NF](../docs/plans/NF-crew-experience-sheet.md) takes Plan [IM](../docs/plans/IM-experience-recordings.md)'s
recollection origin and its fields and builds them first, for the company's crew experience sheet
([crew experience contract](crew-experience.md)). Every addition is optional: a set, bundle or file
without them reads exactly as before, and the entry fields are decoded with `decodeIfPresent` on the
phone. A set that carries a subject kind or origin the phone does not know is refused whole by name, as
any newer version is (§6).

- **Origin `recollection`.** Known before a recorded job confirmed it: a sheet row, or (Plan IM) an
  experience recording. It is bound to no job, so `sourceJobIDs` and `confirmedJobCount` are absent and
  `confirmedJobCount` reads as 0. When FP's merge later confirms one on a job, the count rises and the
  citation earns FP's stronger wording. It is worded as recalled, never as seen on a job.
- **Entry fields** `faultCode?` (1–40 characters: the code as the display shows it), `tried?` (1–500:
  what was checked or tried) and `outcome?` (1–120: how sure the crew is, in words, never a number).
  Plain text, no line feed (§7.4). The phone's document text for an entry gains `Fault code:`,
  `Checked:` and `How sure:` lines; an entry without them reads as before.
- **Symptom subject** `{ kind: "symptom", equipmentType, phrase }` (Plan IM decision 4): an equipment
  type from the vault's closed list, with the symptom phrase. It answers only within that equipment
  type. Its citation subject is the equipment type. FP's unsigned bundle (no office) does not carry it
  and refuses it by name.
- **Citation** (§7.1): `Crew experience · <subject> · <YYYY-MM-DD> · approved by <role>` for a
  `recollection`.
- **Lead-in**, when an answer rests on crew experience alone: *"From your company's experience (not
  the manufacturer's manual):"*.
- **A company without an office** receives crew experience as a sealed set on the company-vault
  catalog, bound to its `profileId` and one `vaultId`, under its own kind
  (`avenkin.crew-experience-set`) — the crew experience contract §6–7. No office key is needed.

What is built (NF P0, P1): the phone's `LearningEntry` and `LearningCandidate.Origin` carry all of this,
and the shared core writes it. The phone applies a crew-experience set from the company-vault catalog,
cites a `recollection` as `Crew experience` (`TeamLearningCitation`, `CitationLineParser`) and opens an
answer resting on it alone with its lead-in (`TeamLearningDisclosure`). Retrieval reads the symptom
subject since IM P0 (§13).


## 12. Amendment — the portal binding (2026-11-26, Plan NG; additive to v1)

Plan [NG](../docs/plans/NG-team-learnings-reviewed-in-the-portal.md). A company whose vaults come from
the licence portal and that runs no office reviews its crew's candidates in the portal. The phone sends
them over the **seat channel** (Plan JS P2: nonce-gated requests signed by the phone's own seat key, to
the origin of the licence's signed `profile` claim) rather than the managed connection of §2. Nothing
in §1–§11 changes for an office. The reference is
`Tools/LicenceIssuance/Sources/LicenceIssuance/SeatLearning.swift` (Foundation only, compiled into the
app as well) with the envelope check `SeatWire.openLearningEnvelope` and the join key
`SeatWire.learningJobSessionID` in `Seats.swift`. Golden fixtures: `fixtures/team-learning-portal-v1/`.

### 12.1 The portal binding

The candidate (§3) and its status (§4) carry, **in place of** `organizationID`, `enrolmentID`,
`officeID` and `generation`:

| Field | Meaning |
|---|---|
| `profileId` | The company profile the phone is enrolled in (a safe identifier, 1–80 of `A–Z a–z 0–9 - _ .`) |
| `seatID` | The seat the phone holds: its seat lease's `deviceKeyHash`, 64 lowercase hex |

and one field of §3 changes meaning: **`jobSessionID` is a join key, never the session id** (decision 3):
the first 32 lowercase hex characters of SHA-256 over `"openglasses.learning-job-session.v1\n"` ‖
`profileId` ‖ `"\n"` ‖ the session id, UTF-8. The same job gives the same key within one company and an
unrelated key in another. `jobNumber` goes as it is, so the administrator can find the job; `author` is
the technician's display name (decision 4). Evidence stays names and counts: no photo, reading value or
nameplate text (decision 5). A candidate carries no customer, site, location or transcript (§3, §8).

Limits, in Unicode scalars, with §7.4's text rule (no control character but a line feed inside
`finding`, no bidirectional control): `finding` 1–2,000 (empty in a withdrawal), `symptom`/`fix` up to
500, `author` 1–120, `jobNumber`/`taskID`/`modelToken` 1–80, `spokenModel` up to 500, at most 100 page
and 100 citation names of up to 300 each, at most 20 redaction names (safe identifiers). `candidateID`
and an `entryID` are 32 lowercase hex; integers are 1 to 2^53 − 1 (counts may be 0). A withdrawal
(`withdrawn: true`) has an empty `finding` and no `symptom` or `fix`. `SeatLearningCheck` is what both
sides hold a candidate and a status to; each refusal is named (`SeatLearningProblem`: the reason and the
field), and `negative-candidates-v1.json` / `negative-statuses-v1.json` pin them.

### 12.2 The seat actions

Two actions beside `claim`, `renew` and `release`, under the same origin. Each is the seat channel's
envelope `{ nonce, request, signature }`: `nonce` from `POST /seats/nonce`, `request` the request JSON
base64, `signature` ECDSA P-256 (DER, base64) by the phone's seat key over
`"openglasses.seat-request.v1\n"` ‖ action ‖ `"\n"` ‖ nonce ‖ `"\n"` ‖ the request bytes exactly as sent.
The action's name is inside the signature, so a candidate cannot be replayed as a status fetch. The
service opens the `lease` the request carries, finds the seat by its `deviceKeyHash` and verifies the
signature with that seat's key (as for a renewal). Replies are JSON, at most **8 KiB**, unsigned: data
for the author's job, never publication (§4) and never authority.

| Action | Request (JSON, cap) | Reply |
|---|---|---|
| `POST /seats/learning-candidate` | `{ lease, candidate }` — the candidate of §12.1 (**32 KiB**) | `{ status }`: the §4 status for the candidate and the revision the service now holds — `received`, or the decision if one was made; or `{ refusal }` |
| `POST /seats/learning-status` | `{ lease, after? }` (4 KiB) | `{ statuses: [ … ], next? }`: this seat's candidates' statuses only, ordered by `candidateID`, starting after `after`; `next` is where the following page starts, absent on the last; or `{ refusal }` |

- **Revisions** (`SeatLearningIntake.keep`). A higher revision replaces the held one; the same or a lower
  revision changes nothing. The reply names the revision held, so a repeated or replayed candidate yields
  the same `received`, and a retry that crossed a newer send never replaces it.
- **Paging** (`SeatLearningIntake.page`). At most 32 statuses a page, and fewer when the next would take
  the encoded reply past 8 KiB (one always fits). The phone stops after 64 pages in one fetch.
- **Received is durable.** `received` is answered only once the candidate is committed (§4).

**Refusals** (`SeatLearningRefusal`, unsigned like every seat refusal):

| Name | When | The phone |
|---|---|---|
| `badNonce` | the nonce was unknown, used or stale | asks for another nonce, once |
| `badRequest` | the envelope did not open, or the request did not decode or pass §12.1 | keeps the candidate queued and names it on the job |
| `tooLarge` | the request is over its cap | as above |
| `freed` | the lease's seat was freed, or lapsed unheard | as above; the seat check claims again on its own schedule |
| `licenceLapsed` | the profile's licence has run out | as above |
| `unknownProfile`, `notSeatChecked` | no such profile, or its licence counts no seats | as above |
| `routeOff` | the company does not review learnings in the portal (no company vaults, or the switch is off) | as above |
| `notIncluded` | the licence does not include team learnings | as above |

A refused candidate **stays queued**: an absent or refusing service is not a failed send (§3), and the
technician's job names the refusal until a send is received.

### 12.3 The phone

- A candidate (filed, amended or withdrawn) is queued for the portal; only its id and revision are in
  the queue, and the send reads the candidate as it then stands, so a newer revision supersedes a queued
  older one. A withdrawal of a candidate the portal never received is not sent. The queue retries without
  limit and counts no attempt while the service is out of reach or refuses.
- The candidate becomes `sent` only on the service's `received` for its revision (or a later one).
- After a foreground, a phone with candidates `sent` and not yet decided fetches the statuses, page by
  page. A status is applied only when it names this phone's `profileId` and `seatID` and passes §12.1:
  `received` changes nothing further; `approved`, `merged` and `not_taken_up` are final and reach the
  author's job with the entry id or the reason. A status is not publication: an approved entry answers
  only once it arrives in the vault's crew-experience set (crew experience contract §6), which NG adds
  `origin: spoken` entries to.
- Nothing is sent, or fetched, under HIPAA mode (§8), on a licence without team learnings or after it
  has lapsed, or without a live seat lease. A lapsed licence keeps what was published (§6).

### 12.4 Which route a company uses

One route per company, in this order (`SeatLearningRoute.choose`, pinned by `routes-v1.json`):

1. **Office** (Plan JL), when the phone holds an office binding;
2. **Portal** (this section), when the company has company vaults on the portal and the profile's
   `organizationTeamLearningsInPortal` is not `false` (a company-owned value the administrator may set;
   absent reads as on, decision 9);
3. **Reviewer device** (FP P3/P4), otherwise.

A phone never sends a candidate by two routes: on the portal route the FP bundle is not queued for the
organisation's endpoint, and on the other routes nothing goes to the portal.

### 12.5 Publishing an approved learning (2026-11-27, NG P0b)

What the administrator approves is published in the vault's crew-experience set (crew experience
contract §11), beside the sheet's rows, as an entry with `origin: spoken`, its `candidateID` and the jobs
it was filed on: `sourceJobIDs` are the §12.1 `jobSessionID` join keys, never a session id, and
`confirmedJobCount` counts them. It is cited `Team learning · …` (§7.1), not `Crew experience · …`, and the
phone reads it as a team learning (FP's lead-in). *Same as* folds a candidate into a published entry by
FP's merge rule, held in the shared core as `CrewExperienceMerge.merge(jobSessionID:into:)` (the
phone's `LearningReview.merge` calls it): a job already counted adds nothing; a sheet row merged with a
job becomes job-confirmed and stays a `recollection`. Builds 775–778 refuse a set holding a `spoken`
entry, so the service publishes one only once every seat held on the company reports build
`CrewExperienceSet.spokenEntriesMinAppBuild` (779) or later (`CrewExperienceSet.mayPublish(_:seatBuilds:)`,
`SeatPolicy.mayPublishCrewExperience`); until then the learning waits in the portal.

What is built (NG P0, P1, P0b): the shapes, checks, paging and route rule in the shared core; the phone's
seat actions, queue item, status fetch, job status line and route choice; the set's `spoken` origin and
fields, the merge rule and the older-phone gate in the core, and the phone citing a `spoken` entry as a
team learning (§12.5). Not built: the portal's endpoints, queue page and merge into the crew-experience
set (S1).

## 13. Amendment — experience recordings (2026-11-27, Plan IM P0; additive to v1)

Plan [IM](../docs/plans/IM-experience-recordings.md). A technician records what they already know, one
case per recording, and a candidate is drafted from part of it (IM P1–P3, not built). This section is
the shape that candidate travels in, the closed list a symptom subject names its equipment from, and
how the phone answers with both. Every addition is optional and encoded only when present: a
candidate, bundle, set or manifest without them is the bytes it was, and reads exactly as before.

**Candidate (§3)** gains three optional fields, plain text under §7.4 (no line feed):

| Field | Meaning |
|---|---|
| `tried?` | What was checked or tried on the way to the fix; up to 500 characters |
| `outcome?` | How sure the technician is, in their words ("worked once"), never a number; up to 120 characters, the entry's limit (§11), so an approval carries it as written |
| `evidence.recording?` | `{ recordingID, segmentStart, segmentEnd }`: the experience recording it was drafted from (32 lowercase hex) and the part of it, as whole seconds from the recording's start, `segmentStart..<segmentEnd`, with `0 ≤ segmentStart < segmentEnd ≤ 86,400` |

`recording` is a pointer, never the audio or its transcript, which stay where the recording is kept
(IM decision 2). A withdrawal (`withdrawn: true`) has no `tried` and no `outcome`, as it has no
`symptom` or `fix`. The phone redacts `tried` and `outcome` at capture and on intake, as it does the
other text fields. FP's unsigned bundle carries all three for candidates, and `tried`/`outcome` for an
entry (§11's limits: 1–500 and 1–120). The portal's candidate (§12.1) does not carry them yet: it gains
them with IM's delivery (P3).

**Approval.** An entry approved from a `recollection` candidate carries no `sourceJobIDs` and no
`confirmedJobCount` (§11); merged into an entry, a recollection confirms no job, so the count stays.

**Equipment types.** A vault's manifest may carry `equipment_types`, a closed list of names (each
1–80 characters, no control character, none listed twice as compared below, 1–200 names). A malformed
list refuses the manifest by name (`VaultPackRules.equipmentTypeIssues`, shared by the phone and the
licence service). Two spellings are one type when they are equal trimmed, with every run of
whitespace as one space, case-folded (`VaultPackRules.equipmentTypeKey`), and a subject is stored in
the list's own spelling. A symptom subject's `equipmentType` comes from that list: the phone's review
refuses one not on the list of every vault it is approved for, and a vault that declares a list holds
back a symptom entry of another type when the set is placed (as an unknown model is, §7.2). A vault
that declares no list takes the type its issuer checked against its own (the crew experience sheet,
crew experience contract §4.3). A company layer adds to the publisher's list; it never removes a type.

**Retrieval.** A symptom subject answers only within the turn's equipment type (decision 4). The type is
resolved, in order, from the vault's list named in the turn (whole words, any case, a plural `s`/`es`),
then named in the job's context, then the active unit's own types — what its approved, live model
entries say it is (`subject.equipmentType`, matched to the unit by identity, §7.2). A symptom entry of
another type is not retrieved at all. With no type resolved, it is treated as a model entry is with no
unit identified: nothing scopes it, and its document's first line names its equipment.

**Ranking** (decision 5). Among the learnings that clear the evidence floor, every learning seen on a job
(a `confirmedJobCount`, or any origin but `recollection`) ranks ahead of a recollection no job has
confirmed; each keeps its order otherwise, and manual passages keep their places.

**Lead-in** (decision 5). An answer resting on recollections alone opens with §11's crew experience
lead-in, *"From your company's experience (not the manufacturer's manual):"*: a recollection from a
recording is crew experience like a sheet row, so it is introduced by the same sentence. An answer
with a learning seen on a job among its learnings opens with FP's, with that learning's count.

**Refusal by name.** The bundle's version stays 1. An older phone meeting a candidate, entry or evidence
carrying a key it does not know refuses the whole bundle by that key's path (*"it carries
candidates[0].tried, which a team-learning file doesn't have"*), as it refuses any newer shape.

**Fixtures** (`fixtures/team-learning-v1/`): `candidates-four-origins-v1.json` (one candidate per
origin, the recollection with `tried`, `outcome` and `recording`), `candidates-pre-amendment-v1.json`
(an older bundle that must import unchanged), `decisions-four-origins-v1.json` (one entry per origin),
`decisions-symptom-subject-v1.json` (a symptom entry, which FP's bundle refuses at
`entries[0].subject.kind`), `negative-bundles-v1.json` (each refusal by case and path),
`manifest-with-equipment-types-v1.json`, `manifest-without-equipment-types-v1.json`,
`manifest-equipment-types-negative-v1.json` (each list refusal in its words) and
`equipment-type-turns-v1.json` (the turn's type, and what a symptom of each type does with it).

What is built (IM P0): all of the above on the phone, and the list's rules in the shared core. The
recorder (P1) and the drafting pass (P2, §13.1) are built on the phone. Not built: delivery to a
reviewer (P3).

### 13.1 The drafting pass (2026-11-27, Plan IM P2)

A recording's redacted transcript becomes drafted `recollection` candidates on a reviewer's device or
in the office's intake, on the organisation's own provider (IM decision 1). **Both run these rules from
the same schema and fixtures**, so a recording drafts to the same candidate wherever it is processed:
`fixtures/team-learning-v1/recollection-draft-schema-v1.json` (the schema) and
`recollection-drafts-v1.json` (ten scripted recollections with their segments, a model's answer per
segment and the drafts expected, then answers that must be refused). The phone's implementation is
`RecollectionSegmenter`, `RecollectionDraftRules`/`RecollectionDraftValidator` and `RecollectionDrafter`;
`tests/test_recollection_drafts.py` (standard library, `python3 -I`) is a second implementation held to
the same fixtures. A draft is not a candidate until a person reviews it (§1), and nothing here is sent.

**Offsets.** Every span is a half-open range of Unicode scalar offsets into the transcript
(`{ start, end }`), which is what a Python `str` indexes.

**Segments.** The transcript is split into sentences (after `.`, `!` or `?` followed by whitespace or the
end). A sentence that is or ends with the recorder's next-case marker ("that's one, next case", a bare
"next case") ends a case, and its words after the marker open the next; a finish marker ("that's all")
ends the transcript (`ExperienceRecordingMarkers`, IM P1). Within a case, a sentence naming exactly one of
the vault's models, after an earlier one named another, opens a new case. A segment runs from its first
sentence's first character to its last's last. Segmentation is the phone's; an intake may take the
segments from wherever it has the vault's model index, and is held to the fixture's segments.

**The extraction.** One schema-forced call per segment (Plan AD's structured path): a closed object of
eight fields, `model`, `equipmentType`, `symptom`, `findings`, `tried`, `fix`, `outcome`, `siteNote`, each
`{ text, quotes[] }` (at most 6 quotes): the field in the transcript's words, and the exact words it rests
on. Empty text means the transcript does not say. The limits are told to the model in each field's
description, not enforced by the schema.

**The rules, in order, per field** (fields in the order above):

1. The shape: exactly the eight keys, each exactly `text` (a string) and `quotes` (strings). Otherwise
   the answer is refused `malformed`.
2. The text is held to §7.4 (a line feed survives in `findings` only; any other control character, or a
   bidirectional control, refuses the answer `controlCharacter`). Empty after trimming: the field is
   absent, whatever its quotes.
3. Filled with no non-blank quote: refused `unsupported`. Each quote is found in the segment by
   comparing both lowercased with every run of characters that are not letters or digits (Unicode
   categories L and N) as one space, trimmed, on whole words; the span is from the first matched
   character's offset to just after the last's. A quote not found refuses the answer `quoteNotFound`.
4. **Support.** Every word of the text must be among its quotes' words, except one-character words and
   a short list of little words (`the`, `and`, `it`, `was`…, in the test), and allowing a plural or past
   tense (two letter-only words, the shorter at least three long, the longer the shorter plus `s`, `es`,
   `ed`, `d` or `ing`). When it is not, a name (`model`, `equipmentType`) refuses the answer
   `unsupported`; any other field becomes its quotes' own words, verbatim, joined by `" … "`, and is
   marked `verbatim`.
5. `equipmentType` must be on the vault's closed list (§13, compared by `equipmentTypeKey`) and is kept
   in the list's spelling. Not listed: held back `notListed` with the words said; no symptom subject is
   drafted from it.
6. Over its limit (in scalars: `model` and `equipmentType` 80, `symptom`, `tried`, `fix` 500, `findings`
   2,000, `outcome` 120; a site note has none): held back `overLimit` with `count` and `limit`. Never
   cut.

**The site** (IM decision 6). A learning field whose spans, filled or held back, overlap the site note's,
or whose words contain the site note's words, refuses the answer `siteInLearning`. The site note is a
separate draft, `{ segment, text, spans }`, for a site document (Plan HV), never part of a learning.

**The draft.** An answer with `symptom`, `findings` or `fix` filled or held back drafts
`{ segment, recording, fields, heldBack, modelToken?, spokenModel?, subject?, safetyTerms }`:

- `recording` is the candidate's evidence (§13): the recording's id and the segment as whole seconds,
  estimated because the recorder keeps no timings, `floor(start·d/n) ..< ceil(end·d/n)` capped at `d`
  and at least one second, for a transcript of `n` scalars and a duration of `d` seconds (at least 1).
- `modelToken` is the vault's model when the drafted model names exactly one; otherwise `spokenModel`
  carries it as said. `subject` is `{ kind: "model", modelToken, equipmentType? }`, else, with a listed
  type and a symptom, `{ kind: "symptom", equipmentType, phrase }` (the symptom), else absent.
- `safetyTerms` are what the team-learning safety check finds in the findings, symptom, fix and what was
  tried (§7.3): shown to the reviewer, never a refusal.
- Filed (IM P3), it is a `recollection` candidate whose `finding` is the findings, or failing them the
  fix, then the symptom.

An answer refused, or missing, drafts nothing for its segment, and the other segments are drafted as
usual. The refusal is reported by kind and field.
