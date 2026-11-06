# Plan KQ — A Model Trained to Search (manual passages embedded by a retrieval model, measured before it answers)

**Status:** 📝 Drafted 2026-11-07 from the owner's question: could a newer embedding model, or a learned
sparse model, do better than the ones manual search uses today? Nothing built. P0 and P1 run on the Mac
with no change to the app. The app changes only if P1 meets the bar below.

## Why

Field Assist searches manuals with Apple's contextual model (Plan [IV](IV-manual-retrieval-rounds.md) P4),
and with the standard sentence model until that model's asset is on the phone. Neither was trained to
search. `NLContextualBackend` averages the token vectors of a general-purpose language model. The sentence
model looks words up. Both give a usable signal. Neither was trained to put a question next to the passage
that answers it.

The rounds since IV have taken the rules around that signal a long way:
- the gate's lexical criterion and full-match floor;
- clause chunking and the edition rule;
- BM25F inside the ranking groups;
- the code lead (Plan [KO](KO-code-lead.md)).

What is left points at the signal itself:
- **Ranking.** Plan [KN](KN-learned-passage-order.md) P0 put 77% (sentence) and 64% (contextual) of misses
  in ranking: the answer is among the candidates but not among the passages sent. Inside the groups no
  fitted order beat the rules (KN P2). The similarity rank is the input the rules can't improve.
- **Recall.** On the code book, IV found the ungated top 20 holds the answer for 0.68 of questions, and a
  perfect reranker over the top 30 would reach at most 0.69 / 0.72. Past that, only a better first stage
  helps.
- **Scripts.** Plan [JY](JY-multilingual-manual-search.md) gives each script its own Apple model. A script with no
  model is searched by its words alone, and `NLEmbedding` has sentence models for four languages.

Today, with KO, on ten local answer keys: hit@4 180 (sentence) and 213 (contextual) of 331 scored
questions, as sent 187 and 224.

## The candidate

**EmbeddingGemma 2, text encoder only.** It was released on 2026-10-06 under Apache 2.0 with ungated weights,
and trained for retrieval. Per the launch coverage:
- the text encoder is about 270M parameters, and needs about 190 MB of RAM quantised;
- vectors can be cut short (768, 512, 256);
- a task prefix tells it whether it is reading a question or a document;
- it reads far more than the 256 tokens our contextual model does.

P0 checks each of these against the model card before anything depends on it. The model's image and audio
towers are not used.

## Hard constraints

These shape every phase. A design that breaks one is out, however well it scores.

1. **Never on the GPU.** A question is embedded while the phone is locked and the glasses are in use. iOS
   forbids Metal in the background, and MLX's failure there is an uncatchable abort that kills the app (see
   `LocalLLMService`'s guards). The model runs through Core ML with compute units pinned to the CPU, or
   CPU and Neural Engine. It never runs on MLX and never on `.all`.
2. **No fp16 unless measured safe.** The model card warns that float16 can give NaN or degraded vectors.
   The Neural Engine computes in fp16. The default is int8 weights with fp32 activations on the CPU. The
   Neural Engine is allowed only if P0 measures no NaN and vectors matching the fp32 reference (cosine
   ≥ 0.999) over the whole eval corpus.
3. **Question and document are told apart.** Today `EmbeddingBackend.embed(_:)` has one entry. The new
   backend needs the query prefix on a question and the document prefix on a passage. Getting this wrong
   costs quality silently, so it is a type, not a convention.
4. **Downloaded, not bundled.** The weights come down on first use through `ModelDownloader`, as Kokoro's
   and ASR's do: staged, verified, installed atomically. Until they are on the phone, today's models answer.
   The download goes to a host the privacy copy already discloses, or the copy changes in the same PR.
5. **Its own gate numbers.** `RetrievalEvidencePolicy.default(for:)` is measured per embedder. The new
   model's entry comes from P1's sweep. It never borrows the sentence or contextual numbers. A model with
   no measured entry never answers a vault.
6. **Rules unchanged.** The table, clause and token groups, the code lead, BM25F, the model penalty and
   candidate depth stay as they are. P1 re-measures the code lead on the new model, because KO chose its
   half on today's two.
7. **Keys stay local.** Licensed manuals, code books and answer keys never enter the repository, in any
   form. Runs print counts only.

## The bar (P1)

The model goes into the app only if, on the same ten keys with the shipped request and gate rules:
- **hit@4 at least 223 of 331**, 10 more than the contextual model's 213; as sent, at least 234;
- **no key's hit@4 lower by more than 1**;
- **in-scope refusals no higher, and out-of-scope refusals at least 57 of 107**, the contextual model's
  count, at the gate numbers chosen;
- **on the phone (P3):** a question embedded in under 150 ms on the CPU, and the largest held vault
  re-indexed within one overnight charge, resumably.

If it misses the bar, the plan ends at P1 with the numbers written down, and nothing changes in the app.

## Phases

### P0 — convert and check (Mac, headless)

- A conversion script under `Scripts/` that turns the text encoder into a Core ML package with int8 weights.
  Weights and packages live outside the repository.
- Check the card's figures against the converted model: parameters, context length, dimensions, prefixes,
  licence text.
- Parity against the reference fp32 encoder on a few hundred invented sentences: cosine ≥ 0.999 at each
  dimension kept.
- Re-run that check in fp16 on the Neural Engine. Count the NaNs and record the parity.
- Check that `swift-transformers`, already a dependency, tokenizes as the reference does, byte for byte, on
  the same sentences.

### P1 — measure on the keys (Mac runner)

- `RETRIEVAL_EVAL_EMBEDDER=eg2[:<dim>]` in `Scripts/retrieval-eval`, through the same `DocumentStore`,
  `DocumentChunker` and `VaultRetriever` the app uses.
- Sweep the gate numbers (`similarityFloor`, `fullMatchFloor`, `sharedFraction`) for the new model.
- Re-measure the code lead (`RETRIEVAL_EVAL_CODE_LEAD`).
- Measure 768 and 256 dimensions. Keep the smaller one if it is within 2 hit@4.
- Measure on the non-Latin keys from Plan JY where they are held, against each script's Apple model and
  against words alone.
- **Optional arm, learned sparse.** Run it only if a document-side sparse model under Apache 2.0 or MIT is
  found. It weighs passage terms at index time and needs no model at question time, so it would also be safe
  in the background. It is measured as a third score beside BM25F, not in its place. With no such model, the
  arm is skipped (see Rejected).
- Write it up the way KO did: per-key table, refusals, characters sent, and how far to trust it.

### P2 — in the app, behind a flag (headless)

- A query/document role on `EmbeddingBackend`. Today's backends ignore it.
- `CoreMLEmbeddingBackend` with compute units fixed at init per P0. A test fails if they include the GPU.
- A `DownloadableModelBundle` for the weights, with Field Assist's settings showing the size before the
  download.
- **The wearer chooses the model.** Settings › Field Assist's "Smarter manual search" switch becomes a
  choice of three, with the switch's current meaning kept for the first two:
  - **Standard**: the sentence model.
  - **Smarter**: Apple's contextual model, today's default.
  - **Search-trained**: the new model, with its size shown, downloaded when chosen.

  `Embedder.fieldAssist` reads the choice. Each option falls back down the list (new → contextual →
  standard) until its model is on the phone, so a choice never leaves a vault unsearchable. Changing the
  choice re-indexes each vault once, resumably, through `VaultEmbeddingUpgrade`, with the old index
  answering until the new one is whole. Vectors are stamped with their own `modelId`. No new mechanism.
  An organisation profile can pin the choice through a new profile key, added in the same PR. The current switch's
  stored value maps onto the first two options, so no install changes model on upgrade.
- `RetrievalEvidencePolicy.default(for:)` gains the P1 entry.
- Tests:
  - the role reaches the prefix;
  - a missing or partial download falls back with no re-index;
  - changing the choice re-indexes once, each way, and a choice whose model is missing falls back;
  - the old switch's stored value maps to Standard or Smarter;
  - the gate entry is picked by id;
  - a vault never answers on a model with no gate entry.
- Every other embedding user (`SemanticMemoryStore`, general documents, skills) stays on `Embedder()`.

### P3 — the phone (device)

- Question latency, peak memory and battery on the phone's CPU, and on the Neural Engine if P0 cleared it.
- Re-index time for the largest held vault, including one interrupted run that resumes.
- A question asked with the phone locked and the glasses in use: it answers, and nothing touches the GPU.
- Phone vectors against the Mac's on 50 passages: cosine ≥ 0.999.
- Plan KE's re-run questions and Plan KG's symptom questions on the phone's extractor.
- Then the default decision (open question 3).

## Rejected

- **SPLADE as published.** The best-known checkpoints are CC BY-NC-SA 4.0 or carry non-commercial licences.
  Avenkin is a paid app, so they can't ship. Learned sparse retrieval in general also overlaps what is
  already here. BM25F and the exact-token and spoken-code groups cover term matching. Its WordPiece
  vocabulary splits a code like a fault number into fragments, so the token tier would stay either way. The
  checkpoints found are English only. Its one distinct gain, learned term expansion (a symptom said one way
  matching a manual that says it another), is P1's optional arm, not a phase.
- **Running the model on MLX.** Metal in the background kills the app (constraint 1).
- **Bundling the weights.** Hundreds of megabytes in every install, for a feature only Field Assist uses.
- **The new model as a reranker only**, embedding the question and 30 candidates each turn while the index
  stays on today's model. That is 31 encodes per question on the CPU, which is too slow per turn. Embedding
  passages once at index time gets the same signal for one encode per question.
- **A language-model rerank.** That is IV's open question 3, a separate lever with a model call per turn.
  This plan doesn't decide it.

## Open questions for the owner

1. **Dimension.** Should we keep the smallest that stays within 2 hit@4 of 768 (recommended, since it
   saves storage per vault and is faster to compare), or always 768?
2. **When the download is offered.** At Field Assist setup, or on the first vault import? It is Wi-Fi only
   either way, with the size shown.
3. **If it wins.** The wearer can always choose any of the three (P2). Should Search-trained become the
   default for new installs after P3, or stay a choice the wearer makes for one release?
4. **Switching back and forth.** A change of choice re-indexes, and so does changing back. Should we
   keep the previous model's vectors too, so switching back is instant (about twice the index storage for
   a vault while both are kept), or re-index each time (recommended, since switching is rare)?
5. **Afterwards.** Should memory recall and general documents follow it in a later plan, once the phone
   numbers are known?
