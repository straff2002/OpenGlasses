# Plan EJ — Manual Retrieval Fidelity (what a real OEM manual pair exposed)

**Status:** ✅ P1–P3 implemented 2026-09-07 (headless); device measurement of `nl-sentence`/`nl-contextual` gate pending. P1: ranking, heading detector, whole-line page markers, lookup preference. P2: the gate measured against the real pair (`RetrievalGateCalibrationTests`) and given a lexical criterion plus per-backend defaults. P3: the extractor warns on printed numbering that disagrees with the PDF, derives its manifest hint from the file name, and self-checks; the `nl-word` gate re-measured on a set widened with short questions and its shared-term count scaled to question length (`sharedFraction` 0.75) — §2. **The device run this still needs:** run `RetrievalGateCalibrationTests` on an iPhone with the `com.apple.linguisticdata` sentence asset present and the two manuals in `examples/vaults/lennox-slp99/documents/`, then record the printed variant table for the `nl-sentence` backend here and set `RetrievalEvidencePolicy.default(for:)` for it from that table rather than from a guess.
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

Two changes, one measurement — and the measurement changed the design, so what follows is what was
built and what it scored, not what was planned.

**The criteria.** `RetrievalEvidencePolicy` now carries three switchable criteria beside the token
rule (a code-like token found verbatim is always evidence):

- `similarityFloor` — the absolute cosine floor, unchanged at 0.30.
- `margin` — the relative criterion the plan asked for: a non-token passage is evidence only if its
  similarity is within `margin` of the best passage in the ranked list. **It cannot do the job it
  was proposed for.** The best passage in a list is always within any margin of itself, so a margin
  trims a weak tail and can never make a query insufficient. This is a property of the criterion,
  not of this corpus; `testRelativeMarginTrimsTheTailButCannotRejectAQuery` pins it. It ships,
  switchable and off by default.
- `minSharedTerms` — content-word overlap between the question and the passage
  ([[LexicalSupport]]: lowercase, letters only, four characters or more, a short stopword list, one
  pass of suffix trimming). This is the criterion that actually refuses anything on this backend.

**Measured, `nl-word.en`, 2026-09-07** (simulator; the sentence asset is refused in the simulator
sandbox and a device without it runs the same fallback). Corpus: the Lennox pair, 685 chunks.
Twelve in-scope questions, each labelled with the printed pages that answer it, taken from the
manuals by grep rather than from a run of the retriever; twelve out-of-scope questions (other
manufacturers, a torque figure the book never gives, refrigerant charging, a heat-pump defrost
board, ductwork sizing, weather, price, warranty). `RetrievalGateCalibrationTests` is the
instrument and prints this table.

Similarity distribution over the top four passages of each question:

| | min | median | max |
|---|---|---|---|
| in-scope (n=48) | 0.838 | 0.888 | 0.917 |
| out-of-scope (n=48) | 0.846 | 0.876 | 0.897 |

The ranges overlap completely: the best out-of-scope passage outscores most in-scope ones. **No
floor and no margin can separate them at any setting.** That is the finding; the rest of the table
follows from it.

| variant | recall@4 | insufficiency recall | in-scope questions refused |
|---|---|---|---|
| floor 0.30 (shipped before P2) | 0.750 | 0.000 | 0.000 |
| floor 0.30 + margin 0.02 | 0.750 | 0.000 | 0.000 |
| floor 0.30 + margin 0.005 | 0.750 | 0.000 | 0.000 |
| floor 0.88 | 0.667 | 0.417 | 0.250 |
| floor 0.30 + terms ≥ 1 | 0.750 | 0.167 | 0.000 |
| floor 0.30 + terms ≥ 2 | 0.833 | 0.333 | 0.000 |
| **floor 0.30 + terms ≥ 3 (default)** | **0.833** | **0.667** | **0.083** |
| floor 0.30 + terms ≥ 4 | 0.583 | 1.000 | 0.167 |
| floor 0.30 + terms ≥ 5 | 0.250 | 1.000 | 0.583 |
| floor 0.30 + terms ≥ 3 + margin 0.02 | 0.833 | 0.667 | 0.083 |

Recall@4 is measured *after* the gate, which is why it rises with the lexical criterion up to three
terms: dropping passages that share nothing with the question promotes the ones that do into the top
four. Above three terms the criterion starts cutting into the answer itself.

**The chosen default for `nl-word` is `(floor 0.30, no margin, minSharedTerms 3)`.** It beats the
shipped gate on both axes — recall@4 0.750 → 0.833, insufficiency recall 0.000 → 0.667 — for one
in-scope question in twelve refused. The plan's original target ("maximise recall@4 with
insufficiency recall ≥ 0.9") is only met at four terms, which costs a quarter of the recall and
refuses one in-scope question in six; the target was set before the shape of the curve was known,
and a technician mid-job is better served by rephrasing a question occasionally than by losing two
in five correct answers. `RetrievalEvidencePolicy.default(for:)` chooses by `modelId` prefix and
`FieldSessionService` adopts it from the store's embedder when the store is set, so both lookup
tools and the per-turn prompt block inherit it; a test that pins a floor still overrides by
assigning afterwards.

**What the default still lets through**, on this corpus: *"how do I replace the heat exchanger on a
Carrier 58MVB"*, *"how do I charge the refrigerant on the outdoor unit"*, *"how do I reset the
defrost board on a heat pump"*, *"how do I wire a Trane XR95 two stage thermostat"*. Every one asks
about a subject this furnace manual genuinely covers, on a machine it does not — the passages
returned really are about heat exchangers, and no lexical rule can tell that the question was about
somebody else's. Rejecting these needs the question's *subject equipment* compared against the
vault's, which is a different mechanism (the nameplate/model the session already knows) and is not
attempted here. The vault's prompt rules and the page citation on every passage are what carry it,
which is why both are validator-required.

**What it wrongly refuses**, on this corpus: *"which propane conversion kit does this furnace need"*
— which the retriever was already missing before the gate (no anchor page in its top four), so the
gate turned a wrong answer into an honest refusal. The example vault's printed check *"how long is
the pre-purge before ignition"* is refused too; the manual's own wording is "pre-purge period" and
"ignitor warm-up", and the question shares only two terms with anything retrieved.

**Re-measured, 2026-09-07, on a widened set (P3).** The `minSharedTerms 3` default has a
structural cost the first measurement could not see: [[LexicalSupport]] drops words under four
letters, so a spoken question with fewer than three content terms — *"pre-purge time"* has two —
can never meet a flat count of three, whatever the manual says. Short questions are the ones a
technician with their hands full actually asks, and the first set had none. Five short in-scope
questions (two or three content terms, the same subjects and so the same grep-verified anchor pages
as their long-form siblings) and four short out-of-scope ones were added, giving 17 in-scope and 16
out-of-scope. The variant measured against it: required shared terms =
`min(minSharedTerms, max(1, ceil(sharedFraction × queryTerms.count)))`, so the bar drops for a short
question and never rises for a long one.

Similarity on the widened set, top four passages per question — still overlapping completely, and
now over a wider range because a two-word question scores differently from a sentence:

| | min | median | max |
|---|---|---|---|
| in-scope (n=68) | 0.656 | 0.880 | 0.917 |
| out-of-scope (n=64) | 0.651 | 0.868 | 0.897 |

| variant | recall@4 | insufficiency recall | in-scope questions refused |
|---|---|---|---|
| floor 0.30 (shipped before P2) | 0.706 | 0.000 | 0.000 |
| floor 0.30 + margin 0.02 | 0.706 | 0.000 | 0.000 |
| floor 0.30 + margin 0.005 | 0.706 | 0.000 | 0.000 |
| floor 0.88 | 0.471 | 0.562 | 0.471 |
| floor 0.30 + terms ≥ 1 | 0.706 | 0.188 | 0.000 |
| floor 0.30 + terms ≥ 2 | 0.824 | 0.438 | 0.000 |
| floor 0.30 + terms ≥ 3 (the P2 default) | 0.765 | 0.750 | 0.176 |
| floor 0.30 + terms ≥ 4 | 0.412 | 1.000 | 0.353 |
| floor 0.30 + terms ≥ 5 | 0.176 | 1.000 | 0.706 |
| floor 0.30 + terms ≥ 3 + margin 0.02 | 0.706 | 0.750 | 0.235 |
| floor 0.30 + terms ≥ 3 + fraction 0.5 | 0.824 | 0.562 | 0.000 |
| floor 0.30 + terms ≥ 3 + fraction 0.6 | 0.882 | 0.688 | 0.000 |
| **floor 0.30 + terms ≥ 3 + fraction 0.75 (adopted)** | **0.824** | **0.750** | **0.118** |

**Adopted: `sharedFraction = 0.75` beside the count of 3.** The adoption rule set before the run was
"fewer in-scope refusals without lowering insufficiency recall below the P2 figure on the same set",
and only 0.75 meets it: insufficiency recall is unchanged at 0.750, in-scope refusals fall from 3 of
17 to 2, and recall@4 rises from 0.765 to 0.824. Fractions of 0.5 and 0.6 refuse nothing in scope but
give up insufficiency recall (0.562 and 0.688) — the wrong direction, since a refusal is a rephrase
and a confident wrong answer is not recoverable. That the fraction costs nothing on the out-of-scope
side is the point and not luck: a short *out-of-scope* question is asked for proportionally less too,
and still shares nothing at all with what came back. `RetrievalGateCalibrationTests` asserts both
halves of the rule against the flat-count row, so a future corpus that makes the scaling cost
something fails the test rather than passing quietly.

The two in-scope questions the adopted default still refuses are *"which propane conversion kit does
this furnace need"* (which the retriever was already missing before any gate — no anchor page in its
top four) and *"trap water amount"*, whose three terms ask for all three and whose page prints the
figure as "10 fl. oz. (300 ml) of water into the trap" without the word *amount*. The four
out-of-scope questions it still answers are unchanged, and unchanged in kind: every one asks about a
subject this manual covers, on a machine it does not.

**`nl-sentence` and `nl-contextual` are unmeasured** and deliberately left at today's gate (floor
0.30, no margin, no lexical criterion) rather than given a guessed value: their cosines span a
different range and the lexical criterion may be unnecessary once similarity separates. That
measurement needs one device run with the `com.apple.linguisticdata` asset present, and is recorded
here when taken.

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
- **P2 — measured gate (one PR).** ✅ 2026-09-07. `EmbeddingBenchmark` negatives +
  `insufficiencyRecall`, the relative-margin criterion (which the measurement then showed cannot
  refuse a query), [[LexicalSupport]] and the `minSharedTerms` criterion that can,
  `RetrievalEvidencePolicy.default(for:)` wired from the store's embedder, and
  `RetrievalGateCalibrationTests` — the instrument, skipped when the manuals are not checked out.
  The `nl-word` numbers are in §2. The `nl-sentence` / `nl-contextual` numbers still need one device
  run with the `com.apple.linguisticdata` asset present and are recorded in the Status line when
  taken. Shipped with the guide edits (§5, nameplate spellings and step 6) because the step-6
  wording depends on the measured behaviour; the Route C extractor note stays with P3.
- **P3 — extractor + example (small PR).** ✅ 2026-09-07. §4's script changes (a per-page warning
  when a page's own first line prints a page number that disagrees with the PDF's index, and a
  count of them in the closing summary), the hint fix (`kind` and a `title` suggestion derived from
  the file name, labelled as something to edit), a `--self-check` mode that runs the marker and hint
  rules over synthetic inputs and exits non-zero on a mismatch — the script has no test target — and
  the Route C note in the guide. Re-run for real on both Lennox PDFs: **0 numbering warnings on each**,
  and the output is byte-identical to the committed-locally documents apart from the hand-edited H1.
  Shipped with the measured `sharedFraction` follow-up to P2's gate (§2).

## Acceptance

- `ExampleVaultLennoxTests` asserts, not prints, that *"the display shows E223 on a heat call"*
  cites Service Manual page 20 or Installation Instructions page 47, and that every citation for
  the pair is either `Title, page N` or `Title, page N, §<a heading with two or more words>`.
- Against the Lennox pair with the measured default, *"what is the torque for the blower wheel set
  screw"* produces the insufficiency sentence on the `nl-word` backend headlessly, asserted in
  `ExampleVaultLennoxTests`; *"how do I replace the heat exchanger on a Carrier 58MVB"* does **not**,
  and cannot be made to by any similarity or lexical rule, because the passages it returns are
  genuinely about heat exchangers (§2). It stays a printed check with that explanation. The gate as
  a whole refuses 2 out of 3 out-of-scope questions and 1 in 12 in-scope ones on this backend
  (§2's table); the sentence-backend numbers need a device run and are not claimed.
- `DocumentChunkerTests` rejects `FIGURE 5`, `TABLE 22.`, `WARNING`, `7 - Inspect the condensate
  drain and trap for leaks and`, `1 AFUE 98.1% 98.1% 98.2%`, `C 24VAXC COMMON`, and accepts `5.3
  Safety Requirements`, `Chapter 12`, `SAFETY PROCEDURES`, `BOTTOM RETURN AIR`. (`Heating Sequence
  of Operation` was listed here as an accepted heading in error: it is mixed case and unnumbered, so
  no rule in §3 reaches it. P1 pinned it as a negative.)
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

## P1 findings (2026-09-07)

The ALL-CAPS heading rule, even after §3's tightening, still yields wiring-diagram and display
fragments: on the Lennox pair a citation can read `§BOTH SENSOR`, `§1- DATA LOW CONNECTION`,
`§PRESS TO RESET`, `§TEST B`. Every one satisfies the same lexical shape as a real heading like
`BOTTOM RETURN AIR` — two or more words, the letter share, no label prefix, no digits to speak of —
so no rule over the *text of the line* separates them. The next lever is structural rather than
lexical: position on the page, font size or weight from the extractor, or a per-manual list of
headings supplied at import. Both need information the chunker does not currently receive, so this
is deferred rather than attempted; the citations remain locatable (title and printed page are always
right) and only the optional `§section` is noise.
