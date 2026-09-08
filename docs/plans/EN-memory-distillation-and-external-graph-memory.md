# Plan EN — Memory Distillation and External Graph Memory (a graph that changes its mind)

**Status:** 🚧 P1–P3 implemented 2026-09-08 (headless; the live enrichment call and the first
connection to a self-hosted server are the pending edges). Normal house rhythm: one PR for the whole
plan, the edges named rather than pretended.
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

## P1 findings (2026-09-08)

**Eight columns, not six.** The design named `session_id`, `confidence`, `state`, `observations`,
`valid_from` and `superseded_at`. Two more were needed for the rules to be computable at all.
`last_seen`, because expiry is "last observed longer ago than the window" and `created_at` is the
*first* sighting — the very asymmetry the Origin section complains about. And `distinct_sessions`,
because "corroborated across two conversations" cannot be told from a single `session_id` column
that the newest observation overwrites; counting at write time is the only way a repeat inside one
session and a repeat across two are different rows.

**Migration is column-by-column, and a fresh database is not migrated.** `PRAGMA table_info` is read
before the `ALTER TABLE`s and only the columns actually missing are added, so a crash halfway
through leaves `user_version` at 0 and the next launch completes the job rather than failing on a
duplicate column. A database that has no `edges` table yet is created at version 1 directly and logs
no `.migrated` line: a migration count of zero and "there was nothing to carry" are different
statements, and only one of them is true on a first launch.

**The upsert never bumps confidence.** A repeat increments `observations`, moves `last_seen`, counts
a new session and takes `MAX(confidence, incoming)` — but it does not add anything. Confidence is
owned entirely by the distiller, which emits it as an *absolute* value computed from the entry
confidence and the observation count. That is what makes `decide` idempotent: apply its decisions,
feed the result back in, and every candidate reads `.keep`. A delta-based increment would have made
every extra pass a promotion.

**`Policy.default` needed a dial the plan did not name.** Shipped: provisional 0.5, direct claim 1.0,
reinforcement increment 0.15, **same-session ceiling 0.75**, promotion threshold 0.8, corroborating
sessions 2, confidence floor 0.6, expiry window 14 days, ingests between passes 20. The ceiling is
the addition. Without it, 0.5 + three increments crosses 0.8 and a wearer who restates something
three times in one conversation promotes it by arithmetic — which is exactly the rule the design
wrote down ("a wearer restating something twice in a minute is one claim, not two") and could not
otherwise enforce.

**A twice-in-one-session guess lands in a deliberate limbo.** 0.5 + 0.15 = 0.65: above the 0.6 floor,
so it never expires; below the 0.8 threshold and capped by the ceiling, so it never promotes. It
stays, and it reads `(unconfirmed)`, until a second conversation corroborates it. This is intended —
the alternative is either dropping a claim the wearer made twice or promoting one nobody confirmed —
but it means the graph accumulates a long tail of unconfirmed edges that only the ceiling keeps
honest.

**Supersession wins over promotion within a single pass.** An edge decided `.promote` and then found
to be the older destination of a functional relation is overwritten with `.supersede`: there is
nothing to promote an edge *into* if it is no longer current. Order-independence comes from deciding
into a dictionary keyed by edge id and applying supersession last, not from sorting the input.

**One thread-lifecycle seam, not six call sites.** `ConversationStore.onThreadLeft` fires from
`endThread` and from `startThread` when it replaces a live thread — the case nobody ever calls
`endThread` for — and `AppState` wires it to the pass. A `distill` call copied into each of the
places a thread changes would have been forgotten in the next one. `resumeThread` deliberately does
*not* fire it: switching back to an old conversation is not leaving the graph in a state that needs
tidying, and the ingest budget (every 20 ingests) covers the long session that never ends at all.

**"An exact repeat reinforces without a second row" is a store test, not a distiller test.** The plan
filed it under `BrainDistillerTests`, but a pure engine over values has no rows to count; the claim
is about the `ON CONFLICT` clause. It lives in `BrainStoreTests.testAddEdgeAndNeighbors`, which now
asserts one row and two observations where it used to assert only that the duplicate was ignored.

**A retired fact had no way back, and now has one** (review fix). "Nothing is deleted, history stays"
is the right rule for supersession and the wrong one for a wearer who moves back: a second
"Maria lives in Wellington" lands on the row supersession stamped, and the original upsert left it
stamped, so the graph would have insisted on Auckland forever. A **direct** restatement now revives
the row — permanent, `superseded_at` cleared, `valid_from` set to now, so the very next pass retires
Auckland by the same recency rule that retired Wellington. A *provisional* repeat does not: a guess
cannot overturn a decision the distiller already made. The pass also rolls back rather than commits
if any statement in its transaction fails — a pass that promoted an edge but failed to retire the
one it replaced would leave two present-tense answers to the same question, which is the state this
whole plan exists to end.

## P2 findings (2026-09-08)

**`backgrounded:` was dropped from the gate's signature.** The design listed
`decide(agentMode:enrichmentEnabled:hipaaMode:provider:backgrounded:)`, but none of the four
conditions reads it: the on-device exclusion is unconditional, so a background flag could only ever
have changed an answer the provider check already gave. A parameter no rule consults is a parameter
that will grow a rule by accident, so the gate takes four inputs and the reason for the on-device
exclusion is written beside it instead.

**A fifth refusal, for a phone with no model at all.** `provider` is optional, because
`Config.activeModel` is; `nil` yields `.noProvider` rather than being folded into
`.onDeviceProvider`, so the log line distinguishes "you have not set up a model" from "your model
runs on the phone", which are different things for the wearer to do something about.

**Only the wearer's own utterance is sent.** Not the assistant's reply. Three reasons, in order of
weight: the reply is the model's own prose, so mining it for relations lets the model corroborate
itself into the graph; `evidence` has to be checkable against exactly one string, and two sources
would mean a span could "come from" text the wearer never said; and less text leaves the device.
Evidence matching is case-insensitive — a model that re-capitalises a span is still pointing at the
wearer's words, and an absent span is still absent.

**The schema `completeStructured` needed is an object wrapping the array, not the array.** It is
handed straight to Anthropic as an `input_schema` under a forced `tool_choice`, to OpenAI-shaped
providers as function `parameters`, and through `GeminiSchemaTranslator` as a `responseSchema` — all
three want a top-level object, so the shape is `{"relations": [...]}` with `relations` required and
each item requiring all six keys. `relation` and both kind fields carry `enum` lists, so a
well-behaved provider is constrained to the same vocabulary the parser enforces; a test asserts the
two lists are literally the same, because a closed list the model cannot see is a list it guesses
around and every guess is a silent drop.

**The ontology decides what a relation points at, not the answer.** `dstKind` must be present and
must be one of the five kinds — a missing or nonsense value is a refusal — but the value actually
stored comes from `RelationOntology.destinationKind(for:)`. A model that calls Wellington an
organisation still gets a place in the graph.

**`BrainRelationExtractor.isUsableName` was widened from `private` to internal** rather than having
its 60-character-and-no-leading-stopword bound restated in the parser. Two statements of one rule
agree until one of them is edited.

**The call site starts a task rather than awaiting one.** `enrich` is fired from the same `accept:`
closure as `observeTurn`, after the reply has been accepted, and nothing waits for it; a logged
refusal, a failed provider call and an empty answer are each one counted `PrivacyLog` line and no
edges. It
runs on the main actor (the service is `@MainActor`, as is everything it touches), which is
harmless because every step that takes time is a suspension, not work.

**A refusal is logged only when the wearer asked for the feature.** `SkipReason.isWorthLogging` is
false for `agentModeOff` and `enrichmentDisabled` and true for `hipaaMode`, `onDeviceProvider` and
`noProvider`, so the privacy log names the refusals a wearer would otherwise mistake for a broken
feature instead of writing a line per turn for everyone who never switched enrichment on.

**Deferred edge, unchanged:** the live provider call, measured on a device. The wiring, the gate,
the prompt, the schema and the parser are all exercised headlessly; what no test here can tell you
is what a real model returns for a real turn.

## P3 findings (2026-09-08)

**The optional `Bool` needed the same explicit decode every other defaulted field needs.** Swift's
synthesized `Decodable` ignores a property's default and demands the key, so `requires_agent_mode`
is read with `decodeIfPresent(Bool.self) ?? false` in the hand-written initialiser the entry already
had. The five entries that shipped before it decode unchanged, and a test asserts the flag is true
for exactly one row of the six.

**Two placeholders, and the existing validator already covered them.** `http://{host}:{port}/mcp`
needs both fields, and `validationError`'s unmatched-placeholder rule is written over
`placeholderKeys` rather than over `{host}` specifically — so an entry referencing `{port}` with no
matching field is rejected for free. The test the plan asked for confirms that rather than
introducing anything.

**The egress default needed no argument, which is the point.** `.redact` is hardcoded in
`makeServerConfig` with no per-entry override, so a memory server — exactly the kind of server it
would be tempting to trust — gets the same outbound screen as everything else, and
`testBundledCatalogueLoadsAndEveryEntryIsValid` covers it by iterating every bundled row.

**The Agent-Mode gate is visible, not hidden.** A gated row stays in the list, greyed, with
"Requires Agent Mode" where its transport and auth line would be, and the install screen refuses
with the footer `MCPServerSettingsView` already uses. A hidden row cannot tell the wearer why the
thing they were looking for is not there.

**Nothing in this phase touches `BrainStore`, `BrainTool` or the router.** The entry is a catalogue
row and a decoded field; the external server is a peer memory the model may call, and a `recall`
result is never ingested. The plan's "not a sync target" is enforced by there being no code that
could do it.

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
