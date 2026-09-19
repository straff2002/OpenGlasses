# Plan FK — Memory Quality and Conversation Continuity Benchmarks

**Status: 📝 Drafted 2026-09-19 — not scheduled; no implementation under this plan.** Reviewed
2026-09-19: corpus aligned to shipped locales, store caps/eviction and tool consumers added,
invocation corrected for this repo's known simulator traps.

Build a reproducible, synthetic benchmark that proves relevant memory reaches the actual prompt,
stays inside the correct scope, survives supported restarts, and disappears when deleted. Measure
retrieval separately from model answer quality. Deliver one PR, with baseline and candidate reports.

## Ownership and independent implementation

This plan supplies evaluation infrastructure, fixtures and CI gates; it does not change production
ranking, storage semantics or provider prompts to make a test pass.
[FI](FI-memory-retrieval-relevance.md) implements ranking,
[FJ](FJ-live-wearer-memory-continuity.md) implements live snapshots, and
[FL](FL-correction-effectiveness-evidence.md) implements skill-feedback attribution.
FK can land first: retain known-gap expectations in a dated baseline manifest. Those cases run and
report failure against the target while CI gates existing invariants; do not hide them as skipped
or call them passing. Promote each gap to a required assertion when its owning feature lands.

## Starting points

- `OpenGlassesTests/MemoryInjectionBoundsTests.swift`, `MemoryContextDiagnosticsTests.swift` and
  `SemanticMemoryEmbeddingMigrationTests.swift`: bounded prompt/store/embedding coverage.
- `OpenGlassesTests/MemoryRecallCoreTests.swift`, `MemoryRecallServiceTests.swift`,
  `ConversationRecallCoordinatorTests.swift` and `ConversationRecallPerformanceTests.swift`:
  conversation recall coverage. Keep semantic facts and conversation recall distinct in reporting.
- `OpenGlasses/Sources/Services/SemanticMemoryStore.swift`: real persisted fact retrieval. Its
  stores are capped at 20,000/10,000 characters (raised from 3,000/1,500 on 2026-09-19) with `trim` eviction, `upsert` stamps `Date()`, and no
  production path writes `expires_at` — fixtures need a write-clock seam and must seed expiry directly.
- `Services/NativeTools/MemorySearchTool.swift` and `BrainTool.swift`: tool-side retrieval over the
  same scorer; benchmark them as routes alongside the prompt, since in live mode they are the only
  query-specific path.
- `OpenGlasses/Sources/Services/LLMService.swift`: ordinary/lean/on-device prompt assembly and clipping.
- Both live session managers under `Services/GeminiLive/` and `Services/OpenAIRealtime/`: actual setup.
- `project.tests.yml`: includes `OpenGlassesTests`, with `Fixtures` as test resources.
- `.github/workflows/tests.yml`: existing generated-project, simulator and pinned-dependency workflow.

Create fixtures under `OpenGlassesTests/Fixtures/MemoryQuality/` and pure metric helpers/test adapters
under `OpenGlassesTests/`. Add a short fixture/run guide next to the fixtures and checked-in synthetic
baseline reports under `docs/evaluations/memory-quality/`. Do not add a second package depending on
iOS-only libraries solely to run these tests. Use the existing XCTest target and temporary stores.

## Fixture schema

Use versioned JSON decoded by Swift Codable. Reject unknown schema versions, duplicate IDs,
references to nonexistent facts, invalid timestamps and malformed action sequences. Each scenario
contains:

| Field | Meaning |
|---|---|
| `schemaVersion`, `id`, `category`, `language` | Stable nonpersonal labels; schema version initially 1. |
| `clock` | Fixed UTC starting instant; all advances are explicit. |
| `facts` | ID, key, value, namespace, written time, optional expiry. All content invented. |
| `activeScope`, `memoryEnabled`, `retrievalEnabled` | Initial persona/project and controls. |
| `embeddingMode` | `unavailable`, `fixedVectors`, `failure`, or `versionMismatch`; no downloaded model. |
| `steps` | Ordered save/query/edit/delete/advance/reopen/scope-switch/connect/reconnect/reset/disable actions. |
| `expected` | Relevant fact IDs, graded relevance (0/1/2), forbidden IDs/canaries, expected absence reason,
  allowed route and budget, required terminal state. |

Example: `parking-replacement` starts with `global:parking_location = lot B, level 3`, advances time,
replaces the same key with `lot C, level 1`, reopens the store, and asks “Where is my car parked?”.
Only the current value may reach the prompt. A persona-specific unrelated parking fact is a forbidden
canary. A following delete must make the current fact unavailable on a fresh query/connection.

Encode expected relevance by fixture IDs, never by searching arbitrary output prose for a success
word. For final prompt assertions use structured in-memory selected references plus exact synthetic
canaries to catch formatter/transport leakage. Production diagnostics must never contain these IDs.

## Corpus and scenarios

Initial corpus: at least 120 query cases across at least 12 scenario families. Cover the app's
shipped locales rather than an arbitrary pair: at least 10 cases each for Chinese (Simplified and
Traditional), Japanese (mixed kana/kanji, no spaces), accented Latin (de/es/fr), Polish (`ł`, `ż`)
and Ukrainian (Cyrillic case folding). Include English paraphrases and numeric identifiers.
Reserve 30 query cases as a versioned holdout: inspect them for correctness, but do not tune ranking
constants case-by-case against their failures. This is a modest engineering regression corpus, not
proof of universal multilingual semantic understanding.

Required families:

1. Relevant fact positioned after eight alphabetically earlier distractors.
2. Paraphrase and lexical exact-match retrieval, reported separately by embedding mode.
3. Accent/case/punctuation, one-character IDs, Chinese segmentation and numbers/units.
4. Unrelated question/no match, punctuation-only query, empty store and unreadable store.
5. Global plus current persona, forbidden other persona, scoped project exclusion.
6. Same-key replacement and explicitly conflicting global/persona facts without silent conflation.
7. TTL expiry before/after store reopen, including expiry while a live snapshot is active (seeded
   `expires_at`; no production writer exists yet).
7a. Eviction: a short relevant fact saved into a full store, then queried; the write that cannot fit.
8. Memory disabled versus retrieval disabled, including asserting zero reads when memory is disabled
   — on the prompt path **and** through `memory_search`/`brain` tool calls (known gap until FI).
8a. `[REMEMBER: k = v]` / `[REMEMBER_GLOBAL: …]` tag writes from a model response, then recall.
9. Persistence across store reopen and conversation reset; reset must not erase durable memory unless
   the existing reset contract explicitly requests erasure.
10. Whole-entry budget omission, long keys/values and ordinary lean-provider clipping.
11. Ordinary → live → ordinary, both providers, valid resume versus fresh rebuild.
12. Deletion/erasure/scope change during outstanding async selection and provider setup.
13. Stored prompt-injection text and diagnostic-export canaries.
14. FL evidence attribution: unreviewed skill, exposed approved revision, silence, explicit feedback,
    unrelated tool success, ambiguous multiple skills, duplicate/stale feedback and retention expiry.

Use fixed synthetic stores of 100/1,000/10,000 facts for cost measurements, separate from quality
cases. 100 is reachable through the real store's caps (~300–500 rows max); 1,000 and 10,000 exercise the pure
ranker directly and must say so in the report.
Seed generators and record seeds. Do not make corpus size depend on locale or dictionary iteration.

## Measurements and definitions

- `Recall@k`: relevant IDs present among top k divided by all relevant IDs, for k = 1, 3 and 8.
  Exclude queries with no relevant IDs from this denominator and report their count separately.
- `MRR@8`: mean reciprocal rank of the first relevant result within eight, zero if absent.
- `nDCG@8`: graded relevance with gain `2^grade - 1` and discount `log2(rank + 1)`, normalized by
  ideal DCG. Report N/A when ideal DCG is zero, never silently convert that case to a perfect score.
- `No-match accuracy`: fraction of labelled unrelated queries producing no matched facts.
- `Prompt recall`: relevant facts actually present after budget/render/provider composition;
  report separately from retrieval recall and identify intentional budget omissions.
- `Forbidden inclusion`: count of cross-scope, deleted, expired, disabled-memory or canary leaks.
- `Continuity`: required current facts present across the explicitly supported lifecycle transitions.
- `Diagnostics fidelity`: selected/rendered/dropped counts and absence reason agree with the payload.
- `Cost`: ranking latency p50/p95, allocations or peak memory where reliably measured, corpus size,
  thread/actor behaviour, and counts of store/embedding/network operations.

Use deterministic fake vectors for adapter correctness. An unavailable embedding model cannot pass
semantic paraphrase tests by inventing vectors. Real embedding/model evaluation is a separate opt-in
run whose model/version/hardware are recorded. Provider answer accuracy is also separate from prompt
recall: correct prompt inclusion cannot prove the model used it correctly.

## Baselines and release gates

Before FI/FJ/FL behaviour changes, commit the measured baseline, including known failures. Every
report carries schema/corpus version and digest, tested commit, build configuration, toolchain,
OS/host, embedding mode and exact invocation. Never put credentials, real user content or private
paths in committed reports. Record working-tree modifications when the tested tree is not clean.

Initial target gates (proposed requirements, not measured claims):

- Zero forbidden inclusions, zero privacy-canary diagnostic leaks, deterministic ordering and valid
  schema for all mandatory cases. These are absolute gates from the first FK PR.
- Lexical-answerable subset: Recall@3 >= 0.90 and MRR@8 >= 0.80, with no-match accuracy >= 0.95.
  Report each language/subset separately; a large English subset cannot hide another subset's failure.
- Exact lifecycle fixtures: 100% required prompt inclusion when within budget and enabled; 100%
  expected omission on disable/delete/expiry. Query-specific live relevance is not promised by FJ.
- No quality regression beyond 0.02 absolute versus the accepted baseline on a gated subset, and no
  loss of a previously passing isolation/lifecycle invariant. New corpus versions show both reports.
- Performance: report p95 at each size; use FI's 25 ms/1,000-fact target only on a declared comparable
  optimized host. CI correctness must not fail on a noisy absolute wall-clock cutoff. Add a host-
  qualified performance gate only after repeat-run variance is measured.

Any target change requires a documented rationale, before/after results and review. Do not silently
remove failures, relabel hard queries as unrelated, alter expected IDs or lower thresholds to merge.

## Implementation checkpoints

### P0 — Loader, metrics and baseline

Build fixture loader, metric functions and table-driven tests. Unit-test metrics against hand-computed
small rankings, including missing/duplicate results and zero-relevant queries. Capture today's baseline
without modifying production outcomes; known-gap manifest names owner FI/FJ/FL and expected removal.

### P1 — Real store and prompt adapters

Use temporary directories and real semantic-memory CRUD/reopen, not a second toy store. Inject time
and embeddings through production seams. Call actual ordinary prompt assembly and capture provider
setup using fake transports. If a seam does not exist, extract the smallest dependency seam while
preserving behaviour; do not test a copied prompt builder. Verify resource fixtures load from the
bundle in generated Xcode projects.

### P2 — Lifecycle and correction scenarios

Add deterministic event scheduling for late async callbacks, reset/delete races and scope changes.
Use FL's event/revision identities when available; before that, maintain explicit known-gap results.
Do not use arbitrary sleeps or real remote tools. Assert all pending tasks/subscriptions are drained.

### P3 — CI, reports and optional device protocol

Add a bounded benchmark suite to the existing test workflow, reuse its toolchain/project action, and
upload synthetic machine-readable JSON plus Markdown summary and xcresult. Do not call external
providers in PR CI. Separate optional manual/provider runs by credentials and label. Set retention
consistent with existing CI artifacts, never include environment dumps.

## Reproduction and verification

Follow `docs/BUILDING.md` to install the pinned build prerequisites and generate the project with
unit tests included (`./Scripts/generate-xcodeproj.sh`; do not set `OPENGLASSES_SKIP_TESTS=1`). List
available simulators using `xcrun simctl list devices available`. Run the existing workflow's resolved
package setup first; `Package.swift` alone does not define the XCTest target.

Example local invocation after setup, replacing the destination with an available simulator UUID:

```bash
xcodebuild test \
  -project OpenGlasses.xcodeproj \
  -scheme OpenGlasses \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' \
  -only-testing:OpenGlassesTests/MemoryQualityBenchmarkTests \
  -resultBundlePath "$SCRATCH/OpenGlassesMemoryQuality.xcresult" \
  -onlyUsePackageVersionsFromResolvedFile \
  -collect-test-diagnostics never \
  SWIFT_EMIT_LOC_STRINGS=NO
```

The result path must not already exist. `-collect-test-diagnostics never` avoids a multi-minute
post-pass stall; `-only-testing` takes the test **class** name (a wrong identifier silently runs
nothing — check the executed count); use a simulator UUID destination, since a name-based
destination can hang when an iPhone is plugged in. `SWIFT_EMIT_LOC_STRINGS=NO` keeps the tracked
string catalog untouched. Additional flags/cache paths should match the checked-in CI
workflow on the target machine. Run related memory/reset/live/skill tests and the required normal CI
checks before merging. A pure Swift fixture harness may help development but is not a substitute for
adapter/XCTest verification. No glasses or model are required for mandatory fixture tests.

For optional live runs, use only synthetic facts, record backend/model and repeat count, distinguish
payload inclusion from answer correctness, and explicitly test delete/disable/restart. Capture
provider failures as failures or unavailable evidence, never replace them with fixture results.

## Completion

Complete when fixture/metric tests, real store/prompt adapters, baseline report, CI artifact publishing
and reproduction guide exist. FK can be built while feature targets remain unmet: its status must
state which FI/FJ/FL target results are still known gaps. A green infrastructure gate is not a claim
that those feature outcomes have shipped. Preserve earlier reports for comparison.
