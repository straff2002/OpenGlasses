# Plan FM — Conversation Context Budgeting and Field Session Continuity

**Status:** Implemented for ordinary ChatGPT Subscription turns on 2026-09-19; simulator
validation recorded below. Device acceptance and reproduction of the tester's build remain pending.
**Trigger:** A tester using ChatGPT (Subscription) reports “Exceeded model context window size”
while testing vault Q&A and photos. Starting a new chat sometimes recovers. The reported build
is 378; the request that failed and its selected model have not been captured or reproduced.

## Outcome

A technician can continue the same conversation through repeated context compactions without
losing the active equipment, recorded measurements, completed work, current procedure position,
corrections or unresolved safety checks. The visible conversation remains intact. The model sees
a bounded working context backed by durable session records and retrievable history.

This is not a promise that every historical word stays in the model's context. Relevant details
must remain recoverable, and missing or ambiguous evidence must be acknowledged rather than guessed.

## Verified starting point

- `Services/LLMService.swift` uses a fixed `maxEstimatedTokens = 80_000`. Both compactors inspect
  history alone and require more than six messages. The initial check precedes prompt assembly;
  `sendChatGPT` also calls `trimHistory` after appending the user message, but that check is still
  history-only. Instructions and tool declarations are added separately to the outgoing request.
- The ChatGPT tool loop constructs subsequent requests through `ResponsesTranslator.requestBody`.
  Budget enforcement needs to run there too, after tool output has enlarged the input.
- `Services/LLM/HistoryHygiene.swift` provides image pruning and approximate history estimates.
  Its base64-size image heuristic is not an authoritative provider image-token calculation.
- `FieldAssist/FieldSession.swift` already persists equipment, tasks, identity fields and evidence.
  `FieldSessionService` persists changes and restores equipment; procedure position is recovered
  through audit events. Reuse this storage and lifecycle rather than introducing a competing job record.
- `FieldSessionService.promptContext` explicitly includes equipment, current procedure context
  and manual retrieval. Audit other prompt contributions before extending this: durable storage
  alone does not prove that all completed work and readings reach the next request.
- `ModelFetcher` loads the account model catalog, but request budgeting currently does not use a
  verified per-model cloud context limit. `ModelFallbackChain` also uses a shared cloud estimate.

Related work: [EL equipment identity](EL-equipment-identity.md),
[FC memory inventory](FC-memory-context-inventory.md), and
[FK continuity benchmarks](FK-memory-quality-and-continuity-benchmarks.md).
FM owns production request budgeting and Field Assist continuity; reuse FK fixtures where useful.

## Scope and invariants

- First release: ChatGPT Subscription through the ordinary `LLMService` conversation/tool loop,
  including standard voice Q&A and photos. Share pure budgeting components for later provider adoption.
- Gemini Live and OpenAI Realtime have separate context lifecycles and are not silently covered by
  this release. No change to glasses capture or speech recognition in this plan.
- Compaction never ends a field session, changes active equipment, marks a task complete, or
  removes saved chat messages. Session deletion and explicit reset retain their existing semantics.
- A suggested check is not completed work; visiting a procedure step does not prove the work was
  performed. Preserve reported, observed, inferred, pending and confirmed states separately.
- Model summaries cannot override authoritative equipment, task or procedure state.
- Tool calls and results remain valid pairs; recovery must not execute completed actions again.
- Preserve existing privacy boundaries, provider permissions and deletion behaviour. Job memory
  stays scoped to its session/equipment and does not become global personal memory.

## Design

### 1. Model-aware whole-request budget

Add a pure `RequestContextBudget` component under `Services/LLM/` and a model-limit resolver.
Resolve limits by provider, endpoint and model ID. Use validated catalog metadata when supplied;
otherwise use a versioned, source-verified model table and a conservative documented unknown-model
fallback. Record the limit's provenance. Do not assume subscription and API endpoints share limits.
Verify current backend contracts during implementation before selecting values or adding wire fields.

The input allowance is the effective context limit minus response/reasoning reserve and a safety
margin. Respect any separate maximum input limit as well. Reserving space is internal accounting;
send output-limit parameters only where the backend supports them.

Estimate the actual outgoing instructions, translated input (including function arguments/results),
tool schemas, images and framing overhead. Use supported tokenization where practical, conservative
text estimates otherwise, and image estimates based on the model's image handling rather than
counting base64 characters as ordinary text. Return a per-component breakdown for diagnostics.

Run this check before **every** network submission, including tool-loop requests, recovery requests
and any summarization request. A short history is never exempt. Changing models resolves a new budget.

### 2. Build a bounded request without changing the transcript

Introduce a request-context builder that retains separate categories until budgeting is complete:
protected instructions, session snapshot, current user turn, recent exchanges, older summary,
retrieved passages, optional context and tool definitions. Avoid trimming an opaque system string.

When over budget:

1. Omit older images from the request while retaining stored attachments and references.
2. Deduplicate retrieved evidence and choose the highest-ranked complete passages that fit. Keep
   citations and relevant table headers, units and warning context. Expose omissions; do not turn
   a truncated passage into apparently complete evidence.
3. Replace older complete exchanges with a bounded summary tied to covered message IDs. Preserve
   structured session state independently. The summarizer itself must use bounded chunks; if it
   fails, fall back to deterministic selection and stored evidence references.
4. Bound oversized tool outputs at their producers/renderers, retaining retrievable references.
   Preserve active tool exchanges and never split function-call/result pairs.
5. Recalculate until within budget. If the current turn plus protected context cannot fit, return
   a clear local capacity error before sending. Do not silently cut the question or safety state.

Allocate both per-component and total bounds. Keep tool schemas required by pending calls and
continuity retrieval available; any tool filtering must preserve the current workflow.
Persist the working summary and its coverage separately from the visible transcript, using existing
conversation storage where suitable. Cancellation or failed summaries must not destroy the previous
valid working context. Repeated compaction must not recursively inflate summaries.

### 3. Durable Field Assist continuity

Build a bounded `FieldSessionContextSnapshot` from existing session state and audit-backed progress.
Refresh it before each send, including after a tool changes equipment, measurements or task state.
Do not capture it once at the beginning of a multi-step tool loop.

The snapshot must contain:

- Active equipment and relevant confirmed identity fields with provenance.
- Current task/procedure, current step, selected branches and next pending action.
- Recorded completed/skipped/failed checks and their results, distinct from navigation history.
- Measurements with units, time, equipment/task scope and source event IDs.
- Corrections, superseded values, unresolved hypotheses, safety prerequisites and open questions.

First audit the existing task/evidence recording tools. Reuse them for spoken reports and extend
their schema only for uncovered facts. Ensure ordinary voice reports such as “I checked the fuse;
it is good” and “that reading was 24 volts, not 240” reach durable state before their source turns
can be compacted away. Proposed extracted facts must cite source turns, pass validation and remain
unconfirmed where speech or meaning is ambiguous. Never convert an assistant recommendation into
a completed action. Ask for clarification only where the ambiguity affects the work.

The full evidence record may grow; the prompt snapshot must not. Always retain active identity,
current position and unresolved safety state, then select relevant/recent progress within budget.
Provide structured retrieval of older checks/readings by task, equipment and source ID, reusing
existing tools if they can serve this reliably. Include an explicit pointer when older evidence is
omitted. If essential state cannot fit, stop with a capacity explanation rather than hiding it.

Equipment corrections invalidate stale summaries. Equipment changes must not carry measurements or
completed checks onto the new machine; retain the old evidence under its original scope. Add only
backward-compatible persisted fields and verify resume, end-session and deletion paths.

### 4. One bounded overflow recovery

Classify context overflow from structured provider errors, including streamed failure events.
Use narrowly matched message fallback only where structured codes are unavailable. Do not treat
every HTTP 400 as overflow or confuse context capacity with subscription quota/authentication.

On a confirmed overflow, reduce the effective input allowance, rebuild context and retry the failed
model request once per user turn. Keep the user message singular and reuse already-completed tool
results. Do not restart the entire tool loop or replay state-changing actions. Handle partial streamed
text with the existing reset mechanism so the UI does not concatenate failed and recovered replies.

If recovery fails, preserve the session and provide an actionable error. Do not silently switch
provider or claim that a new chat is required. Record only privacy-safe counts, limit provenance,
model ID and recovery outcome; no prompts, credentials, images or equipment readings in diagnostics.

## Implementation sequence

1. **Baseline and model limits:** identify the build-378 revision and selected model if available;
   reproduce with synthetic long vault/photo/tool histories. Add pure limit resolution and full
   request accounting fixtures. Distinguish confirmed local gaps from the unconfirmed tester cause.
2. **Continuity foundation:** audit state-to-prompt coverage; implement durable recording gaps,
   bounded snapshots and older-evidence retrieval. Prove spoken corrections survive persistence.
3. **Budgeted requests:** integrate request selection, bounded summaries/retrieval and refreshed
   snapshots into ChatGPT's send boundary. Preserve transcript and attachment storage.
4. **Recovery:** classify overflow, retry once without duplicate actions and add privacy-safe
   component diagnostics. Keep ordinary authentication/quota/error behaviour unchanged.
5. **Acceptance:** run focused existing and new tests through the repository's documented XCTest
   workflow; validate on-device voice Q&A with an active vault. Record model/build and remaining
   limitations. Broader cloud-provider rollout is a separate follow-up after this path passes.

## Acceptance tests and release gate

- A history below 80,000 estimated tokens with large instructions/tools is reduced before send.
- One to six large messages, a huge manual/tool result, repeated images and a mid-loop result are
  budgeted; all outgoing mocked requests fit the resolved allowance.
- Unknown models, model switches, summary failure and protected context exceeding capacity have
  deterministic outcomes. Summarization requests also fit their own budget.
- Simulate at least 100 turns and multiple compactions: identify a model by voice, record checks
  and readings, correct one reading, branch a procedure, then ask what was checked and what is next.
  Assert required facts in the actual transmitted request or retrieved evidence, not just storage.
- Retrieve an older measurement omitted from the snapshot. Preserve units, source and correction
  precedence. Recommendations and merely visited steps never appear as completed checks.
- Change equipment and verify old evidence cannot be attributed to the new machine. Resume the app
  and verify continuity; end/delete a session and verify it cannot leak into a later job.
- Inject a context error after a state-changing tool: one retry, one user message, one tool execution,
  valid tool-result pairing and no duplicated streamed answer. A second overflow exits cleanly.
- Confirm visible chat/attachments remain intact and diagnostics contain no source content.
- On device, run hands-free spoken model lookup and sustained diagnostic Q&A without creating a
  new chat. Separately test photo turns; nameplate image quality is not this fix's acceptance criterion.

Release requires both bounded outgoing requests and continuity assertions to pass. An overflow
workaround that loses diagnostic progress does not satisfy this plan.

## Implementation decisions and evidence

The first implementation uses deterministic working-context selection plus exact, durable Field
Assist recall instead of a generated rolling summary. This is an intentional change to design
section 2: summaries can alter numbers or imply that proposed work was completed. Existing structured
task state and procedure position remain authoritative; unstructured speech is retained verbatim
as an **unverified technician report**, with a source ID and equipment scope. It is not automatically
promoted into a structured completed check or confirmed measurement. Captured readings retain units
and capture method. A later extraction/summary layer is optional and must satisfy the same tests.

Implemented surfaces:

- `RequestContextBudget`: estimates the translated instructions, input (including function
  arguments/results and images), schemas and framing. Text uses a conservative UTF-8-byte upper
  estimate; images use an 8,192-token allowance for prepared photos. Model context reserves include
  response/reasoning headroom and a margin. These are estimates, not tokenizer-exact guarantees.
- Known Subscription model defaults use the upstream Codex catalog verified on 2026-09-19:
  [model catalog](https://github.com/openai/codex/blob/main/codex-rs/models-manager/models.json).
  Exact model IDs resolve to the default 272,000-token window, not optional extended windows.
  Valid account-specific catalog metadata can override it for one hour; anonymous metadata is
  ignored. Unknown models/endpoints use a conservative 32,768-token fallback.
- `LLMService`: checks every ChatGPT tool-loop submission, refreshes Field Assist instructions
  after tool mutations, and retries a context rejection once below the dispatcher. Both HTTP
  errors and streamed error codes participate. A second failure cannot restart the entire turn
  through model cascading. Stateless Subscription requests are also checked before submission.
- Selection removes old complete exchanges only from request copies. The saved chat remains intact.
  In-memory historical photo payloads retain the existing pruning lifecycle to avoid accumulating
  base64 images throughout a long visit; saved photo attachments are not deleted.
- `VaultPromptBuilder` bounds optional core files for ChatGPT at 24,000 bytes, prioritising query
  matches and retaining whole safety files and manifest rules. `VaultRetriever` selects complete
  passages within a 12,000-byte content allowance for prompts and tool results. Both name omissions
  explicitly and require further lookup instead of treating missing evidence as absence.
- `FieldSessionContextSnapshot`: renders recorded identity fields, open tasks/safety state,
  session escalations and an 8,000-character tail of complete reports/results. It stops at the
  first omitted report so an oversized correction cannot leave its older value looking current.
  Protected active/safety state can exceed that historical allowance; the outer request budget
  then refuses rather than silently dropping it.
- `field_session recall`: paginates exact task/report/reading records from the current equipment
  scope. A query returns the first match and subsequent records so corrections can be read. Empty
  query retrieves chronology. Long records have explicit continuation offsets; partial evidence
  must not be interpreted as complete.
- Session metadata adds backward-compatible equipment scopes for tasks, identity and procedure
  position. Changing/clearing equipment separates old evidence, clears the old active procedure,
  and prevents it being restored onto the new machine. Old work remains in the job/audit record.
- Privacy diagnostics contain numeric component estimates, model/limit provenance and retry
  outcome only. Exact technician content is held in the existing session audit storage, not logs.

### Validation

Focused simulator suites cover 100-turn request reduction with the real Field Assist snapshot,
report persistence/restart, corrections, task status versus recommendations, equipment changes,
captured units, end-session isolation, legacy decoding, bounded manual/core references, streamed
overflow handling and an actual dispatched tool followed by overflow recovery without reexecution.
Existing session, equipment, work-record, retrieval, streaming, translator and cascade regressions
are included. Final isolated iPhone 17 Pro / iOS 27 simulator run: **165 tests, 0 failures,
2 skipped** (existing EquipmentIdentity/WorkRecord cases need the uninstalled Lennox manual files).
All new tests passed. The app/test target built successfully; the first final run stalled before
XCTest attached, and the same built tests passed on a fresh isolated simulator using
`xcodebuild test-without-building -parallel-testing-enabled NO` with the focused class list.
`git diff --check` passed. No physical-device or live-account claim is made.

Remaining limits: the build-378 failure and model response quality have not been reproduced with
the tester's account or physical glasses. A current question, essential instructions or a single
non-manual tool result that cannot fit still produces a clear local capacity error; it is never
silently truncated. Unknown models may need catalog refresh or a verified limit-table addition.
Live-mode context lifecycles and generated summaries remain separate work. Continuous conversation
is supported through bounded context and retrieval, not an unlimited in-memory model window.
