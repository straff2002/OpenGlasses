# Plan AX — Typed Memory Taxonomy (project-scoped recall + relevance over the existing stores)

**Status: ✅ Re-scoped and shipped ([#128](https://github.com/straff2002/OpenGlasses/pull/128)).**
**Re-scoped after auditing the code** — most of what an earlier draft proposed already exists, so this
plan targeted only the genuine gaps. Shipped in #128: **project-scoped memory** (`ProjectMemory` +
`ProjectMemoryScope`/`ProjectMemoryFormatter` + `project_memory` table on `BrainStore` + `project_note`
tool + flag-gated injection) and **relevance retrieval** (threading the turn into
`SemanticMemoryStore.systemPromptContext(query:)` at all call sites); both default-on for beta. The
audit also retired the dead `UserMemoryStore` entirely (its call sites rerouted to
`SemanticMemoryStore.systemPromptContext(query:)`, which already retrieves by relevance) — so Gap 2
below is moot, not deferred: there is no second store left to teach relevance retrieval to.
Deterministic cores are pure and tested; **zero LLM calls**. Remaining items are decisions, not planned
work: an optional `project` kind classifier (build only if free-text seeding needs it). No new SPM
dependency. Strictly on-device.

## What already exists (and why the original plan shrank)
An audit of the memory subsystem found three of the four "kinds" already modelled, plus the
relevance-retrieval mechanism the first draft proposed to build:

- **`SemanticMemoryStore`** (SQLite + embeddings) already holds key→value **facts** with vectors, and
  `systemPromptContext(query:)` **already relevance-filters** them via `semanticSearch` (top-8 by
  cosine) — exactly the "differentiated recall" idea. It also has an **agent diary**
  (`writeDiary` / `relevantDiary(for:)`) which *is* episodic memory, already retrieved by relevance.
- **`UserMemoryStore`** (JSON) holds the same key→value **facts/preferences**, LLM-managed via
  `[REMEMBER: key = value]` — but **dumps all of them** into every prompt (char-budgeted, sorted by
  key); it has **no** relevance retrieval.
- **`BrainStore`** (graph) holds typed relations, encounters, and needs.

So against the four kinds an earlier draft wanted to introduce:

| Kind | Reality |
|---|---|
| **semantic** facts | ✅ already modelled (both stores) |
| **episodic** | ✅ already exists (the diary, relevance-retrieved) |
| **preference** | ✅ already captured as facts (LLM-tagged) |
| **project state (active-scoped)** | ❌ **genuinely missing** — the gap this plan fills |

A standalone `TypedMemoryStore` would therefore largely **duplicate `SemanticMemoryStore`**. Dropped.
What's actually missing is narrow and concrete.

## The two real gaps
1. **Project-scoped memory.** Nothing models "what I'm in the middle of" as a first-class, *active-job*
   memory that's injected while a project is active and yields when it changes. Facts are durable and
   global; project state is transient and scoped. A field tech mid-way through a walk-in cooler job at
   Site 7 should have "compressor swap is next" surface while that job is open — and stop competing for
   prompt space once it's done.
2. **~~`UserMemoryStore` still dumps everything~~ — moot: `UserMemoryStore` no longer exists.** The
   audit that shipped this plan retired it outright; its call sites route through
   `SemanticMemoryStore.systemPromptContext(query:)`, which already retrieves by relevance. There is
   no second, dump-all fact store left to fix.

## What we build
### Gap 1 — Project-scoped memory (pure core + thin store extension)
- **`ProjectMemory`** — `{ id, projectTag, text, createdAt }`. A note scoped to a project/job.
- **`ProjectMemoryScope`** (pure) — given `(records, activeProject)` returns the records eligible for
  injection: those whose `projectTag` matches the active project (and none when no project is active).
  Pure, trivially tested.
- **`ProjectMemoryFormatter`** (pure) — eligible records → a `# Current project` block. Empty → "".
- Persistence rides `BrainStore`'s `brain.sqlite` (one un-synced on-device DB) via a small
  `project_memory` table — no new store class, no new file, no gateway exposure.
- **Active project** comes from `FieldSessionService` (an active job session); when none is active the
  block is empty. An explicit "I'm working on X" can seed a record via the classifier (below).

### Gap 2 — moot (`UserMemoryStore` retired)
- The original plan was to bring `UserMemoryStore` up to the relevance-retrieval behaviour
  `SemanticMemoryStore` already had. Instead, `UserMemoryStore` was retired outright and its call
  sites rerouted to `SemanticMemoryStore.systemPromptContext(query:)` — so the target behaviour was
  reached by deleting the store that lacked it, not by extending it. Nothing left to build here.

### Optional glue — a lightweight kind tag (only if it earns its keep)
- **`MemoryClassifier`** (pure, zero LLM) — `classify(_ text:) -> MemoryKind` where
  `MemoryKind ∈ {preference, project, episodic, semantic}`, used **only** to route an incoming memory:
  a `project` cue seeds a `ProjectMemory`; an `episodic` cue could seed the diary; everything else stays
  a fact. This is routing, not a new store — it adds the *one* dimension the stores don't have, without
  duplicating them. Build it only if Gap 1's seeding needs it; otherwise the `FieldSessionService`
  signal is enough.

## Scope
In:
- `Sources/Services/Brain/ProjectMemory.swift`, `ProjectMemoryScope.swift`,
  `ProjectMemoryFormatter.swift` (pure core) + a `project_memory` table in `BrainStore`.
- Relevance retrieval via `SemanticMemoryStore.systemPromptContext(query:)` at all call sites —
  shipped by threading the turn through, not by a `UserMemoryStore` overload (that store no longer
  exists).
- `(optional)` `Sources/Services/Brain/MemoryClassifier.swift` for routing only.
- Prompt wiring: inject the project block (when a job is active) and pass the turn to
  `SemanticMemoryStore`, both default-on for beta.

Out (deferred):
- A standalone `TypedMemoryStore` — **explicitly not building**; it duplicates `SemanticMemoryStore`.
- Re-typing existing facts/diary entries — new memories route going forward; no back-fill.
- A user-facing memory editor by kind — read path first.

## Architecture — the seam
```swift
struct ProjectMemory: Identifiable, Equatable {
    let id: UUID; let projectTag: String; let text: String; let createdAt: Date
}

enum ProjectMemoryScope {                              // pure
    static func eligible(_ records: [ProjectMemory], activeProject: String?) -> [ProjectMemory]
}
enum ProjectMemoryFormatter {                          // pure
    static func block(_ records: [ProjectMemory]) -> String   // "# Current project…" or ""
}

// Gap 2 reuses the SkillRetriever-shaped selection (similarity injected) over user-memory facts,
// ideally via one shared pure ranker rather than a second copy.
```
The decisions that matter — which project records are eligible, which facts are relevant — are pure and
tested; the only live edge is reading the active job and embedding the turn. With both flags off, the
prompt is assembled exactly as today.

## Build order
1. **Pure core + tests** — `ProjectMemoryScope`, `ProjectMemoryFormatter` (and `MemoryClassifier` only
   if needed). Deterministic; no store, no model.
2. **`project_memory` table** in `BrainStore` + round-trip / scoping tests.
3. **Project block wiring** — inject when `FieldSessionService` has an active job, behind a flag.
4. ~~`UserMemoryStore` relevance overload~~ — moot; `UserMemoryStore` was retired instead, and its
   call sites route through `SemanticMemoryStore.systemPromptContext(query:)`, which already ranks
   by relevance.

## Tests
- `ProjectMemoryScope.eligible`: only the active project's records pass; no active project → empty;
  multiple projects don't bleed.
- `ProjectMemoryFormatter.block`: empty → ""; formats eligible records under one heading.
- `SemanticMemoryStore` retrieval: below floor → all (unchanged); above floor → relevant subset + always
  the shortest/durable few; empty turn → all.
- `(if built)` `MemoryClassifier`: project cue → `.project`; preference cue → `.preference`; ambiguous
  → `.semantic` (never a confident wrong kind).

## Open questions / decisions needed
- **Shared ranker.** Gap 2 and `SkillRetriever` want the same "keep exact/durable + top-K by injected
  similarity" logic. Factor one pure ranker both call, or keep them separate for clarity? Leaning
  shared, since divergence is the real risk.
- **Project lifecycle.** Does a project's memory delete on job close, or persist (archived) for "what
  did I do on the Site 7 job"? Probably archive-not-delete, with only the *active* job injected.
- **Classifier necessity.** If `FieldSessionService` already names the active job, project seeding may
  not need a text classifier at all — prefer the explicit signal; add the classifier only if free-text
  "I'm working on X" capture proves worth it.
- ~~**Two fact stores.**~~ Resolved by deletion: `UserMemoryStore` was retired outright, not merged;
  `SemanticMemoryStore` is now the sole fact store. Whether `SemanticMemoryStore` and `BrainStore`
  themselves should unify remains a separate, still-open decision.

## Why this matters
The audit turned a big speculative feature into a small, honest one: the assistant already remembers
facts, preferences, and past events with relevance — what it *can't* do is hold "what you're in the
middle of" as a scoped, active context, and its JSON fact store still bloats every prompt. Both gaps
are real, both land as pure tested cores over stores that already exist, and neither duplicates working
infrastructure. Pairs with [Visual State Memory](visual-state-memory.md) (aged keyframe descriptions →
diary/episodic) and the [Embedding Quality Upgrade](embedding-quality-upgrade.md) (sharper similarity
through the same `Embedder` seam that both gaps use).
