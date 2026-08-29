# Plan DX — Private Memory Timeline and Control Surface

**Status:** 📝 Drafted (2026-08-29)
**Origin:** Follow-up to the opportunity assessment's “explicit private memory” recommendation and
the DK plan review. The app already retains several kinds of memory, but it has no single place where
the user can see, correct, or genuinely remove what is retained.
**Priority:** P1 differentiated everyday product, after DK P0–P2 for conversation-backed entries.
Independent of the waveguide/HUD; the management experience is phone-first.

---

## Product promise

“Show me what OpenGlasses remembers, where each memory came from, and let me correct or forget it.”

The timeline is an explicit control surface over durable memory. It is not a lifelog, a second chat
history, or permission to retain every camera frame and transcript. Glasses may capture or retrieve a
memory by voice; browsing, correction, export, and bulk deletion stay on the phone.

## Verified starting point

Memory is already split across independent stores with different semantics:

- `ConversationStore` is the protected source of truth for chat. Its current FTS projection is not
  lock- or deletion-safe; Plan DK replaces that projection with a lock-scoped in-memory index.
- `SemanticMemoryStore` holds user facts/preferences and diary observations in
  `semantic_memory.sqlite`, with
  namespaces and semantic retrieval.
- `BrainStore` holds relational knowledge and project-scoped notes in `brain.sqlite`.
- `ObjectMemoryStore` holds remembered object locations as JSON in `UserDefaults`.
- Notes, saved places, receipts, calendar events, and reminders have their own operational stores or
  system frameworks; they are not automatically “memory” merely because the app can query them.

Today the stores have no shared provenance vocabulary, capability contract, or user-facing index.
A UI that copies their content into one more database would create another deletion, lock, migration,
and privacy problem—the exact class of problem DK is fixing.

## Prerequisites and ordering

1. **DK P0–P2 is mandatory before conversation content joins the timeline.** Until DK's coordinator
   reports `.ready`, the conversation adapter reports `.locked`, `.rebuilding`, or `.unavailable` and
   returns no content.
2. The non-conversation timeline can be developed in parallel with DK, but it must remain behind a
   default-off feature flag until the storage-protection and deletion audit in DX P0 passes.
3. DX does not block **My Day**. My Day should remain the earlier visible everyday-copilot slice; DX
   is the control surface that later lets the copilot use durable memory transparently.

## Decisions and invariants

1. **Existing stores remain authoritative.** There is no unified content database and no durable
   timeline cache. `MemoryTimelineRepository` is a façade that performs an ephemeral, stable merge of
   records returned by source adapters.
2. **The default feed contains durable memories, not every event.** Explicitly saved facts, object
   locations, project notes, and diary observations qualify. Full conversation turns remain in Chat;
   they appear only in an explicit timeline search/recall result and link back to their thread.
3. **Provenance is data, not copy.** Every item names its source, capture method, time, and scope.
   Existing rows whose origin cannot be proven migrate as `legacyUnknown`; the UI never guesses that
   they were explicitly saved.
4. **Browsing does not broaden agent recall.** A record being visible in the timeline does not make it
   eligible for prompt injection. Existing memory flags, conversation lock, namespace rules, and
   active-project scoping continue to decide agent recall.
5. **Lock and protected-data state fail closed.** A locked/unavailable source contributes a labelled
   source status, never stale rows. No adapter reads around its source's protection boundary.
6. **Forget means source deletion.** The repository calls the authoritative adapter, waits for a
   verified result, and then refreshes. Hiding a row or deleting only a projection is not success.
   Where a source cannot delete a single item correctly, the UI disables that action and says why.
7. **Memory-off and erase are different operations.** Turning durable capture off prevents new
   memories and prompt injection; it does not silently delete existing data. “Erase” names its exact
   scope and requires confirmation.
8. **Local-only by default.** The timeline adds no gateway sync, analytics, Spotlight indexing, or
   cloud search. Export is user-initiated, confirmed, protected, excluded from backup, and cleaned up
   through the app's shared temporary-export lifecycle.
9. **No HUD dependency.** No timeline renderer, card browser, or Neural Band interaction is in scope.
   Voice routes may save, search, open on phone, or forget one unambiguous item through DJ's shared
   execution authority.

## Common read model—identity, not storage

```swift
struct MemoryTimelineItem: Identifiable, Equatable, Sendable {
    let id: MemoryTimelineID       // sourceID + source-owned stable record ID
    let kind: MemoryKind           // fact, observation, object, project, conversation
    let title: String
    let preview: String
    let createdAt: Date
    let updatedAt: Date?
    let origin: MemoryOrigin       // explicit, inferred, imported, system, legacyUnknown
    let source: MemorySourceRef    // store + deep-linkable record/thread reference
    let scope: MemoryScope         // global, persona, project, conversation
    let capabilities: Set<MemoryCapability> // open, edit, delete, export
}
```

The model deliberately contains no embedding or copied full-text payload. A source may return a
bounded preview for the current request; opening or editing resolves the current record from that
source again. Stable identity is `(sourceID, recordID)`, so identical text in two sources is not
silently deduplicated into one record with ambiguous deletion behavior.

## Repository and source adapters

```swift
protocol MemoryTimelineSource: Sendable {
    var sourceID: MemorySourceID { get }
    func page(_ request: MemoryPageRequest) async -> MemorySourcePage
    func search(_ request: MemorySearchRequest) async -> MemorySourcePage
    func resolve(_ id: MemoryTimelineID) async -> MemoryResolution
    func mutate(_ request: MemoryMutation) async -> MemoryMutationResult
}

actor MemoryTimelineRepository {
    // Fans out to allowed sources, merges by (createdAt, stable ID), and preserves
    // per-source locked/rebuilding/unavailable status alongside the results.
}
```

Initial adapters:

| Adapter | Source of truth | Browse behavior | Mutation behavior |
|---|---|---|---|
| `SemanticMemoryTimelineSource` | `SemanticMemoryStore` | Facts and diary observations, namespace-labelled | Edit/delete through store APIs; refresh and verify |
| `ObjectMemoryTimelineSource` | `ObjectMemoryStore` | Explicitly saved object locations | Edit/delete the named object record |
| `ProjectMemoryTimelineSource` | `BrainStore` | Active project by default; archived project only by explicit filter | Edit/delete by stable project-memory ID |
| `ConversationMemoryTimelineSource` | `ConversationStore` + DK coordinator | Search-only; absent from default feed; source status visible | Open thread; deletion remains thread/message-owned |

Notes, saved places, receipts, reminders, and events are follow-up adapters only when their source has
a stable identity, honest provenance, record-level deletion, and the correct system permission. DX
must not turn the timeline into a second copy of Apple Calendar or Reminders.

### Partial availability

Repository results contain both items and source status. If semantic memory is available while
conversation recall is locked, the UI shows the semantic results and a “Conversations are locked”
status row. It never presents the partial set as “everything OpenGlasses remembers.” Pagination uses
a per-source cursor plus a deterministic `(date, id)` merge; one slow source cannot reorder rows
already shown.

## Access policy—not a new iOS permission

`MemoryAccessPolicy` is a pure internal policy evaluated before every adapter operation:

```swift
enum MemoryOperation { case browse, search, open, edit, delete, export, agentRecall }

struct MemoryAccessContext {
    let operation: MemoryOperation
    let userInitiated: Bool
    let protectedDataAvailable: Bool
    let conversationRecallState: ConversationRecallState
    let activePersonaID: String?
    let activeProjectID: String?
    let durableMemoryEnabled: Bool
    let inferredMemoryEnabled: Bool
}

enum MemoryAccessDecision { case allow, confirm, deny(MemoryDenialReason), unavailable(MemorySourceState) }
```

Policy rules:

- Phone browsing/search is user-initiated and may span selected scopes, but still respects lock and
  protected-data state.
- Agent recall is limited to existing eligible namespaces and the active project; DX grants no new
  prompt access merely because the timeline can display a record.
- Inferred/diary memories have a separate toggle and a visible label. Disabling them removes them
  from injection and future capture, while existing records remain manageable in the timeline.
- Archived projects are browseable by deliberate filter but never injected as active context.
- Delete and export require confirmation. Voice deletion must resolve exactly one record; ambiguity
  returns candidates for phone review rather than guessing or bulk-deleting.
- Conversation search is allowed only when DK reports `.ready`; a lock transition invalidates the
  result before open/export/delete can proceed.

This policy does not replace iOS permissions for Calendar, Reminders, Contacts, Location, or Photos.
Those remain enforced by their owning frameworks and adapters.

## Phone experience

Add a **Memory** destination reachable from the everyday experience surface and from Settings →
Intelligence. It has four deliberately small surfaces:

1. **Timeline** — newest first, filterable by kind and source, with explicit/inferred badges and
   visible locked/unavailable source rows.
2. **Search** — on-device federated search; conversation results appear only here and deep-link to
   the original thread.
3. **Memory detail** — full provenance, scope, capture method, created/updated time, source link, and
   only the edit/delete/export actions the source truthfully supports.
4. **Controls** — durable memory on/off, inferred observations on/off, included sources, retention
   explanation, per-source counts, export, and exact-scope erase actions.

The empty state teaches the explicit flow: “Say ‘remember that…’ or save an object, note, or project
detail.” It must not encourage continuous recording. VoiceOver reads origin and scope before action
buttons; dynamic type, keyboard search, and destructive-action labels follow Plans DF/DG.

## Phases

### P0 — Contracts, privacy audit, and source readiness 🔴

1. Add the pure item/identity/capability types, `MemoryAccessPolicy`, merge/pagination core, and fake
   adapters with exhaustive tests.
2. Audit every proposed source for file protection, backup behavior, stable IDs, per-record deletion,
   lock behavior, and content-free logging. A failing source is excluded rather than weakened.
3. Move `ObjectMemoryStore` out of `UserDefaults` into an injected, protected local store with a
   versioned, retryable migration. Remove the legacy preference only after round-trip verification.
4. Add provenance fields at write boundaries. Legacy rows become `legacyUnknown`; do not infer
   provenance from their text.
5. Add `Config.memoryTimelineEnabled`, default off. The flag hides the surface and voice routes; it
   does not alter or erase source data.

### P1 — Non-conversation timeline MVP 🟠

1. Implement semantic, object, and project adapters over their existing stores.
2. Ship Timeline, filters, detail, source status, edit/delete, and controls on the phone.
3. Keep project prompt injection unchanged: only the active project is injected even when archived
   projects are visible by filter.
4. Add deterministic deep links from a row to its owning project/object/memory editor where one
   exists; otherwise detail remains the honest owner.

### P2 — DK-backed conversation search 🟠

1. Implement the conversation adapter strictly through `ConversationRecallCoordinator`.
2. Keep conversation turns out of the default feed; federated search returns bounded snippets and
   thread links only while unlocked.
3. Invalidate open result handles immediately on lock, protected-data loss, store replacement, or DK
   projection-version change.
4. Delete/truncate stays owned by `ConversationStore`; after mutation, wait for DK projection parity
   before reporting success.

### P3 — Explicit capture, correction, and voice routes 🟡

1. Route “remember this” writes with explicit origin and a source reference; inferred diary writes
   carry inferred origin and obey the separate toggle.
2. Add “what do you remember about…?”, “forget…”, and “open my memories” routes. Search is read-only;
   edit/delete execute through DJ's authority and never resolve ambiguity automatically.
3. Add source-owned correction APIs where safe. A correction updates the authoritative record and
   invalidates embeddings/projections; the repository stores no patch of its own.
4. Add a protected export with manifest + records, user preview, no hidden attachments, and
   deterministic cleanup. Import is deferred until a conflict/versioning design exists.

### P4 — Additional explicit-memory adapters 🟡

Add notes, saved places, and structured-capture outputs one source at a time. Each adapter must pass
the P0 contract suite. Calendar and Reminders remain linked operational data by default rather than
durable OpenGlasses memory; a user can explicitly save a reference, but DX does not mirror their
databases.

## Tests and evidence

- **Policy matrix:** every operation × locked/protected-data/memory-enabled/inferred/project state;
  conversation content never passes before DK `.ready`.
- **Merge core:** stable order, identical timestamps, duplicate text with distinct IDs, pagination,
  one failed/slow source, and lock during an in-flight search.
- **Adapter contracts:** stable IDs; bounded previews; truthful capabilities; edit/delete round-trip;
  missing record; source failure; namespace and active-project isolation.
- **Provenance:** every new write carries an origin; legacy migration produces `legacyUnknown`; no
  UI or tool upgrades unknown origin to explicit.
- **Deletion:** delete removes the authoritative content and its searchable projection; failed writes
  remain visible and report failure; rapid delete/search cannot resurrect a row.
- **Filesystem/privacy:** no new durable timeline content file; protected-store attributes and backup
  exclusions verified; object-memory legacy data removed only after verified migration; no content in
  production logs.
- **Conversation integration:** lock/rebuild/ready, lock during result open, thread delete, truncate,
  edit/regenerate, store replacement, and projection-version ordering using DK's fixtures.
- **UI/accessibility:** VoiceOver order, Dynamic Type through accessibility sizes, keyboard search,
  explicit destructive labels, empty/partial/locked states, and small-iPhone layouts.
- Release build and full suite green; on-device protected-data and biometric-lock smoke recorded.

## Rollout and rollback

P0/P1 ship behind `memoryTimelineEnabled` default off. Enable for internal builds only after every
included source passes the contract and filesystem tests. P2 cannot enable before DK P0–P2 is on by
default. A rollback hides the façade and disables voice routes; it never restores a plaintext index,
reverses a completed protected-store migration, or deletes source data.

## Exit criteria

DX is complete when:

- the user can inspect every included durable-memory source from one phone surface without a copied
  timeline database;
- every item displays truthful origin, scope, time, source, and supported actions;
- locked or unavailable sources are visible as unavailable and leak no stale content;
- agent recall remains no broader than before DX unless the user separately enables its existing
  source setting;
- correction and deletion mutate the authoritative store and its projection, with regression tests;
- no continuous transcript/frame lifelogging or automatic cloud sync was introduced; and
- conversation search satisfies DK's lock, deletion, and projection-integrity guarantees.

## Explicit non-goals

- A new all-memory SQLite database, event bus, or cloud account.
- A complete copy of Chat, Calendar, Reminders, Photos, or Health data.
- Continuous visual/audio capture, passive location history, face dossiers, or social scoring.
- HUD/waveguide browsing or Neural Band navigation.
- Automatic import/export sync or a public memory API.
- Using the timeline's broad phone-browse authority as the agent's prompt-injection authority.
