# Plan FJ — Wearer Memory Across Live Voice Sessions

**Status: 📝 Drafted 2026-09-19 — not scheduled; no implementation under this plan.** Reviewed
2026-09-19 against `main`: invalidation narrowed to included facts, mutation inventory and the
live memory-tool path added, dormant expiry timer dropped.

Include a bounded snapshot of the wearer's saved memory when starting either live voice backend.
A wearer who saves a preference in ordinary conversation should not lose it merely by entering live
mode. Retire stale provider context on deletion, memory disablement or a scope change. Deliver one
PR for this plan; use the checkpoints below for review and testing.

## Current implementation and ownership

| Repository path / symbol | Starting point |
|---|---|
| `OpenGlasses/Sources/Services/GeminiLive/GeminiLiveSessionManager.swift`, `startSession`, `buildSystemInstruction`, `makeRecoverySeams` | Builds live instructions on start and certain reconfigurations/recovery paths; currently records wearer memory as `notInjected`. `buildSystemInstruction(recoveredContext:)` is **synchronous** and has three callers today (start, the vision reconfigure, the no-resume recovery rebuild): pass the snapshot in as a value; never fetch memory inside the builder. |
| `ToolDeclarations.allDeclarations(registry:includeOpenClaw:)` | Both live backends declare every native tool, including `memory_search` and `brain` — so saved facts **already** reach live provider history through tool results, with no invalidation and no memory-off gate (FI adds the gate). |
| `SemanticMemoryStore` mutation paths | `remember`/`rememberGlobal` (and the `trim` eviction each triggers), `forget`, `clearAll`, `clearPersonaMemories`, `purgeExpired`, `purge(olderThan:)` (the retention scheduler), `parseAndExecuteCommands` (`[REMEMBER…]` tags from ordinary turns and `AgentScheduler`), legacy JSON migration and `syncFromGateway`. This is the inventory the typed change signal must cover. |
| `OpenGlasses/Sources/Services/OpenAIRealtime/OpenAIRealtimeSessionManager.swift`, `startSession`, `buildSystemInstruction`, `stopSession` | Independently builds instructions and also records `notInjected`. |
| `OpenGlasses/Sources/Services/OpenAIRealtime/OpenAIRealtimeService.swift`, `configure` and setup send | Carries instructions into the wire payload; completion of a builder is not proof the provider accepted it. |
| `OpenGlasses/Sources/App/OpenGlassesApp.swift`, `memoryContextForPrompt` | Ordinary-turn memory assembly and the current settings gates. Inject dependencies from AppState rather than reaching for a second store singleton. |
| `OpenGlasses/Sources/Services/Diagnostics/MemoryContextSnapshot.swift`, `MemoryContextRecorder.swift` | Existing live route labels and `connectSnapshot(age:)`; retain truthful freshness. |
| `OpenGlasses/Sources/Services/Live/LiveContextHandover.swift` and `ConversationReset/ConversationResetCoordinator.swift` | Existing recovery/history and reset generation boundaries. They remain owners of history continuity and reset. |
| `OpenGlasses/Sources/Services/Privacy/SubjectErasureCoordinator.swift` | Subject erasure must also invalidate derived live memory context. |

[FI](FI-memory-retrieval-relevance.md) owns memory selection and structured `MemoryContextBlock`.
FJ may implement against an injected stub before FI merges, but production must use the shared FI
builder; do not ship a second ranker. [EX](EX-conversation-reset-across-backends.md),
[FF](FF-blind-assistant-readiness.md), [EW](EW-session-resource-cleanup.md) and
[BD](BD-realtime-session-resilience.md) retain reset, accessibility, resource and recovery ownership.
This plan does not add conversation transcription persistence, live auto-extraction, new tools,
external graph reads or new AI providers.

## Wearer contract

- Existing Memory and Memory Retrieval settings retain their ordinary-turn meanings. Memory off
  performs no memory read and puts no saved-memory block in the outgoing setup.
- Initial live setup selects recent global and active-persona facts; there is no transcript query at
  connection time. Do not pretend an empty query means the upcoming question was predicted.
- A live session uses a connection-time snapshot. A newly added fact becomes available on the next
  new connection; show that limitation in the memory settings help text. No polling or reconnect
  on every ordinary insertion. Query-specific refresh during a running session is a separate feature.
- An edit/replacement, deletion or eviction **of an included fact**, memory disablement,
  persona/project scope change, subject erasure, or a bulk/unknown mutation invalidates the current
  snapshot immediately. A change to a fact the snapshot did not include does not — retiring a
  conversation because an unrelated row changed would make Settings edits disruptive for nothing.
  Because a row's ID survives an edit (`"<namespace>:<key>"`), compare included (ID, last-write
  time) pairs, not IDs alone. Stop the affected
  live conversation before it can answer again with stale saved memory. Explain briefly that memory
  changed and the user can restart the conversation. Never silently resume the retired session.
- Information already sent to a provider cannot be recalled by clearing a local buffer. UI/export
  copy must describe prevention of future reuse, not deletion from the provider's infrastructure.

- Facts the model fetches mid-session through `memory_search`/`brain` are tool results in provider
  history, outside the snapshot. For this plan: invalidation of any fact returned by such a call in
  the current live generation retires the session the same way (record returned references at the
  tool boundary, process-local only). If that proves too broad to build here, say so explicitly in
  the settings help and the FC inventory rather than implying the snapshot is the only live egress.

The initial implementation deliberately uses session retirement for invalidation on both backends.
An instruction update alone cannot remove facts from provider conversation history, cached responses
or resumption state. Do not implement a backend-specific shortcut that weakens this guarantee.

## Shared contracts

Proposed types under `OpenGlasses/Sources/Services/Live/`:

| Type | Minimum fields / responsibility |
|---|---|
| `LiveMemoryRequest` | Backend route, conversation generation, session generation, captured persona/project scope, memory/retrieval switches, injected time and character budget. |
| `LiveMemorySnapshot` | Structured FI block, selected local memory references, captured scope and privacy generation, store revision, earliest selected expiry, assembly time. Contents remain process-local. |
| `LiveMemorySnapshotProvider` | Async injectable builder returning a snapshot or a typed absent/unavailable result; no capture/audio/session side effects. |
| `LiveMemoryPolicy` | Pure decision for assemble/accept/discard/retire; evaluates generation, scope, revision changes and selected references. |
| `LiveMemoryCoordinator` | One snapshot per live generation, change subscriptions (an expiry deadline is deferred until a TTL writer exists — see P2); cancellation/teardown routed through existing session owners. |

Use explicit lifetime identity even when two consecutive sessions use the same persona. Capture all
inputs before await and validate them again immediately before transport configuration and setup
send. A late result after Stop/reset/switch is discarded. Never re-enable a stopped session from an
invalidation callback. UI-facing state remains `@MainActor`; selection can operate on immutable data.

Add a typed store-change signal with reason, affected reference IDs/namespaces and revision. A bulk
clear or unknown mutation conservatively invalidates all snapshots in the affected store/scope.
Privacy generation changes are independent of ordinary insertion revisions. All existing local and
gateway mutation entry points must be inventoried; gateway facts are excluded from initial FJ setup,
so their arrival does not widen live egress. Do not emit raw IDs or namespace names in diagnostics.

## Prompt assembly and budget

Use the FI builder with `query: nil` and an explicit global/active-persona scope. Initial budget is
2,400 characters total including headings, maximum eight entries overall, maximum 300 characters
per value and 80 per key. Give each nonempty allowed section up to four entries first, then fill
unused slots with the remaining most recent eligible entries. Drop whole lowest-priority entries
until the block fits. These are shared constants, not duplicate backend values.

Append a clearly delimited saved-memory data section to the existing instruction composition.
It must say facts may be outdated and must not override the current user, system rules or tool
permissions. Escape delimiters and control characters. Preserve mode/accessibility instructions,
vision status, location, tools, reading/project context, recovery handover and injection policy in
their existing relative order; where a backend lacks a section, do not claim parity or add unrelated
features. Saved memory is never a user message, spoken greeting or automatic tool invocation.

Memory budget cannot silently truncate safety instructions or history handover. Provider setup size
validation happens after complete composition. If the existing provider budget cannot accommodate
the block, omit whole entries, record budget omission, and continue with truthful memory diagnostics.
Do not claim exact tokens using a character estimate. Read failure allows connection without memory
and records unavailable; it must not invent an empty personal profile.

## Lifecycle and diagnostic semantics

| Event | Required result |
|---|---|
| Start | Assemble once, validate generation/scope, configure actual transport with that block. |
| Builder called again for camera/context changes | Reuse the valid snapshot; do not reset its age or add duplicate blocks. |
| Transport reconnect with a supported resume handle | Reuse the valid snapshot represented by that handle; preserve original snapshot age. |
| Rebuild without resume / backend switch | Assemble a new snapshot from current eligible memory; old callbacks cannot win. |
| Edit/delete/evict of an included or tool-returned fact, disable, scope change, erasure, bulk clear | Invalidate first, cancel pending start, stop response/audio, retire transport/resume handle and affected history handover via existing owners. |
| Explicit Stop / reset / failed setup | Release snapshot, subscriptions and expiry work; no retained memory in service configuration or queued payloads. |
| Ordinary new memory insertion | Keep the existing snapshot; next new connection sees it. If insertion replaces an existing key, classify as edit. If the insertion's `trim` evicts an included fact, classify that as a deletion. |
| Unrelated edit/delete | Keep the snapshot; no retirement. |

Deleting a fact may leave its text in local conversation handover. For invalidations, reset the
reusable conversation context conservatively through the existing reset seam; do not try substring
redaction of arbitrary model paraphrases. Scope changes use the same boundary. A failed reset stops
the session and remains visible as a failure; it never continues using the previous setup.

Keep assembly, submitted setup and provider acceptance separate. Extend finite diagnostic state
if necessary; only record the active live snapshot when its generation is submitted to transport,
and mark acceptance separately if the backend supplies acknowledgement. Builder previews must not
replace active diagnostics. Failed setup/stop clears active state. Count actual included/clipped
entries, preserve `connectSnapshot(age:)`, and retain absent reasons from FI. No memory contents,
keys, IDs, hashes, persona names or transcripts enter `PrivacyLog` or diagnostic exports.

## Implementation checkpoints

### P0 — Shared builder and lifecycle policy

Add fake store/clock/transport seams and pure lifecycle tests. Audit live start/rebuild/reset callers
and store mutation paths in an implementation note. Use FI types or a protocol-compatible fixture.
Define coordinator ownership before changing backend builders; no second reconnect controller.

### P1 — Wire both providers

Inject the snapshot provider from AppState. Replace unconditional `notInjected` records with actual
assembly/submission state. Capture outgoing Gemini setup and OpenAI session configuration in tests
and assert the memory bytes once in the actual payload, not only in a standalone formatter.
Preserve existing capability/injection gates, and keep memory unavailable handling nonfatal.

### P2 — Invalidation, disposal and accessibility

Wire edits, eviction, retention purge, erasure, scope changes and settings disablement through typed
notifications. **No expiry deadline timer yet:** no production writer sets `expires_at`, so a timer
would guard a path nothing exercises. Keep the earliest-expiry field in the snapshot and filter at
assembly; add the deadline in the PR that first writes a TTL. `purgeExpired` still flows through the
ordinary deletion signal.
Cancel stale assembly and clear recovery/configuration buffers. Add one concise localized status
and a restart action using existing live controls and audible lifecycle machinery; no duplicate TTS
owner. Respect mute, VoiceOver and existing lifecycle priorities. A privacy stop can interrupt speech.

### P3 — Acceptance and evidence

Run integration/race tests, update `FC-memory-context-inventory.md`, and record both provider device
passes separately. Update `ProcessingSummary` (FF PR8, "where each part of a request goes") so saved
memory is listed as going to the live provider when this ships, and the Prompt Inspector's live view
shows the same block the transport received. Update public memory capability text only to the behaviour actually shipped.

## Acceptance matrix

Tests must use controlled clocks, fake stores and captured transport messages; no provider credentials.
Cover both backends for: enabled/disabled/empty/unreadable memory; unrelated edit (no retirement);
eviction of an included fact by a later insert; invalidation of a fact returned by `memory_search`; persona isolation; budget omission;
long/malicious values; start-stop during await; two concurrent starts; old callback after switch;
reset during configure; deletion before setup send; deletion after setup; included expiry (seeded `expires_at`, filtered at
assembly); unrelated insert; replacement under the same key; failed setup; reused resume snapshot; fresh rebuild; and
no-resume rebuild after invalidation. For OpenAI, test only resume behaviours the current adapter
actually supports; unsupported resume must become a fresh setup, never a simulated success.

Assert no stale fact in outgoing setup/handover, no automatic re-start after privacy invalidation,
zero retained subscriptions/deadlines after stop, and no memory canary in diagnostics. Existing live
recovery, reset, audio lease and memory-diagnostic tests must still pass.

Device acceptance: save a synthetic preference in ordinary mode, start each provider, ask for it,
stop/restart, then edit/delete/disable it during live use. Record actual prompt inclusion separately
from model response accuracy. Verify the lifecycle notice and restart action with VoiceOver and on
glasses, including interrupted speech and reconnect. Credentials/hardware unavailable means owed
provider/device evidence, not a passing end-to-end claim.

## Rollout and completion

Use one internal rollout switch defaulting off until both adapter tests and invalidation tests pass;
turning it off retires sessions carrying the feature before any new setup. No persistent memory
migration is required. An application restart never restores a serialized snapshot. Complete when
both providers send the bounded block, invalidation prevents further old-context responses, existing
reset/recovery tests pass, and docs distinguish local automated evidence from owed device checks.
