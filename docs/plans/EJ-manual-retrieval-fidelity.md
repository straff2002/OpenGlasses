# Plan EJ — Manual Retrieval Fidelity (what a real OEM manual pair exposed)

**Status:** 📋 Planned 2026-09-07.
**Origin:** The first vault built from a real pair of OEM manuals — a Lennox SLP99UHVK gas furnace
service manual (85 pages) and installation instructions (78 pages), 400 KB of extracted text, 692
chunks — was imported headlessly through the shipped validator, importer, lookup tool, procedure
runner and retriever (`examples/vaults/lennox-slp99`, `ExampleVaultLennoxTests`). The vault side
held: validation clean, every code and model resolves from the core, procedures walk, a bare `E223`
cites Service Manual page 20 and Installation Instructions page 47. The retrieval side did not: a
spoken sentence carrying the code dropped the code's own rows, an out-of-scope question about a
different manufacturer's furnace came back "sufficient", and every citation carried a nonsense
section. These are the failures the vault guide's step 6 tells a customer to report to us; they
should not survive to the first pilot.
**Priority:** P1 for the Field Assist commercial track — it gates the Plan ED product promise
("when the manual is silent the assistant says so") on real manuals rather than the test fixtures.
**Surfaces:** Retrieval only. No UI, no HUD, no schema change. Pairs with
[Plan ED](ED-vault-manual-retrieval.md) (which it corrects) and
[Plan EF](EF-scanned-manual-import.md) (unchanged).

---

## Verified starting point

Read against the code on 2026-09-07 and against the simulator run recorded in the example's README.

- **Ranking.** `VaultRetriever.retrieve` merges semantic hits (`DocumentStore.query`) and exact
  whole-token hits (`DocumentStore.passages(containingToken:)`) into one list sorted by
  `score = similarity + min(maxBoost, tokenBoost × matchedTokens)`, with `tokenBoost = 0.25` and
  `maxBoost = 0.5`. A token-search passage arrives with `similarity = 0`, so a code that appears in
  a passage the embedder did not also return is worth exactly 0.25. On the simulator every semantic
  hit scored 0.87–0.91. Result for the turn *"the display shows E223 on a heat call"*: four passages
  of LED-menu prose from page 45, no E223 row. The bare-code path (`turn: "E223"`) works only because
  it has no semantic competitor. `VaultManualRetrievalTests.testKeywordSearchSuppliesPassagesTheEmbedderCannotReach`
  pins the 0.25 score.
- **Evidence gate.** `RetrievalEvidencePolicy.isEvidence` is `similarity >= 0.30 || matchedTokens
  non-empty`. `DocumentStore.query` already drops anything under `minSimilarity = 0.05`. With
  cosines of 0.87–0.91 for *"torque for the blower wheel set screw"* and *"replace the heat exchanger
  on a Carrier 58MVB"* the gate passes everything; `insufficientSentence` was never produced against
  the real manuals. The simulator ran `nl-word.en` (the averaged `NLEmbedding.wordEmbedding`
  fallback — the `com.apple.linguisticdata` sentence asset is refused in the simulator sandbox), which
  is the same backend a device falls to when the sentence asset is missing. The 0.30 floor was chosen
  in ED without a measurement on either backend. `EmbeddingBenchmark` (recall@k, MRR, a labelled
  smoke corpus) exists for exactly this kind of decision and has no out-of-scope negatives in it.
- **Section headings.** `DocumentChunker.detectHeading` accepts (a) `^\d+(\.\d+)*\s+\S` — which
  matches numbered list steps (`7 - Inspect the condensate drain…`), spec-table rows (`1 AFUE 98.1%
  98.1% 98.2%`) and flowchart labels; (b) `Chapter/Part/Section/Article N`; (c) any line of
  `[A-Z0-9\s.,;:()&/-]+` with four uppercase letters — which matches `FIGURE 5`, `TABLE 22.`,
  `WARNING`, `CAUTION`, `BOTTOM RETURN AIR`, `C 24VAXC COMMON`. On the Lennox pair the top
  "sections" by chunk count were `BOTTOM RETURN AIR` (19), `FIGURE 5` (13), `TABLE 22.` (13),
  `WARNING` (9), `CAUTION` (8). `VaultRetriever.Passage.citation` appends `§section` to every
  citation; `DocumentRAGTool` renders the same field. `DocumentChunkerTests` pins the four positive
  cases and three negatives, none of which are figure/table/list-step lines. `DocumentChunker` has a
  single consumer, `DocumentStore`, so the blast radius is the RAG store (vault manuals, Reading
  Companion imports, memory documents) and nothing else.
- **Page markers.** `DocumentChunker.pageNumber(in:)` matches `^\s*page\s+\d` — a *prefix*, so a
  wrapped table-of-contents line beginning `Page 62 VII Typical Operating…` sets the page to 62 while
  still on page 1 (observed: the Lennox TOC chunk). Marker lines are breakpoints only; their text is
  kept in the chunk, so passages read `… Page 34 Page 34 TEST B …` when the OEM prints its own page
  header (Lennox does, on every page). If an OEM's printed numbering differed from the PDF index
  (unnumbered cover, roman-numeral front matter) the OEM's line would silently override the
  extractor's — the exact citation error ED's per-page extraction was built to prevent.
  `Scripts/extract-manual-text.swift` writes `Page N` as its marker deliberately, so a human can read
  and correct the text; the in-app PDF path uses form feeds and is not affected by the leak but is
  affected by the OEM header override.
- **Core lookup cap.** `EquipmentLookupTool.searchMatches` returns at most three `##` sections in
  file order. A spelling that also appears in an introduction or a summary table before the model's
  own section pushes that section out. Fixed in the example by moving every spelling into the model
  headings; the guide does not say to.
- **Extractor hint.** The script's closing hint prints `"kind": "service_manual"` and the input file
  name as `title` for every manual.

## Product promise, restated

The three things ED promised, made true on real manuals:

1. A spoken code always retrieves its own row first, whatever else the sentence contains.
2. A question the manuals do not cover produces the fixed insufficiency sentence, on both embedder
   backends, with a threshold that was measured rather than guessed.
3. A citation is `Title, page N` — and `§section` only when the section is a real heading.

## Design

### 1 · Token hits sort first (ranking)

Replace the additive score with a two-key sort: passages with `matchedTokens` non-empty rank ahead
of passages without, then by `score` within each group. Keep `tokenBoost`/`maxBoost` for ordering
among token hits (two matched codes beat one). `score` stays what it is, so the existing
`testKeywordSearchSuppliesPassagesTheEmbedderCannotReach` assertion on 0.25 still holds; a new test
states the invariant directly: a token hit with similarity 0 outranks an unmatched passage with
similarity 0.99.

Fill, not replace: a turn with a code keeps room for prose. `retrieve` takes token hits first up to
`limit`, then semantic hits — so *"the display shows E223 on a heat call"* returns the E223 rows from
both manuals and, if `limit` allows, the best semantic passage. When the same row appears in two
manuals (the Lennox pair repeats the diagnostic table verbatim) both are kept; deduplicating across
titles is a model-side judgement, and the second citation is useful.

### 2 · A gate that is calibrated, not assumed (evidence)

Two changes, one measurement.

**Relative margin instead of an absolute floor.** `RetrievalEvidencePolicy` gains a second criterion:
a passage counts as evidence when its similarity clears the floor **and** it is within `margin` of
the best passage in the ranked list, *or* it carries a token. The gate then asks "is anything here
markedly better than the background?" rather than "is anything above 0.30?", which is the question
that survives a change of embedder. Both parameters stay injectable; both defaults come from the
measurement below.

**Measurement.** Extend `EmbeddingBenchmark` with a negatives set — questions with no relevant
passage in the corpus (other manufacturers, torque specs, weather) — and a score,
`insufficiencyRecall`: the fraction of negatives for which the gate says insufficient at a given
policy. Run it against both backends (`nl-word` headless; `nl-sentence` and `nl-contextual` on a
device via the existing Diagnostics screen path that already reports embedding readiness) with the
Lennox pair as the corpus, and pick the `(floor, margin)` pair that maximises positive recall@4 with
insufficiency recall ≥ 0.9. Record the numbers per backend in this plan's Status line and in
`RetrievalEvidencePolicy`'s doc comment, with the backend they were measured on. If the two backends
need different floors, `RetrievalEvidencePolicy.default(for: Embedder)` chooses by `modelId` — one
place, stamped the same way persisted vectors are.

The insufficiency sentence itself does not change; the vault rules already tell the model to relay
it.

### 3 · Headings a technician would recognise (chunker)

Tighten `DocumentChunker.detectHeading` to what a manual's headings actually look like:

- Reject lines beginning `FIGURE`, `TABLE`, `NOTE`, `WARNING`, `CAUTION`, `DANGER`, `IMPORTANT`
  (case-insensitive, optional trailing number/punctuation) — labels, not sections.
- Reject a numbered line whose number is followed by ` - `, `)`, or `.` with a space before a
  lowercase word (`7 - Inspect…`, `1) Remove…`) — list steps.
- Require that letters outnumber digits and that the line has at most one run of two or more
  spaces — a spec-table row (`3.5 / 10.0 3.5 / 10.0`) fails, a heading passes.
- Keep the ALL-CAPS rule but require at least two words and ≥ 60 % letters, so `SAFETY PROCEDURES`
  passes and `C 24VAXC COMMON` (a terminal label) still passes only if it has the letter share — it
  does not.
- Cap accepted headings at 80 characters; ED's citation is spoken aloud.

Pin every Lennox false positive listed above as a negative in `DocumentChunkerTests`, alongside the
existing positives. `VaultRetriever.Passage.citation` and `DocumentRAGTool` are unchanged: they
render `§section` when present, and after this change it is present less often and right when it is.

### 4 · Page markers as whole lines, dropped from the text (chunker + extractor)

- `pageNumber(in:)` matches the **whole trimmed line**: `^page\s+\d{1,4}$` (case-insensitive) or
  `^-\s*\d{1,4}\s*-$`. A wrapped TOC line no longer moves the page.
- `pageHeadingBreakpoints` returns the ranges of recognised marker lines; `taggedSentences` skips a
  sentence that is exactly a marker line, so `Page 34 Page 34` never reaches a chunk. Form feeds are
  already invisible.
- **Precedence rule.** A marker line that follows a form feed or an extractor marker within the
  first two lines of a page is the OEM's header and is ignored for numbering — the extractor's
  physical page wins. Encoded as: once the document has shown form feeds *or* `Page N` lines at
  page starts, a second marker within the same page's first two lines does not change `page`. This
  is the case ED's per-page extraction exists for; a test with mismatched OEM numbering pins it.
- `Scripts/extract-manual-text.swift`: keep `Page N` (human-readable is the point of Route C), but
  print, per page, when the page's own first line is also a `Page N` line with a *different* number
  — the one situation a customer needs to know about before import. Fix the closing hint: derive
  `kind` from the file name (`install` → `install_guide`, `wiring` → `wiring`, else `service_manual`)
  and print a `title` with hyphens replaced by spaces, labelled as a suggestion.

### 5 · Core lookup and the guide (small)

- `EquipmentLookupTool.searchMatches`: when the query is code-like, prefer sections whose **heading**
  contains it before sections whose body does, then fall back to body matches — still capped at
  three. Pinned by a test with a file whose intro mentions the model before its own section.
- `docs/field-assist-vault-guide.md`: in "A nameplate reference", say to put every spelling of a
  model in that model's heading and why; in "Step 6 · Test the loop", replace the hand-check for
  out-of-scope questions with the statement that the gate is measured (and what the measured
  behaviour is), keeping the "tell us if you get a confident answer" line. Note in Route C that the
  extractor warns when a manual's printed numbering disagrees with its PDF pages.

## Phases

House style: deterministic core first, one PR per plan, the live edge last.

- **P1 — pure core (one PR).** §1 ranking, §3 heading detector, §4 whole-line markers + text
  strip + precedence, §5 lookup preference. All headless. Tests: new invariants in
  `VaultManualRetrievalTests` and `DocumentChunkerTests`, the Lennox false positives as negatives,
  and `ExampleVaultLennoxTests` gaining two assertions that were printed-not-asserted on 2026-09-07:
  the sentence turn cites the code's page, and no citation for the Lennox pair contains
  `§FIGURE`, `§TABLE`, `§WARNING` or a list-step. Full suite + Release green before the PR (the
  suite's own Reading Companion and memory chunking tests are the regression net for §3/§4).
- **P2 — measured gate (one PR).** §2: `EmbeddingBenchmark` negatives + `insufficiencyRecall`, the
  relative-margin criterion, `RetrievalEvidencePolicy.default(for:)`, the two numbers measured and
  recorded. Headless gives the `nl-word` number; the `nl-sentence` / `nl-contextual` numbers need
  one device run through the Diagnostics screen and are recorded in the Status line when taken. Ships
  with the guide edits (§5) because the guide's step-6 wording depends on the measured behaviour.
- **P3 — extractor + example (small PR).** §4 script changes, the hint fix, and re-running the
  Lennox example through the extractor to confirm no numbering warnings fire on that pair.

## Acceptance

- `ExampleVaultLennoxTests` asserts, not prints, that *"the display shows E223 on a heat call"*
  cites Service Manual page 20 or Installation Instructions page 47, and that every citation for
  the pair is either `Title, page N` or `Title, page N, §<a heading with two or more words>`.
- Against the Lennox pair with the default policy, *"how do I replace the heat exchanger on a Carrier
  58MVB"* and *"what is the torque for the blower wheel set screw"* produce the insufficiency
  sentence on the `nl-word` backend headlessly, and on the sentence backend on a device (recorded).
- `DocumentChunkerTests` rejects `FIGURE 5`, `TABLE 22.`, `WARNING`, `7 - Inspect the condensate
  drain and trap for leaks and`, `1 AFUE 98.1% 98.1% 98.2%`, `C 24VAXC COMMON`, and accepts `5.3
  Safety Requirements`, `Chapter 12`, `SAFETY PROCEDURES`, `Heating Sequence of Operation`.
- A chunk never contains a recognised page-marker line; a document whose OEM header numbering
  differs from its physical pages cites the physical page.
- No change to `documents.sqlite` schema, `VaultManifest`, or any UI string.

## Risks and non-goals

- **Re-indexing.** Chunk boundaries do not move (sentence packing is untouched); only `section`
  metadata and marker-line removal change. Existing stores keep working; a re-index is not forced.
  A `DocumentStore.reindexOutdated`-style pass keyed on a chunker version is deferred until a
  boundary change needs it.
- **Over-tightening headings.** A manual with `1 Introduction`-style numbered headings must still
  work — the list-step rule keys on the separator after the number, not on the number alone. The
  positives in `DocumentChunkerTests` guard it.
- **Not in scope.** Cross-encoder reranking, a different embedder, deduplicating repeated tables
  across manuals, and the extractor's OCR path (EF) are unchanged.
