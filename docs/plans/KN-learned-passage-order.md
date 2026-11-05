# Plan KN — A Learned Order for Manual Passages (the signals already measured, weighed by the answer keys)

**Status:** 📋 P0 run 2026-11-05 (local): the bar is met, 300 scored questions and 98 out of scope across 8 vaults and four manual types, with today's numbers on both Mac embedders; P1 next, nothing implemented. Drafted 2026-11-05 from the owner's question. The owner took all five decisions as recommended the same day. Revised the same day: the answer keys must span
manual types, P2 holds out a whole type, and P3 applies only to the types it measured. The question was whether a small
model should do part of the manuals work. The answer drafted here: one small model, for ranking only, and only
if it beats the rules on manuals it was not fitted on. The answer keys come before the model, and P0 decides
whether there are enough of them.
**Track:** Field Assist first (every vault with manuals), app-wide underneath: the retriever is shared.
**Related:** Plan [IV](IV-manual-retrieval-rounds.md) (the retrieval rounds, BM25F, the evidence gate), Plan
[KG](KG-symptoms-in-the-manuals-words.md) (symptom questions, the unit's documents), Plan
[KE](KE-symptom-diagnosis-and-vault-only.md) (the re-run), Plan [EL](EL-equipment-identity.md) (the model
penalty), Plan [JJ](JJ-table-lookup-and-rule-chains.md) (table rows), Plan
[JY](JY-multilingual-manual-search.md) (term rules per language), Plan [AM](embedding-quality-upgrade.md)
(the embedding backends).

---

## Why

`VaultRetriever.retrieve` finds candidates by meaning, by words, by code token, by clause and by table. It then
sorts them by a chain of comparisons:

1. the group (named table, clause, exact token);
2. inside a named table, rows before pages;
3. clause offset;
4. model penalty;
5. how many spoken codes matched;
6. BM25F;
7. the score.

Each step was added for a field report or a measured round, and each one is right where it was measured. Taken
together they are a hand-weighted ranking function whose weights are "always beats the next key". Nothing in
the chain can say that a passage strong on three signals should lead a passage that wins only on the first one
they differ on.

The miss classes the eval already prints show where this costs. A **ranking** miss means the answering passage
was gathered and then outranked, so better recall would not have helped and a better order would. On KG's symptom
questions on the phone's text, the right page was in the candidates far more often than it reached the top four.

A ranking function over a dozen signals that already exist is a small, well-understood learning problem. A model
for it is tens to a few hundred numbers. It runs on the CPU in microseconds, so it works while the phone is
locked, where an on-device language model does not. It is deterministic, and it can be tested headlessly. It never
reads a manual. It reads numbers about candidates the retriever has already gathered.

## What exists, and what doesn't

- **The measuring exists.** `Scripts/retrieval-eval` runs the app's own `DocumentStore`, `DocumentChunker` and
  `VaultRetriever` over a vault and an answer key. It prints hit@1, hit@4, the as-sent line and the miss
  classes, as counts only. `OpenGlassesTests/RetrievalEval/RetrievalEvalCore.swift` scores both it and the
  simulator test. The answer-key format (`pages`, `rules`, `tables`, `outOfScope`) is the labelling format this
  plan needs.
- **The answer keys are few.** One is committed: the example vault's calibration set, 36 questions over two
  manuals (`examples/vaults/lennox-slp99/eval/calibration.jsonl`). Others were written locally for earlier
  rounds: a refrigerator vault's symptom, out-of-scope and acceptance questions (KE, KG), and a code book's key
  (IV). They cover a handful of manual families in total. That is enough to measure a rule and too few to fit
  weights and still hold manuals out. **The data is the limit, not the model.**
- **The signals exist but are not collected anywhere.** `Passage` carries `similarity`, `score`,
  `matchedTokens`, `matchedModels`, `modelPenalty`, `kind`, `recognisedFromScan`, `tableMatch`, `clauseMatch`,
  `source`, `vectorPending` and `termRule`. `retrieve` computes the BM25F weight (`lexical`) and throws it away
  after the sort. Nothing writes a candidate's signals out with a label.
- **The gate reads the order.** `policy.decide(ranked, limit:question:)` judges the passages at the top, so a
  new order can change what is refused. Out-of-scope refusals have to be measured alongside hits.

## Principles

- **Order only.** The learned score never adds a candidate, removes one, or changes the gate's rules. Recall
  stays the routes' job, and refusal stays the gate's.
- **The hard tiers stay hard at first.** A named table, a clause and an exact code token are what the
  technician asked for by name, and they keep their groups. The learned score replaces the comparisons inside
  a group (steps 4–7 above). Letting it cross groups is a P2 measurement, not a default.
- **Numbers in, numbers out.** Features are numbers about a candidate. The export holds no question, passage,
  heading, document title or document id in clear, and the weights are numbers fitted from those numbers.
- **No manual is held out by accident.** Every figure this plan quotes is fitted on some manuals and measured on
  others it never saw (leave one manual family out). A score on the manuals it was fitted on means nothing for
  the next customer's vault.
- **The rules stay as the fallback.** An unknown embedder, a term rule never measured, a feature-schema mismatch
  or the flag off all fall back to today's order, exactly as it is.

## Rejected

- **A model of the manuals.** A model that stores a vault's content, or answers from it, does not carry over to
  the next customer's manuals. It would also have to be fitted on licensed text, and weights fitted on text can
  hold it.
- **An on-device cross-encoder or language-model reranker.** It would read every candidate's text against the
  question, at tens to hundreds of milliseconds per passage on Metal. Metal work does not run while the app is
  in the background, which is when the glasses are used. It is also opaque to review. If P2's small model is not
  enough, this is the next question, in its own plan.
- **Learning from the technician's taps on the phone.** It is per-device and unreviewed, and a citation tap is
  weak evidence. Team learnings (Plan FP) already carry what a person has checked.
- **Weights written without data.** Having a model write the weights from a description of the features is a
  cheap arm to try in P2. It does not replace the answer keys, which are the only way to know whether any
  weights are better.

## Phases

### P0 — enough answer keys, and today's numbers (local; owner and testers)

- Inventory every answer key that still exists locally: its family, its number of questions and its
  out-of-scope questions. Counts go in this plan; the keys stay where they are.
- Set the bar to start P2: **at least 150 scored questions across at least five manual families**, and at least
  30 of them out of scope. **The families must span at least three manual types**: service or diagnostic
  manuals, owner or install manuals, and code books or standards, each with at least 30 questions. Five
  families of one type would pass a count and say nothing about the next customer's manuals. IT, automotive
  and other trades join when a pilot has those manuals. If the inventory falls short, write keys for the families the pilots use, in the
  existing format, as technicians would ask the questions. That is the work of this phase.
- Give every keyed document a manual type from a small fixed set, written into the vault manifest's existing
  per-document `kind` (free text and informational today; see P3).
- Record today's numbers, per family, per manual type and per embedder (`nl-word` in the simulator, `nl-sentence` and contextual
  on the Mac runner): hit@1, hit@4, as-sent, out-of-scope refused, and the ranking-miss share. These are the
  baseline P2 has to beat.
- Nothing ships. If the keys cannot be written, the plan stops here and says so, and the keys written so far
  still sharpen every later retrieval round.

**P0 as run (2026-11-05).** Local; nothing ships. The keys, the manuals and the indexes stay on the Mac they were
written on, outside every repository.

- **Inventory.** Four English keys already existed: the example furnace pair (committed), a code book's, and
  three from the multilingual rounds (a dangerous-goods regulation, an EU regulation, a programming tutorial).
  They held one service family, with 18 answerable questions. Five keys were written for P0 and checked page by
  page against the PDF text:
  - a refrigerator vault's service and diagnostic questions (44 documents);
  - the same vault's owner, install and quick-start questions;
  - a heat-pump service manual (336 pages);
  - a network switch's installation guide (100 pages).

  The heat-pump and switch manuals are public downloads from the manufacturers' sites. A drive manual for the
  electrical trade was refused by its publisher's site to an automated download, and is still owed.
- **The bar is met.**
  - 300 scored questions and 98 out of scope, across 8 vaults (9 keys).
  - Manual types, scored questions:

    | Type | Scored | Keys |
    |---|---|---|
    | Service or diagnostic | 80 | refrigerator service, heat pump, the furnace pair (service and install, counted here) |
    | Owner or install | 53 | refrigerator owner, switch |
    | Code books and standards | 133 | code book, two regulations |
    | Software documentation | 34 | programming tutorial (a fourth type, not required) |

  - The type of each key is recorded with the keys. The manifests of vaults the app's authors don't own are not
    edited.
- **Today's numbers.** Sentence model (`nl-sentence`), Mac runner, shipped order and gate:

  | Key | Type | Scored | hit@1 | hit@4 | Out of scope refused | Misses that are ranking |
  |---|---|---|---|---|---|---|
  | Furnace pair (example vault) | service and install | 18 | 10 | 10 | 15 of 18 | 8 of 8 |
  | Refrigerator, service | service | 35 | 8 | 13 | 2 of 10 | 12 of 22 |
  | Refrigerator, owner | owner and install | 30 | 5 | 10 | 3 of 10 | 11 of 20 |
  | Heat pump | service | 27 | 9 | 17 | 4 of 8 | 7 of 10 |
  | Network switch | install | 23 | 7 | 8 | 6 of 7 | 13 of 15 |
  | Code book | code book | 66 | 24 | 35 | — | 22 of 31 |
  | Dangerous-goods regulation | standard | 34 | 14 | 19 | 10 of 15 | 14 of 15 |
  | EU regulation | standard | 33 | 9 | 13 | 14 of 15 | 16 of 20 |
  | Programming tutorial | software | 34 | 8 | 8 | 15 of 15 | 25 of 26 |
  | **All** | | **300** | **94** | **133** | **69 of 98** | **128 of 167** |

  Contextual model, same runner, order and gate:

  | Key | hit@1 | hit@4 | Out of scope refused | Misses that are ranking |
  |---|---|---|---|---|
  | Furnace pair | 14 | 18 | 12 of 18 | none missed |
  | Refrigerator, service | 10 | 19 | 2 of 10 | 9 of 16 |
  | Refrigerator, owner | 6 | 12 | 1 of 10 | 8 of 18 |
  | Heat pump | 7 | 14 | 3 of 8 | 8 of 13 |
  | Network switch | 10 | 13 | 5 of 7 | 9 of 10 |
  | Code book | 25 | 36 | — | 19 of 30 |
  | Dangerous-goods regulation | 23 | 27 | 8 of 15 | 4 of 7 |
  | EU regulation | 12 | 18 | 12 of 15 | 12 of 15 |
  | Programming tutorial | 23 | 27 | 12 of 15 | 5 of 7 |
  | **All** | **130** | **184** | **55 of 98** | **74 of 116** |

  The contextual model finds more (hit@4 133 → 184 of 300) and refuses less (69 → 55 of 98). The heat pump is the
  one key it does worse on (17 → 14). The two models disagree enough that P2's per-embedder weights (decision 5)
  look right. The simulator's `nl-word` baseline is not run yet; it is owed before P3's calibration test relies on it.

- **What the numbers say.**
  - **Ranking is the larger problem.** 77% of all misses on the sentence model and 64% on the contextual model are ranking misses: the answering passage was in the top
    30 candidates and outranked. That is the share P2 can win back. Recall (17% of misses overall, and up to 36%
    on the refrigerator vault) is not this plan's to fix.
  - **The gate on the refrigerator vault refuses almost nothing.** It turned away 5 of 20 out-of-scope questions,
    against 15 of 18 on the furnace pair. That is KG's finding 3 again, on a larger vault and a new key, and it
    stays the gate's problem, not P2's. P2's bar ("out-of-scope refusals not lower") starts from these numbers.
  - **The gate refuses answerable questions on prose-heavy documents.** 23 of the tutorial's 34 answerable
    questions and 12 of the EU regulation's are refused, though hit@4 is read with or without refusal. Worth its
    own look before P3, since a learned order changes what the gate reads.
- **Found on the way: multilingual owner manuals are read as other languages.** Of the refrigerator vault's 44
  documents, 4 were detected as French, Dutch or Polish and searched with those stemmers. The owner manuals
  print English, French and Spanish in one PDF. A Dutch or Polish reading is wrong either way. This belongs to
  Plan [JY](JY-multilingual-manual-search.md), and P3's "measured term rules only" would exclude those documents
  as it stands.

### P1 — the features, written out (headless)

- `RankingFeatures`, a pure value computed in `retrieve` from what it already holds. For each candidate:
  - the similarity's rank and gap to the best, within this question's candidates (raw similarity is flat across
    a manual and differs per embedder);
  - BM25F, and the shared-term count and fraction;
  - whether a heading holds a question term;
  - matched codes, matched models and the model penalty;
  - the passage kind (prose, table row, figure);
  - recognised from a scan;
  - the source (manual or team learning);
  - assigned to the unit (KG P4);
  - vector pending;
  - the passage's length;
  - the routes that found it, and how many.
- Built inside the retriever and passed out only on the eval path. With no export asked for, the app does
  nothing more than today.
- The runner writes one JSON line per candidate when `RETRIEVAL_EVAL_FEATURES=<path>` names a file outside the
  repository: the features, the label (holds the answer or not, from the key), a question number, the family's
  number and the embedder. No strings from the vault.
- Tests: features are identical across runs; the order is unchanged with the export on; and a guard test that
  the exported line for an invented manual contains none of its words.

### P2 — fit, hold out, compare (local, Mac)

- A script, not app code, fits three arms on the exported features:
  1. logistic regression;
  2. a small network (one hidden layer of at most 16);
  3. weights written by a model from the feature descriptions alone, with no data.
- Each arm is measured with one family left out at a time, against the P0 baseline and on the same candidates.
  **It is then measured again with one whole manual type left out at a time**, which is the harder test and the one
  that says whether the order carries over to a kind of manual it has never seen.
- Measured twice: inside the groups (the default), and across them.
- **The bar to ship:**
  - hit@4 up on the pooled held-out questions;
  - no family's hit@4 lower by more than one question;
  - hit@1 not lower;
  - out-of-scope refusals not lower on any family;
  - with a manual type held out, that type's hit@4 not lower by more than one question, and its out-of-scope
    refusals not lower. A type that fails keeps the rules (P3), and the others can still ship.
- This is measured per embedder; weights that pass on one embedder ship for that embedder only.
- The outcome is written into this plan either way. "The rules are as good as a fitted order" is a finding: it
  closes the question and P3 is not built.

### P3 — the learned order behind a flag (headless)

- `LearnedPassageOrder`: weights in source, stamped with the feature-schema version and the embedder id
  (`EmbeddingVersion`). A stamp that doesn't match falls back to the rules.
- Used only inside the groups, unless P2's cross-group run met the bar and the owner chose it.
- `Config` flag, **off by default**; the runner gets `RETRIEVAL_EVAL_ORDER=learned` so every later round can be
  read both ways.
- Applies only to term rules P2 measured (likely English first); every other language keeps the rules until a
  key in that language exists.
- Applies only to manual types P2 measured, read from each document's manifest `kind`, normalised to the fixed
  set. A group that holds a passage from a document of an unmeasured type, or with no `kind`, keeps the rules for
  that question. Imported documents without a `kind` (most of a personal library today) therefore keep the
  rules; whether import should guess a type is a later question, not this plan's.
- Tests:
  - golden scores for invented candidates;
  - fallback on a stamp mismatch;
  - fallback for a group holding a document of an unmeasured or missing type;
  - the calibration set under `nl-word` not worse with the flag on;
  - the gate's out-of-scope refusals on the calibration set unchanged.

### P4 — the phone, then the default (device)

- Run the KE re-run questions and the KG symptom questions on a phone with the flag on and off, on the phone's
  extractor and the device's embedder.
- If the bar holds there, the default goes on in its own PR. The rules stay in the code as the fallback.

## Decisions (all five taken as recommended, 2026-11-05)

1. **May weights fitted from locally held answer keys be committed?** **Taken as recommended:** yes. They are a few hundred
   numbers fitted on numbers, with no text, and the PR states its training sets by count and family number only.
   The keys themselves never leave the machine.
2. **Who writes the missing keys, and for which families?** **Taken as recommended:** the families the current pilots use,
   written by the owner and the testers who have those manuals, about 25–40 questions each, with a quarter out
   of scope.
3. **The bar in P2.** **Taken as recommended:** pooled hit@4 up, no family down by more than one question,
   out-of-scope refusals never down.
4. **Groups hard, or the learned score across them?** **Taken as recommended:** hard, unless P2 shows crossing wins with no
   refusal lost.
5. **Weights per embedder, or one set?** **Taken as recommended:** per embedder. The simulator's word-average model and the
   device models behave too differently for one set.
