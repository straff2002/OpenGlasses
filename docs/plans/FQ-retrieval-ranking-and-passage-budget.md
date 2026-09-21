# Plan FQ — Retrieval Ranking, Query Variants and the Passage Budget

**Status:** 📝 Drafted 2026-09-21. Nothing in this plan is implemented. Phase 1 is a measuring
stick and must land before Phases 2 and 3, which are judged against the baseline it records.
**Origin:** [Plan EJ](EJ-manual-retrieval-fidelity.md) fixed what the first real OEM manual pair
exposed and left two things behind. The first is an instrument gap: the calibration harness scores
`recall@4` and insufficiency recall, and neither can see *where in the four* a correct passage
landed — which is precisely the shape of the failure EJ P1 had to fix by hand (the E223 rows were
retrieved and ranked below LED-menu prose). The second is a budget gap: a Field Assist answer is
**spoken**, the passage list is capped at four, and today two of those four can be the same table row
printed in both manuals. `examples/vaults/lennox-slp99/README.md` records it as "correct, just
verbose at `limit: 4`". At four passages, verbose is a quarter of the evidence budget.
**Priority:** P2 for the Field Assist commercial track. Nothing here is a correctness defect — EJ's
invariants hold — but Phase 1 is a prerequisite for every future retrieval change, including the
index-side work listed under *Follow-on work*, which cannot state an acceptance criterion without it.
**Surfaces:** Retrieval and its test harness only. No UI, no HUD, no schema change, no re-index.
Pairs with [Plan EJ](EJ-manual-retrieval-fidelity.md) (whose invariants it must preserve),
[Plan EK](EK-manual-structure-and-figures.md) (citation-as-door, which bears on §3's open decision),
[Plan EL](EL-equipment-identity.md) (the model-scope penalty, likewise) and
[Plan AM](embedding-quality-upgrade.md) (which owns the embedding backend and is untouched).

---

## Verified starting point

Read against `main` on 2026-09-21. Paths are repository-relative; locate symbols rather than relying
on line numbers alone.

- **The ranked list.** `VaultRetriever.retrieve`
  (`OpenGlasses/Sources/Services/Vault/VaultRetriever.swift:163`) builds up to three query parts from
  the turn, the OCR text and the running procedure step, issues each at
  `max(request.limit * 2, 4)` candidates (`:193`), adds an exact whole-token search per code-like
  token (`:195-199`), merges on `"\(documentId)#\(chunkIndex)"` keeping the better `rankScore`
  (`:185-191`), then sorts in **two groups** — every passage with `matchedTokens` first, then
  everything else, each group by `rankScore` (`:207-217`). That two-group sort is EJ P1's invariant
  and this plan does not touch it.
- **The evidence gate.** `RetrievalEvidencePolicy.decide` (`:424-429`) filters the ranked list
  through `isEvidence` (`:409-422`) — a verbatim code-like token is always evidence; otherwise the
  passage must clear `similarityFloor`, the optional relative `margin`, and the
  `LexicalSupport` shared-content-term criterion — then takes `prefix(limit)`.
  `RetrievalEvidencePolicy.default(for:)` (`:399-404`) ships `minSharedTerms: 3`,
  `sharedFraction: 0.75` for the `nl-word` backend and leaves the sentence and contextual backends
  at the unmeasured floor, exactly as EJ §2 records.
- **The passage budget.** `VaultRetriever.boundedOutcome` (`:246-265`) is the only de-duplication
  that reaches the spoken answer, and it is **exact-identity only**: a `Set` of
  `"\(documentId):\(chunkIndex)"` (`:251-253`). Two chunks that are different rows of the same
  reprinted table, or the same row printed in two manuals, both survive it and both consume a slot
  of the 12,000-character budget.
- **The metrics that exist.** `EmbeddingBenchmark` (`OpenGlasses/Sources/Services/RAG/EmbeddingBenchmark.swift`)
  already has `recallAtK` (`:14`), **`meanReciprocalRank` (`:26`)** and `insufficiencyRecall`
  (`:72`). MRR is written, tested by its own smoke corpus, and **never called by the vault harness**.
- **The metrics the vault harness reports.** `RetrievalGateCalibrationTests.testGateVariantsMeasuredAgainstTheLennoxPair`
  (`OpenGlassesTests/RetrievalGateCalibrationTests.swift:173`) prints one row per policy variant with
  `recall@4` (`:228`), insufficiency recall (`:229`) and the in-scope refusal rate. Nothing else.
- **A latent trap in the harness shape.** `locationId` (`:364`) returns the constant `"hit"` for a
  passage on an anchor page and `nil` otherwise, and the ranked-id list is built with **`compactMap`**
  (`:223-225`), which *collapses the misses out*. `recall@4` survives that only because the gate has
  already truncated to four; **MRR would be silently wrong on this shape** — a correct passage at
  rank 3 behind two misses would report a reciprocal rank of 1.0. Phase 1 must fix the list
  construction before it can add a rank-sensitive metric. This is the single most important
  implementation note in the plan.
- **Query construction.** The only variant generated today is the OCR one (`:176-182`): a nameplate
  dump is replaced by its `CodeTokenizer.candidateTokens` joined with spaces, so boilerplate does not
  drown the embedding. The spoken turn itself is embedded **verbatim**, filler words and all.
- **The vocabularies both stages would reuse.** `LexicalSupport.contentTerms`
  (`OpenGlasses/Sources/Services/Vault/LexicalSupport.swift:40`) — lowercase, letters only, four or
  more characters, a stopword list, one pass of suffix trimming — and `CodeTokenizer.candidateTokens`
  / `isCodeLike` (`OpenGlasses/Sources/Services/Vault/CodeTokenizer.swift:10`, `:27`). Both are pure,
  both are already the shared vocabulary of the gate and the boost.
- **The three production retrievers.** `FieldSessionService.manualRetriever`
  (`OpenGlasses/Sources/Services/FieldAssist/FieldSessionService.swift:827`, feeding
  `promptContext(turn:)` at `:771`), `ManualLookupTool` (`:116`) and `EquipmentLookupTool` (`:166`).
  All three construct a `VaultRetriever` over the same store closures, so a change inside `retrieve`
  reaches all three and needs no call-site edits.
- **The corpus.** `examples/vaults/lennox-slp99` — the two committed-locally OEM manuals (85 and 78
  pages, ~690 chunks), 17 in-scope questions each labelled with the printed pages that answer it and
  16 out-of-scope questions, all in `RetrievalGateCalibrationTests` and skipped when a developer has
  not dropped the manuals in. `ExampleVaultLennoxTests.swift:554` builds the same retriever for the
  end-to-end assertions.
- **What the simulator measures.** `nl-word.en`, the averaged word-embedding fallback: cosines of
  0.838–0.917 for in-scope questions and 0.846–0.897 for out-of-scope ones — two distributions that
  overlap completely (EJ §2). **Every assertion this plan adds must be on token behaviour, rank
  behaviour or set membership, never on an absolute cosine**, because on this backend an absolute
  cosine means nothing and on a device with the sentence asset it means something different.

## Product promise, restated

1. Every retrieval change after this one is argued from a measured delta on the committed corpus,
   including where in the answer a correct passage landed, not only whether it appeared at all.
2. A technician who asks the way technicians actually talk — *"right, the display's showing E223 on
   a heat call, what've I got here"* — gets the same evidence as one who asks in keywords.
3. The four passages a spoken answer is built from are four *different* things.

## Design

### 1 · Metrics: rank, not just presence

**A shared, pure scorer.** Add `meanReciprocalRank`'s missing sibling to `EmbeddingBenchmark` beside
the two that already live there, and give both a ranked-list shape that carries misses:

- `normalizedDCG(_ k: Int, results:labels:)` — binary graded relevance, gain `1` for a relevant
  position and `0` otherwise, discount `1 / log2(rank + 1)`, normalised by the ideal DCG of the
  **same number of relevant items the candidate pool actually contains** for that query, capped at
  `k`. Stating the ideal from the candidate pool rather than from an unknown corpus-wide relevant
  count is the only definition that is computable here and reproducible across runs; it is written
  in the doc comment so nobody re-derives it differently later. `nDCG@k` is 1.0 when every relevant
  passage the retriever could have found sits at the top, and 0.0 when none is retrieved.
- Both `nDCG` and the existing `meanReciprocalRank` take `rankedIds` in which a **non-relevant
  position is present, not elided**. The harness's ranked-id construction changes from `compactMap`
  to `map` with a distinct miss marker, and `recallAtK`'s behaviour is unchanged by that (it asks
  `prefix(k).contains(want)`).
- `k` is a parameter. This plan uses `nDCG@4` — four is the shipped passage limit and the number a
  spoken answer is built from. **Plan FK's `nDCG@8` for memory calls the same function with `k = 8`**;
  there must be exactly one nDCG implementation in the codebase, and FK's starting-points section is
  amended to point at it rather than to a new one.

**The table.** `testGateVariantsMeasuredAgainstTheLennoxPair` prints, per variant:
`variant | recall@4 | MRR | nDCG@4 | insufficiency recall | in-scope refused`. The two new columns
are computed over the same gated lists as `recall@4`, so a criterion that drops a correct passage
costs all three consistently.

**The baseline.** The run of that table against the shipped default — `floor 0.30 + terms ≥ 3 +
fraction 0.75` on `nl-word.en`, the two Lennox manuals present — **is recorded in this document in
§1's Baseline table as part of the Phase 1 PR**, in the same form EJ §2 records its variant table.
Until that run exists the table below holds the columns and the word *pending*; a Phase 1 PR that
does not fill it in is not finished. The corresponding device run with the
`com.apple.linguisticdata` sentence asset present is owed and is not claimed by this plan — the same
device run EJ's Status line already owes.

| backend | recall@4 | MRR | nDCG@4 | insufficiency recall | in-scope refused |
|---|---|---|---|---|---|
| `nl-word.en` (simulator, shipped default) | 0.824 (EJ §2) | pending | pending | 0.750 (EJ §2) | 0.118 (EJ §2) |
| `nl-sentence` (device) | pending | pending | pending | pending | pending |

**One assertion, not a number.** Phase 1 asserts a *relationship* rather than a value, because the
value is a property of one corpus on one backend: for every in-scope question the shipped default
answers, `MRR ≥ recall@4 / 4` (a hit inside the top four can never have a reciprocal rank below a
quarter) and `nDCG@4 ≤ recall@4` under binary gain. Both are arithmetic identities of the
definitions; they fail loudly if the ranked-list plumbing regresses to eliding misses, which is the
bug this phase exists to prevent.

### 2 · Deterministic query variants, on low recall only

The turn is embedded verbatim. A spoken turn is a sentence with a stem, filler and a subject:
*"the display shows E223 on a heat call"* carries three content terms after
`LexicalSupport.contentTerms` and about nine other words that contribute nothing but pull the
averaged vector towards the corpus mean. The code path is already covered by the token search, so
the variant work is for the questions that carry **no** code-like token at all — the majority of the
in-scope set, and the ones `recall@4 = 0.824` is leaving on the table.

**The variants.** Pure, from the turn text alone. No model, no network, no state:

1. **Content-term variant.** `LexicalSupport.contentTerms(turn)` joined by spaces, in first-appearance
   order (the existing function returns a `Set`, so the ordering helper is new and lives beside it).
   *"the display shows E223 on a heat call"* → `display shows heat call` — stemmed, so it is the same
   vocabulary the gate scores against. Emitted when it has at least two terms and differs from the
   turn.
2. **Quoted-span variant.** Any span the turn puts in quotes, emitted whole. Rare from speech,
   common from the Chat tab and from a pasted fault description.
3. **Leading-interrogative strip.** Drop a leading *what is / what's / how do I / how does / why does
   / where is / which / when does / can you tell me / tell me / show me* and any leading filler
   (*right, ok, so, um, uh, er, look, listen*), then emit the remainder if it changed and still has
   at least two content terms. This is the one that matters for dictated speech: transcription keeps
   the filler and the wake-word tail, and `Embedder` averages every word of it.
4. **Clause split.** Split on `,` `;` `and` `but` `then` and emit any clause of three or more content
   terms. *"I've got no ignition and the pressure switch is chattering"* asks two questions; the
   manual answers them in two different places.

Capped at **three** variants, de-duplicated case-insensitively against each other and against the
turn, each at least four characters. The cap is the latency budget: each variant is one more
`DocumentStore.query`, which is a full cosine pass over the namespace's chunks
(`OpenGlasses/Sources/Services/RAG/DocumentStore.swift:118-148`), and a voice turn cannot pay for
five of them.

**The trigger.** Variants are generated **only when the first pass under-recalls**, so the common
case costs nothing:

> After the verbatim turn, the OCR variant and every token search have been merged, if the merged
> candidate count is below `request.limit` — or if it is below `2 × request.limit` and **no**
> candidate carries a matched token — generate variants and query each at
> `max(request.limit * 2, 4)`, merging into the same map by the same rule.

The second clause is the one that fires on the Lennox corpus: a code-carrying turn already has its
answer and does not need help, while a prose question that returned a thin pool of look-alike
passages does. The predicate is a pure function of the merged map and is unit-tested on its own.

**Interaction with the existing OCR variant.** Unchanged and unconditional. The OCR text is a
nameplate dump, not a sentence; its token-joined form is a *replacement* for an unusable query, not
a recall rescue, and it runs on the first pass as it does today (`VaultRetriever.swift:176-182`).
The procedure-step part is likewise left on the first pass. Only the spoken/typed turn feeds §2.

**Interaction with EJ's two-group sort.** None, by construction. A variant's results enter the same
`merged` map through the same `consider` closure, so a passage's `matchedTokens` are computed against
the *same* boost-token set (derived from the turn and the OCR text, not from the variant) and the
two-group sort at `VaultRetriever.swift:207-217` runs once, afterwards, over the union. A variant can
add a passage; it can never reorder the groups or promote a passage above a token hit.

**Interaction with the evidence gate — the constraint that governs this phase.** Expansion widens
the candidate pool, and a wider pool of look-alike passages is exactly how a gate starts answering
questions it should refuse. Two rules:

- `RetrievalEvidencePolicy.decide` continues to be called with the content terms of the **original
  parts only** — `queryTerms: LexicalSupport.contentTerms(parts.joined(separator: " "))`
  (`VaultRetriever.swift:221-222`), unchanged. A variant is a way of *reaching* a passage, never a
  way of *justifying* one: scoring a passage against a variant's own reduced term set would make
  the shared-term criterion trivially easier to satisfy, which is the failure mode.
- Acceptance is stated as a two-sided inequality on the Phase 1 baseline (see *Acceptance*), so a
  recall gain bought with insufficiency recall is a failed phase, not a shipped one.

### 3 · Diversity inside each ranking group

Select the final passages with maximal marginal relevance instead of taking `prefix(limit)` off the
front of the ranked list.

**The selection.** Greedy, deterministic, pure over the ranked list:

- Relevance is the passage's existing `rankScore` (`VaultRetriever.swift:83` — `score` less the
  EL model-mismatch penalty), normalised within the group by its maximum so that λ trades two
  quantities on the same scale. Normalising within the group and not globally is required: a
  token-hit group can contain passages of `similarity = 0`, and a global normalisation would make
  every token hit's relevance term vanish.
- Redundancy is the **maximum Jaccard overlap of `LexicalSupport.contentTerms` with any
  already-selected passage** — the same stemmed vocabulary the gate uses, so a technician can be
  told why two passages were treated as the same thing.
- `mmr = λ · relevance − (1 − λ) · redundancy`, **λ = 0.7**, the conventional starting point; it is a
  named constant on `RetrievalEvidencePolicy` so the calibration harness can sweep it as a variant
  column alongside the gate variants, and the shipped value is set from that sweep rather than from
  this paragraph.
- Ties are broken by the existing deterministic order — `rankScore`, then `(documentName,
  chunkIndex)` (`:208-209`) — so the same request always yields the same four passages.

**Applied inside each group, never across.** The selection runs over the token-hit group to fill its
slots, then over the non-token group to fill whatever `limit` leaves. EJ's invariant — a passage with
a matched token outranks every passage without one — is a property of the group boundary and is
untouched. `ExampleVaultLennoxTests` gains an assertion stating it directly against the Lennox pair.

**Where it runs.** In `RetrievalEvidencePolicy.decide` (`:424-429`), after `isEvidence` filtering and
in place of the bare `prefix(limit)`. Running it after the gate means diversity never rescues a
passage the gate refused and never causes a refusal — `decide` still returns `.insufficient` on an
empty evidence set, unchanged. `boundedOutcome`'s exact-identity de-duplication (`:251-253`) stays as
the last line of defence for the character budget.

#### Open decision — does the same row in two manuals count as redundant?

The Lennox pair reprints its whole diagnostic table: a query for `E223` legitimately returns the row
from Service Manual page 20 **and** from Installation Instructions page 47. Under the rule above
those two have near-identical content terms and the second would be dropped as redundant.

**Against dropping it.** EJ §1 decided explicitly to keep both ("deduplicating across titles is a
model-side judgement, and the second citation is useful"). EK P3 then made every citation a door — a
`Source:` line opens that page in the app — so the second citation is no longer just corroboration,
it is a *second route to the material* for a technician who has only one of the two manuals to hand,
or whose copy of one is the OCR-recognised one carrying the provenance note.

**For dropping it.** The answer is spoken. Reading two byte-identical rows aloud with two different
sources is not corroboration to a listener, it is repetition — and it costs a slot out of four that a
genuinely different passage could have used.

**Recommendation: exempt the token-hit group, apply MMR only to the non-token group.** A verbatim
code match is the strongest evidence the retriever has and it is exactly the case where the same row
legitimately appears twice; the prose group is where near-duplicates are noise rather than a second
door. Concretely: MMR runs unconditionally on the non-token group, and on the token-hit group only
between passages of the **same document** (so a reprinted table in one manual is still trimmed, and
the cross-manual pair survives). This is stated as a policy flag, both behaviours are measured in the
harness, and the plan is not implemented on this point until Greig picks.

**→ Open decision for Greig.** The alternative worth considering is coupling it to EL instead: when
`FieldSessionService.retrievalModelScope` (`:290`) reports an identified machine, the second manual's
row is more likely to be redundant (both are about the machine in the room); when no machine is
identified, both citations help the technician work out which manual applies. That is a more precise
rule and a less predictable one, and predictability in what gets spoken is worth something.

## Phases (one PR each)

House style: deterministic core first, the live edge last. All three phases are headless.

- **P1 — the measuring stick (one PR).** §1. `EmbeddingBenchmark.normalizedDCG`; the ranked-id
  construction in `RetrievalGateCalibrationTests` changed from `compactMap` to `map` with an explicit
  miss marker; MRR and nDCG@4 columns in the variant table; the two arithmetic-identity assertions;
  the baseline run recorded in §1. Plan FK's starting-points section amended to name the shared
  scorer for its `nDCG@8`. **No production code changes at all** — this phase must be provably
  incapable of moving a number it is measuring. Tests: `EmbeddingBenchmarkTests` (new cases for
  nDCG: empty ranked list, all-relevant, relevant-at-tail, a list that elides misses must *not*
  silently score well — assert the shape contract), `RetrievalGateCalibrationTests` unchanged in its
  existing assertions.
- **P2 — query variants (one PR).** §2. A pure `RetrievalQueryVariants` type beside
  `LexicalSupport` with the four rules and the cap; an ordered-content-terms helper; the
  low-recall predicate as its own pure function; the wiring inside `VaultRetriever.retrieve` between
  the first-pass merge and the two-group sort. Tests: `RetrievalQueryVariantsTests` (each rule, the
  cap, de-duplication, a turn that yields nothing, a turn that is already keywords, the filler-heavy
  spoken forms); `VaultManualRetrievalTests` gains a case pinning that variants do not fire when the
  first pass is healthy (the existing `seenQueries` recorder at
  `OpenGlassesTests/VaultManualRetrievalTests.swift:306` is the instrument) and a case pinning that
  the gate is still given the original terms; `RetrievalGateCalibrationTests` reports the table with
  and without expansion.
- **P3 — diversity (one PR).** §3, after Greig settles the open decision. λ and the redundancy rule
  on `RetrievalEvidencePolicy`; the greedy selection in `decide`; the group-boundary invariant.
  Tests: `VaultManualRetrievalTests` (two near-identical passages and one different one at `limit:
  2` returns one of each; a token hit still outranks a higher-scoring non-token passage after
  selection; determinism across repeated calls); `ExampleVaultLennoxTests` asserts the group
  invariant and the reprinted-table behaviour the decision picks;
  `RetrievalGateCalibrationTests` sweeps λ as a variant column.
- **Owed, not a phase.** The device run of the Phase 1 table on the `nl-sentence` backend, which is
  the same device run [Plan EJ](EJ-manual-retrieval-fidelity.md) already owes and should be taken
  once for both.

## Acceptance

Measured on the committed Lennox pair with `RetrievalGateCalibrationTests`, `nl-word.en`, against the
Phase 1 baseline. Every criterion is a **delta**, because the absolute values are properties of one
corpus on one backend.

- **P1.** The table prints five columns. `recall@4`, insufficiency recall and the in-scope refusal
  rate for the shipped default are **unchanged to three decimal places** from EJ §2 (0.824 / 0.750 /
  0.118) — the phase changed no production code, and a moved number means the harness changed what
  it measures. The two identity assertions hold. Plan FK's nDCG references one function.
- **P2.** `recall@4` and `nDCG@4` both rise against the P1 baseline; **insufficiency recall does not
  fall**, and the in-scope refusal rate does not rise. That is the adoption rule and it is asserted,
  not merely printed: a variant set that buys recall with false confidence fails the phase. If no
  variant set meets it, the phase ships the harness column showing why and the expansion stays off
  behind its flag — the same discipline EJ applied to the relative margin it proved could not work.
- **P3.** At `limit: 4`, the number of selected passages sharing more than 0.8 Jaccard content-term
  overlap with an earlier selected passage falls to zero in the non-token group. `recall@4` does not
  fall by more than 0.02; `MRR` does not fall at all (diversity reorders the tail, not the head);
  insufficiency recall is unchanged (selection runs after the gate and cannot change its verdict).
  The chosen cross-manual behaviour is asserted against the real E223 query in
  `ExampleVaultLennoxTests`.
- **Throughout.** No assertion anywhere in this plan compares an absolute cosine. No change to
  `documents.sqlite`, `VaultManifest`, `DocumentChunker`, any chunk boundary, any embedding, or any
  UI string. No re-index is triggered or required.

## Risks

- **A rank metric on a flat-similarity backend.** On `nl-word.en` the ordering within the non-token
  group is nearly arbitrary, so `nDCG@4` will be noisy there and a small movement is not evidence of
  anything. Mitigated by stating acceptance as a direction plus a floor rather than a target, and by
  the fact that the metric's real value is on the sentence backend and on future index-side changes.
- **Latency.** Up to three extra `DocumentStore.query` passes on a low-recall turn, each a full
  cosine scan of the namespace. The trigger is designed so the common Field Assist turn (a code, a
  healthy first pass) pays nothing, but the worst case is a four-fold retrieval cost on the oldest
  supported phone. P2 must record a measured per-pass time on the Lennox corpus alongside the
  quality table, and the cap of three is the lever if it is too slow.
- **Over-diversifying a genuinely repetitive answer.** Some correct answers *are* four adjacent rows
  of one table. λ = 0.7 is chosen to be relevance-dominated, the λ sweep is in the harness, and the
  group exemption in §3 is the specific guard.
- **The harness is the product's only witness.** Every number here comes from one corpus of one
  furnace in one language, behind a skip when the manuals are absent. It is a good witness for
  regression and a weak one for generalisation; a second vault pair from a different manufacturer
  would be worth more than any tuning in this plan, and is not in it.

## Non-goals

- **No model in the retrieval path.** No LLM query rewriting, no intent classification before
  retrieval, no generated questions or summaries in the index. A Field Assist turn must work with the
  phone in aeroplane mode, and a second round trip before retrieval is unaffordable
  ([Plan CU](CU-voice-turn-latency.md) owns that budget).
- **No reranker model.** No cross-encoder, no scoring model, no downloaded asset. §3 is arithmetic
  over text the retriever already has.
- **No re-index.** Nothing here changes a chunk, an embedding or a chunk boundary, so no existing
  store is invalidated and `EmbeddingVersion` is untouched.
- **No embedder change.** [Plan AM](embedding-quality-upgrade.md) owns the backend; this plan
  measures whatever backend is active and hard-codes nothing about it.

## What this plan does not reopen

- **[EJ](EJ-manual-retrieval-fidelity.md)** — the two-group sort, the heading detector, whole-line
  page markers, the measured gate criteria and their `nl-word` defaults all stand. §2 and §3 are
  built to be invisible to them, and the acceptance criteria pin that.
- **[EK](EK-manual-structure-and-figures.md)** — the type-driven heading grammar, `kind`/`figure`
  on chunks, diagram exclusion from semantic query, citation format and the citation-as-door route
  are unchanged. §3's open decision is informed by EK P3 but changes nothing in it.
- **[EL](EL-equipment-identity.md)** — `EquipmentScopeCheck`, the `ACTIVE EQUIPMENT` block and the
  model-mismatch penalty are unchanged; §3 reads `rankScore`, which already has the penalty folded
  in, rather than re-deriving it.
- **[AM](embedding-quality-upgrade.md)** — the `EmbeddingBackend` seam, version tagging and lazy
  re-embed are untouched.
- **[FK](FK-memory-quality-and-continuity-benchmarks.md)** — FK owns memory benchmarking end to end.
  The only contact is that FK's `nDCG@8` calls the scorer Phase 1 adds instead of a second copy; FK's
  corpus, fixtures, gates and scope are entirely its own.
- **[FN](FN-vault-manual-removal.md)** — the availability check immediately before the gate
  (`VaultRetriever.swift:214-215`) is untouched and still runs before anything is decided.

## Follow-on work (not in this plan)

Two groups, recorded here so they are not lost and are deliberately **not** specced, lettered or
added to the index.

**(a) Query-time passage assembly.** Expanding a short retrieved chunk with its immediate neighbours,
and merging two adjacent retrieved chunks into one contiguous passage instead of speaking both with
their overlap repeated. This needs an adjacency accessor on `DocumentStore` (the `chunk_index` column
makes one trivial) and it *changes the text that gets spoken and cited*, which is a bigger promise
than anything in this plan — so it belongs in its own small plan or a later phase, after Phase 1 can
measure what it costs.

**(b) Index-side quality, which all force a re-index.** A heading-path breadcrumb prepended to the
*embedding input only* (the hierarchy EK P1 already extracts is currently collapsed to one flat
nearest section); carrying a table's header row across a chunk boundary so a spec row does not embed
as bare numbers; and chunker diagnostics — a tier chain, a validator that rejects obviously broken
output and falls through, and a reason a customer-authored vault can be shown. Each changes chunk or
embedding output, so each invalidates existing stores and none can state an acceptance criterion
until Phase 1's baseline exists. **The cautionary precedent is EK P1**, which improved headings from
type and cost 0.06 of `recall@4` on the labelled set — a real, measured regression that was only
visible because someone measured. None of these should ship on plausibility.
