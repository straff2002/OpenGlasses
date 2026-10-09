# Plan FP — Team Learnings (what the organisation's technicians learn reaches every technician)

**Status:** 🚧 **P0 ✅ shipped 2026-10-09** — the inventory below (five corrections to this plan),
and `DeliveryRequest` now carries a `Payload` enum whose one case is `.workRecord(WorkRecord,
partsRequestIds:)`, so P3's bundle is a new case rather than a rewrite of the channels; no behaviour
change. **P1 ✅ shipped 2026-10-09** — `team_learning` (note / list / amend / withdraw) files a
`LearningCandidate` in the contract's §3 shape into its own `LearningCandidateStore`, bound to the
job, the machine, the running task and its evidence, redacted at capture, gated on the new
`.teamLearnings` capability and withheld under HIPAA; the turn that filed it is withheld from every
prompt and replaced by a fixed "filed, awaiting review" line, and the job record carries the
candidate's existence, never its words. **P2 ✅ shipped 2026-10-10** — review, publish and retrieve,
headless: `LearningReview` (a pure state machine) turns a candidate into a `LearningEntry` in the
contract's §5 shape (plus `origin`/`sourceJobIDs`/`confirmedJobCount`) kept in its own
`LearningEntryStore`; `LearningCorpus` publishes one single-chunk document per entry per vault under
`learning:<vaultId>`; one retriever factory on `FieldSessionService` serves all three retrieval sites
and tags every passage `.manual` or `.teamLearning`; a learning is never `.sufficient` alone — the
named `.teamLearningOnly` outcome opens with a lead-in the app composes — and the disclosure is held
in four places (lead-in, citation, badge flag, job log and record). The reviewer device is a
device-local setting for v1 (open question 1). **P3 ✅ shipped 2026-10-10** — bundle exchange,
headless: an unsigned `LearningBundle` (candidates field → reviewer; statuses, entries and
retractions reviewer → field) with a strict decoder that refuses the whole file by a named reason,
a pure `LearningBundleMerge` that converges whatever the order, a `LearningBundleIntake` that
imports candidates for review and stages decisions until each is accepted, the delivery-channel
and offline-queue routes, the vault-export artefact, the author's filed → sent → approved / not
taken up status on their own job, and the technician's name as a setting. P4 next; P5 unbuilt.
Drafted 2026-09-21; two owner decisions recorded the same
day: the reviewer is a supervisor back at base, and a learning may answer where the manual is silent
so long as it is clearly one (open questions 1 and 4). **Three more decided 2026-10-09** (see "Where a
learning comes from"): the completed job report is the first origin and the spoken note the second;
the office, not the phone, mines reports for candidates, with a person approving; and an entry
counts the jobs it was confirmed on so an answer can say "noted on three previous jobs".
**Office contract:** when the reviewer works in Avenkin Office, the candidate, its status and the
published set are specified in [`Contracts/team-learning.md`](../../Contracts/team-learning.md)
(draft v1, design only, 2026-10-04). P1–P3's unsigned bundle remains the route for an organisation
without an office.
**Origin:** A commercial partner reselling Field Assist to service companies asked for the thing a
vault cannot currently hold: not the manufacturer's book, but what *this* organisation's crew has
worked out about the machines in its territory. A technician who discovers that a particular board
fails a particular way tells whoever is standing next to them, and nobody else ever hears it.
**Priority:** P2 on the Field Assist commercial track — after a pilot proves the manual loop
(EJ/EK/EL/EM), because a learnings corpus with nothing to cite beside it is just a notes app.
**Surfaces:** one tool and a voice phrase during a job; a review queue on the phone; retrieval and
citations; the vault export and pack routes. No new backend.

---

## Where a learning comes from (decided 2026-10-09)

A conversation with an appliance-repair prospect sharpened the ask. Their technicians search the
web for fault codes and are mostly satisfied with the answers they get; the gap is **older
appliances that show no fault code and whose manuals are hard to find**. What they wanted was the
thing the crew's own completed jobs already contain: *on three previous jobs with these symptoms,
this repair fixed it* — linked to those jobs and clearly marked as the crew's experience rather than
the manufacturer's instruction, because circumstances differ. Three decisions follow.

1. **The completed job report is the first origin; the spoken note is the second.** Field Assist
   already produces the report, and a report carries the symptom, the equipment identity, the
   readings and pages verified, and the fix — everything §1's candidate wants, with a job to point
   back at. The `team_learning` tool stays: a technician who has worked something out should say so
   while still standing in front of it. But the loop no longer *depends* on anyone remembering to.
   The candidate shape in §1 and in the contract is unchanged; only its `origin` gains a case:
   `spoken` (the tool), `report` (cut from a report by a person — Office FX20.4 today), or
   `reportReview` (drafted by the office's review pass, below).
2. **The office mines reports, not the phone, and a person still approves.** A review pass at
   the office reads committed job reports and drafts candidates into the Learnings tab, grouped
   by model and symptom, for the supervisor to tidy and approve or discard. It is the office's
   phase (a successor to FX20 in the office repository), it is optional, it runs on the
   organisation's own provider credentials with the office's existing rule that what leaves the
   computer is shown first, and **nothing anywhere in this plan trains or fine-tunes a model** —
   a drafted candidate is text in a queue until a named person approves it, exactly as a spoken
   one is. The phone never runs this pass: it has no batch of reports to read and no reviewer to
   hand drafts to. Consequence for open question 2: still no — a report-derived draft helps its
   own author no more than a spoken one does.
3. **An entry counts the jobs it was confirmed on.** An approved entry carries `sourceJobIDs`
   (job identifiers only — never a customer, site or address) and `confirmedJobCount`; the office
   merges a new candidate that says what an approved entry already says into that entry and
   raises the count instead of publishing a duplicate. The citation stays
   "Team learning · <model> · <date> · approved by <role>", and the spoken lead-in may add
   "noted on <n> previous jobs" when the count is above one. "Resolved" is stronger than
   "noted": it needs the job's follow-up outcome (no call-back, or a later job on the same unit),
   which the office does not hold yet, so `confirmedJobCount` means *filed on*, and an
   `outcomeConfirmed` marker is reserved for when it does. A learning scoped to a symptom rather
   than a model, so a fault-code-less appliance can be matched by what it is doing, is open
   question 7.

The contract (`Contracts/team-learning.md`) gains `origin`, `sourceJobIDs?` and
`confirmedJobCount?` on the entry as a v1 amendment when its fixtures are cut; both are optional
so FX20.5a's provisional office code stays valid.

## Product promise

"Say what you worked out while you are still standing in front of it. Your supervisor back at base reads it, fixes the
wording and approves it. From then on every technician's answer can quote it — named as your crew's
finding, never mixed up with the manufacturer's book, and never allowed to outrank a safety note."

## Verified starting point (main @ build 410)

- **A vault has two tiers, and neither is safely writable from the field.** `VaultManifest.files` is
  core markdown loaded whole into the prompt every turn by `VaultPromptBuilder.promptContext`;
  `VaultManifest.documents` (`VaultDocument`, identified by its `file` name — there is no id) is
  chunked into `DocumentStore` under `DocumentStore.vaultNamespace(id)` = `"vault:<id>"` and
  retrieved per turn by `VaultRetriever`.
- **An "append to a vault file" pattern already exists, and copying it here would be a bug.**
  `NotesVaultTool` and `HealthVaultTool` call `VaultStore.append(_:entry:date:)`, which writes a
  timestamped `## <ISO>` section into the *overlay*. Overlay core files are read by
  `VaultStore.readAll()` and go straight into the system prompt — an unreviewed sentence written that
  way is being asserted to the model on the very next turn.
- **The core tier cannot absorb this anyway.** `VaultValidator.coreBudgetCharacters` is `32_768` and
  the Lennox example core is already 29,242 characters (EM P1). Separately, the equipment lookup
  returns whole `##` sections in file order and stops at three, so a growing learnings file would
  crowd a model's own section out of its own answer.
- **Citations are machine-attached, not recalled.** `VaultRetriever.Passage.citation` composes
  `documentName`, `page` and either `§section` or the figure name; with neither page nor section it
  is the document name alone. `RetrievalEvidencePolicy` decides `.sufficient` / `.insufficient`
  before the model sees anything, and `ModelScope` penalises a passage naming a model the session is
  not working on (EL).
- **A session already knows what evidence looks like.** `FieldSession.Evidence` carries `readings`,
  `photos`, `citationsOpened`, `pagesVerified` and (since GB P1) `pagesShown`; `FieldSession.Task`
  carries origin, status and its own `Evidence` — both declared in `WorkTask.swift`;
  `EquipmentIdentity` carries `modelToken`, `heading`, `file`, `source`, `recognisedAt`,
  `statedModel`, `vaultMatch`, and a `nameplateText` kept for audit and deliberately never put in a
  prompt. *(Corrected in P0.)* That last precedent is the
  one this plan needs most.
- **Delivery without anybody's server ships, and it is `WorkRecord`-shaped.** `DeliveryChannel`
  (email / messages / whatsapp / telegram / share sheet / endpoint), `DeliveryPolicy`,
  `ReportComposerAvailability`, `DeliveryOutcome` all work. `DeliveryRequest` held
  `let record: WorkRecord`; since P0 it holds a `Payload` (one case, `.workRecord`), so a second
  document kind is one new case. `EndpointSyncSink` is real and wired — `AppState.makeSyncSink()`
  builds `OfficeReportSink(fallback: EndpointSyncSink(fallback: LocalSyncSink()))` when the office
  transport is present, the endpoint sink alone otherwise *(corrected in P0)* — posting
  `QueuedOp.workRecord`/`.partsRequest` to an organisation's own HTTP endpoint with an
  `Idempotency-Key`; with no endpoint configured `LocalSyncSink` calls every op delivered. "No
  backend" is the default, not an absolute. The peer sink Plan T names waits on Plan BL, unstarted.
- **A pack cannot carry manuals, and its vault cannot have them removed.**
  `VaultPackCatalogService.installPack` refuses a pack whose `manifest.documents` is non-empty, and
  `VaultManualRemoval.eligibility` returns `.protectedPack` for any pack-installed vault. What a pack
  update *does* preserve it preserves by construction: `VaultImporter.installReporting` replaces the
  baseline wholesale but clears the overlay only when `isFirstBaseline`, so overlay edits, the
  `VaultDocumentLedger` and the removal journal all survive.
- **Redaction is narrower than its name.** `SecretPatterns` has eight secret patterns and exactly two
  PII patterns — an email address and a dash-grouped IRD number. It will not remove a customer's name
  or street address. `Config.hipaaDisabledTools` withholds `send_via`, `send_message` and three
  others from `NativeToolRegistry.tool(named:)` under `Config.hipaaMode`.
- **Tiering is ready and unenforced.** Gates ask a capability, not a tier (Plan FS):
  `FieldAssistEntitlement.shared.has(_:)` / `check(_:)` over `FieldAssistCapability`.
  `SessionExporter` asks `.auditedExport`; the document tier and custom vaults ask `.ownVaults`;
  `check(_:)` returns the reason a paywall needs. `check(atLeast:)` only describes the licence, and
  `isGranted(atLeast:)` does not exist *(corrected in P0)*. Seats are recorded, never enforced —
  there is no server to enforce them against.

## The loop

**Capture → review → publish → retrieve with attribution.** Each arrow is a deliberate stop. A
candidate is unreviewed text written by one person in a plant room; it never answers anybody's
question, including its own author's, until a named person has approved it.

### 1 · Capture

A `team_learning` native tool (`note` / `list` / `amend` / `withdraw`) and the phrase *"note this for
the team"*. `LearningCandidate` (`Codable`): id, `sessionId`, `jobReference`, the
`EquipmentIdentity` in force (or the spoken model token when none resolved), `symptom`, `finding`,
`fix`, `FieldSession.Evidence` reused rather than re-invented, `taskId`, author display name,
`createdAt`, and the `SecretPatterns.hits` that fired. *(Corrected in P1: the record's keys are the
contract's §3 names — `candidateID`, `jobSessionID`, `jobNumber`, `taskID`, `vaultID`, `spokenModel`
— with `origin`, `revision` and `status` beside them. It carries the identity's token, heading,
source and stated model, never the whole `EquipmentIdentity`, whose `nameplateText` stays on the
session. Evidence is copied from `FieldSession.Evidence` into the contract's shape — pages verified
and citations opened by name, readings and photos by count — not stored as the session type, which
holds reading ids and photo file names. The redaction names are the ones `SecretPatterns.redact`
returns while masking, so the stored text and the stored names cannot disagree.)* Three rules the
code enforces, not the model:

- Candidates live in their **own store** — `LearningCandidateStore`, JSON in the app container,
  registered in `SensitiveStore` so `DataStoreRegistryTests` keeps it honest. Never the vault
  overlay, never `DocumentStore`. A guard test asserts no candidate text can reach
  `VaultPromptBuilder.promptContext` or `FieldSessionService.promptContext(turn:)`. *(P1: the store
  is `learningCandidates` — third-party linkage, because a name slipped past capture is exactly what
  it can hold — walked by the subject erasure, protected, backup-excluded, capped at 500, and
  cleared when the phone leaves its organisation. The guard covers the turn that said the finding
  as well as the store: see the P1 bullet below.)*
- `SecretPatterns.redact` runs at capture and the tool reads the redacted text back. This is a floor,
  not a privacy control: it catches an email address and an IRD number and nothing else, so the tool
  also speaks the standing rule ("no customer names or addresses") and review is where a name
  actually gets caught.
- The tool self-gates on `Config.fieldAssistActive` at execute time like its siblings; the
  **entitlement** check — a new `FieldAssistCapability` case granted by team and enterprise
  licences — sits in the service layer, where `SessionExporter` and `VaultImporter` put theirs.
  `team_learning` joins `Config.hipaaDisabledTools` — a clinical site's "learning" is a patient note
  wearing a different hat. *(P1: `note` and `amend` are gated; `list` and `withdraw` are not —
  neither adds anything, and a technician on a lapsed licence can still take back what they said.)*

The candidate folds into `SessionExport` / `WorkRecord` like any other session artefact, so the
customer's job record shows that an observation was filed *and* that it was not yet in use.
*(Corrected in P1: the fold is a `LearningCandidateReference` — id, status, model token, date,
`in_use: false` — kept on the session (`FieldSession.teamLearnings`), so `WorkRecord` stays a pure
function of the session; and it is the **organisation's** job record, not the customer's. Contract
§8 keeps candidates out of every customer-facing report, so no customer summary or printed
work-order line carries it, and `SessionExporter.exportedRecord` drops it from a customer-audience
export.)*

### 2 · Review, with nobody's server

**Decided 2026-09-21: the reviewer is a supervisor (or whoever holds that job) back at base, not a
technician in the field.** So the loop has a direction: candidates travel *in* from the field phones
to the supervisor's device, and approved entries travel back *out* to every technician. For P1–P3 the
supervisor reviews in the app on their own iPhone or iPad, and both legs ride the delivery channels
that already ship. The organisation already puts Field Assist on that device under the same team
licence; the app already has a vault editor and a composer; and a Mac-side script would strand the
decision on one laptop, which is exactly the failure Plan EI diagnosed for licence minting.

Three consequences of putting the reviewer at base:

- **Capture and review are different devices by default.** A field phone files and sends; it does
  not show the review queue. The queue appears only on a device marked as a reviewer, so a technician
  cannot approve their own finding by accident. `LearningReview` refuses an approval whose approver
  is the entry's author unless the device is a reviewer device — the one-person shop still works, and
  the record says that author and approver were the same person.
- **Sending is part of capture, not an afterthought.** A candidate that never leaves the phone helps
  nobody, so filing one queues a bundle for the organisation's configured channel (`OfflineQueue`,
  a new `OpKind`), sent when the technician next has signal — the supervisor is not standing next to
  them. The session shows *filed*, *sent* and, when the outbound bundle arrives, *approved* or
  *not taken up* with the supervisor's reason, so the author hears what became of it.
- **The supervisor works at a desk, in batches.** Review is a list with equipment, symptom, fix,
  evidence and the author, sorted by model, with duplicates grouped — not a voice flow. A larger
  desk surface than a phone is a later question; nothing in P1–P3 depends on one. An organisation HTTP endpoint (`EndpointSyncSink`) is a P5 accelerator for customers who run
one; the BL bridge is a P5 successor, not a dependency.

`LearningReview` is a pure state machine: `candidate → approved | edited+approved | rejected |
merged(into:) | superseded(by:) | retracted(reason:)`. Approval records the approver's display name
and role, the timestamp, and the text *as approved* — which may differ from the text as captured, and
both are kept.

**A bundle from another phone is untrusted input.** There is no team key: the Ed25519 private key
behind `SkillPackSignature.productionPublicKeyBase64` is the vendor's and off-repo, so a service
company cannot sign anything. A `LearningBundle` arriving by email or AirDrop is validated
structurally, shown to the reviewer in full as literal text, and never applied without an explicit
approval per entry. Plan R's posture applies: it is data, not instruction. *(Corrected in P3: the two
directions are handled differently because they ask different things of the person receiving them.
A `candidates` bundle is a review queue, not a decision, so its candidates land straight in the
reviewer's `LearningCandidateStore` — `received`, origin kept, with an `importedFrom` note — and only
on a device marked as a reviewer's; approving one is `LearningReview`, exactly as for a local one,
author-as-approver rule included. A `decisions` bundle changes what answers questions, so it is
staged by `LearningBundleIntake` and nothing in it is applied until each entry, status or retraction
is accepted. "Sending is part of capture" is built for an organisation with an endpoint — filing,
amending or withdrawing queues the phone's candidates for it — and is the composer or share sheet
otherwise; the session shows* sent *only once a bundle has really left.)*

### 3 · Publish: a namespace beside the vault, not a file inside it

| Option | Verdict |
|---|---|
| A core file (`learnings.md` in `files`) | **No.** Every turn's prompt grows without bound against a 32,768-character budget already 90% spent, and the three-section lookup limit turns the crew's notes into a denial of service on the manufacturer's own tables. |
| A `VaultDocument` in the `documents` tier | **No.** `installPack` refuses a pack whose `documents` is non-empty and `VaultManualRemoval` refuses removal from a pack vault, so on the delivery route the partner most wants, a learning could be neither added nor retracted. Every edit would also be a manifest edit plus a ledger diff. |
| **A sibling namespace in `DocumentStore`** | **Yes.** |

`LearningCorpus` ingests **one document per approved entry** under `"learning:<vaultId>"`, with
`documentId` = the entry id and `name` = `"Team learning · <model token> · <approved date> · approved
by <role>"`. An entry is a few hundred characters, so `DocumentChunker`'s 700-character target makes
it one chunk, and `VaultRetriever.Passage.citation` — no page, no section — renders exactly that
name. The citation composer needs no change. *(Corrected in P2: `documents.id` is the table's
primary key, so one id cannot sit in two vaults' namespaces and an entry with empty `vaultIDs` is in
all of them; the document id is `<entryID>@<vaultId>`, the entry id read back as its first 32
characters. The chunker is bypassed — `DocumentStore.ingestWhole` writes exactly one chunk, so a
long finding is never split — and the document's text is a small artefact: `Model: <token>` or
`Practice: <topic>`, then the symptom, finding and fix.)*

The namespace earns its keep three ways: it sits outside the manifest, the baseline and the ledger,
so a pack update, a vault re-import and an FN manual removal all leave it alone; retraction is one
`DocumentStore.forget(documentId:inNamespace:)` rather than a manifest edit against protected pack
content; and **the namespace is the provenance**, so a team learning cannot be mistaken for OEM
evidence anywhere downstream. Three sites build a `VaultRetriever` with their own `QueryFunction` /
`TokenSearch` closures — `FieldSessionService.manualRetriever(store:)`, `ManualLookupTool` and
`EquipmentLookupTool.manualFallback` — so P2 gives them one shared factory on
`FieldSessionService` that queries and merges both namespaces, and `VaultRetriever` itself is
untouched *(corrected in P0)*. *(Corrected in P2: "untouched" was one step too far. The factory
tags each `DocumentStore.Passage` with its `source` and, for a learning, its entry's model token,
and the retriever carries `source` onto its own passage and scores a learning's model penalty by
that token instead of by its text — scoring by identity cannot happen anywhere else, because the
penalty is applied inside `retrieve`.)*

**Supersession borrows the shape Plan EN used for facts that change.** An entry is stamped
(`supersededAt`/`supersededBy`, or `retractedAt` + reason) and kept in `LearningEntryStore` *(corrected
in P2: approved entries have their own store, registered as `learningEntries`; candidates stay in
theirs)* as history, while its document leaves the retrieval namespace: the organisation keeps the record of what
it once believed — an auditor's question — without the assistant still saying it. Honest limit: a
phone that never receives the retracting bundle keeps answering from the old entry, exactly as it
would with a stale vault, and the review screen says so.

### 4 · Distribute

| Route | Reused | Built in P3 | Still missing |
|---|---|---|---|
| Bundle by email / Messages / share sheet | `DeliveryChannel`, `DeliveryPolicy`, `ReportComposerAvailability`, `DeliveryOutcome` (a hand-off is not a send) | `DeliveryRequest.Payload.learningBundle`; subject and bodies from counts, the text only in one JSON attachment (`team-learning-<direction>-<yyyyMMdd-HHmm>.json`, a protected staged export); receiving by opening that file from Mail, Messages, AirDrop or Files | a screen that composes and sends one (P4) |
| Offline queue to an organisation endpoint | `OfflineQueue`, `EndpointSyncSink`, `ConflictResolver` | `OpKind.teamLearning`, `QueuedOp.make(learningBundle:)`, in `EndpointSyncSink.handledKinds` with the direction in the envelope; filing queues the phone's candidates when an allowed endpoint exists | the endpoint answering with decisions (P5) |
| Vault export / import round trip | the `VaultExporter` folder shape | `learnings/team-learnings.json` (the vault's entries as a decisions bundle) in an export; the folder importer stages it | — ; `isExportable` stays false for packs, so a team on a pack vault moves learnings **only** by bundle |
| Signed pack update | `VaultPackManifest`, `SkillPackSignature`, `VaultPackCatalogService` | nothing | the pack format has no learnings slot; a signed `learnings.json` is P5, and is the vendor's or partner's route, never a crew's |

Merge semantics are `LearningBundleMerge`, pure: match on entry id; the later `approvedAt` wins; a
tombstone beats content whatever its timestamp; an unrecognised `schemaVersion` is refused whole
rather than partially applied; a duplicate finding from two phones surfaces as a merge candidate for
the reviewer instead of being silently deduplicated. *(Corrected in P3. **A decisions bundle is a
delta, not a whole set.** The office's learning set (contract §5–§6) replaces the namespace whole,
because it is signed, sequenced and from one office; an unsigned bundle arrives by hand, out of order
and possibly from more than one reviewer, so an entry absent from it cannot mean "withdrawn" — only a
retraction withdraws. Two consequences the code forced: at the same `approvedAt` the job lists join
and the larger count stands (an office merge raises the count without moving the approval time),
with any text difference settled by a fixed order of the wire form, so no tie depends on arrival
order; and a retraction for an entry the phone does not hold is kept as a tombstone in a small
ledger beside `LearningEntryStore`, so the content arriving later in an older bundle is stored
already retracted. Candidates match on `candidateID` + `revision`; a decided candidate keeps its
decision; a status is final once applied. **Ordering:** a decisions bundle older than one already
applied under the same organisation label (by `sequence` when both carry one, else `issuedAt`) is
refused whole as `reordered`; every decisions bundle a device composes is cumulative — every entry,
retraction and decision it holds — so refusing an older one costs nothing once a newer one arrives.
A candidates bundle is not ordered that way: many phones send under one label, and each candidate
carries its own revision.)*

**No signing, stated plainly** (P3). A crew cannot sign: the only key the app trusts for signed
content is the vendor's, whose private half is off-repo, and an organisation without an office holds
no key of its own. So `LearningBundle` carries no signature and the decoder does not look for one;
the signed route is the office contract (`Contracts/team-learning.md`), whose candidate, status and
learning-set envelopes wrap the same codable payloads this bundle carries.

### 5 · Trust rules at answer time

- **Two provenances, never one heap.** `VaultRetriever.Passage` gains
  `source: .manual | .teamLearning`, set from the namespace by the caller (not `provenance`: that
  name is taken by the recognised-from-scan closure — corrected in P0); the prompt block
  labels learnings and the spoken answer names them ("your crew noted, not in the manual").
- **A learning may answer where the manual is silent — as long as it is clear that it is one
  (decided 2026-09-21).** `RetrievalEvidencePolicy.decide` may return `.sufficient` on a
  `.teamLearning` passage only when a `.manual` passage also clears the floor, so EJ's gate keeps
  meaning "the manual covers this". When only a learning clears it, the outcome is a third, named
  result — `.teamLearningOnly` — not a quiet pass: the answer *opens* by saying the manual does not
  cover this and that what follows is the crew's own finding, then gives it. "Clear" is enforced in
  four places rather than left to the model's phrasing: the spoken lead-in is composed
  deterministically and prepended; the citation reads "Team learning · …", never a manual title; the
  phone and HUD surfaces badge the answer as a team learning; and the session log and `WorkRecord`
  record that the answer rested on a learning alone, with the entry's id and approver, so a job
  record never implies the manufacturer said it. `TeamLearningDisclosureTests` pins all four.
- **A learning never overrides a safety note.** A standing prompt rule beside the manifest's
  `prompt_rules`, plus a deterministic `LearningSafetyCheck` at review time that *surfaces* — never
  auto-rejects — a candidate colliding with the vault's safety core file, because "the manual says X
  but on this unit…" is precisely the knowledge worth capturing. Publishing one needs a second
  confirmation. *(P2: the rule is `VaultPromptBuilder.teamLearningRule`, added to the `RULES:` list
  only when the vault has published learnings, so a vault without them reads exactly as before; the
  safety core is every core file named for safety, the rule the prompt builder already uses.)*
- **Equipment scoping is exact, not textual.** An entry carries a `modelToken` resolved through
  `VaultModelIndex`, so `ModelScope` scores it by identity rather than by scanning prose; an entry
  filed against a model the vault does not know is flagged at review rather than published blind.
- **Gating and erasure.** The team-learning capability at capture, review, publish and bundle import;
  already-published learnings stay *readable* on a lapsed licence, following Plan FN's decision 5.
  *(P2: supersession and retraction are not gated — taking an answer out of service is always
  allowed, as P1's withdraw is — and HIPAA mode refuses review and publish and leaves the corpus
  unqueried.)*
  Nothing here needs `agentModeEnabled` until P5's endpoint/BL auto-publish, gated at the service
  layer. Both the candidate store and the corpus namespace join the `SubjectErasureCoordinator` walk.

## P0 inventory (2026-10-09)

Read off `main` at build 480. Every name below was opened, not recalled. Where it contradicts
"Verified starting point" or §1–§5, the earlier text has been corrected in place and the
correction is listed at the end of this section.

### Prompt context a Field Assist turn can see

- **`FieldSessionService.promptContext(turn:)`** is the one Field Assist builder. In order it
  appends `VaultPromptBuilder.promptContext(for:referenceByteLimit:turn:)` (manifest rules, the
  attribution line, then `VaultStore.readAll()` — every core file, overlay first, safety files
  never dropped by the byte bound); `EquipmentIdentity.promptBlock` (model token and heading,
  never `nameplateText`); `ProcedureRunner.promptContext()`; `continuityContext(turn:)`;
  `manualPassagesContext(turn:store:)` (the `MANUAL PASSAGES` block from `VaultRetriever.promptBlock`);
  and `pausedJobPromptNote`.
- **`continuityContext(turn:)` → `FieldSessionContextSnapshot.render(session:events:)`** renders
  every in-scope `.userMessage` log event as *"Technician report … (unverified transcript)"*, every
  `.captureRecordSaved` reading, each task's `completionNote`/`procedureOutcome`/`citation`, open
  tasks with their `safetyNote`, identity fields, unresolved escalations, and the job brief
  (`JobBriefContract.lines(site:faultReport:brief:)`). `field_session` *recall* reads the same events
  through `FieldSessionContextSnapshot.recall`. **Consequence for P1:** the spoken *"note this for the
  team — …"* is itself a `.userMessage` and reaches the snapshot whatever the candidate store does,
  and anything P1 writes into a task's `completionNote` or a log event's text would too. P1 has to
  decide whether the filing utterance is excluded from the snapshot or accepted as the technician's
  own words in their own conversation; the acceptance line "never quotes the candidate" depends on it.
- **Callers.** `LLMService.buildSystemPrompt` wraps the result in `<field_assist_context>` and
  `LLMService.refreshedFieldInstructions(_:turn:)` replaces it after every tool iteration — both pass
  the turn. `GeminiLiveSessionManager` and `OpenAIRealtimeSessionManager` call `promptContext()` with
  **no turn**, so `manualPassagesContext` returns nil there: on the live modes manuals (and, later,
  learnings) arrive only through the lookup tools.
- **Other blocks on a Field Assist turn.** `LLMService.debriefContext()` →
  `DebriefContract.block(job:record:)` quotes selected `WorkRecord` fields (equipment model, task
  titles, readings, sign-off) during a debrief; `LiveJobContract.block(session:)` feeds the live
  modes' job surface (`LiveJobBridge`, `JobSurfaceRefresh`); the *job notes* block
  (`ProjectMemoryFormatter.block` over `BrainStore.projectMemories(for:)`) when
  `Config.projectMemoryEnabled`. `ReadingCompanionService.promptContext(turn:)` and
  `ProjectContextService.promptContext()` sit beside them but read reading sessions and a project
  namespace's document count, not a vault. `SystemPromptBuilder` builds the tool list, routing rules
  and app guide only — it carries no vault content.
- **Tool results the model reads** are prompt context too: `ManualLookupTool`, `EquipmentLookupTool`
  (whole `##` core sections, `prefix(3)`, then `manualFallback`), `ManualFigureTool`.

P1's `TeamLearningPromptIsolationTests` therefore covers `VaultPromptBuilder.promptContext`,
`FieldSessionService.promptContext(turn:)` (which includes the snapshot), `DebriefContract.block`
and `LiveJobContract.block`, not only the first two.

### Queries against a vault namespace in `DocumentStore`

`DocumentStore.vaultNamespace(_:)` is `"vault:" + id` (`vaultNamespacePrefix`), with
`isVaultNamespace(_:)` beside it. Callers:

- **Three sites build a `VaultRetriever`, each with its own closures:**
  `FieldSessionService.manualRetriever(store:)` (the per-turn block), `ManualLookupTool.execute`
  (adds a `documentIds` filter), and `EquipmentLookupTool.manualFallback(query:ocrText:store:)`.
  Each wires `query:`, `tokenSearch:`, `provenance:` (recognised-from-scan), `availability:`
  (`VaultManualRemoval.availabilityCheck`), the session's `retrievalPolicy` and
  `retrievalModelScope`.
- **Direct reads that bypass the retriever:** `FieldSessionService.partsVerifier`
  (`passages(containingToken:namespace:limit:)`), `ManualFigureTool` (`passages(figure:…)`,
  `passages(onPage:…)`), and `documentCount(namespace:)` gates in `activeVaultHasManuals`,
  `manualPassagesContext`, `ManualFigureTool`, `ManualLookupTool`, `EquipmentLookupTool`.
- **Writers and removers:** `VaultImporter` ingests under the namespace and `clear(namespace:)`s it
  on uninstall; `VaultManualRemoval` forgets per document.
- **Unscoped readers a new namespace would leak into:** `DocumentsView` lists every namespace except
  `isVaultNamespace`; `ReadingStatsView` lists `documentStore.list()` unfiltered; `StudyService`
  resolves a document from `list()` by id or name. `DocumentRAGTool`, `BrainTool` and
  `ProjectContextService` are scoped to `"global"` or a project id and cannot reach `learning:`.
  **P2 must add a `learning:` predicate beside `isVaultNamespace` and use it in those three readers.**

### Writes to a vault overlay (`Documents/Vaults/{id}/`)

- `VaultStore.append(_:entry:date:)` — `NotesVaultTool.log` (the `notes` vault) and
  `HealthVaultTool` (the `health` vault). Core-file content: it is in the prompt on the next turn
  whenever that vault is the active one.
- `VaultStore.write(_:contents:)` — `VaultSingleFileEditor` (in `VaultFilesEditorView.swift`, behind
  both `VaultFilesEditorView` and the citation sheet `VaultFileCitationSheet`) and
  `HealthVaultFileEditor` (in `HealthVaultEditorView.swift`).
- Not prompt content: `VaultDocumentLedger.save(to:)` (`_documents.json`, via `VaultImporter`) and
  `VaultRemovalJournal.save(to:)` (`_removals.json`, via `VaultManualRemoval`).
  `ProcedureLibrary` and `CaptureFlowLibrary` read overlay `procedures/` and `flows/`; no in-app
  writer was found. `VaultImporter.installReporting` removes the overlay only when `isFirstBaseline`.

Nothing in FP writes here, and nothing should.

### `SensitiveStore` registration

`SensitiveStore` in `Services/Privacy/DataStoreRegistry.swift` is one case per store with a
`Record` (data class, subject linkage, protection, backup exclusion, retention, `deleteAll`,
`deleteSubject`, `owner`, `ownerPaths`, `location`). `DataStoreRegistryTests` enforces it by
scraping `OpenGlasses/Sources`: any file that calls `sqlite3_open`, writes into a container
directory (`.write(to:` / `createFile(atPath`), JSON-codes into `UserDefaults` or adds a Keychain item
must appear in some record's `ownerPaths` or in the test's reasoned `exempt` list. It also checks
that `ownerPaths` exist, that each named delete API is a `func` in its owner, and that
`docs/plans/ET-iso27701-privacy.md`'s generated matrix matches `SensitiveStore.markdownTable()` —
**a new case means regenerating that matrix** (`TEST_RUNNER_UPDATE_PLAN_DOCS=1`) in the same PR.
P1's `LearningCandidateStore` is a new case; the `learning:` corpus is already inside `.ragDocuments`
(`documents.sqlite`) and needs no case of its own.

### The erasure walk

`SubjectErasureCoordinator.order` walks derived stores before sources; `erase(_:now:recordInLedger:)`
switches on each `SensitiveStore` and returns one `ErasureReceipt`, with a `default` receipt of
*"not wired into the erasure walk"*. `SubjectErasureTests.testCoordinatorWalksEveryStoreTheRegistrySaysCanCarryASubject`
fails when a store with an available `deleteSubject`, or a `.thirdPartySubject` linkage, is missing
from `order`; `DataStoreRegistryTests.testEveryFileBackedStoreTheErasureWalkReachesIsExcludedFromBackup`
then requires `backupExcluded`. To join, a store needs: a case in `order`, a handle in
`SubjectErasureCoordinator.Stores`, a branch in `erase` (and in `eraseMemoryFact` if it can hold a
remembered fact), and wiring at **both** `Stores` constructions in `OpenGlassesApp.swift` — the
`memoryFacts` services and the launch-time `ErasureReplay` (only the latter runs `.person`/`.document`
subjects; `ErasureLedger` replays them when a store comes back). What already covers FP for free:
`eraseDocuments` searches every namespace for a person's name, so the `learning:` corpus is reached
by `.ragDocuments`; `eraseQueue` deletes any queued op whose payload contains the subject, so a
queued learning bundle is reached by `.offlineQueue`. Noted in passing: neither app construction sets
`Stores.vaultDirectories`, so the `.vaultLedger` step reports "no vault directory was supplied" on a
document erasure.

### The offline queue and its sinks

`OpKind` (`Services/Offline/QueuedOp.swift`): `logEntry`, `photoUpload`, `clipUpload`,
`llmGrounding`, `auditExport`, `captureRecord`, `workRecord`, `partsRequest`, `subjectErasure`.
`QueuedOp.make(workRecord:)` queues `WorkRecord.json` under the session id. `SyncEngine.flush()`
drains through one `SyncSink`; `AppState.makeSyncSink()` builds
`OfficeReportSink(fallback: EndpointSyncSink(fallback: LocalSyncSink()))` when the office transport
exists, else the endpoint sink alone. `EndpointSyncSink.handledKinds`, `OfficeReportSink.handledKinds`
and `QueuedRecordRows.kinds` are each `[.workRecord, .partsRequest]`; every other kind falls through
to `LocalSyncSink`, which calls it delivered. P3's `.teamLearning` has to be added to whichever of
those three sets should carry it, and `EndpointSyncSink.body(for:)` shapes its envelope.

### The entitlement gate

Gates ask a **capability**, not a tier (Plan FS): `FieldAssistEntitlement.shared.has(_:)` /
`check(_:)` over `FieldAssistCapability` (`bundledVaults`, `ownVaults`, `auditedExport`,
`orgConfiguration`, `everyVaultPack`). `SessionExporter` gates on `.auditedExport` (team and
enterprise licences); `VaultImporter` and `VaultRegistry` gate own vaults and manual indexing on
`.ownVaults` (team, enterprise, or a subscription). `check(atLeast:)` survives but describes the
licence for the entitlement screen — "no gate asks it" — and `isGranted(atLeast:)` does not exist.
FP's gate is therefore a new `FieldAssistCapability` case (e.g. `.teamLearnings`) granted by the
team and enterprise licences in `capabilities(for:)`.

### HIPAA withholding

`Config.hipaaDisabledTools` is `web_search`, `send_message`, `send_via`, `openclaw_skills`,
`reading_session`. Under `Config.hipaaMode`, `NativeToolRegistry.tool(named:)` returns nil for them
and `toolNames` drops them; the schema list (`ToolCallModels`) and the Siri catalogue read the same
set. Adding `team_learning` to the set is all P1 needs.

### `SecretPatterns`

Confirmed: eight secret patterns (`openai_key`, `github_token`, `slack_token`, `google_api_key`,
`aws_access_key_id`, `jwt`, `bearer_token`, `private_key_block`) and two PII patterns (`email`,
`nz_ird`). `redact(_:placeholder:)` returns the masked text and the names that fired;
`hits(in:)` the names alone.

### Shapes P1 reuses

- `FieldSession.Task` and `FieldSession.Evidence` are declared in `FieldAssist/WorkTask.swift`, as an
  extension of `FieldSession`. `Evidence` has `readings` (capture-record ids), `photos` (file names),
  `citationsOpened`, `pagesVerified` and `pagesShown` (put on screen, never verified). A task carries
  its own `evidence`; with no task running, evidence lands on `FieldSession.jobEvidence`.
- `EquipmentIdentity` carries `modelToken`, `heading`, `file`, `source`, `recognisedAt`,
  `nameplateText` (audit only, never in a prompt), `statedModel` and `vaultMatch`. A session can
  cover several units (`visitedUnits`, `continuityScope`), so "the identity in force" is the active
  one at filing time.
- `WorkRecord` flattens equipment into `WorkRecord.Equipment`, whose `model` is the **stated** model,
  not `modelToken` — a report-origin candidate must take its identity from the session, or match
  through `VaultModelIndex`, never from that string. It also carries `tasks`, `jobEvidence`,
  `faultReport`, `site` (a customer address) and `debriefs`.
- `SessionExport` holds `workRecord: WorkRecord?`; `SessionExporter.buildExport` assembles it.

### The `DeliveryRequest` seam (shipped in P0)

`DeliveryRequest` carried `let record: WorkRecord` and `let partsRequestIds`. Every reader was
checked: the composer (`ReportComposerModel`) and `presentDelivery`'s channel switch read only the
envelope (subject, bodies, attachments, recipients, clip plan); `FieldSessionService.completeDelivery`
reads `sessionId` and `partsRequestIds`; `JobSendService.owns(_:)` reads `sessionId`; the record
itself was read in exactly three places in `OpenGlassesApp.swift` — the two unattended-route enqueues
and the share-sheet rebuild of an office report. Now `DeliveryRequest.Payload` is an enum with one
case, `.workRecord(WorkRecord, partsRequestIds:)`, answering `sessionId`, `jobReference`,
`partsRequestIds` and `queuedOp()`. Both enqueues call `request.payload.queuedOp()`; the rebuild
pattern-matches the report case. `record`, `partsRequestIds` and the old `init(…record:…)` remain
as accessors, so every other call site is unchanged. P3 adds a `.learningBundle` case and its
`queuedOp()` branch; it then makes `record` optional (or removes it), and only report code reads
it. `DeliveryRequest.confirmation` still says "Job report"; a bundle needs its own sentence.

### Corrections made to this plan

1. **Tier gate** (starting point, §1, §5): `isGranted(atLeast: .team)` → a `FieldAssistCapability`
   checked with `has(_:)`/`check(_:)`; `SessionExporter` asks `.auditedExport`, `VaultImporter`
   `.ownVaults`.
2. **Sink chain** (starting point): the live chain starts at `OfficeReportSink` when the office
   transport is present; `DeliveryRequest` is no longer bound to `WorkRecord` (this phase).
3. **Where retrieval is wired** (§3): not one place — three `VaultRetriever` constructions plus two
   direct readers. P2 adds one shared factory (on `FieldSessionService`) that all three use, rather
   than merging namespaces in `manualRetriever(store:)` alone.
4. **Name collision** (§5): `VaultRetriever` already has a `provenance` member (the
   recognised-from-scan closure behind `Passage.recognisedFromScan`/`provenanceNote`). §5's passage
   field for manual-versus-learning is renamed `source` (`.manual | .teamLearning`).
5. **Shapes** (starting point): `Task`/`Evidence` live in `WorkTask.swift`; `Evidence` has
   `pagesShown`; `EquipmentIdentity` also has `recognisedAt`, `statedModel`, `vaultMatch`.

## Phases (one PR each)

- **P0 — inventory and seams.** ✅ 2026-10-09. Every site that assembles prompt context, queries a vault namespace,
  or can write to a vault overlay, plus the `SensitiveStore` and erasure-walk registration points.
  Output: that inventory in this doc, and the `DeliveryRequest` generalisation with no behaviour
  change.
- **P1 — capture core, headless.** ✅ 2026-10-09. `LearningCandidate`, `LearningCandidateStore`, `team_learning`,
  evidence binding to the active task and session, the redaction pass, the gates, the session-export
  fold. Tests are the gate: `TeamLearningCaptureTests` (voice verbs, a candidate bound to a session
  with no active task, amend and withdraw, old sessions decode), `TeamLearningRedactionTests` (what
  fires and what provably does not — a customer name survives redaction and the test says so),
  `TeamLearningPromptIsolationTests` (no candidate text reaches either prompt builder).
  **What shipped** (`Services/FieldAssist/TeamLearning/`, `NativeTools/TeamLearningTool.swift`):
  - *The candidate.* `LearningCandidate` with `origin` (`spoken` | `report` | `reportReview`; the
    phone files only `spoken`, the other two decode for later bundles), `revision`, `status`
    (`filed`, `withdrawn`, and the office's `sent`/`received`/`approved`/`merged`/`not_taken_up`
    for later), the contract's field names, and `LearningCandidateText` enforcing the contract's
    text rules at capture: normalise (tab → space, CR/CRLF → LF, LF kept inside `finding` only),
    refuse any other control character and the bidirectional overrides with the reason, redact with
    `SecretPatterns.redact`, then measure the redacted text in Unicode scalars — `finding` 1–2,000,
    `symptom`/`fix` ≤ 500, `author` 1–120 — refusing over-length with the count and the limit
    rather than truncating. `withdraw` keeps the record with `withdrawn` and the text fields
    emptied, as the contract carries it. `amend` replaces the fields said and keeps the rest,
    raises the revision and redacts again; "the last one", an empty id, a full id or an unambiguous
    prefix of four or more characters (`list` reads six) all resolve.
  - *The binding* (`LearningCandidateService`): the active session and job number, the identity in
    force (or the model as spoken when none was resolved), the running task, and a copy of that
    task's evidence — or the job's when no task is running — as names and counts.
  - *The gate.* `FieldAssistCapability.teamLearnings`, granted by team and enterprise licences and
    not by a subscription. The tool checks `Config.fieldAssistActive`; the service checks the
    capability and speaks the `check(_:)` reason (`FieldAssistPaywallCopy.teamLearnings*`, licence
    entry, never purchase). HIPAA: `team_learning` is in `Config.hipaaDisabledTools`. Also in
    `FieldToolProfile.names` (offered during a job) and `OfflineToolPolicy` (`.local`).
  - *The filing utterance.* The turn that said the finding is logged as a `.userMessage` before the
    tool runs (Direct mode logs at the top of `LLMService.sendMessage`), and an append-only log
    cannot unsay it — so it is **withheld, not deleted**. Filing (and amending) writes a dedicated
    `team_learning_filed` / `team_learning_amended` event whose payload lists the source ids of the
    turns it withholds; `FieldSessionContextSnapshot` (and so `field_session recall`) skips those
    turns and renders the event as one fixed line — *"A team-learning candidate was filed (awaiting
    review; not evidence)"* — with no candidate text. Which turn: on the Direct path
    `FieldSessionService.turnSourceID` names the turn in flight (set by `LLMService` for the length
    of a turn), so that id is withheld exactly, before or after it is logged. On the live modes a
    transcript gets its id when it lands, which can be on either side of the tool call, so the
    technician lines of the 15 seconds before the filing are withheld and the next one to land in
    the 15 seconds after it is tagged withheld as it is written — over-withholding a neighbour
    rather than leaking the finding; the neighbour stays in the log and the snapshot already tells
    the model not to infer absence. The audit log, the office transcript and the conversation thread
    keep the words: they are records of what was said, internal to the organisation, and not prompt
    builders. (Honest limit: the live conversation the technician is in still holds what they just
    said, as any conversation does.)
  - *The phrase.* There is a deterministic phrase router (Tier 0, `ConversationClassifier`), so
    *"note this for the team …"* (and "note that / note / log this / log that for the team") opening
    an utterance with at least three words after it routes straight to `team_learning note` with the
    rest as the finding, **verbatim** — the technician's words, not a model's paraphrase — and a
    Tier-0 turn is never written to the job's log at all; it runs under a `tier0-` turn id that
    withholds nothing else. A bare phrase, or the words inside a sentence, reach the model, which
    routes by the tool's description (which names the phrases); that is also the route on the live
    modes.
  - *The author.* Nothing in the app holds a technician's display name — no setting, licence field,
    organisation profile key or office binding — so P1 uses the device's name
    (`UIDevice.current.name`), which on iOS 16+ is the generic model name ("iPhone") without the
    user-assigned-device-name entitlement. ~~A technician-name setting, or the name from the
    organisation's enrolment, is owed before P3 sends anything.~~ *(Closed in P3:
    `Config.technicianDisplayName`, with the device name as the fallback — see the P3 bullet.)*
  - *The fold.* `FieldSession.teamLearnings` (optional, absent when none) holds a
    `LearningCandidateReference` per candidate, updated on the job it was filed on even after that
    job ended; `WorkRecord.teamLearnings` (`team_learnings`, absent when none) carries it; it is in
    no `summaryLines`, no `customerSummaryLines` and no email body, and a customer-audience export
    leaves it out. Older sessions, records and exports decode unchanged.
  - *The store* joins the registry (`learningCandidates`, ET matrix regenerated) and the subject
    erasure walk (a case in `order`, a handle in `Stores`, a branch in `erase`, wired at both
    `Stores` constructions in `OpenGlassesApp.swift`), and is cleared on organisation departure.
- **P2 — review, publish and retrieve, headless.** `LearningReview`, `LearningCorpus` ingest and
  retract, `origin`/`sourceJobIDs`/`confirmedJobCount` on the approved entry with the "noted on
  <n> previous jobs" lead-in, the artefact renderer and citation name, `source` on the passage, the evidence-gate
  rule, `ModelScope` by identity, the prompt rules, `LearningSafetyCheck`. Tests:
  `TeamLearningReviewTests`, `TeamLearningRetrievalTests` (a learning alone never yields
  `.sufficient` and instead yields `.teamLearningOnly`; a learning beside a manual passage does; the
  citation head is exact), `TeamLearningDisclosureTests` (lead-in, citation, badge flag and the
  work-record line all present on a learning-only answer), a review state machine that refuses
  author-as-approver off a reviewer device,
  `TeamLearningSupersessionTests` (stamped and kept, gone from the namespace, replay idempotent).
  ✅ 2026-10-10. **What shipped** (`Services/FieldAssist/TeamLearning/`):
  - *The entry.* `LearningEntry` carries the contract's §5 names — `entryID`, `subject` (`{kind: "model",
    modelToken, manufacturer?, equipmentType?}` or `{kind: "practice", topic}`), `vaultIDs` (empty =
    every vault), `finding`/`symptom`/`fix`, `approvedAt` (whole seconds), `approvedByRole` (1–80),
    `authorIsApprover`, `contradictsSafetyNote`, `supersedes`, `candidateID` — and the amendment's
    `origin`, `sourceJobIDs`, `confirmedJobCount`; beside them, as phone-side history only, the
    approver's name, the text as captured when it was edited, and the supersession and retraction
    stamps. `TeamLearningCitation` composes the §7.1 name byte for byte, the date in UTC.
  - *Review.* `LearningReview` is pure: `candidate → approved | editedAndApproved | rejected(reason) |
    merged(into:)`, `approved → superseded(by:) | retracted(reason:)`, everything else refused by name,
    and the transition that reached a final state replayed returns it unchanged. Approval runs the
    contract's text rules over the text as approved, records name, role and time, keeps both texts
    when they differ, defaults the subject to the resolved model (then the model as spoken; a
    candidate with neither needs one named) and the scope to the vault it was filed in.
    `LearningReviewService` is the thin layer over the stores and the corpus.
  - *Reviewer device (open question 1, decided for v1).* `Config.teamLearningReviewerDevice`, a
    device-local Bool, off by default, declared as `SettingKey.teamLearningReviewerDevice` — a ceiling
    an organisation profile may pin **off** and lock. `LearningReview` refuses an approval (or a merge)
    whose approver is the candidate's author, by display name folded for case and spacing, unless the
    device is a reviewer device; when it allows it, `authorIsApprover` is true. No screen sets it; P4
    shows the queue only there.
  - *Merge (decision 3).* `merge(candidate, into: entryID)` adds the candidate's job to `sourceJobIDs`
    and raises `confirmedJobCount` — a job already counted adds nothing — and creates no entry; the
    citation and the corpus document do not change, only the lead-in's count. A merged-into entry
    must be live. `mergeSuggestions` offers live entries with the same subject by identity and the
    same finding once case, diacritics and spacing are folded; whether they say the same is the
    reviewer's call.
  - *Safety.* `LearningSafetyCheck` matches the approved text's words against the `##` headings of
    every core file named for safety (less heading words that name no hazard) and a fixed hazard list
    (lockout, bypass, jumper, energised, gas, rollout, refrigerant, …). A collision is surfaced with the
    words and files; approving it needs `confirmsSafetyDeparture`, recorded as
    `contradictsSafetyNote: true`. **Its limit:** it is vocabulary, not meaning — a paraphrase that
    avoids every listed word passes, and a harmless mention ("checked the gas pressure") is flagged.
    Both errors land in front of the reviewer, which is where the check sends everything.
  - *Unknown model (contract §7.2).* `LearningCorpus.placement` publishes an entry only to vaults whose
    `VaultModelIndex` knows its token and reports the rest as `unknownModel`; `placementPreview` shows
    the flag before approval. A practice entry has no model to know.
  - *The corpus.* `DocumentStore.learningNamespace(_:)`, `learningNamespacePrefix` and
    `isLearningNamespace(_:)` sit beside the vault ones; `ingestWhole` writes one chunk under a chosen
    id. `LearningCorpus` publishes, withdraws and reconciles (the contract's whole-set replace, which P3
    calls). `DocumentsView` lists `personalDocuments()`; `ReadingStatsView` and `StudyService` read
    `listExcludingTeamLearnings()`. The namespace is outside the manifest, baseline, ledger and
    `VaultManualRemoval`, whose availability check never gates a learning; a re-import, a pack update
    and removing every manual leave it untouched (tested). Leaving the organisation clears the entries
    and every `learning:` namespace.
  - *Retrieval.* `FieldSessionService.makeRetriever(store:documentStore:documentIds:namespaces:)` is
    the one factory; `retrievalNamespaces(vaultId:)` lists `vault:<id>` (`.manual`) then
    `learning:<id>` (`.teamLearning`) — the list is the parameter a later corpus joins — and HIPAA mode
    drops the second. A `documentIds` filter (a manual named by title) reads the manuals alone. A vault
    with learnings and no manuals is searchable. `RetrievalEvidencePolicy.decide` returns `.sufficient`
    only with a manual passage among the evidence (and keeps one when learnings fill the limit), and
    `.teamLearningOnly` when only learnings clear. `ModelScope.penalty(forSubjectToken:)` scores a
    learning by identity (trimmed, case-folded, any spelling of the active model); a practice entry is
    never penalised. The `MANUAL PASSAGES` block labels a learning `TEAM LEARNING (not the manual)`; a
    learning-only block tells the model to open with the exact lead-in.
  - *Disclosure, in four places* (`TeamLearningDisclosure`). (1) The lead-in — "The manual doesn't
    cover this. Your crew's own finding[, noted on <n> previous jobs]:" — is handed to the model and,
    on the Direct path, prepended to the reply by `LLMService` exactly once per turn. (2) The citation
    is the §7.1 name; `CitationLineParser` reads it whole as `Citation.Kind.teamLearning`, which opens
    nothing yet. (3) `FieldSessionService.answerEvidence` (`basis`, `teamLearningBadge`) and
    `Citation.isTeamLearning` are the badge flags; the visible badge is P4's. (4) A learning-alone
    answer writes a `team_learning_answered` event (entry ids and roles, no text) and a
    `TeamLearningAnswer` on the session and the `WorkRecord` (`team_learning_answers`), once per turn;
    a customer-audience export drops it and every team-learning citation, and no summary line carries
    it.
  - *Store and gates.* `LearningEntryStore` (`team-learning-entries.json`) is registered as
    `learningEntries` (third-party linkage, complete protection, backup-excluded, history kept until
    erased), walked by the subject erasure and wired at both `Stores` constructions. Review and publish
    ask `.teamLearnings` (the review copy is `FieldAssistPaywallCopy.teamLearningsReview*`) and refuse
    under HIPAA; supersession and retraction are ungated; retrieval asks nothing.
  - *Honest limits.* On the live modes the lead-in is an instruction to the model, not a prepend: the
    app does not hold that reply. On the Direct path a streamed reply shows the tokens before the
    lead-in is put in front of the final text. A reviewer device can approve only candidates that
    are on it until P3 brings bundles in.
- **P3 — bundle exchange, headless.** `LearningBundle` codec, structural validation of untrusted
  input, `LearningBundleMerge`, `QueuedOp.teamLearning` with both directions (candidates in to the
  reviewer, decisions and approved entries out), the filed / sent / approved / not-taken-up status
  on the author's session, the learnings artefact added to
  `VaultExporter`. Tests: `LearningBundleTests` (truncated, reordered and unknown-version bundles each
  refused whole), `LearningBundleMergeTests` (tombstone precedence, duplicate surfacing, two-phone
  convergence).
  ✅ 2026-10-10. **What shipped** (`Services/FieldAssist/TeamLearning/`):
  - *The bundle.* `LearningBundle` is one closed object — `schemaVersion: 1`, `kind:
    "avenkin.learning-bundle"`, `direction` (`candidates` | `decisions`), `organisationLabel?`,
    `issuedAt`, `sequence?`, and four arrays in the contract's own shapes: candidates (§3, plus
    `origin`), statuses (§4), entries and retractions (§5, plus the amendment's fields). The office
    envelopes' per-item binding fields are absent — a crew has no binding — so the signed route will
    wrap these payloads rather than translate them. A candidates bundle carries candidates only; a
    decisions bundle carries no candidate. Encoded with sorted keys, so the same bundle is the same
    bytes. **Unsigned, by design** (§4).
  - *Untrusted input.* `LearningBundle.decode` reads the bytes with a strict JSON reader
    (`LearningBundleJSON`: duplicate keys, fractions, exponents, leading zeros and integers beyond
    2^53 − 1 refused by name; truncation told apart from malformed input; depth bounded), checks
    the version and kind first (a later version is refused as a version, not as an unknown key),
    walks a closed schema (unknown and missing keys by path, types, the contract's text rules — a
    line feed only inside `finding`, control characters and bidirectional overrides refused —
    and its length caps), then the rules a schema cannot say (direction, no item twice, a
    withdrawal empty, an approval naming its entry). 2 MiB ceiling. Every refusal is the whole
    bundle and says nothing was used. `SecretPatterns.redact` runs over every incoming text field;
    the names that fired are recorded, and a candidate's own `redactions` gain them.
  - *The merge.* `LearningBundleMerge` (§4 above): pure, convergent and idempotent — two phones that
    apply the same bundles in opposite orders end identical, and applying one twice changes nothing.
  - *Receiving.* `LearningBundleIntake`: a candidates bundle on a reviewer device lands in the review
    queue (`received`, `importedFrom` set) with duplicate and merge suggestions reported; on a field
    phone it is refused (`notAReviewerDevice`). A decisions bundle is staged; `pending` lists every
    entry, status and retraction with its literal text and what accepting it would change;
    `accept(entryIDs:candidateIDs:)`, `acceptAll()` and `discard()` (which leaves no trace). Accepted
    entries go through `LearningCorpus.publish`. **The file-open route:** the app is registered for
    `public.json` at *Alternate* rank (never Owner — other apps keep JSON), opened as a copy like a
    job file; `onOpenURL` hands any JSON to the intake, which refuses what is not a bundle by name
    and removes the inbox copy. An imported vault folder's `learnings/` file goes to the same intake.
    No screen yet — the intake's last line goes to the debug log; P4 puts the review on it.
  - *Sending.* `LearningBundleOutbox` composes the phone's candidates (every one filed here and not
    yet answered, withdrawals included) and a device's decisions (every entry it holds, retractions
    and tombstones, and a status for each candidate that arrived in a bundle), both cumulative; a
    vault export's learnings; and the `DeliveryRequest` for a channel. `DeliveryRequest.Payload`
    gained `.learningBundle(_:direction:)`: subject, body and short body are composed from counts —
    no candidate, entry or reason text, which travels only in the one JSON attachment — with its own
    confirmation sentence, and `record` is now `WorkRecord?`, read only by report code. A bundle
    belongs to no job: it is filed under `LearningBundle.queueSessionID`, and `finishDelivery` routes
    its outcome to the outbox rather than a job's log or its "report not sent" flag. Queue:
    `OpKind.teamLearning` posts to an organisation endpoint (`EndpointSyncSink.handledKinds`, the
    bundle's bytes as the payload, its direction in the envelope, the op id as `Idempotency-Key`);
    it is **not** in `OfficeReportSink.handledKinds` (the office route is the signed contract) nor
    in `QueuedRecordRows.kinds` (that list is the unsent *job reports* screen and the per-job and
    departure counts; a bundle shows in the general queue list as "Team learnings").
  - *The author's status* (P2's open point, closed). `sent` is set when a bundle carrying the
    candidate left — a confirmed send (`DeliveryOutcome.sent`) or the endpoint accepting the queued
    op (`EndpointSyncSink.onDelivered`, never the local fallback) — never when it is composed or
    staged. `received`, `approved`, `merged` and `not taken up` (with the reviewer's reason on the
    candidate) are set when a decisions bundle saying so is accepted. Each change writes a
    `team_learning_status` event (id, status, whether an entry made from it answers here — never
    text) into the log of the job the candidate was filed on, open or ended, through that job's own
    logger as P1 does, and updates `FieldSession.teamLearnings` and so `WorkRecord.team_learnings`;
    `in_use` turns true once an approved or merged-into entry answers on the phone.
  - *Vaults.* `VaultExporter` writes `learnings/team-learnings.json` — the vault's entries, live and
    retracted, as a decisions bundle — unless HIPAA mode is on, the capability is missing or there
    are none; the validator ignores the folder. Uninstalling a vault forgets its `learning:<vaultId>`
    namespace at once; the entries stay in `LearningEntryStore`, and `republish()` (now also run
    after a folder import) puts them back if the vault returns.
  - *The author's name* (owed since P1). `Config.technicianDisplayName` — device-local, trimmed,
    control characters turned to spaces, capped at the contract's 120, empty = unset — is what a
    candidate is filed under, the device name the fallback; existing candidates are not rewritten.
    `SettingKey.technicianDisplayName` is organisation-owned: a profile that names the technician
    sets and locks it, and a bad name is a named drop. One row, "Your name, as your team sees it",
    heads the Job Reports group in Field Assist settings — the only UI in this phase.
  - *Gates.* HIPAA mode: no bundle in or out. Composing a bundle, importing candidates and accepting
    entries or statuses ask `.teamLearnings` (new `FieldAssistPaywallCopy.teamLearningsBundle*`
    lines); accepting a retraction asks nothing, as P2's retraction does; published learnings stay
    readable on a lapsed licence. The bundle ledger joins `learningEntries` in the registry and is
    cleared and erased with it.
  - *Honest limits.* Nothing yet composes and sends a bundle except the endpoint queue: the composer
    route is wired (`AppState.presentTeamLearningBundle`) but no screen calls it. A file opened with
    the app is staged or imported silently, its outcome in the debug log, until P4. Two reviewers
    under one organisation label share one ordering watermark, so the older of two bundles composed
    at different times is refused until its reviewer sends again (contract §10.7).
- **P4 — surfaces.** The reviewer-device setting and a batch review queue shown only there (Custom Vaults, and the Job tab if Plan FO has landed), capture
  confirmation read-back, a corpus browser with retract, a HUD line when an answer leans on a
  learning, vault-guide Step 8 and a fourth situation in its sharing section.
- **P5 — the deferred edge.** A signed `learnings.json` in the pack format; the endpoint channel; the
  BL bridge; and device acceptance with a real crew — two technicians capturing in the field, one supervisor approving at base,
  a third phone answering from the result. None of it blocks P1–P4.

## Acceptance

- A scripted session on the Lennox example: *"note this for the team — on the 090 the pressure switch
  tubing sweats and reads open on a cold start"* files a candidate bound to the active equipment and
  task, with the pages verified so far as its evidence; the same question asked immediately
  afterwards still answers from the manual alone and never quotes the candidate.
- Approved and carried to a second device by bundle, that question answers with both a manual
  citation and `Team learning · SLP99UH090XV60CK · …`, spoken as the crew's finding.
- Retracting it removes it from retrieval on the approving phone and, once the tombstone bundle is
  applied, on the other; the entry remains in the review history with its reason.
- A pack update and a vault re-import both leave the corpus untouched; every existing vault,
  retrieval, export and pack test stays green.

## Open questions for the owner

1. ~~How is the reviewer role asserted?~~ **Decided for v1 (2026-10-10, P2): a device-local setting**,
   `Config.teamLearningReviewerDevice`, off by default, declared in `SettingKey` so an organisation
   profile can already pin it off and lock it. Whether a Plan CT profile should *name* the reviewer
   (pin it on, signed by the vendor's key) stays open for later; nothing in P2–P3 depends on it.
2. ~~Does an unapproved candidate help its own author?~~ **Decided 2026-10-09: no**, for spoken and
   report-derived drafts alike — the first thing a technician would do is read it back to a customer
   as if it were the book.
3. **One corpus per vault, or one per organisation across vaults?** The namespace is keyed by vault
   id, which is simple and scoped; a crew running both a refrigeration and an IT vault would file the
   same finding twice.
4. ~~May a team learning answer a question the manual is silent on?~~ **Decided 2026-09-21: yes, as
   long as it is clear that it is a team learning** — see §5 for what "clear" is held to. The
   stricter annotate-only alternative is not taken.
5. **Bundle authenticity.** Given that a crew cannot sign, is an unsigned reviewed bundle acceptable
   for v1, or should the vendor offer per-organisation signing as part of the Plan EI issuance work,
   so a bundle can be attributed as well as read? *(P3 built the unsigned bundle: structure checked,
   every entry accepted by a person, the label read as a label and never as authority.)*
6. **Retention.** Does a learning expire? A finding about a board revision superseded three years ago
   is worse than no finding, and nothing here ages anything out.
7. **Symptom-scoped learnings.** Everything here is scoped by model identity (§5). The
   appliance-repair case is precisely the unit whose model is unknown or whose manual is absent,
   where the useful key is the symptom ("drum turns but no heat"). Should an entry be allowed a
   `subject` of kind `symptom` within an equipment type, matched by the office's own vocabulary
   rather than free text, and how is its reach bounded so a dryer finding never answers for a
   dishwasher? Not needed for P1–P3; it changes retrieval, so it is decided before P4.

Related: [F Field Assist](F-field-assist.md), [ED manual retrieval](ED-vault-manual-retrieval.md),
[EG vault packs](EG-vault-packs.md), [EJ retrieval fidelity](EJ-manual-retrieval-fidelity.md),
[EL equipment identity](EL-equipment-identity.md), [EM work record](EM-work-record-and-parts.md),
[FN manual removal](FN-vault-manual-removal.md), [FO guided job flow](FO-guided-job-flow-and-job-tab.md),
[CT organisation profiles](CT-org-configuration-profiles.md), [T offline queue](T-offline-field-queue-and-sync.md).
