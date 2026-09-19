# Plan FL — Evidence for Whether Approved Corrections Help

**Status: 📝 Drafted 2026-09-19 — not scheduled; no implementation under this plan.** Reviewed
2026-09-19 against `main`: trigger-keyed skill replacement, the approval write order, the missing
turn identity and a third skill writer added below.

Connect an approved evolved skill to the turns that actually received it and to explicit evidence
about those turns. Let the wearer see whether a correction helped, failed again or has not been
evaluated. Preserve human approval and existing tool authority. Deliver one PR for this plan.

## Current position

| Repository path / symbol | Existing behaviour / gap |
|---|---|
| `OpenGlasses/Sources/Services/Skills/UserCorrectionDetector.swift` | High-precision phrase detector; keep its narrow meaning. A detected phrase is a candidate signal, not proof which skill failed. |
| `OpenGlasses/Sources/Services/Skills/SkillEvolutionService.swift`, `noteUserTurn`, `approve` | Agent-Mode-gated failure batches produce reviewed proposals. Approval saves a voice skill with a new UUID, currently without a durable origin/revision link. Order today: `store.approve(id:)` **then** `VoiceSkillStore.save` — a crash between them leaves an approved proposal with no skill, which reconciliation must repair. `noteUserTurn` receives prompt/response **strings**; no turn identity exists anywhere in the app yet. |
| `OpenGlasses/Sources/Services/Skills/EvolvedSkillStore.swift` | Local protected SQLite pending/approved/dismissed lifecycle, deletion and subject-text matching. Extend rather than duplicate the proposal bank. |
| `OpenGlasses/Sources/Services/NativeTools/VoiceSkillsTool.swift`, `VoiceSkill`, `VoiceSkillStore` | Voice skill storage (a JSON list) and prompt injection; needs optional origin/revision metadata and selected-reference output. **`save` replaces by trigger, not ID**, and `delete` is by trigger: any later skill with the same trigger silently replaces an approved one under a new ID, orphaning its origin link. Three writers: `SkillEvolutionService.approve`, the `voice_skills` tool, and `Memory/MemoryLoopService`. |
| `OpenGlasses/Sources/Services/Skills/SkillRetriever.swift` | Selects candidates; selection alone does not prove the final prompt included a skill. |
| `OpenGlasses/Sources/Services/LLMService.swift`, `buildSystemPrompt` | Voice skill block enters the full prompt here; inspect lean/local/agent paths for actual inclusion. |
| `OpenGlasses/Sources/App/OpenGlassesApp.swift`, `noteUserTurn` call | Has previous prompt/response context; bind feedback to concrete turn identity rather than adjacency alone. |
| `OpenGlasses/Sources/App/Views/SuggestedSkillsView.swift`, `VoiceSkillsManagerView.swift` | Existing review/manage surfaces; display evidence here. |
| `OpenGlasses/Sources/Services/Privacy/SubjectErasureCoordinator.swift` | Erasure must reach derived evidence and origin-linked approved copies. |
| `OpenGlassesTests/SkillEvolutionTests.swift`, `SkillRetrieverTests.swift` | Existing approval/selection regressions. |

This plan extends the existing self-evolution feature. It does not auto-approve, rewrite, enable or
retire skills; learn broad personality rules; add a general feedback model; or allow a learned skill
to grant permissions. [DJ](DJ-composed-tool-safety-and-execution-outcomes.md) owns tool outcomes;
[DM](DM-privacy-safe-production-logging.md) owns content-free diagnostics;
[FK](FK-memory-quality-and-continuity-benchmarks.md) supplies synthetic longitudinal scenarios.
No dependency on FJ is required: a route that does not inject evolved skills produces no exposure.

## User-facing behaviour

After approving a proposed skill, the wearer can inspect evidence in its existing management view:
“Used in 5 answers. You marked 2 helpful and 1 not helpful. 2 have no feedback.”
Use “included in 5 answers” if only prompt exposure can be proven; do not imply causal influence.
The final copy must distinguish exposure, completed answer and explicit evaluation.

Offer optional **Helpful** / **Not helpful** actions on an eligible completed answer and in the skill
history. Bind an action to that answer and exact skill revision. Do not interrupt normal voice turns
with feedback questions. Add no new always-listening command grammar. Where more than one approved
skill was present, let the user choose a skill or rate the answer without skill attribution; do not
assign a blanket rating to all skills.

A detected “that's wrong” records a correction candidate linked to the corrected turn. It does not
lower every exposed skill's rating. Positive phrases, silence, lack of a correction, successful audio
playback and unrelated tool completion are not skill success. “Not helpful” is feedback, not a request
to change the instruction. Existing edit/disable/delete controls remain the only ways to change use.

## Data model and identities

Add pure Sendable/Codable value types under `Services/Skills/`:

- `SkillRevisionRef`: origin proposal UUID, approved voice-skill UUID, integer revision.
- `SkillExposure`: exposure UUID, turn UUID, conversation generation, exact revision, route enum,
  time, and lifecycle (`prepared`, `submitted`, `answerCompleted`, `interrupted`, `failed`).
- `SkillFeedbackEvent`: unique event UUID, exposure reference, kind (`helpful`, `notHelpful`,
  `correctionCandidate`, `objectiveSatisfied`, `objectiveFailed`, `inconclusive`), evidence origin,
  time, optional superseded event ID and optional typed objective ID.
- `SkillEvidenceSummary`: counts by revision and evidence type, evaluated/exposed denominators,
  last observation time, retention window and insufficient-evidence state.
- `SkillEvidencePolicy`: pure reducer validating references, transitions, deduplication and aggregate
  counts. Inject clock and UUID generation in tests.

Persist no prompt, response, transcript, correction text, arguments, contact names, memory values or
model reasoning in the evidence tables. Existing proposal content stays in its current protected
store; the new tables only reference it. IDs are local sensitive metadata, not diagnostic tokens.
A revision is the persisted instruction/trigger revision, not a hash of private text. On edit,
increment revision and keep old evidence separate; never carry positive ratings onto changed text.

Suggested additive SQLite tables in the existing evolved-skill database:

- `skill_origins(proposal_id PRIMARY KEY, voice_skill_id UNIQUE, revision, link_state)`.
- `skill_exposures(id PRIMARY KEY, turn_id, conversation_generation, proposal_id, voice_skill_id,
  revision, route, state, created_at, UNIQUE(turn_id, voice_skill_id, revision))`.
- `skill_feedback(id PRIMARY KEY, exposure_id, kind, evidence_origin, objective_id, supersedes_id,
  created_at)` with explicit uniqueness for one active user verdict per exposure.

Add indexes for revision/time and exposure lookup. Foreign-key/cascade enforcement must be enabled
on every relevant connection or implemented and tested transactionally. Use schema-versioned,
idempotent migration in a transaction; failure leaves the existing skill bank readable and evidence
collection disabled with a typed local error. Reopen/upgrade tests must use real SQLite files.

## Approval linking and compatibility

Fix identity before linking. `VoiceSkillStore.save` must upsert by ID; a trigger collision with a
*different* ID is an explicit replacement that ends the old skill's origin link (link state
`replaced`, evidence retained until retention prunes it) rather than an invisible overwrite. The
`voice_skills` tool and `MemoryLoopService` keep their current user-visible behaviour (a same-trigger
save still wins) but go through that replacement path. An edit that keeps the ID bumps the revision
only when trigger or instruction text actually changed.

Generate the voice-skill ID before persistence and record a pending origin link with that ID. Save
the voice skill idempotently, then mark approval/link committed. The two stores do not share a
transaction: use a small recoverable state machine and reconcile on launch. A retry cannot create a
second voice skill; an interrupted approval cannot be reported as linked and active until both sides
agree. Keep existing approval UI semantics and proposal validation/injection screening.

Add optional origin/revision fields to existing Codable voice skills so old files decode unchanged.
Legacy approved skills without a reliable origin link remain usable with “Evidence unavailable for
this older skill”. Do not fuzzy-match instructions/names to invent provenance. A user editing a
legacy skill may start a new explicitly linked revision only through the existing reviewed flow.
If an approved skill is deleted or disabled, stop future exposure collection immediately.

## Exposure and feedback pipeline

1. Carry structured selected skill references alongside the prompt block from `VoiceSkillStore`.
   Preserve existing exact-trigger and retrieval rules; this plan does not change which skills win.
2. Record `prepared` only after final rendering/budget decisions. On actual request dispatch record
   `submitted`; cancelled preparation is not exposure. Correlate with a turn identity — which does not exist yet: mint a `TurnID` (UUID) at the start of
each ordinary turn in `AppState`, carry it through prompt assembly and the response, and pass it to
`noteUserTurn` in place of adjacency. Keep it process-local and out of `PrivacyLog`; this is the
smallest seam FL needs and later plans (FK lifecycle fixtures) can reuse it.
3. Record answer completion/interruption/failure from actual turn outcomes, keeping speech-delivery
   status separate. Provider retries within the same logical turn do not count as new uses.
4. Expose optional feedback for a known answer and revision. Validate origin, turn/generation and
   revision; old UI events after reset/deletion cannot attach to a new turn. An explicitly retained
   history action may rate its original answer, never the currently active answer by accident.
5. Persist a user verdict once. A changed verdict supersedes the previous one transactionally; it
   does not increase the evaluated denominator twice. Repeated callback/event IDs are idempotent.
6. Record correction candidates using the existing detector, linked to the previous identified turn
   only when that turn is known. Multiple exposed skills or ambiguous turn references remain
   unassigned/inconclusive. Never infer that the next unrelated turn validated a repair.

Generic instructions cannot be objectively graded. For an explicitly typed objective, a deterministic
validator may emit objective evidence only if it declares the exact skill revision, target property,
turn/tool invocation identity and result it checked. For example, an approved structured-output skill
may be tested for a required field against an actual parsed result. A tool's `.completed` status does
not establish that the user's request or a behavioural correction was satisfied. `.outcomeUnknown`,
rejected calls, evaluator failure and unavailable evidence must never become positive feedback.

Ship user feedback and correction-candidate tracking first within this PR; the objective-validator
interface plus one deterministic fixture implementation is sufficient. Do not add an LLM judge or
claim objective grading for production skills with no validator. Objective counts remain separate
from subjective feedback in summaries.

## Statistics and safeguards

Show raw counts before percentages. Helpful rate is helpful / (helpful + notHelpful) for the same
revision and retention window; unknown, candidate and objective events do not enter that denominator.
Show no percentage below five explicitly rated distinct turns. Do not label the rate confidence,
probability of correctness or causal improvement. Do not silently weight repeated events from one
turn as independent observations. Include the number of unrated exposures.

No automatic threshold changes skill behaviour. A repeated failure can make an existing review view
show “Review suggested”, but cannot alter prompts, trigger a new LLM analysis without the existing
Agent Mode gates, enable tools or issue side effects. Preserve the existing proposal batch policy.
Any future automatic promotion/retirement requires a separate plan and evaluation.

## Privacy, retention and reset

Collect new evidence only while Agent Mode and the relevant existing learning controls permit it;
turning Agent Mode off stops collection immediately without deleting approved user-authored skills.
Default evidence retention: 30 days and at most 1,000 exposures globally, pruning oldest first in
bounded batches with their feedback. Do not retain aggregates beyond the underlying evidence window.
Settings help must explain this bound. No sync, remote analytics or raw-content debug export.

Apply `StoreProtection` to database, WAL and SHM as existing persistence requires. Global erasure
clears evidence, links and cached summaries. Proposal/voice-skill deletion removes linked evidence;
subject erasure resolves subjects through existing content owners, then cascades by IDs to all linked
copies and evidence. If a legacy link cannot be resolved, report the same honest limitation as the
existing erasure contract; do not claim complete removal based on an empty evidence query.
Conversation deletion removes matching turn evidence when mappings exist. Conversation reset clears
pending attribution and advances generation but follows the current contract for retained history.
A stale callback after erasure must fail generation/tombstone validation rather than recreate rows.
Diagnostics may contain only finite event kinds, aggregate counts and durations; not local IDs or
content-derived hashes. Add privacy-log canary tests.

## Implementation checkpoints

### P0 — Pure evidence policy and migration

Implement identities, reducer, metric rules, protected schema migration and retention. Test with an
injected clock/IDs and temporary directories. Extend approval persistence to carry origin identity
with crash reconciliation. Do not collect production evidence until the link is reliable.

### P1 — Actual prompt exposure and turn lifecycle

Instrument final prompt dispatch on existing ordinary/full/lean/on-device/agent routes where skills
are actually included. Build an inventory showing supported versus not-injected routes. A clipped or
omitted skill produces no exposure. A live route with no evolved skills must remain not-injected;
FJ's saved-memory snapshot is not skill exposure. Add captured-request integration tests.

### P2 — User feedback and review UI

Add bound optional feedback actions, evidence summaries per revision, legacy/insufficient-evidence
copy and retention help. Use existing views/navigation; no separate dashboard. Localize new strings,
support VoiceOver labels and Dynamic Type, and keep counts truthful after edit/delete/restart.
Wire correction candidates without expanding the phrase detector's false-positive surface.

### P3 — Erasure, crash/race tests and qualification

Wire deletion/subject erasure/Agent Mode/reset, prune expired evidence, and test delayed feedback.
Add FK-compatible synthetic scenarios and update feature/index status with automation versus device
UI evidence separated. No automatic rule mutation or new provider requests are introduced.

## Acceptance tests

- Pending/dismissed proposals never produce approved-skill exposures; ordinary unrelated voice skills
  do not acquire invented origin links. Legacy decoding remains compatible.
- Approval interrupted before/after each store write reconciles to zero or one linked skill, never two;
  the current order (proposal approved, skill not yet saved) is one of the tested crash points.
- A later same-trigger save from the voice tool or `MemoryLoopService` marks the approved skill's link
  `replaced`; its evidence never attaches to the new skill.
- Selected-but-clipped, prepared-but-cancelled and failed-before-dispatch cases are not submitted uses.
- Same turn retry, duplicate feedback and changed verdict preserve correct denominators.
- Silence, “yes”, successful speech delivery and unrelated completed tools cannot mark a skill helpful.
- A correction with multiple skills or an unknown prior turn remains unassigned/inconclusive.
- Revision edits isolate evidence; disable/delete/reset during pending callbacks prevents resurrection.
- Store reopen preserves identities/events; invalid migration disables collection without losing skills.
- Retention and all erasure paths remove linked rows/caches; diagnostic canaries never appear.
- UI summary values equal pure reducer results, distinguish unrated from failure and suppress rates
  below the sample floor. VoiceOver actions identify the answer/skill they affect without exposing
  private content in accessibility diagnostics.

Add `SkillEvidencePolicyTests`, `SkillEvidenceStoreTests`, `SkillExposureIntegrationTests` and
`SkillApprovalRecoveryTests`; retain `SkillEvolutionTests` / `SkillRetrieverTests`. Use FK's documented
Xcode invocation, selecting these classes, then run required CI checks. Real model calls are not
needed for policy, persistence, privacy or captured-request tests. Device UI passes are separate.

## Rollout and completion

Keep collection behind an internal switch until linking, migration, dispatch and erasure tests pass.
Turning it off stops collection; stored skills continue to work. Additive schema/optional fields must
remain readable by the previous app version; rollback never deletes approved skills. Complete when
origin/revision linking, actual exposure, explicit feedback, retention/erasure and accessible review
are implemented and tested. Report unmeasured usefulness honestly; counts alone do not establish
that the feature improves conversation quality.
