# Plan FP — Team Learnings (what the organisation's technicians learn reaches every technician)

**Status:** 📝 Drafted 2026-09-21 — nothing implemented.
**Origin:** A commercial partner reselling Field Assist to service companies asked for the thing a
vault cannot currently hold: not the manufacturer's book, but what *this* organisation's crew has
worked out about the machines in its territory. A technician who discovers that a particular board
fails a particular way tells whoever is standing next to them, and nobody else ever hears it.
**Priority:** P2 on the Field Assist commercial track — after a pilot proves the manual loop
(EJ/EK/EL/EM), because a learnings corpus with nothing to cite beside it is just a notes app.
**Surfaces:** one tool and a voice phrase during a job; a review queue on the phone; retrieval and
citations; the vault export and pack routes. No new backend.

---

## Product promise

"Say what you worked out while you are still standing in front of it. A lead reads it, fixes the
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
  `photos`, `citationsOpened`, `pagesVerified`; `FieldSession.Task` carries origin, status and its
  own `Evidence`; `EquipmentIdentity` carries `modelToken`, `heading`, `file`, `source`, and a
  `nameplateText` kept for audit and deliberately never put in a prompt. That last precedent is the
  one this plan needs most.
- **Delivery without anybody's server ships, and it is `WorkRecord`-shaped.** `DeliveryChannel`
  (email / messages / whatsapp / telegram / share sheet / endpoint), `DeliveryPolicy`,
  `ReportComposerAvailability`, `DeliveryOutcome` all work — but `DeliveryRequest` holds
  `let record: WorkRecord`, so it is not a generic envelope. `EndpointSyncSink` is real and wired
  (`SyncEngine(queue:sink: EndpointSyncSink(fallback: LocalSyncSink()))`), posting
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
- **Tiering is ready and unenforced.** `FieldAssistEntitlement.shared.isGranted(atLeast: .team)`
  gates the document tier, custom vaults and `SessionExporter`; `check(atLeast:)` returns the reason
  a paywall needs. Seats are recorded, never enforced — there is no server to enforce them against.

## The loop

**Capture → review → publish → retrieve with attribution.** Each arrow is a deliberate stop. A
candidate is unreviewed text written by one person in a plant room; it never answers anybody's
question, including its own author's, until a named person has approved it.

### 1 · Capture

A `team_learning` native tool (`note` / `list` / `amend` / `withdraw`) and the phrase *"note this for
the team"*. `LearningCandidate` (`Codable`): id, `sessionId`, `jobReference`, the
`EquipmentIdentity` in force (or the spoken model token when none resolved), `symptom`, `finding`,
`fix`, `FieldSession.Evidence` reused rather than re-invented, `taskId`, author display name,
`createdAt`, and the `SecretPatterns.hits` that fired. Three rules the code enforces, not the model:

- Candidates live in their **own store** — `LearningCandidateStore`, JSON in the app container,
  registered in `SensitiveStore` so `DataStoreRegistryTests` keeps it honest. Never the vault
  overlay, never `DocumentStore`. A guard test asserts no candidate text can reach
  `VaultPromptBuilder.promptContext` or `FieldSessionService.promptContext(turn:)`.
- `SecretPatterns.redact` runs at capture and the tool reads the redacted text back. This is a floor,
  not a privacy control: it catches an email address and an IRD number and nothing else, so the tool
  also speaks the standing rule ("no customer names or addresses") and review is where a name
  actually gets caught.
- The tool self-gates on `Config.fieldAssistActive` at execute time like its siblings; the **tier**
  check sits in the service layer, where `SessionExporter` and `VaultImporter` put theirs.
  `team_learning` joins `Config.hipaaDisabledTools` — a clinical site's "learning" is a patient note
  wearing a different hat.

The candidate folds into `SessionExport` / `WorkRecord` like any other session artefact, so the
customer's job record shows that an observation was filed *and* that it was not yet in use.

### 2 · Review, with nobody's server

**Recommended for P1–P3: a lead reviews on their own phone, and the bundle travels by the delivery
channels that already ship.** The organisation already puts Field Assist on the lead's phone under
the same team licence; the app already has a vault editor and a composer; and a Mac-side script would
strand the decision on one laptop, which is exactly the failure Plan EI diagnosed for licence
minting. An organisation HTTP endpoint (`EndpointSyncSink`) is a P5 accelerator for customers who run
one; the BL bridge is a P5 successor, not a dependency.

`LearningReview` is a pure state machine: `candidate → approved | edited+approved | rejected |
merged(into:) | superseded(by:) | retracted(reason:)`. Approval records the approver's display name
and role, the timestamp, and the text *as approved* — which may differ from the text as captured, and
both are kept.

**A bundle from another phone is untrusted input.** There is no team key: the Ed25519 private key
behind `SkillPackSignature.productionPublicKeyBase64` is the vendor's and off-repo, so a service
company cannot sign anything. A `LearningBundle` arriving by email or AirDrop is validated
structurally, shown to the reviewer in full as literal text, and never applied without an explicit
approval per entry. Plan R's posture applies: it is data, not instruction.

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
name. The citation composer needs no change.

The namespace earns its keep three ways: it sits outside the manifest, the baseline and the ledger,
so a pack update, a vault re-import and an FN manual removal all leave it alone; retraction is one
`DocumentStore.forget(documentId:inNamespace:)` rather than a manifest edit against protected pack
content; and **the namespace is the provenance**, so a team learning cannot be mistaken for OEM
evidence anywhere downstream. `FieldSessionService` builds the retriever's `QueryFunction` /
`TokenSearch` closures, so both namespaces are queried and merged there and `VaultRetriever` itself
is untouched.

**Supersession borrows the shape Plan EN used for facts that change.** An entry is stamped
(`supersededAt`/`supersededBy`, or `retractedAt` + reason) and kept in `LearningCandidateStore` as
history, while its document leaves the retrieval namespace: the organisation keeps the record of what
it once believed — an auditor's question — without the assistant still saying it. Honest limit: a
phone that never receives the retracting bundle keeps answering from the old entry, exactly as it
would with a stale vault, and the review screen says so.

### 4 · Distribute

| Route | Reused | Missing |
|---|---|---|
| Bundle by email / Messages / share sheet | `DeliveryChannel`, `DeliveryPolicy`, `ReportComposerAvailability`, `DeliveryOutcome` (a hand-off is not a send) | `DeliveryRequest` is bound to `WorkRecord`; it needs a generic payload or a sibling envelope |
| Offline queue to an organisation endpoint | `OfflineQueue`, `EndpointSyncSink`, `ConflictResolver` | a `QueuedOp.teamLearning` kind |
| Vault export / import round trip | the `VaultExporter` folder shape | it exports manifest + core + procedures + documents and knows nothing of a learnings namespace; `isExportable` is false for packs, so a team on a pack vault can move learnings **only** by bundle |
| Signed pack update | `VaultPackManifest`, `SkillPackSignature`, `VaultPackCatalogService` | the pack format has no learnings slot; a signed `learnings.json` is P5, and is the vendor's or partner's route, never a crew's |

Merge semantics are `LearningBundleMerge`, pure: match on entry id; the later `approvedAt` wins; a
tombstone beats content whatever its timestamp; an unrecognised `schemaVersion` is refused whole
rather than partially applied; a duplicate finding from two phones surfaces as a merge candidate for
the reviewer instead of being silently deduplicated.

### 5 · Trust rules at answer time

- **Two provenances, never one heap.** `VaultRetriever.Passage` gains
  `provenance: .manual | .teamLearning`, set from the namespace by the caller; the prompt block
  labels learnings and the spoken answer names them ("your crew noted, not in the manual").
- **A learning is not evidence on its own.** `RetrievalEvidencePolicy.decide` may return
  `.sufficient` on a `.teamLearning` passage only when a `.manual` passage also clears the floor;
  otherwise the outcome is the manual-silent sentence *plus* the learning, offered as a colleague's
  report. This keeps EJ's gate meaning what it said.
- **A learning never overrides a safety note.** A standing prompt rule beside the manifest's
  `prompt_rules`, plus a deterministic `LearningSafetyCheck` at review time that *surfaces* — never
  auto-rejects — a candidate colliding with the vault's safety core file, because "the manual says X
  but on this unit…" is precisely the knowledge worth capturing. Publishing one needs a second
  confirmation.
- **Equipment scoping is exact, not textual.** An entry carries a `modelToken` resolved through
  `VaultModelIndex`, so `ModelScope` scores it by identity rather than by scanning prose; an entry
  filed against a model the vault does not know is flagged at review rather than published blind.
- **Gating and erasure.** `isGranted(atLeast: .team)` at capture, review, publish and bundle import;
  already-published learnings stay *readable* on a lapsed licence, following Plan FN's decision 5.
  Nothing here needs `agentModeEnabled` until P5's endpoint/BL auto-publish, gated at the service
  layer. Both the candidate store and the corpus namespace join the `SubjectErasureCoordinator` walk.

## Phases (one PR each)

- **P0 — inventory and seams.** Every site that assembles prompt context, queries a vault namespace,
  or can write to a vault overlay, plus the `SensitiveStore` and erasure-walk registration points.
  Output: that inventory in this doc, and the `DeliveryRequest` generalisation with no behaviour
  change.
- **P1 — capture core, headless.** `LearningCandidate`, `LearningCandidateStore`, `team_learning`,
  evidence binding to the active task and session, the redaction pass, the gates, the session-export
  fold. Tests are the gate: `TeamLearningCaptureTests` (voice verbs, a candidate bound to a session
  with no active task, amend and withdraw, old sessions decode), `TeamLearningRedactionTests` (what
  fires and what provably does not — a customer name survives redaction and the test says so),
  `TeamLearningPromptIsolationTests` (no candidate text reaches either prompt builder).
- **P2 — review, publish and retrieve, headless.** `LearningReview`, `LearningCorpus` ingest and
  retract, the artefact renderer and citation name, `provenance` on the passage, the evidence-gate
  rule, `ModelScope` by identity, the prompt rules, `LearningSafetyCheck`. Tests:
  `TeamLearningReviewTests`, `TeamLearningRetrievalTests` (a learning alone never yields
  `.sufficient`; a learning beside a manual passage does; the citation head is exact),
  `TeamLearningSupersessionTests` (stamped and kept, gone from the namespace, replay idempotent).
- **P3 — bundle exchange, headless.** `LearningBundle` codec, structural validation of untrusted
  input, `LearningBundleMerge`, `QueuedOp.teamLearning`, the learnings artefact added to
  `VaultExporter`. Tests: `LearningBundleTests` (truncated, reordered and unknown-version bundles each
  refused whole), `LearningBundleMergeTests` (tombstone precedence, duplicate surfacing, two-phone
  convergence).
- **P4 — surfaces.** Review queue (Custom Vaults, and the Job tab if Plan FO has landed), capture
  confirmation read-back, a corpus browser with retract, a HUD line when an answer leans on a
  learning, vault-guide Step 8 and a fourth situation in its sharing section.
- **P5 — the deferred edge.** A signed `learnings.json` in the pack format; the endpoint channel; the
  BL bridge; and device acceptance with a real crew — two technicians capturing, one lead approving,
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

1. **Who is the reviewer, structurally?** There is no server and seats are recorded, not enforced, so
   "lead" is a role the organisation asserts and the app records. Is a device-local role setting
   enough for v1, or should a Plan CT organisation profile name the approver, so the role is at least
   signed by the vendor's key?
2. **Does an unapproved candidate help its own author?** Arguably the person who wrote it should be
   able to retrieve it on their own phone. The draft says no, on the grounds that the first thing a
   technician would do is read it back to a customer as if it were the book.
3. **One corpus per vault, or one per organisation across vaults?** The namespace is keyed by vault
   id, which is simple and scoped; a crew running both a refrigeration and an IT vault would file the
   same finding twice.
4. **May a team learning answer a question the manual is silent on?** The draft allows it, clearly
   labelled and never as `.sufficient` evidence. The stricter alternative — a learning may only
   annotate an answer the manual already grounds — is safer and considerably less useful.
5. **Bundle authenticity.** Given that a crew cannot sign, is an unsigned reviewed bundle acceptable
   for v1, or should the vendor offer per-organisation signing as part of the Plan EI issuance work,
   so a bundle can be attributed as well as read?
6. **Retention.** Does a learning expire? A finding about a board revision superseded three years ago
   is worse than no finding, and nothing here ages anything out.

Related: [F Field Assist](F-field-assist.md), [ED manual retrieval](ED-vault-manual-retrieval.md),
[EG vault packs](EG-vault-packs.md), [EJ retrieval fidelity](EJ-manual-retrieval-fidelity.md),
[EL equipment identity](EL-equipment-identity.md), [EM work record](EM-work-record-and-parts.md),
[FN manual removal](FN-vault-manual-removal.md), [FO guided job flow](FO-guided-job-flow-and-job-tab.md),
[CT organisation profiles](CT-org-configuration-profiles.md), [T offline queue](T-offline-field-queue-and-sync.md).
