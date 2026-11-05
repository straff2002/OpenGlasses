# Plan IV — Manual Retrieval Rounds (every change measured on a field manual pair and a code book)

**Status:** ✅ P0–P7 shipped (2026-10-17/18). Both measurements run as a process, on both
embedders; the device's evidence gate carries the lexical criterion; the newest edition answers and
an older one only when asked; chunks keep their line breaks and a clause-numbered document is
chunked at its clauses; Field Assist searches manuals with the contextual model by default;
`manual_lookup` asks for the book's own words and, where a manual has a back-of-book index, offers
what the index names; a clause-numbered document's answers carry six passages, prose four; inside
each ranking group the question's words are weighed by BM25F, a heading's words three times a
body word's (P7). Section titles in the embedded text and cross-reference following were measured
and shelved (P6); fusion, a rule-starts preference, a deeper pool and token max-sim were measured
and rejected (P7). After the rounds (2026-11-06), the sentence model's gate gained a full-match floor: a passage
that prints every word of a question of four or more content terms clears 0.10 rather than 0.30
(hit@4 147 → 154 of 331 over the Lennox and Plan KN keys, out-of-scope refusals unchanged; see
"After the rounds"). Phone runs owed for P4–P7 (listed in each); the table is under "Where the
rounds ended".
**Track:** Field Assist (B2B): every vault with manuals, and the regulations vertical in particular.
**Related:** Plans [ED](ED-vault-manual-retrieval.md) / [EJ](EJ-manual-retrieval-fidelity.md)
(manual retrieval and its evidence gate), [EK](EK-manual-structure-and-figures.md) (structure from
type), [P](P-chunk-citations.md) (page and section citations), [AM](embedding-quality-upgrade.md)
(the contextual embedder, default off), [IN](IN-verifiable-code-lookup.md) (P3 standards as a kind
and editions; P4 compare two editions), [HK](HK-controlled-document-revisions.md) (revisions and
`supersedes`), and the retrieval fix merged as
[#763](https://github.com/straff2002/OpenGlasses/pull/763) (page and common numbers aren't codes,
a lexical route, words-first ordering, a lookup miss that stops the search).
**Origin:** 2026-10-17. A tester's job on the Lennox furnace vault (the flame-sensor procedure that
was never retrieved) led to #763. The same day, a partner supplied two editions of an electrical
code book and a set of electrician exam sheets with the rule numbers written as answers, **for
testing only**. They were turned into a local answer key and a failure breakdown, measured against
the shipped retriever. The owner asked for the improvements to be generic, not specific to one code
book, and for every round to be checked against both measurements.

---

## How this plan was measured, and what is never shipped

Two measurements, run on the same retriever code the app ships (`VaultRetriever` over the
`DocumentStore` searches, the session's evidence gate), on both embedders: the device's sentence
model (`nl-sentence`) and the simulator's word-average fallback (`nl-word`).

- **Lennox calibration.** The 18 in-scope and 18 out-of-scope questions of
  `RetrievalGateCalibrationTests`, over the example vault's two manuals (present only on a
  developer's machine, as today). Recall@4 is a passage from an answering page among the four the
  model gets; insufficiency is an out-of-scope question correctly refused. This plan measures the
  production path (`retrieve(limit: 4)` through the shipped gate), which is slightly stricter than
  the calibration test's ranked-prefix method; the test's own numbers after #763 are recall@4
  0.889 and insufficiency 0.778 on `nl-word`.
- **Code-book answer key (local only).** 72 questions transcribed from the partner's exam sheets,
  each with the rule or table number the answer cites, over the code book's text. Hit@k is "a
  passage among the top k prints the expected rule or table". It is a sanity check, not a training
  set: no threshold here was tuned to it.

**Nothing from the code books, the exam sheets or the answer key is in this repository, in this
plan, in a fixture or in a log.** The publishers restrict copying, the copies are licensed to
individual users and were provided for testing only; every derived artefact was deleted when the
measurement was done. Only aggregate counts appear below. P0 describes how a developer rebuilds the
local eval from their own licensed copy.

## What happens today (`main` @ `2f2341756`, after #763)

| | Device (`nl-sentence`) | Simulator (`nl-word`) |
|---|---|---|
| Code book, newest edition only: hit@1 / hit@4 | 0.15 / 0.42 | 0.17 / 0.46 |
| Code book, both editions loaded (as the partner's vault is): hit@1 / hit@4 | 0.17 / 0.36 | 0.17 / 0.40 |
| Lennox: recall@4 / hit@1 | 0.56 / 7 of 18 | 0.89 / 13 of 18 |
| Lennox: out-of-scope refused | **0 of 18** | 14 of 18 |

"Device" is the device's embedding model, NaturalLanguage's English sentence model, run on a Mac
through the same retriever code. A phone run is owed (P0 makes it routine).

Two things stand out before any breakdown. Loading the older edition beside the newer one costs six
points of hit@4 on both embedders. And on the device, the evidence gate refuses nothing: the
sentence model's gate is the bare 0.30 floor, which EJ left "unmeasured, device run pending"
(`RetrievalEvidencePolicy.default(for:)`, `VaultRetriever.swift:639–646`).

### Why the code-book questions miss (newest edition only)

Each miss was put in the first class that fits, in this order: answer key (f), chunk boundary (c),
edition duplicates (d), ranking (b), recall (a). Multi-rule or calculation questions (e) are counted
as an overlay, because the one-rule test is the wrong test for them whatever the mechanism.

| Class | Device: count (% of 42 misses) | Simulator: count (% of 39) |
|---|---|---|
| (a) recall: the rule's own text is not in the top 30 candidates | 14 (33 %) | 13 (33 %) |
| (b) ranking: in the top 30, outranked | 20 (48 %) | 19 (49 %) |
| — own text at ranks 5–8 / 9–15 / 16–30 | 7 / 7 / 6 | 9 / 1 / 9 |
| (c) chunk boundary: the rule's continuation is in the top 4, without its number | 7 (17 %) | 6 (15 %) |
| (d) duplicates across editions crowding the top 4 | 0 (one edition) — 3 (7 %) with both | 0 — 3 (7 %) with both |
| (f) expected rule not printed in this edition | 1 (2 %) | 1 (3 %) |
| Overlay (e): question needs several rules or a calculation | 11 of the misses (17 such questions) | 9 of the misses |
| Overlay (f): answer-key doubt (handwriting, a teacher's correction) | 14 of the misses (27 such questions) | 14 of the misses |

What outranks the rule in the ranking misses is mostly other prose (70 of 80 top-four slots on the
device). Contents and index pages take 7 slots and number-dense tables take 3. With both editions
loaded, the other edition's copies take 24 of the slots (16 on the simulator).

**A mechanism found while classifying:** the code book prints each rule as its own line, the number
and a capitalised title, under a one-word group heading. The chunker joins sentences with a space
(`DocumentChunker.swift:118`), so the line break before the number is gone. `ClauseReference`
grades a clause as *starting* only after a line break or sentence punctuation
(`ClauseReference.swift:201–210`). A line such as "Wiring" followed by "12-345 Example title"
(a synthetic stand-in) reaches it as "Wiring 12-345 Example title" and grades as a citation.
Of the 57 expected rules the book prints as a heading, 16 (28 %) are never graded as starting
anywhere in it. So clause search can't lead with the rule's own text, and the chunk
that carries the rule's body (c) has nothing tying it to the number.

### What each lever does, on both measurements

| Lever | Code book hit@4 (device / sim) | Lennox recall@4 (device / sim), refused | Verdict |
|---|---|---|---|
| Baseline (#763, newest edition only) | 0.42 / 0.46 | 0.56 / 0.89, 0 / 14 of 18 | — |
| Newest edition only, against both loaded | +0.06 / +0.06 (from 0.36 / 0.40) | no effect (two manuals, not two editions) | **Adopt** (P2) |
| Dedupe near-identical passages across documents (both editions loaded) | +0.04 / +0.00 | no change | Subsumed by P2 |
| Clause-boundary chunking, only for clause-numbered documents | +0.04 / +0.04; hit@1 0.15→0.21 / 0.17→0.24 | no effect (not clause-numbered) | **Adopt** (P3) |
| The same split at *every* heading, all documents | — | +0.11 / **−0.06**, refused 14→13 on sim | Rejected: lowers Lennox |
| Lexical criterion in the device gate (the `nl-word` rule) | no change | no recall change; refused **0 → 15 of 18** | **Adopt** (P1) |
| Contextual embedder (`NLContextualEmbedding`, AM), against the sentence model | 0.47 (from 0.42); hit@1 0.24 (from 0.15) | **0.94** (from 0.56); with P1's gate 0.89, refused 14 of 18 | Measure on a phone, then adopt (P4) |
| Back-of-book index: question words → index entries → rules | alone 0.29 / 0.29; with the retriever, no gain | no index in these manuals | Not as a ranking source; as a hint (P5) |
| Model rewrites the question in the book's vocabulary (hand-written estimate) | 2 of 9 / 2 of 8 failed questions recovered | 6 of 8 / 1 of 2 recovered | Estimate only (P5) |
| A perfect reranker over the top 30 (upper bound) | ≤ 0.69 / ≤ 0.72 | — | Ceiling for P5 |

The index finds the rule for 7 (device) and 6 (simulator) questions the retriever missed, but
putting its passages into the four slots costs as many as it gains. The book's own index is better
used as a pointer the model can follow than as a passage.

## Verified starting point (`main` @ `2f2341756`)

- **Retrieval routes.** `VaultRetriever.retrieve` merges the embedding query, the exact-token
  search, the clause search and (since #763) the lexical route; groups are clause match, token hit,
  rest; within a group, shared content words lead and the score breaks ties
  (`VaultRetriever.swift`, `retrieve`). The per-turn block, `manual_lookup` and `equipment_lookup`
  all build it through `FieldSessionService.makeRetriever` (`FieldSessionService.swift:1576`).
- **The gate per backend.** `RetrievalEvidencePolicy.default(for:)` gives `nl-word` the measured
  lexical criterion and everything else the bare 0.30 floor (`VaultRetriever.swift:639–646`).
- **Documents have no edition.** `VaultDocument` has `file`, `title`, `kind` (free text,
  "informational"), `source`, `sourceUrl` (`VaultManifest.swift:150`). Two editions coexist only
  as two files with two titles. A vault's `prompt_rules` can tell the model to prefer one, but
  retrieval searches both, and their copies take slots before the model sees anything.
- **Chunking.** Sentences are packed to about 700 characters with a 100-character overlap and
  joined with a space (`DocumentChunker.swift:118`). A `## ` line sets the section but doesn't start
  a chunk. With no `## ` line at all, `detectHeading` guesses sections from numbered, chapter and
  all-caps shapes; it doesn't recognise `NN-NNN` rule numbers (IN P3a noted this).
- **Clause grading.** `ClauseReference.startsHere` needs a line start or sentence punctuation before
  the number (`ClauseReference.swift:201–210`).
- **The embedder.** `Embedder` prefers `NLContextualEmbedding` when
  `Config.contextualEmbeddingEnabled` is on (default **off**, `Config.swift:3892`) and its asset is
  present. Otherwise it uses the NLEmbedding sentence model, falling back to the word average.
  Stored vectors carry an `EmbeddingVersion`, so a model swap re-embeds lazily (AM).

## Decided

1. **The newest edition is the reference; an older edition answers only when asked.** This comes
   from the partner who supplied the code books and is not up for review here. When a vault holds
   the same document in more than one edition, retrieval searches the newest only. The older
   edition is searched, and labelled as such, only when the turn explicitly asks for it. That means
   it names the older edition's year or label ("the 2021 code"), says "the previous edition" or "the
   old code", or asks what changed or for a comparison ("what changed", "compare", "difference
   between editions"). IN P3 (the `edition` field) and IN P4 (`compare_editions`) are where editions
   become first-class; this plan supplies the default and the recognition, and IN P4 consumes them.

## Decisions proposed (owner to confirm)

2. **Every round is measured on both sets, and a lever that lowers either doesn't ship as stated.**
   Each phase's exit names the Lennox calibration (CI-skippable, as today) and the local code-book
   eval (a process, P0) on both embedders.
3. **Shape-specific levers detect their shape and otherwise do nothing.** Clause-boundary chunking
   needs a clause-numbered document, the edition default needs a document loaded in more than one
   edition, and an index hint needs a back-of-book index. A manual without that shape is untouched,
   so the Lennox numbers can't move for those phases, and the exit tests prove it.
4. **The device gate gets the lexical criterion now; the contextual embedder only after a device
   run.** The first is measured on the device's own model (simulated on a Mac with the same
   NaturalLanguage sentence model). The second changes every vector, so it waits for a run on a
   phone.

## Phases (one PR each), ordered by measured gain per effort

### P0 — The two measurements as a process

- `RetrievalGateCalibrationTests` gains a production-path column (`retrieve(limit: 4)` through the
  session's own retriever and gate) beside its ranked-prefix one, and prints the device-model
  numbers when it runs on a Mac or a phone with the sentence model. It still skips without the
  manuals.
- A local-only eval runner (an XCTest class that skips unless a developer points it at a folder):
  it reads the developer's own answer key (JSON lines: question, expected rule or table numbers,
  optional notes), imports the developer's own licensed copy into a temporary store, and prints
  hit@1, hit@4 and the (a)–(f) breakdown above. Nothing in it is content: the README says how to
  write an answer key from one's own study material, and the folder is gitignored like the
  manuals.
- **Exit:** both runs print on both embedders; with no manuals and no answer key, both skip cleanly
  in CI; the README describes the process without naming or quoting any book.

#### What shipped in P0 (2026-10-17)

- **One scoring core for every runner.** `OpenGlassesTests/RetrievalEval/RetrievalEvalCore.swift`
  reads a JSON-lines answer key (`rules`, `tables`, or `pages` per question, `outOfScope`, `multi`,
  `doubt`), runs it through a retriever, and reports hit@1, hit@4, refusals and the miss classes,
  which are expected label not printed, chunk boundary, duplicates, ranking (top 30) and recall.
  It prints counts only, never a question, a passage or a title, so a run's output can go into a
  plan or a PR. `RetrievalEval.retriever(over:policy:)` is the four shipped routes over one store.
  `LocalManualEvalTests` checks it ranks exactly as `FieldSessionService.makeRetriever` does.
- **The simulator runner.** `LocalManualEvalTests.testLocalVaultAgainstItsAnswerKey` imports a
  vault folder as a customer's is and asks through the session's own retriever. It runs only with
  `TEST_RUNNER_RETRIEVAL_EVAL_VAULT` and `TEST_RUNNER_RETRIEVAL_EVAL_ANSWER_KEY`, and skips
  otherwise. The class's other six tests are the core's own, on synthetic fixtures.
- **The Mac runner, on the device's model.** `Scripts/retrieval-eval/run.sh` compiles the app's
  real `DocumentStore`, chunker and retriever with the shared core and four no-op stubs, and runs
  them on NaturalLanguage's sentence model (`RETRIEVAL_EVAL_EMBEDDER=contextual` for P4). The index
  lives in a work folder the developer names, outside the repository. `README.md` there is the
  process: writing an answer key from one's own material, and what never goes in the repository.
- **The calibration test's production-path column.** `RetrievalGateCalibrationTests` prints recall@4,
  hit@1 and insufficiency for every gate variant with each question asked as a turn
  (`retrieve(limit: 4)`), plus the miss breakdown for the shipped gate. It also checks that the
  committed `examples/vaults/lennox-slp99/eval/calibration.jsonl` (the same sets in answer-key form,
  for the Mac runner) matches its own lists.
- **Baseline for the rounds** (main after #763; the device column is the Mac runner):

  | | Device (`nl-sentence`) | Simulator (`nl-word`) |
  |---|---|---|
  | Code book, newest edition only: hit@1 / hit@4 | 0.16 / 0.38 | 0.18 / 0.44 |
  | Code book, both editions: hit@1 / hit@4 | 0.21 / 0.37 | 0.22 / 0.41 |
  | Lennox: recall@4 / hit@1 / out-of-scope refused | 0.56 / 0.39 / 0 of 18 | 0.89 / 0.72 / 14 of 18 |

  The code-book answer key was transcribed again for this round. It has 68 scorable questions
  (18 multi-rule, 24 in doubt), against 72 in the breakdown above, so its numbers sit a few points
  off the breakdown's. Every later round is compared with this table, from the same key, not with
  the breakdown. Misses on the newest edition, device: ranking 24 (57 %), recall 14 (33 %), chunk
  boundary 4 (10 %). Simulator: ranking 22 (58 %), recall 11 (29 %), chunk boundary 5 (13 %).
- **Tests:** `LocalManualEvalTests` (7, one of them skipped unless pointed at a vault) and
  `RetrievalGateCalibrationTests` (3; the measurement and identity cases skip without the manuals,
  the answer-key check always runs).

### P1 — The device's evidence gate (one default, the largest measured change)

- `RetrievalEvidencePolicy.default(for:)` gives `nl-sentence` the lexical criterion `nl-word`
  already has (minimum shared terms 3, scaled by `sharedFraction` 0.75). The comment records the
  measurement in place of "unmeasured". It is first because it is a one-line default with the
  largest measured effect: the device answers out-of-scope questions from whatever it retrieved,
  every time.
- **Exit:** Lennox calibration on the sentence model: out-of-scope refused 0 → 15 of 18, recall@4
  unchanged (measured 0.56 → 0.56). Code-book eval on the device: hit@4 unchanged (measured 0.42 →
  0.42). Both sets on `nl-word` unchanged, since its gate is untouched.
  `RetrievalGateCalibrationTests` asserts the `nl-sentence` default refuses more than the floor
  alone, as it does for `nl-word`.

#### What shipped in P1 (2026-10-17)

- `RetrievalEvidencePolicy.default(for:)` gives `nl-sentence` the `nl-word` rule (three shared
  content terms, scaled 0.75 for short questions, floor 0.30). `nl-contextual` keeps the floor until
  P4's phone run. The policy comment carries the measurement.
- The eval core now counts **in-scope refusals** (a question the manuals answer, told they don't),
  and the calibration test's production-path column prints them beside recall, hit@1 and
  insufficiency, with a `default(for: nl-sentence)` row. The Mac runner takes
  `RETRIEVAL_EVAL_GATE` to measure a candidate gate.
- **Before → after**, same answer key and indexes as every later round:

  | | Device (`nl-sentence`) before | after | Simulator (`nl-word`) |
  |---|---|---|---|
  | Lennox recall@4 / hit@1 | 0.56 / 0.39 | 0.56 / 0.39 | 0.89 / 0.72 (unchanged by construction) |
  | Lennox out-of-scope refused | 0 of 18 | **15 of 18** | 14 of 18 |
  | Lennox in-scope refused | 0 of 18 | 6 of 18 | 1 of 18 |
  | Code book (newest edition) hit@1 / hit@4 | 0.19 / 0.37 | 0.19 / 0.37 | 0.25 / 0.47 |
  | Code book (both editions) hit@1 / hit@4 | 0.24 / 0.35 | 0.24 / 0.35 | — |
  | Code book in-scope refused | 0 of 68 | 2 of 68 | 0 of 68 |

  The P0 baseline table above came from an earlier transcription of the answer key. This one is
  the key kept for the rest of the rounds, so later rounds compare with this table.
- **The cost, stated:** in-scope refusals rise (0 → 6 of 18 on Lennox, 0 → 2 of 68 on the code
  book). Every one of them is a question whose four passages held no answering page before the
  change, since hit@4 doesn't move, so no answer was lost. Those questions now hear "the manuals do
  not cover this" instead of an answer built from the wrong pages, and that sentence is itself
  wrong for them: the manual does cover them, retrieval missed. Gentler settings were swept on both
  sets and buy refusals back only by answering out-of-scope questions again:

  | Gate (device) | Lennox out-of-scope refused | Lennox in-scope refused | Code book in-scope refused |
  |---|---|---|---|
  | floor only (before) | 0 of 18 | 0 | 0 |
  | 1 shared term | 6 | 1 | 0 |
  | 2 terms (fraction 0 or 0.5), or 3 at 0.5 | 8–9 | 3 | 1 |
  | 3 terms at 0.6 | 14 | 4 | 2 |
  | 3 terms at 0.75 (shipped, = `nl-word`) | 15 | 6 | 2 |

  Hit@1 and hit@4 are identical for every row on both sets. The plan's rule was shipped as
  specified. **Decided 2026-10-17 (owner):** keep 3 terms at 0.75, and reword the refusal so a miss
  is not presented as silence: `RetrievalEvidencePolicy.insufficientSentence` now tells the model to
  say it couldn't find the answer in the manuals — never that they don't cover it — and to ask for
  the model number or different words. P2–P4 attack the cause, the misses themselves.
- **Tests:** `VaultManualRetrievalTests` (the per-backend defaults; a synthetic sentence-model
  distribution where the floor answers an out-of-scope question and the new gate refuses it while
  a short in-scope question still leads with its passage), `RetrievalGateCalibrationTests` (the
  `nl-sentence` assertion when it runs on that model), `LocalManualEvalTests` (in-scope refusals
  in the output).

### P2 — The newest edition by default (decided rule 1)

- An edition is recognised from the manifest (`edition`, or HK's `supersedes`, when present).
  Failing that, two documents of the same `kind` whose titles differ only in a year or an edition
  label are taken as editions of one work. The newest is the default; nothing is recognised as an
  edition when neither applies.
- `makeRetriever` searches the default edition unless the turn asks for an older one (decided rule
  1's phrases, and the older edition's own year or label). Then both are searched, and the older
  edition's passages carry its label in the citation.
- **Exit:** a synthetic two-edition fixture answers from the newest, answers from the older one
  when asked by year, by "previous edition" and by "what changed", and labels it. Code-book eval
  with both editions loaded: hit@4 rises to at least the single-edition number on both embedders
  (measured: 0.36 → 0.42, 0.40 → 0.46). Lennox calibration unchanged (two manuals, not editions).

#### What shipped in P2 (2026-10-17)

- **Recognising editions.** `DocumentEditions` (pure) groups a vault's documents into works held in
  more than one edition. They share a `kind` and their titles match once the edition label is out.
  The label is the manifest's new optional `edition` field (`VaultDocument.edition`, the field Plan
  IN P3 names, added here as the minimal piece), else a year in the title. Every edition needs an
  order (a year, a number, or a revision letter), or the group isn't treated as editions. A vault
  with one edition of each document has no editions, and nothing changes for it. HK's `revision`
  and `supersedes` can feed the same type when they land.
- **What a turn asks for.** `EditionRequest.parse` returns `.newest` by default. It returns
  `.named` when the turn names an older edition's year or label, `.previous` for "previous
  edition", "old code", "last code" and their kin, and `.compare` for "what changed", "difference
  between", or "compare"/"versus" next to an edition word or label. Naming the newest edition asks
  for nothing extra.
- **All three paths.**
  - The per-turn block and `manual_lookup` search what the request allows. `makeRetriever` filters
    the vault's manual namespace only, so team learnings and photographed manuals are searched as
    before, and a `document` the model names is searched as named. `manual_lookup` reads the
    technician's own words as well as its query.
  - `manual_figure`'s page and caption choice (`ManualDocumentChoice`) opens the newest edition when
    a page is in two editions of one work and nothing names one.
  - `show_source` and the citation chips resolve a citation by its document title, so an answer
    that cited the older edition still opens it.
- **What the model is told.** On the default, a line says which edition answered and that the
  older one is loaded and used only when asked. When a turn reaches past it, each passage is marked
  `(edition: 2021)` before its text, and the `Source:` line stays the document's title so the
  citation still opens. A comparison is told to answer only from the passages, name the edition
  beside each point, and say it couldn't find something in one edition rather than that nothing
  changed. That last part is the ground IN P4's `compare_editions` builds on.
- **Measured** (stable answer key; the "before" both-editions vault is the same two books under
  titles that carry no year, so no edition is recognised):

  | | Device (`nl-sentence`) | Simulator (`nl-word`) |
  |---|---|---|
  | Code book, both editions loaded: hit@1 / hit@4, before → after | 0.24 / 0.35 → **0.19 / 0.37** | 0.25 / 0.43 → **0.25 / 0.47** |
  | Code book, newest edition only (target) | 0.19 / 0.37 | 0.25 / 0.47 |
  | Code book in-scope refused, both editions | 2 → 2 | 0 → 0 |
  | Lennox recall@4 / hit@1 / refused out-of-scope / in-scope | 0.56 / 0.39 / 15 / 6 (unchanged) | 0.89 / 0.72 / 14 / 1 (unchanged) |

  With both editions loaded, the numbers now equal the newest-only ones on both embedders. hit@4
  rises on both. hit@1 on the device falls from 0.24 to 0.19: three questions were answered first by
  the older edition's copy of the rule. Those are now answered from the newest edition, which ranks
  them lower, so the remaining gap is P3's, not P2's.
- **Tests:** `DocumentEditionsTests` (8). They cover recognition by year, by the manifest's field
  and not across kinds, a single-edition vault being unchanged, the turn table, the searchable
  titles per request, and through a session:
  - the per-turn block on the default, a named year and a comparison;
  - `manual_lookup` reading the technician's words, plus an explicit `document`;
  - a page in both editions opening in the newest, or in the older edition when it's named;
  - an older-edition citation still resolving.

  `LocalManualEvalTests` and the Mac runner apply the same default per question.

### P3 — A rule starts where the book starts it (clause-numbered documents)

- The chunker keeps the line break between sentences that a line break separated, instead of a
  space, so `ClauseReference` can see a rule printed at the start of a line. This is generic, and is
  measured on both sets before anything else in this phase.
- **Shape detection:** a document is clause-numbered when enough of its lines are a clause number
  followed by a capitalised title (`NN-NNN`, `3.9.4.2`, `110.26`), using `ClauseReference`'s own
  recognition. Only then does each such line become a section heading that starts a new chunk, with
  no overlap carried across it. The rule is the chunk's section, so a citation names it (IN P3's
  clause-aware chunking, measured here). Re-chunking goes through IN P0's location migration (a
  text change re-chunks under the same document id).
- Splitting at every heading in every manual was measured and rejected: it lifted Lennox on the
  device but lowered it on the simulator (0.89 → 0.83, one fewer refusal).
- **Exit:** synthetic fixtures: a clause-numbered page whose rules start after a one-word group
  heading grades `.starts`, chunks one rule per chunk and cites it; a manual with numbered
  procedure steps ("1. Ignitor") is *not* detected as clause-numbered and chunks exactly as before.
  Code-book eval: hit@4 +0.04 and hit@1 +0.06 or better on both embedders (measured 0.42 → 0.46 and
  0.15 → 0.21 on the device; 0.46 → 0.50 and 0.17 → 0.24 on the simulator). The line-break join on
  its own lowers neither set on either embedder. Lennox calibration unchanged on both embedders.

#### What shipped in P3 (2026-10-18)

- **Line breaks kept.** `DocumentChunker` now joins two sentences with a line break when a line
  break separated them in the source, and with a space otherwise (`keepsLineBreaks`, on). The
  separator is still one character, so the sentence offsets IN P0 stores, and `PassageLocator`,
  read exactly as before.
- **Clause-numbered documents.** `DocumentChunker.clauseHeadingLines` counts lines that are a
  number with at least two parts followed by a capitalised word, on a short line of their own,
  counting each number once. A document with at least `minimumClauseHeadings` (10) is
  clause-numbered. Each such line becomes a `## ` section, and a chunk starts at it with no
  overlap carried in (`chunksAtClauseHeadings`, on). The measured code book prints about 1,400
  such lines; the Lennox manuals print none, because their numbered steps have one part, so
  nothing changes for them.
- **Self-contained.** It all lives in the chunker, with no new reference to another type (the
  manual contracts compile it on its own). Every route that chunks gets it: import, the
  photographed-manual pages, and IN P0's migration.
- **Existing stores.** `DocumentStore.locationVersion` 1 → 2. `PassageLocationMigration`
  re-chunks a stored vault document under its own id when its text now chunks differently, which
  re-embeds it once at launch, and only rewrites positions when it chunks the same. Document ids,
  page labels and evidence keep their keys. A manual read by recognition is left alone, as before.
- **Measured** (stable answer key, before → after):

  | | Device (`nl-sentence`) | Simulator (`nl-word`) |
  |---|---|---|
  | Code book, newest edition: hit@1 / hit@4 | 0.19 / 0.37 → **0.26 / 0.44** | 0.25 / 0.47 → **0.32 / 0.53** |
  | Code book, both editions loaded: hit@1 / hit@4 | 0.19 / 0.37 → **0.26 / 0.44** | 0.25 / 0.47 → **0.32 / 0.53** |
  | Chunk-boundary misses, newest edition | 5 → 2 | 4 → 2 |
  | Expected rules printed as a heading but never graded as starting (of 63) | 22 → 4 | 22 → 4 |
  | Code book in-scope refused | 2 → 2 | 0 → 0 |
  | Lennox recall@4 / hit@1 / refused out-of-scope / in-scope | 0.56 / 0.39 / 15 / 6, unchanged | 0.89 / 0.72 / 14 / 1, unchanged |

  Line breaks alone leave every hit count unchanged on both sets and both embedders. They take
  "never graded as starting" from 22 to 4, which is what lets clause search lead with a rule's own
  text. The clause-boundary chunking is what moves the hits. With both editions loaded, the
  older edition takes "never starting" to 2. What's left of the code-book misses is now mostly
  ranking (20–27) and recall (8–9), which is P4's and P5's ground.
- **Tests:** `ClauseChunkingTests` (7, invented fixtures):
  - a line break surviving so a rule after a group heading grades `.starts` (and `.cites` without
    it);
  - sentences on one line staying joined by a space;
  - sentence offsets still landing on their sentences;
  - a 12-clause document chunked one clause per chunk and citing each;
  - a prose manual with numbered steps, decimals and a few numbered sections chunking exactly as
    before;
  - fewer headings than the threshold leaving a document alone;
  - a repeated heading counting once.

  `ExampleVaultLennoxTests` now compares a passage with its page's stored text word for word,
  because the page text is rebuilt from words joined by spaces. Both runners take
  `RETRIEVAL_EVAL_CHUNKER` to index with the earlier behaviour, and the eval prints the "never
  graded as starting" count.

### P4 — The contextual embedder, measured on a phone

- Run P0's two measurements on a device with `contextualEmbeddingEnabled` on, against the sentence
  model. Measured on a Mac with the same framework: code-book hit@4 0.47 against 0.42 (hit@1 0.24
  against 0.15), Lennox recall@4 0.94 against 0.56, and 0.89 with 14 of 18 refused under P1's
  gate. If the phone agrees on both sets, the default flips to on, the `nl-contextual` gate
  is calibrated the way P1 calibrated the sentence model, and the asset download (AM) is surfaced
  in vault setup.
- **Exit:** device numbers for both sets on both models recorded in this plan; the default flips
  only if neither set drops; the gate for `nl-contextual` refuses at least what P1's does.

#### What shipped in P4 (2026-10-18)

**Owner decisions:** the contextual model is **on by default for Field Assist only**, meaning the
vault manuals, and every other embedding user keeps its model. A visible switch, "Smarter manual
search", in Settings › Field Assist turns it off. The release notes flag the one-time re-index and
the possible model download.

- **One model per index.** Vault manuals (the `vault:` namespaces) are indexed with
  `Embedder.fieldAssist()`: the contextual model while the switch is on (the default,
  `Config.fieldAssistContextualSearchEnabled`) and its asset is on the device, the standard model
  otherwise. Every chunk keeps its `EmbeddingVersion`. A vault question is embedded with the model
  of the chunk it is compared with, never another, and a vault chunk is never re-embedded inline
  during a search. Personal documents, memory and learnings keep the store's embedder, and the
  app-wide re-index leaves vault chunks alone.
- **Fallback.** Without the asset (offline, a failed request) a vault indexes and answers with the
  standard model and stays searchable. `VaultEmbeddingUpgrade` asks for the asset and re-indexes
  once it arrives. The same path runs when the switch changes either way.
- **Resumable, and the old index answers until the new one is whole.** New vectors go into a
  pending column chunk by chunk; when every chunk of a vault has one, they swap in one transaction.
  A run stopped by the app leaving, the switch changing or a newer run keeps what it built, and
  the next embeds only what is missing. A manual imported mid-way joins the index that answers and
  is picked up by the next pass. Progress shows through `VaultIndexingMonitor`, where every other
  index shows. Each vault runs under its operation lock, after IN P0's location migration.
- **Input length.** The contextual model reads at most 256 tokens and drops the rest silently.
  After P3, the longest chunks are about 700 characters, and of the 200 longest a sixth reached the
  limit (32 in the code book, 39 in the Lennox service manual). A text the model would cut is now
  split at a sentence (else a word) and the pieces' token vectors pooled, so nothing is lost
  (`ContextualInput`).
- **The gate follows the serving model.** The session picks a vault's gate by the model its
  manuals are indexed with now (`retrievalPolicy(forVault:)`), so it changes the moment the
  re-index swaps in. `nl-contextual` is calibrated: three shared terms, scaled 0.6.
- **Timing in support reports.** For a vault manual's indexing and for each question embedded for
  a vault search, the log records chunk counts, model family and milliseconds, never a title or a
  question. A completed re-index logs its chunk count and duration.
- **Measured** (the device's framework models on a Mac, stable answer key, P3's chunker):

  | | Sentence model (shipped before) | Contextual model (now the default) |
  |---|---|---|
  | Code book, newest edition: hit@1 / hit@4 | 0.26 / 0.44 | **0.32 / 0.53** |
  | Code book, both editions: hit@1 / hit@4 | 0.26 / 0.44 | **0.32 / 0.53** |
  | Code book in-scope refused | 2 of 68 | 0 of 68 |
  | Lennox recall@4 / hit@1 | 0.56 / 0.39 | **0.94 / 0.67** |
  | Lennox refused, out-of-scope / in-scope | 15 / 6 of 18 | 12 / 0 of 18 |

  The simulator's tests don't set Field Assist's model, so they run on the store's own embedder.
  This round that came back as the sentence model, and it gave exactly the sentence column (Lennox
  0.56 / 0.39 with 15 / 6 refused, code book 0.26 / 0.44). In earlier rounds the simulator had only
  the word model.

  **The gate sweep** on the contextual model (hit@4 identical on the code book in every row):

  | Gate | Lennox out-of-scope refused | Lennox in-scope refused | Lennox recall@4 | Code book in-scope refused |
  |---|---|---|---|---|
  | floor only | 0 | 0 | 0.94 | 0 |
  | 1 term | 2 | 0 | 0.94 | 0 |
  | 2 terms (fraction 0 / 0.5) | 5 / 4 | 0 | 0.94 | 0 |
  | 3 terms at 0.5 | 7 | 0 | 0.94 | 0 |
  | **3 terms at 0.6 (shipped)** | **12** | **0** | **0.94** | **0** |
  | 3 terms at 0.75 (the other models' rule) | 14 | 1 | 0.89 | 0 |

  **Exit, honestly:** the plan asked for a gate refusing at least what P1's does (15 of 18). No
  setting does on this model without costing answers. 0.75 refuses 14 and loses one in-scope
  answer, so 0.6 was chosen: 12 refused, none of the in-scope questions refused. The owner can
  move it to 0.75 with one line.
- **Owed on a phone:**
  - the asset download on first use;
  - real indexing and re-index times for a code book (the support report now shows them);
  - a backgrounded re-index resuming;
  - the switch;
  - both sets measured with the contextual model on the device.
- **Tests:** `VaultEmbeddingUpgradeTests` (9, with two invented models standing in for the
  standard and contextual ones):
  - a vault searched with the model that built its index whatever the target;
  - a re-index interrupted after one chunk that leaves the old index answering, then resumes,
    embeds only what's missing and swaps in whole;
  - a manual imported mid-way joining the answering index;
  - personal documents untouched;
  - the orchestrator's progress and its no-op once current;
  - the fallback without the contextual model;
  - the gate following the serving model;
  - log lines with durations and no text;
  - the input split.

  `VaultManualRetrievalTests` covers the calibrated default.

### P5 — Helping the model search the book's way (estimates, measured last)

- What is left after P1–P4 is mostly ranking (the rule's text in the top 30, outranked) and
  vocabulary (the question asked in everyday words, the book written in its own). Hand-written
  rewrites into the book's vocabulary recovered 2 of 9 failed code-book questions and 6 of 8 failed
  Lennox questions on the device. A perfect reranker over the top 30 would reach at most 0.69 on
  the code book. These are estimates, so this phase starts by measuring.
- `manual_lookup`'s description asks the model to search in the document's own terms (the name of
  the part, the procedure, the table), and after a miss to try the book's word once, not a
  rephrasing. #763's miss guidance stays.
- **Index hint, for documents that have a back-of-book index** (detected: a trailing section whose
  lines are terms followed by clause or page references). `manual_lookup` appends one line naming
  the index's rules for the question's words. It takes no passage slot, and the model can follow it
  with a clause lookup, which IN P3a already serves. A document without an index gets no line.
- **Exit:** both sets measured with the model in the loop on a device (a scripted run of the
  failed questions through `manual_lookup`), and the phase ships only the parts that moved either
  set without lowering the other.

#### What shipped in P5 (2026-10-18)

**Search in the book's vocabulary.**

- `manual_lookup`'s description asks for the query in the manual's own words (the part, procedure,
  table or rule as the book names it) rather than the technician's phrasing, and says that index
  references or nearest headings in a result are the words to search with.
- **On a first miss, the nearest headings.** When a lookup finds nothing it would answer from, the
  result adds the headings of the three nearest sections. They come from the same search without
  the gate, so there is no new network call and no extra model call. #763's guidance is unchanged:
  the miss still says not to rephrase. The headings appear on the first miss of a turn only, so
  the one retry is guided and a second miss gets the "stop searching" line alone.

**Index hint, only where a manual has one.**

- `BackOfBookIndex` detects a document's own subject index. Detection needs an "Index" heading in
  the last 40 % of the text, followed by at least 30 lines that end in clause numbers (two or more
  parts) or "Table N" / "Section N" references. It reads sub-entries under a heading (the heading's
  words carry over) and references carried onto the next line. A manual without an index gets
  nothing. That was checked on both Lennox manuals, raw and as stored chunks. An index was found
  in both code-book editions.
- `manual_lookup` adds one line naming the rules and tables the index gives for the lookup's
  words, leaving out any the passages already carry. The line takes no passage slot and changes no
  ranking, and the model can follow it with a clause lookup (IN P3a).
- **Fetching the index's clauses as extra candidates was built and measured, and moved nothing.**
  With the route on and off, hit@1, hit@4, refusals and the miss breakdown were identical on both
  sets and both models. It was removed, and the index stays a hint.
- **No third re-index.** The index is not stored. It is parsed from the document's stored chunk
  text the first time a lookup needs it: P3's chunks keep line breaks, and P3's location version
  has already re-chunked every stored document. It is then kept in memory per document, and
  re-read if the chunk count changes. Nothing new is written, so no copy of a publisher's index
  exists outside its own stored text. Parsing a code book takes 36–66 ms on a Mac and a query
  under 1 ms.
- The plan asked for detection at import and storage. Reading the stored text at search time gives
  the same answer for every vault already indexed, and costs no version bump.

**Measured** (Mac runner, the device's framework models, stable answer key, P3's chunker).
Retrieval with P5 equals P4 on both models, because nothing P5 shipped enters the ranking:

| | Sentence model | Contextual model (default) |
|---|---|---|
| Code book, newest and both editions: hit@1 / hit@4 | 0.26 / 0.44 | 0.32 / 0.53 |
| Code book in-scope refused | 2 of 68 | 0 of 68 |
| Code book misses: ranking / recall / chunk boundary / not printed | 27 / 8 / 2 / 1 | 19 / 11 / 1 / 1 |
| Lennox recall@4 / hit@1 | 0.56 / 0.39 | 0.94 / 0.67 |
| Lennox refused, out-of-scope / in-scope | 15 / 6 of 18 | 12 / 0 of 18 |

**Model-in-the-loop, estimates only.** The harness can't run the model, so each miss was retried
once automatically as if the model had followed the hint (`RETRIEVAL_EVAL_RETRY=index|headings`).
"Index" looks up the rules the index names. "Headings" searches the nearest three sections'
headings. A retry counts when its top four hold the answer:

| Estimate: misses one guided retry finds | Sentence model | Contextual model |
|---|---|---|
| Code book, index references | 5 of 38 | 3 of 32 |
| Code book, nearest headings | 9 of 38 | 4 of 32 |
| Lennox, index references | 0 of 8 (no index: no line) | 0 of 1 |
| Lennox, nearest headings | 4 of 8 | 0 of 1 |

These are upper bounds on what a perfectly obedient model gains from one retry. They are not
measured answers. Lennox didn't drop and in-scope refusals didn't rise, because the ranking is
untouched.

- **Owed on a phone:**
  - whether the model writes its queries in the book's words and follows an index line or a
    heading on its one retry (a scripted run of the failed questions through `manual_lookup`,
    the plan's exit);
  - the first-lookup cost of reading a large book's stored text for its index;
  - that a second miss in a turn still stops.
- **Tests:**
  - `BackOfBookIndexTests` (7, all invented):
    - an index found and ranked;
    - a sub-entry carrying its heading's words;
    - a carried-over references line;
    - words the index lacks getting nothing;
    - a contents-page "Index" line with no index behind it;
    - a short list under an "Index" heading;
    - a prose service manual's steps and readings.
  - `VaultManualRetrievalTests` (+3):
    - a miss in a manual with an invented index offering its reference and then the headings,
      with no headings on the second miss;
    - a manual without an index getting no index line;
    - the description.

### P6 — More passages where a passage is one clause

- After P3 a clause-numbered document is chunked at each clause, so one passage is one rule, and a
  measurement pass after P5 found the answer was often the fifth or sixth rule ranked. Six
  passages instead of four: code book 0.53 → 0.57 on the contextual model, 0.44 → 0.50 on the
  sentence model. Eight added only 0.02 more on the contextual model for another ~1,200
  characters. Prose manuals stay at four.
- **Exit:** both sets on both models, the gate, the edition default, citations and P5's hints
  unchanged, the passage budget holding, Lennox unchanged.

#### What shipped in P6 (2026-10-18)

- **Six passages when the best passage is from a clause-numbered document, four otherwise**
  (`ManualPassageLimit`). It covers the per-turn manual block and `manual_lookup`.
  - The retriever is asked for six only when a manual the retrieval may search is clause-numbered,
    so a vault of prose manuals retrieves exactly as before.
  - **A mixed vault is decided by the best passage:** six are kept when the first manual passage is
    from a clause-numbered document, and the outcome is cut to four otherwise. Learnings never
    decide it. A cut that would leave only team learnings gives its last slot to the best manual
    passage, so a sufficient outcome still carries the manual.
  - In a mixed vault the prose answer's four come from the larger candidate pool that six asks
    for. That is the one place the four can differ from before.
- **Derived, not stored, so no re-index.** `DocumentStore.isClauseNumbered(documentId:)` runs P3's
  detector (`DocumentChunker.isClauseNumbered`, now one rule both use) on the document's stored
  chunk text. That text keeps its line breaks since P3's re-chunk. The answer is held in memory
  per document and read again if the chunk count changes. Both Lennox manuals read as prose and
  the code book as clause-numbered.
- **Unchanged:**
  - the evidence gate decides each passage as before;
  - the edition default filters the documents searched before any of this;
  - citations and `show_source` read the passages sent;
  - P5's index line and nearest headings are computed as before.
- **The passage budget holds.** The turn block and the lookup result share a 12,000-character
  bound, which counts each passage's text, citation and a 256-character allowance. Six of the
  longest chunks the chunker makes (900 characters) with long citations come to about 7,800, and
  a test pins it. On the code book six passages average 3,500–3,700 characters.
- **The local eval measures what is sent.** Hit@1 and hit@4 stay on four passages so they compare
  across rounds. An "as sent" line adds the share of questions answered somewhere in what was
  sent, the passages and characters sent, and the refusals on that path
  (`RETRIEVAL_EVAL_PASSAGES=4` leaves it out).
- **Measured** (Mac runner, the device's framework models, stable answer key). Hit@4 is the four
  passages sent before P6; "as sent" is what P6 sends. Newest edition and both editions are
  identical, because the edition default searches the newest.

  | | Sentence: hit@4 → as sent | Contextual (default): hit@4 → as sent |
  |---|---|---|
  | Code book, all 68 | 0.44 → **0.50** | 0.53 → **0.57** |
  | Single rule, answer not in doubt (34) | 0.50 → **0.59** | 0.59 → **0.68** |
  | Multi-rule or calculation (20) | 0.45 → 0.45 | 0.50 → 0.50 |
  | Answer in doubt (23) | 0.35 → 0.39 | 0.43 → 0.43 |
  | Code book passages / characters per question | 4 / 2,352 → 5.6 / 3,510 | 4 / 2,491 → 5.9 / 3,692 |
  | Code book in-scope refused | 2 → 2 | 0 → 0 |
  | Lennox recall@4 → as sent | 0.56 → 0.56 (2.3 passages, 1,581 characters) | 0.94 → 0.94 (4.0 passages, 2,724 characters) |
  | Lennox refused, out-of-scope / in-scope | 15 / 6, unchanged | 12 / 0, unchanged |

  Before P3, four passages cost 2,488 characters on the same book. Six after P3 cost about 1.4×
  that, and eight would cost about 1.9×. The expectation that eight clause chunks cost what four
  older chunks did was checked and does not hold: the chunks retrieved are only about 5 % shorter.
- **Owed on a phone:** whether answers hold up with six passages in a code-book session, and the
  first lookup's cost of reading a large book's stored text for its shape (it runs once per
  document per launch).
- **Tests:**
  - `ManualPassageLimitTests` (8, all invented):
    - asking for six only where a clause-numbered manual can be searched;
    - six kept for a clause-numbered best passage;
    - a prose best passage cutting to four;
    - a leading team learning not deciding it;
    - a cut keeping a manual passage;
    - short and refused outcomes untouched;
    - six of the longest passages fitting the budget in both renderings;
    - the store reading the shape from stored text.
  - `VaultManualRetrievalTests` (+2): an invented clause-numbered manual sends six to the turn and
    to `manual_lookup`, and an invented prose manual still sends four.

#### Measured and shelved (2026-10-18)

The same pass measured two other levers on both sets and both models. Neither ships.

- **Section titles in the embedded text.** The document title and the chunk's heading were
  prepended to the text that is embedded (never the text shown), and the store re-indexed.
  - Code book, sentence model: 0.26 / 0.44 → 0.28 / 0.46, with in-scope refusals 2 → 1.
  - Code book, contextual model: 0.32 / 0.53 → 0.34 / 0.51, with single-rule questions
    0.59 → 0.56.
  - Six and eight passages were no better than without it.
  - On Lennox, applied to all documents, the sentence model dropped 0.56 → 0.50. Limited to
    clause-numbered documents it does nothing there.
  - About one question either way, for a full re-index.
- **Following cross-references.** When the top passages cite a rule they don't contain, that
  rule's own text was fetched as a candidate.
  - It fired on 44 (sentence) and 51 (contextual) of the 68 code-book questions, and on none from
    Lennox.
  - Hits were unchanged in every subset on both models, whether a rule was cited once or twice.
  - The fetched rule held the answer for 10 and 12 questions, every one already answered or
    already in the top 30. Eight of the 12 are removed by the gate's shared-words check.
  - Forcing the fetched rule into the fourth slot lowered hit@4: 0.44 → 0.41 and 0.53 → 0.50.

#### The next round's ground: ranking

The answer is in the ungated top 20 / top 30 for 0.69 / 0.87 of the code-book questions on the
sentence model and 0.68 / 0.82 on the contextual model, against 0.57 sent today. That is up to
0.11 for a perfect reordering of the top 20, and is an estimate. Ranking is 19 of the 32
contextual misses; recall (not in the top 30) is 11, which is P5's book-vocabulary hints, owed a
phone run with the model.

### P7 — Weigh the question's words inside each ranking group (BM25F, headings ×3)

- Since #763 the passages inside a ranking group are ordered by how many of the question's
  content words they share. A count weighs a word printed on most of a book's pages like the rare
  word that names the subject, and cannot tell the passage whose heading names the subject from
  one that mentions it in passing. Ranking was 19 of the 32 contextual misses after P6.
- **Exit:** the spoken-code and named-clause groups first, exactly as before; the order within
  groups only, at the shipped candidate depth; nothing lower on either set or model; refusals
  unchanged; no re-index, no schema change, no model call.

#### What shipped in P7 (2026-10-18)

- **BM25F replaces the shared-word count inside each group** (`VaultRetriever`,
  `LexicalSupport.TermStatistics`). Two fields: the chunk's text, and its section or clause
  heading weighted ×3. k1 1.2, b 0.75, the app's own content terms (`LexicalSupport.termCounts`,
  the counted form of `contentTerms`). Everything ahead of the words is unchanged: the groups, a
  named clause's offset, another model's rows (Plan EL), and the number of spoken codes matched.
  The score still breaks ties.
- **The statistics are derived, not stored.** `DocumentStore.termStatistics(namespaces:)` reads
  the searched namespaces' stored chunk text and headings once: document frequency per term, chunk
  count and total field lengths. It holds them in memory, as P6 does for `isClauseNumbered` and P5
  for the back-of-book index, and reads again only when a namespace's chunk count or text length
  changes. Totals rather than averages, so namespaces add. The session's factory passes the
  namespaces it searches (manuals, learnings, photographed manuals). The retriever asks once per
  retrieval and only when there are candidates and content terms. A retriever built without
  statistics ranks by the shared-word count, as before.
- **Not deepened.** The routes still return twice the passages sent. A 30-deep pool reordered the
  same way measured 0.03 lower as sent on the code book (contextual): the extra candidates are
  more often wrong than right.
- **Measured** (Mac runner, device models, the rebuilt answer key: 66 scorable code-book questions,
  42 single-rule, 24 multi-rule). Hit@1 / hit@4 on four passages; "as sent" is what P6 sends.
  Newest edition and both editions are identical.

  | | Sentence: P6 → P7 | Contextual (default): P6 → P7 |
  |---|---|---|
  | Code book hit@1 / hit@4 | 0.32 / 0.53 → **0.38 / 0.55** | 0.35 / 0.56 → **0.39 / 0.56** |
  | Code book as sent | 0.58 → 0.58 | 0.61 → 0.61 |
  | Single rule hit@1 | 0.43 → **0.48** | 0.45 → **0.52** |
  | Multi-rule hit@1 / hit@4 | 0.12 / 0.33 → 0.21 / 0.38 | 0.17 / 0.38, unchanged |
  | Code book characters sent per question | 3,629 → 3,576 | 3,696 → 3,568 |
  | Code book in-scope refused | 1 → 1 | 0 → 0 |
  | Lennox recall@4 / hit@1 | 0.56 / 0.39 → 0.56 / **0.56** | 0.94 / 0.67 → **1.00 / 0.83** |
  | Lennox refused, out-of-scope / in-scope | 15 / 6, unchanged | 12 / 0, unchanged |

  No subset is lower on either model. The cheaper variant without statistics (shared words plus
  half the heading's shared words) came close: code book hit@1 0.38 contextual and 0.33 sentence,
  Lennox 1.00 / 0.89 contextual and 0.56 / 0.50 sentence. BM25F is ahead on the code book on both
  models and on Lennox with the sentence model, one question behind on Lennox with the contextual
  model, for one in-memory table per namespace.
- **Owed on a phone:** the first retrieval's cost of reading a large book's stored text for its
  statistics (once per namespace per launch, the same read P6 makes for its shape), and whether
  answers in a code-book session lead with the rule asked about more often.
- **Tests:** `HeadingWeightedRankingTests` (9, all invented):
  - term counts agreeing with `contentTerms`;
  - statistics counting chunks rather than occurrences, and adding;
  - a rare shared word outweighing two on every page;
  - a heading word outweighing the same word in the body, and a zero weight switching it off;
  - the retriever: the heading that names the subject leading where a count ties, the rare word
    beating the count, and a spoken code still leading whatever the words weigh;
  - the store: per-namespace statistics, cached, merged, and moved by a manual added;
  - a clause-numbered book where the clause whose heading names the subject leads.

#### Round 8: measured and rejected (2026-10-18)

The same harness measured four other orderings at the shipped candidate depth. None ships.

- **Fusion** (reciprocal-rank fusion of the embedding rank with the word or BM25F rank, k 5–60):
  hit@1 fell or at best held: contextual code book 0.35 → 0.26, sentence code book 0.32 → 0.27,
  Lennox sentence 0.39 → 0.28, Lennox contextual 0.67 → 0.67. The embedding rank is the weaker
  signal inside these pools, and fusion gives it half the say.
- **A rule's starting passage ahead of the first passage that cites it:** no change on any set or
  model.
- **A deeper pool** (30 candidates, then reorder): as sent 0.61 → 0.58 on the contextual code
  book, with BM25F on it 0.58 / 0.38. Depth adds wrong candidates faster than right ones.
- **Token max-sim** (the contextual model's per-token vectors, late interaction): best on the code
  book when it breaks word ties (hit@1 0.42), but Lennox 0.67 against BM25F's 0.83, contextual
  only, and about half a second per question on a Mac to embed the question and 30 passages token
  by token. Not worth a model call per turn for a mixed result.
- **A language-model rerank** of the sent passages is the remaining lever. Its estimated ceiling
  over P7 is about +0.07 hit@1 on the code book. It costs a model call per turn and is left as a
  decision for the owner (open question 3).

## Where the rounds ended

Code book: hit@1 / hit@4 over the answer key's scorable questions. Lennox: recall@4 / hit@1, and
questions refused (out-of-scope / in-scope, each of 18). Device models on a Mac unless marked. P0's
row used the first answer key (68 scorable). From "before P1" on, every row uses the stable key.

| Round | Code book, newest (sentence) | Code book, both editions (sentence) | Lennox (sentence) | Code book (contextual) | Lennox (contextual) |
|---|---|---|---|---|---|
| P0 baseline, first key | 0.16 / 0.38 | 0.21 / 0.37 | 0.56 / 0.39, refused 0 / 0 | 0.24 / 0.47 ¹ | 0.94 ¹ (0.89, 14 refused, under P1's gate) |
| Before P1, stable key | 0.19 / 0.37 | 0.24 / 0.35 | 0.56 / 0.39, refused 0 / 0 | not run | not run |
| P1 lexical gate | 0.19 / 0.37, 2 refused | 0.24 / 0.35 | 0.56 / 0.39, refused 15 / 6 | not run | not run |
| P2 newest edition | 0.19 / 0.37 | 0.19 / 0.37 | unchanged | not run | not run |
| P3 clause chunking | 0.26 / 0.44 | 0.26 / 0.44 | unchanged | not run | not run |
| P4 contextual default | 0.26 / 0.44 | 0.26 / 0.44 | 0.56 / 0.39, refused 15 / 6 | **0.32 / 0.53**, 0 refused | **0.94 / 0.67, refused 12 / 0** |
| P5 book's words + index hint | 0.26 / 0.44 | 0.26 / 0.44 | 0.56 / 0.39, refused 15 / 6 | 0.32 / 0.53, 0 refused | 0.94 / 0.67, refused 12 / 0 |
| P6 six passages for clause-numbered documents | 0.26 / 0.44, **0.50 as sent** | 0.26 / 0.44, **0.50 as sent** | unchanged (four sent) | 0.32 / 0.53, **0.57 as sent** | unchanged (four sent) |
| P6, rebuilt key ² | 0.32 / 0.53, 0.58 as sent | 0.32 / 0.53, 0.58 as sent | 0.56 / 0.39, refused 15 / 6 | 0.35 / 0.56, 0.61 as sent | 0.94 / 0.67, refused 12 / 0 |
| P7 BM25F, headings ×3 ² | **0.38 / 0.55**, 0.58 as sent | **0.38 / 0.55**, 0.58 as sent | 0.56 / **0.56**, refused 15 / 6 | **0.39 / 0.56**, 0.61 as sent | **1.00 / 0.83**, refused 12 / 0 |

¹ From the failure breakdown that preceded P0, where the sentence model measured 0.15 / 0.42 on
the same set. The contextual model was not run again until P4.

² The answer key was rebuilt for round 8 (66 scorable questions), so P6 was measured again on it
and P7 is compared with that row, not the rows above.

The simulator's word model, for the record: code book newest 0.18 / 0.44 at P0, and 0.32 / 0.53
after P3. Lennox started at 0.89 / 0.72 with 14 of 18 refused. Over the rounds, the device's
default path went from 0.16 / 0.38 to 0.32 / 0.53 on the code book and from 0.56 to 0.94 on
Lennox. Out-of-scope refusals went from 0 to 12 of 18, and no in-scope question is refused. What
remains is mostly ranking (19 of 32 contextual misses) and recall (11). P5's estimates put one
guided retry at a few more of those, which only a phone run with the model can confirm.

From P6 on, a code-book answer carries six passages, so "as sent" is the share of questions
answered somewhere in what the model is given: 0.57 on the default path (single-rule questions
0.68), with hit@1 / hit@4 kept on four passages for comparison across rounds.

P7 moved the answering passage to the top, not into the set: on the rebuilt key, hit@1 0.35 →
0.39 on the default path (0.32 → 0.38 on the sentence model) with "as sent" unchanged, and Lennox
recall 0.94 → 1.00 with hit@1 0.67 → 0.83.

## After the rounds: the sentence model's full-match floor (2026-11-06)

The example vault's manual test found it (Plan KE, 2026-11-06). The simulator now runs the sentence model
(`nl-sentence`) rather than the word-average fallback, and a phone runs it too until the contextual model's
asset arrives. On this model, "high fire manifold pressure" was answered from the wrong pages. The passages
that print every word of the question scored 0.18–0.25 and were refused by the 0.30 floor. Passages on
another subject cleared it with three of the four words.

- **The change.** `RetrievalEvidencePolicy` gains `fullMatchFloor` and `fullMatchMinTerms`. A passage
  under the 0.30 floor is still evidence when the question has at least `fullMatchMinTerms` content terms,
  the passage shares every one of them under its own term rule, and its similarity is at least
  `fullMatchFloor`. `default(for:)` sets 0.10 and four terms for `nl-sentence` only. `nl-word` and
  `nl-contextual` are unchanged. The lexical criterion is untouched, and with it off the rule never runs.
  The Mac runner takes `RETRIEVAL_EVAL_FULL_MATCH="<floor>[,<terms>]"` or `off`.
- **Measured.** Mac runner, sentence model, the Lennox key and the nine Plan KN keys: 331 scored and 107
  out-of-scope questions over the same indexes as KN P0. The baseline reproduces KN P0 exactly.

  | Gate (sentence model) | hit@1 | hit@4 | as sent | in-scope refused | out-of-scope refused |
  |---|---|---|---|---|---|
  | 0.30 floor, 3 terms at 0.75 (before) | 103 | 147 | 155 | 67 | 74 of 107 |
  | **+ full match ≥ 0.10, four terms or more (shipped)** | **108** | **154** | **162** | **64** | **74 of 107** |
  | + full match ≥ 0.10, three terms or more | — | 162 | — | 56 | 72 |
  | + full match ≥ 0.15, three terms or more | — | 160 | — | 57 | 72 |
  | + full match ≥ 0.20, two terms or more | — | 162 | — | 53 | 72 |
  | + full match ≥ 0.15, two terms or more | — | 164 | — | 51 | 72 |
  | + full match ≥ 0.10, two terms or more | 120 | 169 | 177 | 46 | 72 |
  | + full match, any similarity, two terms or more | — | 170 | — | 45 | 72 |

  Per key, the shipped row against before (hit@4, in-scope refused): Lennox 10 → 12 and 6 → 5, network
  switch 8 → 9, dangerous-goods regulation 19 → 21, EU regulation 13 → 13 and 12 → 11, programming
  tutorial 8 → 10 and 23 → 22. Refrigerator, heat pump, drive and code book are unchanged. On
  Lennox both manifold-pressure questions (the short form and the sentence form) now reach an
  answering page. The out-of-scope refusals are unchanged on every key.
  `RetrievalGateCalibrationTests` in the simulator, which now runs the sentence model, gives the same
  Lennox numbers on the production path: recall@4 0.56 → 0.67, hit@1 0.56 → 0.61, insufficiency recall
  0.83 before and after, and in-scope refusals 6 → 5.
- **Why four terms.** A two- or three-term minimum finds more: up to 23 more hit@4 and 21 fewer in-scope
  refusals. But at every floor from 0.20 down to none, it answers the same two of the regulation's
  out-of-scope questions. Both are three-term questions, and both machine-written keys still owe a native
  check. They are answered from special provisions that mention the subject in passing, not from a rule
  that answers the question. Similarity does not separate those
  passages from the answering ones, but the question's length does. Four terms keeps every out-of-scope
  refusal. **Owner decision offered:** the two-term rule (the last measured row) trades those two refusals
  for 15 more hit@4 and 18 fewer in-scope refusals than the shipped rule.
- **Tests.** `VaultManualRetrievalTests` covers the per-backend defaults and a synthetic sentence-model case:
  a passage with every word answers under the floor, three of four words does not, a three-term question
  keeps the 0.30 floor, and the word model and an off lexical criterion are unchanged.
  `RetrievalGateCalibrationTests` adds the rule with and without the floor, and on the sentence model
  asserts that the shipped default refuses no fewer out-of-scope questions and recalls no fewer than the
  rule without it. `ExampleVaultLennoxTests`'s manifold anchor assertion is no longer an expected failure.
- **Owed.** A phone run on the sentence model (before the contextual asset arrives) with the example vault,
  and the contextual model measured with the same knob before it is offered there.

## Not in this plan

- Multi-rule and calculation questions (17 of 72 in the answer key). Answering them is IN P3's
  answer rules and the calculators it names, not retrieval.
- Answer-key doubt. The local eval prints it as its own class so that it isn't fixed by tuning.
- Shipping any code book, exam material or answer key, in any form (IN decision 6, EG, FS).
- A new embedding model or a dependency. P4 uses the framework model the app already has.

## Open questions for the owner

1. P2's edition recognition: is a title differing only in a year enough, or should a vault author
   always set `edition` (IN P3) before two editions can coexist?
2. P4: which phone, and with which vaults loaded, for the contextual run?
3. P7's round left one lever: a language-model rerank of the passages sent, estimated at about
   +0.07 hit@1 on the code book for a model call per turn. Worth it, and on which model?
