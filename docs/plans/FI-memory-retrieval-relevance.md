# Plan FI — Relevant Memory Retrieval Without Embeddings

**Status: 📝 Drafted 2026-09-19 — not scheduled; no implementation under this plan.** Reviewed
2026-09-19 against `main`: starting points re-verified; eviction, CJK/locale, shared-consumer,
re-embed and scale corrections folded in below.

Make the facts included in a conversation relevant to the wearer's request even when the embedding
model is missing, unavailable or fails. Apply the same selection policy to shared and active-persona
memory, preserve namespace boundaries, and make an empty match distinguishable from empty storage.
Deliver one PR for this plan, with the phases below as implementation checkpoints.

## Outcome and scope

With twenty saved facts, “Where did I park?” retrieves `parking_location = lot B, level 3` even if
its key sorts after the first eight entries. A failed embedding lookup changes the ranking method,
not the availability of relevant memory. A query about parking must not pull another persona's facts.

This plan changes selection of already-saved semantic memory. It does not add automatic extraction,
external graph services, new model downloads, conversation indexing, or new memory settings.
[EN](EN-memory-distillation-and-external-graph-memory.md) owns distillation/graph evolution;
[DX](DX-private-memory-timeline.md) owns the private timeline;
[FA](FA-reading-source-and-memory-continuity.md) owns broader reading and recall continuity.
[FJ](FJ-live-wearer-memory-continuity.md) consumes the resulting selection contract for live setup;
[FK](FK-memory-quality-and-continuity-benchmarks.md) supplies the cross-route benchmark.
FI must ship its own regression tests without waiting for FK.

## Verified starting points

Paths below are repository-relative; locate symbols rather than relying on line numbers.

| File / symbol | Current behaviour and required change |
|---|---|
| `OpenGlasses/Sources/Services/SemanticMemoryStore.swift`, `render(query:)` | Global query ranking runs only when `embedder.isAvailable`; otherwise alphabetic selection. Persona entries are always alphabetical. Route both eligible namespaces through one selector. |
| Same file, `scoreSearch(query:limit:rows:)` | Already falls back to substring keyword hits. Reuse the scoped row fetch and embedding-version migration; replace the lexical scoring implementation. |
| Same file, `MemoryEntry`, `upsert` | Carries ID, namespace, key/value, topic, `createdAt`, expiry. The SQL upsert overwrites `created_at`, so it is currently the last-write time for selection purposes; do not describe it as immutable creation time. The ID is `"<namespace>:<key>"` — content-derived and **unchanged by an edit**, so ID alone cannot detect a replacement (pair it with last-write time) and an ID is itself private text. `upsert` stamps `Date()` directly; add a clock seam so fixtures can write at controlled times. |
| Same file, `memories` / `personaMemories` caches | `[String: String]` key→value only: no ID, timestamp or expiry. Recent selection needs row metadata, so either widen the cache to `MemoryEntry` values or fetch rows; do not sort a dictionary. |
| Same file, `fetchAllMemories`, `purgeExpired` | Read filter skips `exp < now`; purge deletes `expires_at < now`. Pick one boundary (keep `<`, i.e. a row expiring exactly now is still live) and test it. **No production writer sets `expires_at` today** — TTL is dormant; tests must seed it directly. |
| Same file, `trim(namespace:maxChars:)` | Stores were capped at 3,000 (global) / 1,500 (persona) characters with **shortest-first** eviction. Fixed ahead of this plan, in the PR that added it: caps raised to 20,000 / 10,000, oldest-written evicted first, the row just written never evicted. See *Eviction* below. |
| Same file, `scoreSearch` consumers | Also serves `MemorySearchTool` (`memory_search`) and `BrainTool` (two call sites). Changing the scorer changes those tools' results; neither currently honours `Config.userMemoryEnabled`. |
| Same file, `scoreSearch` embedding path | One `fetchEmbedding` SQL read per row, and a stale-version row is re-embedded **and written back inside the search**, on `@MainActor`. After a model swap the first query re-embeds the whole store on the voice turn. |
| Same file, `renderedContext` / `systemPromptContext` | Bounded rendering and diagnostic counts; preserve existing wrappers while introducing a structured result underneath. |
| `OpenGlasses/Sources/App/OpenGlassesApp.swift`, `memoryContextForPrompt` | Memory enabled controls reads; retrieval enabled controls whether a query is supplied. Preserve this distinction. |
| `OpenGlasses/Sources/Services/Diagnostics/MemoryContextSnapshot.swift` and `MemoryContextRecorder.swift` | Count/size-only diagnostics; extend finite reason/method fields without exposing contents. |
| `OpenGlassesTests/MemoryInjectionBoundsTests.swift`, `MemoryContextDiagnosticsTests.swift`, `SemanticMemoryEmbeddingMigrationTests.swift` | Existing regression coverage that must remain meaningful. |

## Selection contract

Add Foundation-only value types under `OpenGlasses/Sources/Services/Memory/` (names provisional):

- `MemorySelectionRequest`: optional query, explicit allowed namespaces, retrieval-enabled flag,
  injected `now`, per-section entry limit, character budget, memory/store revision.
- `MemoryCandidate`: stable ID, namespace, key, value, last-written time, optional expiry and optional
  embedding score. Do not capture a live store or global persona inside a candidate.
- `MemorySelection`: ordered selected candidates plus method (`semantic`, `lexical`, `hybrid`, `recent`,
  `gatewayProvided`, `none`), eligible/matched/selected counts, omission reasons and revision.
- `MemoryContextBlock`: rendered text, in-memory selected references, revision, and the existing
  privacy-safe snapshot. References are for invalidation/tests; never add IDs or hashes to logs.

Resolve allowed namespaces before reading rows. Ordinary chat permits `global` plus the captured
active-persona ID, never an unrestricted `namespace: nil` search. Project boundaries already applied
by project-specific callers remain authoritative; do not broaden them. Exclude expired entries at
read time (`expiresAt <= now`), even if physical expiry cleanup has not run. Never fall back to rows
outside the allowed scope when matches are sparse.

Memory disabled means no store reads, no embeddings and no gateway reads. Retrieval disabled means
bounded non-query selection, preserving the current product distinction; it does not mean forgetting
saved memory. An empty/nil query also selects recent eligible facts. Sort those by last-write time
descending, then namespace and stable ID ascending; never use dictionary order.

## Ranking algorithm

1. Normalize text using Unicode canonical composition for storage-independent identity and
   case/diacritic folding for Latin and Cyrillic lexical comparison. Diacritic folding does not
   decompose every letter (`ł`, `ø`, `đ`, `ß`): add an explicit, tested fold table for the app's
   shipped locales (de, es, fr, pl, uk plus en) rather than assuming `.diacriticInsensitive` covers
   them. Tokenize letters and numbers; preserve meaningful digits, one-character identifiers and
   tokens from non-Latin scripts. Use a testable tokenizer seam. For unsegmented CJK text — Han
   **and** Japanese kana (ja, zh-Hans and zh-Hant are shipped locales) — use deterministic
   overlapping bigrams over each unsegmented run, with a single character retained for a
   one-character input; do not discard it as an English stop word. Fold full-width/half-width forms
   (NFKC for comparison only) so `ＡＢ１` matches `AB1`.
2. Score key plus value with BM25. Initially use no stop-word list: avoid removing negation, units,
   short names or identifiers. Document any later stop-word policy through benchmark changes.
3. For N eligible documents, document frequency df, term frequency tf, document length L and
   average length avgL, use `idf = ln(1 + (N - df + 0.5)/(df + 0.5))` and
   `idf * tf * (1.5 + 1) / (tf + 1.5 * (1 - 0.75 + 0.75 * L/avgL))`, summed over unique query tokens.
   Empty corpus/query or avgL zero yields no lexical match. Scores must be finite and nonnegative.
4. Preserve the existing semantic score threshold initially. Form separate semantic and lexical
   ranked lists over the same eligible rows; semantic ranking is absent when vectors fail. Combine
   nonempty lists using reciprocal rank fusion: sum `1/(60 + rank)` with ranks starting at one.
   Do not average incomparable raw BM25 and cosine scores. Deduplicate by stable candidate ID.
5. Break ties by last-write time descending, namespace ascending and ID ascending. Rank within each
   existing section so shared and persona facts retain separate entry caps. Maintain section order.
6. With a nonempty usable query and zero matches, inject no unrelated fallback facts. Report
   `noRelevantMatches`, not `empty` storage. A whitespace/punctuation-only query is a no-query request
   and uses recent facts. A query with valid tokens but no overlap is a genuine zero-match request.
7. **Open decision — standing facts.** Today a query with no semantic match still renders facts
   (alphabetically), so a standing fact such as a preferred name, units or language rides along
   with every turn. Rule 6 removes that: "What's the weather?" would no longer carry "call me Sam".
   Recommended default: reserve up to two of the eight section slots for the most recently written
   eligible facts on every query-bearing request, deduplicated against matches, reported under a
   distinct `recentReserve` count so diagnostics never call them matches. The alternative (strict
   rule 6) must be chosen explicitly and recorded as a behaviour change in the P2 report. Do not
   infer "standing" from the keyword `detectTopic` classifier — it is a heuristic, not a contract.

Keep embedding migration out of ranking. The selector reads vectors; it never writes. A row whose
vector is missing or stale ranks lexically for that request and is queued for re-embedding outside
the turn (bounded batch, off the voice path, re-checking store revision before write). This removes
the current per-query write-back from `scoreSearch` without losing the self-healing migration.
Batch the vector read (one query per request, not one per row).

`memory_search` and `BrainTool` share the scorer. Route them through the same selector with their
own limits and explicit namespaces, so tool and prompt retrieval cannot disagree; keep
`SearchResult.similarity` meaning cosine-or-nil rather than silently becoming an RRF score, or rename
it. Make both tools honour `Config.userMemoryEnabled` (memory off → the tool says memory is off and
reads nothing) — today the prompt block is gated but the tools are not, so "memory disabled makes zero
reads" is false until they are. Update their tests; follow the absence-assert rule (assert on a value
token, not a word the no-results message echoes back).

## Eviction

Relevance is pointless if the relevant fact was evicted on write. Split out as a prerequisite fix,
shipped in the PR that added this plan (2026-09-19): least-recently-written evicted first (ties by ID), the
row the current write produced never evicted, a write that cannot fit returns `false`, and caps
raised to 20,000 / 10,000 characters (storage only — prompt size stays bounded by the per-section
caps). The same PR makes `memory_search` and `BrainTool` honour memory-off. FI verifies both still
hold and must not reintroduce either defect; verify against git before treating them as done.

Gateway facts currently arrive as ordered strings without durable local row metadata. Keep their
existing order and cap for this plan, honour existing gateway/privacy eligibility, and mark their
method as `gatewayProvided`; do not invent timestamps or claim semantic ranking for them. FJ's
initial live snapshot excludes gateway facts explicitly.

## Rendering, isolation and cost

Preserve `maxMemoryLines = 8` and `maxValueChars = 300` unless the implementation proves the current
constants changed. Bound keys as well as values (initial key cap: 80 grapheme clusters). Render whole
entries within the caller's budget; never cut a UTF-8 sequence or leave half a field label. Use the
existing memory data framing and prompt-injection policy: stored text is evidence, not an authority
to change tools or permissions. Escape delimiters/control characters deterministically.

Select from an immutable snapshot. If expensive ranking moves off `@MainActor`, pass Sendable value
copies; never share the SQLite handle or capture mutable persona state in a detached task. Before
using an async result, re-check revision and conversation/persona generation. Reuse existing row and
embedding caches; avoid scanning or embedding every candidate afresh per voice frame. No new model
or network request may be introduced by lexical ranking.

A cache, if needed, must key on scope, query normalization, store revision, embedding version and
budget. Invalidate on write, delete, expiry, persona/project changes and privacy reset. Prefer no new
cache until measurements justify it. Store failures must remain `storageUnreadable`, not no matches.
A readable gateway section does not prove the local store is readable.

## Implementation checkpoints

### P0 — Contracts and deterministic ranking

Extract pure ranking/tokenization/budget policy. Add injected clock (selection *and* `upsert`
write time) and fake embedding results. Fix eviction (above) with a regression test that saves a
short fact into a full store and asserts it survives and the oldest row went.
Implement lexical-only, semantic-only and fused selection; freeze ordering with fixture assertions.
No changes to persistence schema are required for initial ranking. If metadata changes become
necessary, add a versioned migration and reopen tests rather than relying on swallowed SQL errors.

### P1 — Store and prompt integration

Route query-bearing global and active-persona sections, `memory_search` and `BrainTool` memory hits
through the selector regardless of embedding availability, and move re-embedding off the turn. Route nil-query/retrieval-disabled requests through recent selection. Keep compatibility
wrappers and update all affected memory diagnostics consistently. Extend snapshot availability with
an explicit no-match state or finite reason; update exhaustive switches/exporters and existing tests.
Measure counts after scope/expiry filtering and after actual rendering; do not call all stored rows
retrieved matches. Keep provider-specific clipping attribution in the provider prompt layer.

### P2 — Regression, performance and documentation

Verify tests below, record a before/after fixture report, update the memory-context inventory and
index status. Document the change from alphabetical to recent defaults and no unrelated query
fallback. No new UI preference is needed. Do not mark FJ or FK shipped with this change.

## Acceptance and validation

- More than eight facts: the relevant parking fact reaches the final prompt without embeddings.
- Persona A and B contain the same key with different values: only global plus the active scope is
  eligible. A deliberately allowed global/persona conflict stays labelled by scope; no silent merge.
- No query and retrieval disabled: newest valid entries are stable; memory disabled makes zero reads.
- Empty store, unreadable store, no matches, expired-only store and budget omission remain distinct.
- Accented names, apostrophes, Chinese queries, emoji-only input, single-character IDs, dates and
  repeated query terms have deterministic results; repeated terms cannot manufacture relevance.
- Embedding failure/version migration, equal scores, deletion during ranking, scope switch during
  ranking and stale async completion cannot change scope or resurrect deleted facts.
- Existing per-section/value caps hold; long keys and malicious delimiters cannot overrun budgets.
- Real stores are modest: the 20,000/10,000-character caps hold roughly 300–500 global and 150–250
  persona rows. Measure pure ranking at 500 (realistic) and 1,000 (headroom) synthetic facts in an
  optimized build, and 10,000 as a pure-algorithm stress case only (the real store cannot hold it
  without bypassing `trim`). Initial target: p95 under 10 ms at 500 and 25 ms at 1,000 facts on the
  declared test host, no main-thread database/embedding stall introduced, and **no cache** — at real
  scale one isn't justified. Treat these as measured engineering targets, not device latency promises.
- A short fact saved into a full store survives eviction; the write that cannot fit returns `false`.
- Memory disabled: `memory_search` and `BrainTool` read no memory rows.
- Japanese kana, Polish `ł`, Ukrainian case pairs and full-width digits match their plain forms.

Add `MemorySelectionTests` and `MemoryLexicalRankingTests`; extend the existing store/injection tests.
Run through the generated Xcode unit-test target using the procedure in FK. Pure tests need no model,
network or glasses. Run the existing relevant tests as well, and report unavailable simulator/build
prerequisites honestly. Release evidence must include the exact commit, toolchain and test command.

## Rollout and completion

No destructive migration and no persisted score cache. Roll back by restoring the selection policy;
never delete facts to undo a ranker. Complete when deterministic/store/prompt tests pass, the scoped
before/after fixture report is checked in, diagnostics describe actual prompt contents, and no new
network/model dependency exists. Real-device timings may remain explicitly owed in the index.
