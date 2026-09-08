# Plan AN — Projects (scoped persona + documents + conversations)

**Status: ✅ Shipped.** Documents scope to the active project namespace (`DocumentRAGTool` +
`DocumentStore.list/documentCount(namespace:)`); conversations carry `personaId` on
`ConversationThread` (legacy threads decode to `nil`) with `threads(forPersona:)` + a Chat-tab project
filter; the active project's knowledge base is grounded into both prompt builders via the pure
`ProjectScope.knowledgeHint` + `ProjectContextService` (only advertised when the project has ≥1 doc);
and `ProjectDetailView` shows a project's prompt + scoped documents + scoped conversations. 8 tests
green in Release. No new SPM packages.

**Updated 2026-07-10:** the shareable export/import bundle (item 5) **shipped** —
`ProjectBundle`/`ProjectBundleCodec` + `ProjectExporter`; export via share sheet in
`ProjectDetailView.swift:99-110`, import via file picker in `PersonasView.swift:144-146`.

**The real deferred item was a leak found in review — closed in Plan BM P8 (`238f787`,
[#193](https://github.com/straff2002/OpenGlasses/pull/193)):** the project boundary was violated —
`BrainTool` queried docs and memory with `namespace: nil`, which `DocumentStore.fetchChunks`
treated as ALL namespaces, so `brain ask` in an unscoped chat quoted every project's documents and
crossed persona memory namespaces; `TeleprompterTool.swift:77` resolved documents by name across
all namespaces too. `DocumentRAGTool` already scoped correctly. Both `BrainTool` and
`TeleprompterTool` now go through a shared `scopedNamespaces()` helper, closing the invariant this
plan's "global fallthrough" open question never stated: **global never sees project docs.**

**Builds on:** the [`Persona`](../../OpenGlasses/Sources/Utils/Config.swift) system (Config + [`PersonasView`](../../OpenGlasses/Sources/App/Views/PersonasView.swift) + [`PersonaPickerSheet`](../../OpenGlasses/Sources/App/Views/PersonaPickerSheet.swift)), the [`DocumentStore`](../../OpenGlasses/Sources/Services/RAG/DocumentStore.swift) `namespace` column (Plan [O](O-document-rag.md)), and [`ConversationStore`](../../OpenGlasses/Sources/Services/ConversationStore.swift) threads.

**Strategic fit:** the organizing layer that makes the standalone app sticky. A **Project** = a named context bundling **{a persona/system-prompt + its own scoped documents + its own conversations}**. One place to say "load this context" — generalizes the museum-docent idea ([[project_museum_context_page]]) into a reusable primitive: a "Spanish tutor" project, a "Code review" project, a "Field site X" project, each with its own knowledge and history. Pairs with [standalone-chat-experience.md](standalone-chat-experience.md) (per-project threads) and [O-document-rag.md](O-document-rag.md) (scoped docs).

**Effort:** ~3–4 days.

---

## What already exists (reuse, do not rebuild)

- **`Persona`** already bundles `{id, name, wakePhrase, modelId, presetId, enabled, icon?, soulOverride?, allowedTools?, ownedTaskIds?}` — i.e. the system-prompt (via `presetId`/`soulOverride`), model, and identity of a context. Activating a persona (`PersonaPickerSheet.activatePersona`) sets `appState.activePersona`, `Config.activeModelId`, `Config.activePresetId`, refreshes the model and **clears LLM history**.
- **`DocumentStore`** already has a `namespace` column (`ingest(..., namespace:)`, `query(..., namespace:)`) — but it **always defaults to `"global"`**; persona scoping is not wired.
- **`SemanticMemoryStore`** already namespaces memory by persona id / `"global"` — the scoping precedent exists.
- **`ConversationStore`** threads record `mode` (AppMode) but **no persona/project id**.
- **`BrainTool`** is already injected with `documentStore` in `NativeToolRegistry`; the knowledge-base query path exists.

## The gap

1. **Documents are global.** Every ingested doc lands in the `"global"` namespace; there's no "ask only about *this* project's docs."
2. **Conversations aren't grouped by context.** A thread knows its `mode` but not which persona/project it belongs to, so History/Chat can't filter to a project.
3. **No single context surface.** Nothing shows "this project = its system prompt + its documents + its chats" in one place.
4. **Knowledge-base tool is unconditional.** `search_knowledge_base`-style retrieval isn't gated on whether the active context actually has documents.

## Design decision

**Extend `Persona` into the Project concept rather than introduce a parallel type.** A Persona already carries prompt + model + identity; a Project is a Persona plus *scoped knowledge and history*. This avoids a duplicate concept and reuses the existing personas UI. In the UI we surface the doc+chat-scoped view as a **Project**; the underlying type stays `Persona`.

## New work

**1. Scope documents to the active project.**
- Pass `namespace: appState.activePersona?.id ?? "global"` at `DocumentStore.ingest` and `query` call sites (the `BrainTool`/Document-RAG query path).
- A "Global" project (`"global"` namespace) remains for unscoped docs available everywhere.
- Small change; the storage layer already supports it.

**2. Tag conversations with their project.**
- Add `personaId: String?` to `ConversationThread`; set it in `startThread` from `appState.activePersona?.id` (nil ⇒ legacy/global). Backwards-compatible decode (optional field).
- Filter the Chat/History thread list by the active project, with an "All" view.

**3. Project detail surface.**
`Sources/App/Views/Projects/ProjectDetailView.swift` (extends `PersonaEditorView`): one screen showing the persona's **system prompt** (preset/`soulOverride`), its **documents** (ingest via Files/scan, list, delete — a `DocumentStore` view scoped to `namespace = persona.id`), and its **conversations** (threads where `personaId == persona.id`). This is the "manage this context" home.

**4. Conditional knowledge-base advertisement.**
Only advertise/inject the `search_knowledge_base` capability when the active project has ≥1 document (query `DocumentStore` chunk count for the namespace). Keeps the tool list honest and avoids the model offering retrieval over an empty KB. Mirrors Plan O's "inject when the project has documents" intent.

**5. (Optional, defer) Shareable project bundle.**
Export/import a Project (persona + its documents) between devices, reusing the Plan [Q](Q-vault-and-skills-library-management.md) vault export/import patterns. Defer past v1.

## Build order

1. `personaId` on `ConversationThread` + `startThread` wiring + decode migration (nil ⇒ global) + tests.
2. Namespace-scope `ingest`/`query` to the active persona id (+ "Global" project) + tests against a temp DB.
3. `ProjectDetailView` (prompt + scoped docs + scoped chats); thread-list filter by project.
4. Conditional KB advertisement (namespace chunk-count gate).
5. (Optional) export/import.
6. Full suite + **Release** build green before PR.

## Open questions

- **Vocabulary.** Surface as "Projects" while keeping `Persona` as the type? *Recommendation: yes* — "Projects" is the user-facing framing of a persona with scoped knowledge/history; don't rename the type.
- **Switching projects clears chat context.** `activatePersona` already calls `clearHistory()`. *Recommendation: keep that* — switching project = switching context — and rely on per-project threads for continuity.
- **Memory scoping.** `SemanticMemoryStore` already namespaces by persona; align project memory to the same id so memory, docs, and chats share one scope.
- **Global fallthrough.** Should a project also see global docs? *Recommendation: query the project namespace first; offer an explicit "include global knowledge" toggle per project rather than always merging.*
- **Default project.** Existing users have only "global" — present that as the default Project so nothing disappears; new personas become projects automatically.

## Dependencies

- Plan [O](O-document-rag.md) (Document RAG, shipped), the `Persona` system (shipped), `ConversationStore` (shipped). No new SPM packages. Stronger retrieval comes from [embedding-quality-upgrade.md](embedding-quality-upgrade.md); the per-project chat UI comes from [standalone-chat-experience.md](standalone-chat-experience.md).
