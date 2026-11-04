# Plan KN — A Learned Order for Manual Passages (the signals already measured, weighed by the answer keys)

**Status:** 📝 Drafted 2026-11-05 from the owner's question; nothing implemented. The question was whether a small
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
  30 of them out of scope. If the inventory falls short, write keys for the families the pilots use, in the
  existing format, as technicians would ask the questions. That is the work of this phase.
- Record today's numbers, per family and per embedder (`nl-word` in the simulator, `nl-sentence` and contextual
  on the Mac runner): hit@1, hit@4, as-sent, out-of-scope refused, and the ranking-miss share. These are the
  baseline P2 has to beat.
- Nothing ships. If the keys cannot be written, the plan stops here and says so, and the keys written so far
  still sharpen every later retrieval round.

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
- Measured twice: inside the groups (the default), and across them.
- **The bar to ship:**
  - hit@4 up on the pooled held-out questions;
  - no family's hit@4 lower by more than one question;
  - hit@1 not lower;
  - out-of-scope refusals not lower on any family.
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
- Tests:
  - golden scores for invented candidates;
  - fallback on a stamp mismatch;
  - the calibration set under `nl-word` not worse with the flag on;
  - the gate's out-of-scope refusals on the calibration set unchanged.

### P4 — the phone, then the default (device)

- Run the KE re-run questions and the KG symptom questions on a phone with the flag on and off, on the phone's
  extractor and the device's embedder.
- If the bar holds there, the default goes on in its own PR. The rules stay in the code as the fallback.

## Decisions for the owner

1. **May weights fitted from locally held answer keys be committed?** Recommended: yes. They are a few hundred
   numbers fitted on numbers, with no text, and the PR states its training sets by count and family number only.
   The keys themselves never leave the machine.
2. **Who writes the missing keys, and for which families?** Recommended: the families the current pilots use,
   written by the owner and the testers who have those manuals, about 25–40 questions each, with a quarter out
   of scope.
3. **The bar in P2.** Recommended as written: pooled hit@4 up, no family down by more than one question,
   out-of-scope refusals never down.
4. **Groups hard, or the learned score across them?** Recommended: hard, unless P2 shows crossing wins with no
   refusal lost.
5. **Weights per embedder, or one set?** Recommended: per embedder. The simulator's word-average model and the
   device models behave too differently for one set.
