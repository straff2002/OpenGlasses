# Plan HK — Controlled Document Revisions (no answer from a replaced manual without saying so)

**Status:** 📝 Drafted (not scheduled) 2026-10-03 — nothing implemented.
**Track:** Field Assist (B2B).
**Related:** Plan [ED](ED-vault-manual-retrieval.md) (manuals as a retrieved tier), Plan
[EK](EK-manual-structure-and-figures.md) (the manufacturer's original beside the text), Plan
[EG](EG-vault-packs.md) (pack versions and Update), Plan
[FS](FS-subscriber-vaults-and-vault-links.md) (vault archives and links), Plan
[FN](FN-vault-manual-removal.md) (removing a manual), Plan
[FX](FX-desktop-office-and-device-sync.md) (signed manual assignments from the office), Plan
[FO](FO-guided-job-flow-and-job-tab.md) (the job and its brief), Plan
[HD](HD-report-transcript-audience.md) (what a report carries), Plan
[CT](CT-org-configuration-profiles.md) (organisation policy), Plan
[HL](HL-revision-impact.md) (what a changed document touches — built on this plan).

---

## Trigger

Greig, 2026-10-03: organisations that build or service complex equipment run on one rule — everyone
works from the approved revision, and a replaced one is withdrawn everywhere it was sent. A field
assistant that answers from manuals has to keep that rule or it cannot be trusted with them.

## Outcome

- **Every manual and procedure has a revision** the technician can hear and the record can print:
  "RTU-500 Service Manual, revision C".
- **A replaced or withdrawn document never answers silently.** The technician is told, in one
  sentence, before the answer — or the answer is refused, if the organisation says so.
- **The record names the revision.** A citation in the work order and the JSON says which revision
  and which exact file it came from, so a reviewer a year later can tell what the technician was
  reading.
- **Nothing changes under an open job.** A replacement that arrives mid-job is announced and
  applied when the job ends, unless the technician asks for it now.

## What exists today (verified against main @ f2f49220)

- **A vault has a version; a document does not.** `VaultManifest.version` and `VaultPack.version`
  exist and drive EG's Update state. `VaultDocument` carries `file`, `title`, `kind`, `source` and
  `source_url` — no revision, no date, no link to what it replaced.
- **The ledger knows a document changed, and tells nobody.** `VaultDocumentLedger` keys every
  ingested document by content hash, and `plan(current:desired:)` re-ingests one whose hash
  differs. The old chunks go and the new ones arrive; the technician hears nothing, and a job
  already open keeps whatever it retrieved.
- **A citation is a string.** `SessionExport.Citation` records `source`, `claim`, `opened`,
  `origin` and `verified_against`. It does not record which revision or which bytes.
- **A procedure has a version nobody compares.** `Procedure.version` is decoded and printed; no
  code asks whether a newer one exists or whether a running procedure is the current one.
- **The office can assign a manual, not withdraw one.** FX's manual assignment authorises a
  particular publisher archive. There is no message that says "stop using this".
- **Removal is deliberately quiet.** FN lets a technician remove a manual, and
  `FieldSessionService` documents that removing a superseded manual must not end a job.

## Design

### 1 · Revision fields on what the vault declares

`VaultDocument` gains three optional, decode-if-present fields:

| Field | Meaning |
|---|---|
| `revision` | The publisher's own label, verbatim: `"C"`, `"2026-03"`, `"Rev 08"`. Never parsed or ordered. |
| `effective_from` | ISO date the revision took effect. Informational; spoken only on request. |
| `supersedes` | Content hash of the document this one replaces. Hashes, not labels, decide identity. |

A document with none of these behaves exactly as today. `Procedure` already has `version`; it gains
the same optional `supersedes` (the replaced procedure's content hash).

### 2 · Revision notices

A **revision notice** is a small signed statement about one document, identified by content hash:

- `superseded` — replaced by the document with this hash (and, for the technician, its title and
  revision label).
- `withdrawn` — must not be used; no replacement is named.

Each carries a reason (one line, shown and spoken), the time it was issued and who issued it.
Notices arrive two ways, and only these two:

1. **Inside a vault update** — the new manifest's `supersedes` field is an implicit notice against
   the old hash. No signature beyond the archive's own publisher signature is needed.
2. **From the office** — a signed message over the FX connection, verified exactly as a manual
   assignment is (organisation, office, enrolment, phone identity, sequence, digest). This is the
   only way to withdraw a document with no replacement.

Notices are stored in the vault's overlay directory as `_revisions.json`, beside `_documents.json`,
so they survive a baseline re-push. A notice against a hash this phone never held is kept (the
document may arrive later from an old archive) and bounded in count.

### 3 · One pure policy decides what happens

`DocumentRevisionPolicy.state(for: contentHash, notices:, installed:)` returns:

| State | Meaning | Retrieval |
|---|---|---|
| `current` | No notice against it | Answers as today |
| `supersededReplacementInstalled` | Replaced, and the replacement is on this phone | Old chunks are not retrieved |
| `supersededReplacementMissing` | Replaced, but the replacement has not arrived (offline, or on mobile data) | Answers, **prefaced** — or refused, by policy |
| `withdrawn` | Must not be used | Never answers; says so |

The preface is fixed app text, not model text: *"This is from revision B, which the office has
replaced. The new revision isn't on this phone yet."* A withdrawn document's refusal names the
document and the reason. An organisation key, `field.supersededManualPolicy` (`warn` — the default
— or `refuse`), lets an organisation turn the preface into a refusal; it is read through the
existing deny-by-default profile path.

The gate sits where the evidence gate already sits: passages from a non-current document are
dropped (or tagged for the preface) before they reach the prompt, so the model never sees text it
is not allowed to answer from.

### 4 · The record names the revision

`SessionExport.Citation` gains optional `revision` and `document_hash`. The work-order PDF prints
the revision beside the title; the JSON carries both. A citation made under a preface also records
`revision_state: "superseded"`, so a reviewer sees that the technician was told. Old exports decode
unchanged.

### 5 · Nothing changes under an open job

A notice that arrives while a job is open is **announced, not applied**: one earcon and one line at
the next quiet moment — *"The office has replaced the RTU-500 service manual. I'll switch to the
new revision when this job ends, or say 'use the new manual' now."* The session keeps a revision
pin (the set of content hashes it started with). Withdrawal is the exception: a withdrawn document
stops answering at once, because a person decided it was unsafe to use.

A running procedure is pinned the same way. A newer procedure is offered at the next start, never
swapped under a step.

### 6 · Where the technician sees it

- The manuals list shows the revision label under each title and a "Replaced" or "Withdrawn" mark.
- The job brief gains one line when it applies: "Manual updated since the last visit here."
- Asking "which revision is this?" reads the label, the effective date and where it came from.

## Phases

- **P0 — the model.** Manifest fields, `_revisions.json`, `DocumentRevisionPolicy`, the notice
  derived from `supersedes` in a vault update. Pure; no UI, no retrieval change.
- **P1 — the record.** Citation fields, PDF and JSON, the manuals-list label, "which revision is
  this?".
- **P2 — the gate.** Retrieval drops or tags non-current passages; the preface and the refusal; the
  session pin and the mid-job announcement; the organisation policy key.
- **P3 — the office notice.** The signed notice message and its fixtures in `Contracts/`, verified
  like a manual assignment. The office side is specified by the contract and built elsewhere.

## Tests

- A manifest without revision fields decodes and behaves as before.
- A vault update whose document names `supersedes` produces a `superseded` notice against exactly
  that hash and no other.
- The policy returns each of the four states for the fixtures that define them; a notice against an
  unknown hash changes nothing until that hash is installed.
- With `warn`, an answer drawn from a superseded document carries the preface and the citation
  records `revision_state`; with `refuse`, no passage from it reaches the prompt.
- A withdrawn document yields no passages, whatever the policy key says.
- A notice arriving during an open job leaves the session's retrieved set unchanged until the job
  ends or the technician asks; a withdrawal takes effect immediately.
- A citation exported before this plan decodes; one exported after it prints the revision.
- An office notice with a bad signature, a stale time, an unknown field or a wrong recipient is
  rejected and changes nothing.

## Out of scope

- Comparing two revisions and saying what changed (see Plan HL P3).
- Ordering revision labels. Publishers do not agree on a scheme; `supersedes` is the only order.
- Fetching a replacement on its own. Delivery stays with EG, FS and FX.
- Telling other phones. That is the office's job, through the notice.

## Open questions

1. Should `refuse` be the default for the Field Assist edition, with `warn` for solo use?
2. A solo technician has no office. Is a vault update the only source of notices for them, or
   should a publisher's catalogue be able to carry withdrawals too?
3. How long is a superseded document's text kept on the phone after its replacement is installed —
   deleted at once, or kept until every open job that pinned it has ended?
