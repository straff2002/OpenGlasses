# Plan EN — Memory Distillation and External Graph Memory (a graph that changes its mind)

**Status:** 📋 Planned 2026-09-08. Headless core first (P1 + P2 pure engines); the single live LLM
call in P2 and the first connection to a self-hosted server in P3 are the deferred edges. Normal
house rhythm: one PR for the whole plan, the edges named rather than pretended.
**Origin:** `BrainStore.ingest(text:subject:sourceRef:sourceKind:)` writes straight into the
permanent graph, and `addEdge` is `INSERT OR IGNORE` against `UNIQUE(src_id, relation, dst_id)`.
Two consequences fall out of that one line. First, a repeat observation is *silently discarded* —
hearing "Alice works at Acme" five times over three weeks leaves exactly the row the first mention
made, so recurrence, the cheapest corroboration signal there is, carries no weight anywhere in the
store. Second, a *changed* fact is not a change: "Maria lives in Auckland" after "Maria lives in
Wellington" is a different triple, so both rows persist, and `neighbors` — `ORDER BY e.created_at
DESC LIMIT n` — hands `BrainTool.unifiedQuery` both as equally true present-tense sentences
("Maria lives in Wellington", "Maria lives in Auckland") with no marker that one is history. The
graph accumulates; it never revises.
**Priority:** P1 for every answer that leans on the brain. `BrainTool`'s `query` and `person`
actions, the dossier, and the `RELATIONSHIPS & ENCOUNTERS` prompt block all read `neighbors`
directly, so a stale edge is not a stale row in a table nobody looks at — it is a sentence the model
is told is a fact.
**Surfaces:** One SQLite migration on `brain.sqlite`, two pure engines, one gated LLM pass, one
catalogue row, one settings toggle. No new store, no new database, no new dependency, no gateway
exposure. Brain data stays strictly on-device — the invariant in `BrainStore`'s own doc comment
("strictly on-device, never synced to the gateway") is not touched by any phase here, P3 included.

---

## Verified starting point

- **Dedupe is exact-triple and lossy.** `addEdge` binds a fresh `UUID` into `INSERT OR IGNORE INTO
  edges (id, src_id, relation, dst_id, source_ref, created_at)`; the table's `UNIQUE(src_id,
  relation, dst_id)` makes a re-observation a no-op. `BrainStoreTests.testAddEdgeAndNeighbors`
  asserts exactly this ("Duplicate edges are ignored", `stats.edges == 1`). Nothing counts
  observations, and `created_at` keeps the *first* sighting, so even recency is the recency of the
  first time we heard it.
- **The `edges` table has no tier, confidence or validity window** — its columns are `id`,
  `src_id`, `relation`, `dst_id`, `source_ref`, `created_at` — and `Edge.sentence` renders present
  tense unconditionally: `"\(srcName) \(verb) \(dstName)\(cite)"`.
- **There is no migration mechanism at all.** `createTables()` is five `CREATE TABLE IF NOT
  EXISTS` statements plus six indexes; `PRAGMA user_version` is never read or written (so it is 0 on
  every existing device) and no `ALTER TABLE` exists in the file. P1 has to introduce the versioning
  as well as use it.
- **Reads never distinguish current from historical.** `neighbors(of:limit:)` selects edges in
  either direction `ORDER BY e.created_at DESC LIMIT \(limit)`; `sources(relation:dstName:)` does
  the same filtered by relation and destination. `BrainTool.unifiedQuery` takes `neighbors(of:
  entityName, limit: 5)` for up to three mentioned entities, and `dossier` takes `limit: 8` — so a
  superseded edge does not merely appear, it consumes one of five slots the answer is built from.
- **The relation vocabulary is already closed, and is larger than it looks.**
  `BrainRelationExtractor.patterns` is ten regexes producing nine distinct stored relations
  (`works_at` from two patterns, `leads`, `founded`, `invested_in`, `lives_in` from two,
  `married_to`, `studied_at`, `attended`); `ingest` synthesizes `mentioned_in`; and `BrainTool`'s
  `link` action documents and accepts a tenth, `knows`, mapping it to `dstKind: "person"`. Nothing
  validates a relation string on the way in — `addEdge` stores whatever it is handed.
- **Five callers ingest today**, all free text — `ReadingCompanionService.swift:128`,
  `MemoryLoopService.swift:89` (the Agent-Mode silent save), `BadgeScanTool.swift:89`,
  `SocialContextTool.swift:39`, `MeetingSummaryTool.swift:256` — and none passes a session or a
  confidence, because there is nowhere to put one.
- **The post-turn hook is a single call site.** `OpenGlassesApp.swift:4465` calls
  `MemoryLoopService.shared.observeTurn(userText:assistantText:toolNames:)` inside the turn's
  `accept:` closure. `decide(turn:nudgesEnabled:agentMode:present:)` is pure of `Config` and
  singletons and is covered by ten tests in `MemoryLoopTests`; only `.saveFact` (Agent Mode) reaches
  `BrainStore`. A conversation's identity is already available beside it:
  `ConversationStore.activeThreadId`, set by `startThread(mode:personaId:)`.
- **A structured cloud completion already exists.** `LLMService.completeStructured(systemPrompt:
  userText:jsonSchema:toolName:maxTokens:)` returns `[String: Any]?`, resolves `Config.activeModel`
  through `medicalInferenceModel(requested:)`, and forces the schema with `tool_choice` on
  Anthropic. `classifyMultiStep` is the precedent for a small, flag-gated auxiliary call
  (`Config.llmComplexityClassifierEnabled`, default off).
- **The gates exist and mean different things.** `Config.agentModeEnabled` (default false) gates
  autonomous and gateway work; `Config.memoryNudgesEnabled` is `@UserDefaultsBacked(default:
  false)`; `Config.hipaaMode` carries `hipaaLocalOnly` and a `hipaaDisabledTools` set of five tool
  names in which `brain` does **not** appear — so the brain keeps working under HIPAA and only a
  *cloud* pass has to be refused. `LLMProvider` includes `.local` ("Local (On-Device MLX)") and
  `.appleOnDevice`, the discriminator P2's gate needs.
- **The catalogue's egress default is hardcoded, not per-entry.**
  `MCPCatalogEntry.makeServerConfig(values:token:)` builds its `MCPServerConfig` with `policy:
  .redact` and the comment "SAFE DEFAULT — one-tap convenience never outruns the Plan R screen."
  There is no field in `mcp-catalog.json` that can raise it, and two tests hold it shut:
  `MCPCatalogTests.testInstallDefaultsToRedactPolicy` and
  `testBundledCatalogueLoadsAndEveryEntryIsValid`, the latter asserting `.redact` for *every*
  bundled entry. Discovered tools are additionally screened by `ToolDefinitionScanner.scan(_:
  nativeNames:)`, which `testCatalogueInstalledServerToolsRunThroughScanner` proves runs for a
  catalogue install.
- **`http` is the live transport.** `MCPTransportKind.http` is annotated "Streamable HTTP — the
  shipped path"; `.sse` is "framing shipped, streaming deferred", which is why the three hosted SSE
  entries in the catalogue carry "live connection lands when SSE + OAuth ship" in their notes.
- **The catalogue is not Agent-Mode gated today.** `Config.agentModeEnabled` appears in
  `MCPServerSettingsView` (the developer-only *inbound* glasses server) but nowhere in
  `MCPCatalogView`, `MCPServersView`, or `MCPCatalog.swift`. P3 therefore has to *add* a gate, not
  inherit one.

## Product promise

"The brain learns what is repeated, forgets what was said once and never again, and knows the
difference between where you live and where you used to live — and if you run your own memory
server, the glasses can use it without a single fact leaving the phone by accident."

## Design

**A provisional tier, and supersession by recency instead of deletion.** An ingested edge is no
longer immediately a fact. It arrives tagged with the session that produced it and a confidence set
by *how* it was produced, and a deterministic pass at session end decides what becomes permanent.
Three rules, all pure:

- *Repetition is evidence.* An exact `(src, relation, dst)` re-observation increments
  `observations` and raises `confidence`. Corroboration across **two distinct sessions** (or one
  high-confidence source — a regex hit, or `link`'s "told directly") promotes a provisional edge to
  permanent. Repeats inside one session raise confidence but cannot promote on their own: a wearer
  restating something twice in a minute is one claim, not two.
- *Functional relations hold one value at a time.* For `lives_in`, `works_at`, `married_to` and
  `leads`, a new distinct destination supersedes the incumbent by recency: the old row is stamped
  `superseded_at` and left in place as history. Nothing is deleted. `founded`, `studied_at`,
  `invested_in`, `attended`, `knows` and `mentioned_in` are non-functional and accumulate as they do
  today.
- *An unrepeated low-confidence claim expires.* A provisional edge below the confidence floor whose
  last observation is older than the expiry window is dropped at the next pass. This is the safety
  valve that makes P2 affordable: a hallucinated relation costs one row for one window.

**The engine is pure over values.** `BrainDistiller.decide(candidates:now:policy:) -> [Decision]`
takes plain `Candidate` values (names, kinds, relation, state, confidence, observations, session
ids, first/last seen) and returns `.promote`, `.reinforce`, `.supersede(at:)`, `.expire`, `.keep`.
No SQLite, no `Config`, no clock — `now` and `Policy` (functional set, promotion threshold,
confidence floor and increments, expiry window) are parameters. `BrainStore` gains a thin
`distill(sessionID:now:)` that reads candidates, calls `decide`, applies the result in one
transaction.

**`RelationOntology` is the one place a relation is spelled.** A closed allow-list — today's ten,
plus a small, deliberate extension (`reports_to`, `owns`, `member_of`, `based_in` for orgs and
places, `parent_of`, `sibling_of`) — with `isFunctional(_:)`, `canonical(_:)` (lower-cased,
spaces → underscores, the normalization `BrainTool.link` already does inline) and
`destinationKind(for:)` (the switch `BrainTool.link` currently owns). Anything outside the list is
dropped, not stored. This is what stops P2 from growing free-text predicates.

**Reads prefer the present and can say "used to".** `Edge` gains `state`, `confidence` and
`supersededAt`; `neighbors` and `sources` gain `includeSuperseded: Bool = false` and exclude
superseded rows by default, so `BrainTool`'s five- and eight-row budgets spend on current facts.
When a superseded edge *is* asked for, `sentence` renders it in the past — "Maria used to live in
Wellington" — and a still-provisional edge renders with an explicit `(unconfirmed)` marker, because
the failure mode that matters is the model reading a guess as a fact.

**Migration is additive and backward compatible.** `PRAGMA user_version` becomes the schema marker
(0 → 1). At version 0, six `ALTER TABLE edges ADD COLUMN` statements land `session_id TEXT`,
`confidence REAL NOT NULL DEFAULT 1.0`, `state TEXT NOT NULL DEFAULT 'permanent'`, `observations
INTEGER NOT NULL DEFAULT 1`, `valid_from REAL` and `superseded_at REAL`; one `UPDATE edges SET
valid_from = created_at WHERE valid_from IS NULL` backfills; `user_version` becomes 1 and
`PrivacyLog.store(.brain, .migrated, count:)` records the rows carried. Every pre-existing edge is
therefore permanent, confidence 1, one observation. `UNIQUE(src_id, relation, dst_id)` is
*retained* — supersession concerns different destinations, and the constraint is what turns a
repeat into an `UPDATE` rather than a second row.

**Enrichment asks a cloud model for what the regexes cannot see, and only under four conditions.**
`RelationEnrichmentPolicy.decide(agentMode:enrichmentEnabled:hipaaMode:provider:backgrounded:)`
is a pure function returning `.run` or `.skip(reason)`, and every skip has a named reason.
It runs only when Agent Mode is on **and** the new `Config.brainEnrichmentEnabled` (default off) is
on **and** `hipaaMode` is off **and** the active `LLMProvider` is neither `.local` nor
`.appleOnDevice`. The on-device exclusion is not a preference: MLX inference cannot run
backgrounded, and a memory pass that fires at the end of a voice turn is exactly the code most
likely to run there. Results enter as **provisional edges at a lower confidence than any regex
hit**, which is what makes a wrong answer self-correcting rather than permanent.

## Phases

### P1 — Distillation core and the schema it needs (headless)

1. `RelationOntology` (new): allow-list, `isFunctional`, `canonical`, `destinationKind(for:)`;
   `BrainTool.link` and `BrainRelationExtractor` both route through it instead of their own inline
   switch and implicit vocabulary.
2. `BrainDistiller` (new): `Candidate`, `Decision`, `Policy`, `decide(candidates:now:policy:)`.
   Pure; no import beyond `Foundation`.
3. `BrainStore` migration: `PRAGMA user_version` gate, the six `ALTER TABLE`s, the `valid_from`
   backfill, the `.migrated` log line; `addEdge` gains `sessionID:`, `confidence:` and `state:` with
   defaults that keep all five existing call sites compiling unchanged; a repeat becomes an `UPDATE`
   that bumps `observations`/`confidence`/last-seen rather than a discarded insert.
4. `BrainStore.distill(sessionID:now:)` applying decisions in one transaction, plus a turn-budget
   trigger so a long session distils without waiting for its end.
5. Reads: `includeSuperseded` on `neighbors`/`sources`, `state`/`confidence`/`supersededAt` on
   `Edge`, past-tense and `(unconfirmed)` rendering in `sentence`; `forget(entityName:)` continues
   to remove history along with the rest.
6. Wiring: `MemoryLoopService` passes `ConversationStore.activeThreadId` as the session id on the
   `.saveFact` path; `AppState` calls `distill` when a thread is left or superseded.

**Tests (all headless, `BrainStore(directory:)` into a temp folder as the existing suites do):**
- `BrainDistillerTests` — exact repeat reinforces without a second row; two distinct sessions
  promote, two repeats in one session do not; a regex-sourced claim promotes immediately; a
  functional relation with a new destination supersedes the incumbent and keeps it; a
  non-functional relation keeps both; an unrepeated sub-floor provisional expires; a repeated one
  does not; `decide` is order-independent and idempotent when re-run on its own output; an
  off-ontology relation yields no decision.
- `BrainSchemaMigrationTests` — a v0 database written with the old column set gains the columns and
  keeps every edge; migrated rows read back permanent, confidence 1, `valid_from == created_at`;
  reopening runs no second migration (`user_version` stays 1); the migration is logged.
- `BrainStoreTests` additions — `neighbors` prefers current over superseded; `sources` excludes
  superseded by default and includes them on request; a superseded edge reads as "used to"; a
  provisional edge reads as unconfirmed; `forget` takes the history with it.

### P2 — Gated relation enrichment (pure engine live, one call site deferred)

1. `RelationEnrichmentPolicy` (new, pure) — the four-condition gate above with named skip reasons.
2. `RelationEnrichmentParser` (new, pure) — `[String: Any]` → `[BrainRelationExtractor.Relation]`,
   validating each object (`src`, `srcKind`, `relation`, `dst`, `dstKind`, `evidence`) against
   `RelationOntology`, rejecting self-loops, names over 60 characters (the bound
   `BrainRelationExtractor.isUsableName` already enforces), an `evidence` span that is not a
   substring of the source text, and capping a turn at eight relations.
3. `Config.brainEnrichmentEnabled` (default off) + a Settings row under the memory group whose
   footer states plainly that the turn's text is sent to the configured provider.
4. One call site: `MemoryLoopService.enrich(turn:sessionID:)`, awaited from the same place
   `observeTurn` is called in `OpenGlassesApp.swift`, using
   `LLMService.completeStructured(systemPrompt:userText:jsonSchema:)` with a `relations` array
   schema. Accepted relations are ingested as provisional at the enrichment confidence.
   `decide(turn:nudgesEnabled:agentMode:present:)` stays pure and untouched.

**Tests:** `RelationEnrichmentPolicyTests` — runs only with all four conditions met, each
condition produces its own skip reason, and `.local`/`.appleOnDevice` are refused by provider rather
than by flag. `RelationEnrichmentParserTests` — malformed JSON, a missing key, an unknown relation,
a self-loop, an over-long name, an evidence span absent from the source, a nine-relation response
truncated to eight, and a well-formed response round-tripping at provisional state. **Deferred
edge:** the live provider call, measured on a device.

### P3 — A self-hosted graph-memory server as a catalogue entry

A sixth entry in `mcp-catalog.json` for a self-hosted graph-memory MCP server exposing
`remember` / `recall` / `forget`: `transport: "http"` (the shipped Streamable HTTP path, not the
deferred SSE one), `auth: "bearer"`, `url_template: "http://{host}:{port}/mcp"` with `host` and
`port` fields, scopes naming the three tools, and notes saying in the wearer's words that this is
*their* server and that the on-device brain is not copied into it. It rides the existing funnel
exactly: template fill → `makeServerConfig` → discovery → the outbound screen → the router.

Two things it must not inherit by accident:
- **Egress policy.** `.redact` is the most restrictive setting `MCPCatalog` can produce — it is
  hardcoded in `makeServerConfig` with no per-entry override, and `.allow` is reachable only by the
  wearer editing the server afterwards. The entry gets that default like every other, and
  `testBundledCatalogueLoadsAndEveryEntryIsValid` extends to cover it.
- **Agent Mode.** The catalogue has no agent gate today, so P3 adds `requires_agent_mode` as an
  optional decoded field on `MCPCatalogEntry` (default `false`, so the five existing rows are
  unchanged), with this entry the first to set it; `MCPCatalogView` disables the row and
  `MCPCatalogInstallView` refuses the install with the same shape of footer
  `MCPServerSettingsView` already uses ("Requires Agent Mode. Enable Agent Mode first…").

**`BrainStore` is not a sync target.** Nothing in this phase reads the brain and sends it anywhere.
The external server is a *peer* memory the model may call, not a mirror.

**Tests:** `MCPCatalogTests` additions — the entry decodes with both fields and its transport;
`resolvedURL` fills host and port and returns `nil` when either is blank; the install lands on
`.redact`; `requires_agent_mode` decodes `true` for it and `false` for the five existing entries;
and an entry referencing `{port}` without a matching field is rejected by `validationError`, as the
existing unmatched-placeholder test already proves for `{host}`.

## Out of scope, noted for their own PRs

- **A `recall` result folded into `BrainTool`'s cited output.** Deliberately not attempted.
  `BrainTool` holds `memoryStore`, `documentStore` and `activeNamespace` and no router or MCP
  handle; giving it one would turn a tool whose own contract is "Fully on-device; no gateway
  required" into a network caller, and would put a remote server's prose inside a block the prompt
  tells the model to answer from. The model can already call `brain` and the external server's
  `recall` in the same turn and attribute each — that is the honest composition, and it needs no
  code.
- **A graph UI.** Browsing, editing and visualising the graph (including un-superseding an edge a
  distillation got wrong) belongs with the private memory timeline work, not here.
- **Cross-device sync of the brain**, permanently — not merely for this plan.
- **Replacing `SemanticMemoryStore`.** The graph and the vector store answer different questions;
  Plan AX already settled that. **Hosting a memory server ourselves** is likewise out: the
  catalogue entry points at the wearer's own machine, over bearer auth only (OAuth stays deferred,
  as the three hosted entries already record).
- **Enrichment on the on-device provider.** Blocked by the background-inference constraint, not by
  taste; it reopens if and when local inference can run backgrounded.

## Risks and how P1 answers them

- **A migration on a device with a real brain.** The whole risk of this plan is one `ALTER TABLE`
  sequence running against a database nobody can inspect. It is additive only (no table rewrite, no
  row deleted, no constraint changed), every new column has a default that reproduces today's
  meaning, and `BrainSchemaMigrationTests` builds a v0 database with the old column set explicitly
  and asserts the row count and the semantics after upgrade. A failed `ALTER` leaves
  `user_version` at 0 and the store readable exactly as before.
- **False supersession from noisy extraction.** A misread "Maria moved to Berlin" would retire a
  correct `lives_in` edge. Three defences: supersession applies only to the four functional
  relations; a provisional edge cannot supersede a permanent one until it is itself promoted; and
  the incumbent is stamped, never deleted, so `includeSuperseded: true` recovers it and a future
  correction path has something to restore.
- **The enrichment call's cost and latency.** One structured call per turn, gated by a
  default-off flag on top of Agent Mode, capped at eight relations, and running after the reply is
  already spoken. If it is still too much, the flag is the dial, and P2's tests do not depend on it
  firing.
- **Prompt injection through an external server's tool descriptions.** A memory server's job is to
  return text other people and tools wrote, and its tool *descriptions* arrive from the network
  too. Both existing screens apply unchanged: `ToolDefinitionScanner.scan` runs at discovery for a
  catalogue install (proved by `testCatalogueInstalledServerToolsRunThroughScanner`), and `.redact`
  keeps the outbound arguments on the reviewed path. The additional rule this plan carries is that
  a `recall` result is never ingested into `BrainStore` — remote text cannot become a local edge.
- **A closed vocabulary that is too closed.** A silent rejection teaches nobody, so
  `RelationOntology` counts drops per relation string; extending the list is then a one-line change
  made on evidence.

## Files

- `OpenGlasses/Sources/Services/Brain/RelationOntology.swift` — new (allow-list, functional set,
  canonical form, destination kind).
- `OpenGlasses/Sources/Services/Brain/BrainDistiller.swift` — new (pure `decide`).
- `OpenGlasses/Sources/Services/Brain/BrainStore.swift` — `user_version` migration, tiered `addEdge`,
  `distill(sessionID:now:)`, `includeSuperseded` reads, `Edge` fields and `sentence` rendering.
- `OpenGlasses/Sources/Services/Brain/RelationEnrichmentPolicy.swift` — new (gate + parser/validator).
- `OpenGlasses/Sources/Services/Memory/MemoryLoopService.swift` — session id on the save path,
  `enrich(turn:sessionID:)`.
- `OpenGlasses/Sources/Services/NativeTools/BrainTool.swift` — `link` routes through the ontology;
  current-over-superseded reads.
- `OpenGlasses/Sources/App/OpenGlassesApp.swift` — the enrichment call beside the existing
  `observeTurn` site; `distill` on thread change.
- `OpenGlasses/Sources/Utils/Config.swift` — `brainEnrichmentEnabled`.
- `OpenGlasses/Sources/Services/MCP/MCPCatalog.swift` — `requires_agent_mode` field.
- `OpenGlasses/Sources/Resources/mcp-catalog.json` — the graph-memory entry.
- `OpenGlasses/Sources/App/Views/MCPCatalogView.swift` — the Agent-Mode gate on a gated row.
- `OpenGlassesTests/BrainDistillerTests.swift`, `BrainSchemaMigrationTests.swift`,
  `RelationEnrichmentPolicyTests.swift`, `RelationEnrichmentParserTests.swift` — new;
  `BrainStoreTests.swift` and `MCPCatalogTests.swift` extended.
