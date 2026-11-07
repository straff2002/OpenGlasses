# Plan KQ — A Model Trained to Search (manual passages embedded by a retrieval model, measured before it answers)

**Status:** 🚧 P2 built 2026-11-07. P2a: the wearer can choose Search-trained in Settings › Field Assist,
and the model downloads from its own public repo. P2b: an organisation's profile can pin the choice. P3,
the phone pass, is owed. P1 run the same day: the bar is met. On the ten local answer keys, with the
shipped request and the code lead, at 768 dimensions and its own gate (floor 0.69, three terms at 0.5):
- hit@4 243 of 331, against the contextual model's 213;
- hit@1 158 against 139, and as sent 254 against 224;
- in-scope refusals 10 against 21, and out-of-scope refusals 63 of 107 against 57;
- no key's hit@4 lower by more than one.

The contextual model on the same lexical rule reaches hit@4 223 and refuses 16 fewer out-of-scope
questions, so the gain is the model's. This model's similarity tells an answer from a near miss, and the
floor uses it.

P0 run the same day, on the Mac and on the owner's iPhone Air (iOS 27.2). The model went on to P1, on the
CPU only:
- **Foreground:** a question embeds in 39 ms warm (p90 41 ms), the first text in 63 ms, and a 404-token
  passage in 197 ms.
- **Memory:** about 167 MB more with the model loaded.
- **Tokenizer:** `swift-transformers` gives the reference's ids on all 329 test texts.
- **Parity:** int8 weights stay within 0.9998 of the reference on the phone, with no NaN.
- **fp16 fails:** no NaN, but every vector drifts (median cosine 0.978), so the Neural Engine is out.
- **Locked, in the background:** five questions in a row took 118–155 ms each. One locked question, the
  first after iOS had reclaimed the model's pages, took 4.7 s. P2 has to warm the model at the start of a
  turn (see P0's findings).

Drafted 2026-11-07 from the owner's question: could a newer embedding model, or a learned sparse model, do
better than the ones manual search uses today? The app's search is unchanged. P0 added a developer check
only. The app changes only if P1 meets the bar below.

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

0. **It ships on the iPhone.** The Mac is a test bench only. It runs the answer keys quickly, but Core ML on
   a Mac is not Core ML on a phone. The compute units, the Neural Engine's fp16 behaviour, memory limits,
   thermal throttling and background rules all differ. Any figure that decides something (latency, memory,
   NaN, parity, the gate numbers) is read on the iPhone. A Mac number only filters what is worth taking to
   the phone.

1. **Never on the GPU.** A question is embedded while the phone is locked and the glasses are in use. iOS
   forbids Metal in the background, and MLX's failure there is an uncatchable abort that kills the app (see
   `LocalLLMService`'s guards). The model runs through Core ML with compute units pinned to the CPU, or
   CPU and Neural Engine. It never runs on MLX and never on `.all`.
2. **No fp16.** The model card says not to use float16. P0 measured it: no NaN, but every vector moved
   (median cosine 0.978 against the reference, none above 0.999). The Neural Engine computes in fp16, so
   the model runs with int8 weights and fp32 activations on the CPU, and only there.
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

### P0 — convert and check (Mac to convert, iPhone to decide)

- A conversion script under `Scripts/` that turns the text encoder into a Core ML package with int8 weights.
  Weights and packages live outside the repository.
- Check the card's figures against the converted model: parameters, context length, dimensions, prefixes,
  licence text.
- Parity against the reference fp32 encoder on a few hundred invented sentences: cosine ≥ 0.999 at each
  dimension kept.
- Check that `swift-transformers`, already a dependency, tokenizes as the reference does, byte for byte, on
  the same sentences.
- **On the iPhone, before P1's sweep:**
  - load the package in a developer build;
  - question latency and peak memory on the CPU and on the Neural Engine, cold and warm;
  - NaN count and parity against the Mac's fp32 vectors on the same sentences;
  - one question with the phone locked.

  Only a compute-unit choice that meets the latency bar on the phone goes on to P1. If none does, the plan
  stops here.

**Run 2026-11-07.** Built from `Scripts/kq-embedder` (`convert.py`, `parity.py`, invented sentences in
`sentences.py`). The phone half is a developer check, `SearchModelPhoneCheck`, under Settings › Advanced ›
Developer › Search Model Check. Its files are copied into the app's Documents by hand, and nothing
downloads.
- **The card, checked.**
  - Apache 2.0 and ungated, as reported.
  - The text model is 24 layers at width 512, with a 262,144-word vocabulary and a projection to 768.
    Its int8 package is 261 MB.
  - It reads 8K tokens, but the config's sliding window is 512 (the card's table says 1024). The package
    takes up to 512 tokens, so every layer sees the whole input, and longer text is split as today.
  - The prefixes are `task: search result | query: ` for a question and `title: none | text: ` for a
    passage. Pooling is the mean over every token, prefix included, then normalised.
- **The conversion.** The library's own forward doesn't trace, because its masks and reshapes come from
  runtime shapes. `convert.py` reimplements it with the same weights and fixed head shapes. It equals the
  library to cosine 1.000000 before any conversion. Parity on the Mac against the float32 reference, 329
  texts (160 questions, 161 passages, 8 in other languages and scripts):

  | Package | Compute | NaN | Min cosine 768 / 256 | Median 768 | Mac ms per text |
  |---|---|---|---|---|---|
  | fp32 | CPU | 0 | 1.00000 / 1.00000 | 1.00000 | 57 |
  | int8 weights | CPU | 0 | 0.99977 / 0.99980 | 0.99987 | 55 |
  | int8, fp16 compute | CPU or Neural Engine | 0 | 0.91516 / 0.92237 | 0.97792 | 24 |

- **The phone (iPhone Air, iOS 27.2, Release build, CPU only).**
  - Compile and load take 2.3 s, and the tokenizer loads in 1.2 s.
  - Footprint is 99 → 266 MB after load, with a peak of 267 MB.
  - The tokenizer matches on 329 of 329 texts.
  - First text 63 ms. Warm median 40 ms, p90 42 ms, max 197 ms (the 404-token passage). Questions alone:
    median 39 ms, p90 41 ms.
  - Parity is identical to the Mac's int8 row.
- **Locked.** These were two runs of the 15-second test with the phone locked, the app in the background
  with a background task, and no audio session.
  - **First run:** the model loaded and the phone was locked before its first prediction. The first
    question took 4,741 ms, with protected data locked and parity 0.99990.
  - **Second run:** with one warm-up in the foreground first, five questions took 119, 119, 145, 136 and
    134 ms at user-initiated priority, and 155, 118, 136, 137 and 132 ms at background priority.
  - During the sleep, iOS reclaimed about 90 MB of the model's pages (253 → 165 MB).

  So the background CPU is about three times slower than the foreground, and still near the 150 ms bar.
  The first question after the pages are reclaimed pays to read them back. P2 warms the model when a turn
  starts (the wake word, or the first audio of a question), so that read happens while the wearer is still
  speaking, and P3 measures the first question after a long lock with the glasses' audio session running.

### P1 — measure on the keys (Mac runner, on the phone's compute choice)

The Mac runner reads the keys quickly. It embeds with the compute units and precision P0 chose for the
phone, so its vectors are the phone's to within P0's parity. A key whose vectors fall outside parity is
re-scored from vectors made on the phone.

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

**Run 2026-11-07.** What was built:
- `Scripts/retrieval-eval`: `RETRIEVAL_EVAL_EMBEDDER=eg2[:<dim>]` and a candidate `RETRIEVAL_EVAL_FLOOR`.
- The app's seam: `CoreMLEmbeddingBackend` (the backend P2 ships, CPU only), `embedQuery` on
  `EmbeddingBackend` and `Embedder`, and the store's three question sites switched to it.
- In the runner, tokens come from the reference tokenizer through `Scripts/kq-embedder/tokenize_server.py`
  (P0: identical to `swift-transformers` on every test text), and vectors are cached at 768 values outside
  the repository.
- The ten keys are the ones from Plans KN and KO, held locally and never committed. Each eg2 run starts
  from a copy of the contextual run's index and re-embeds its chunks through the store's own
  `reindexOutdated`, so all three models are scored on the same passages.
- About 17,000 chunks were embedded once, in about 40 minutes on the Mac's CPU. Counts only.

| Key | Type | Scored | Contextual hit@1 / hit@4 / as sent | eg2 hit@1 / hit@4 / as sent | Contextual refused in / out | eg2 refused in / out |
|---|---|---|---|---|---|---|
| Furnace pair | service and install | 18 | 14 / 18 / 18 | 14 / 17 / 17 | 0 / 12 of 18 | 0 / 10 of 18 |
| Refrigerator, service | service | 35 | 10 / 19 / 19 | 12 / 23 / 23 | 0 / 2 of 10 | 1 / 4 of 10 |
| Refrigerator, owner | owner and install | 30 | 6 / 12 / 12 | 6 / 17 / 17 | 0 / 1 of 10 | 0 / 4 of 10 |
| Heat pump | service | 27 | 7 / 15 / 20 | 8 / 18 / 19 | 4 / 3 of 8 | 4 / 3 of 8 |
| Network switch | install | 23 | 10 / 16 / 16 | 12 / 20 / 20 | 3 / 5 of 7 | 0 / 4 of 7 |
| Drive | service | 31 | 9 / 16 / 18 | 11 / 17 / 20 | 4 / 2 of 9 | 3 / 7 of 9 |
| Code book | code book | 66 | 25 / 45 / 48 | 26 / 44 / 49 | 0 / – | 0 / – |
| Dangerous-goods regulation | standard | 34 | 23 / 27 / 28 | 21 / 28 / 30 | 0 / 8 of 15 | 0 / 6 of 15 |
| EU regulation | standard | 33 | 12 / 18 / 18 | 19 / 27 / 27 | 7 / 12 of 15 | 2 / 12 of 15 |
| Programming tutorial | software | 34 | 23 / 27 / 27 | 29 / 32 / 32 | 3 / 12 of 15 | 0 / 13 of 15 |
| **All** | | **331** | **139 / 213 / 224** | **158 / 243 / 254** | **21 / 57 of 107** | **10 / 63 of 107** |

- **The floor does real work on this model, and sits high.**
  - On the contextual model's rule (three terms at 0.6), floors from 0.40 to 0.55 refuse nothing more.
  - At 0.60 and 0.65 a few more out-of-scope questions are refused at no in-scope cost (59, then 62),
    but 0.65 drops the code book's hit@4 by two.
  - At 0.70 the rule refuses 75 of 107, but turns away six more in-scope questions and drops the furnace
    pair by two. At 0.75 it refuses 90, and hit@4 falls to 208.
  - A full-match floor (0.55 or 0.60 under 0.70) changed nothing.
- **The lexical rule.**
  - Three terms at 0.5, under a floor of 0.68 or 0.69, gives back the in-scope questions the stricter
    rule refused. 0.69 refuses 63; 0.68 refuses 57, the contextual model's count, with hit@4 243 either
    way.
  - Two terms at 0.5 reaches hit@4 251, but refuses only 46 out-of-scope questions.
  - The control: the contextual model on three terms at 0.5 gets hit@4 223, refuses 7 in-scope and 41
    out-of-scope questions. It answers more only by refusing less.
- **The code lead (Plan KO) still earns its place.** With it off, hit@4 is 229 against 243.
- **256 dimensions** score as well (hit@4 245–248) but need their own floor. At 0.70 the code book loses
  two, and at 0.72 the furnace pair loses two, so neither passes the per-key bar. The 768-value vectors
  are the ones measured and the ones the gate is for (open question 1).
- **Characters sent** per question change by −257 to +466 by key. The largest rises are where fewer
  in-scope questions are refused (EU regulation +466, five fewer refused).
- **Not run:**
  - The non-Latin keys from Plan JY. This P1 is the Latin, English-language keys only, so P2 keeps each
    script's own model for documents in another script until those keys are run.
  - The optional learned-sparse arm. No document-side model with a commercial licence was confirmed,
    and BM25F already covers the words.

**How far to trust it.** The gate's two numbers, 0.69 and 0.5, were chosen on these keys, from about a
dozen settings, so the margin over the bar is partly fitted. What isn't fitted is the size of the gap:
- every setting from 0.60 to 0.70 with three terms at 0.5 or 0.6 beats the contextual model's hit@1;
- every one with three terms at 0.5 beats its hit@4 by 30 or more.

The next pilot's manuals, or the P3 phone pass, re-read it.

### P2 — in the app, behind a flag (headless)

- Built in P1: the query/document role (`embedQuery`) and `CoreMLEmbeddingBackend`, CPU only.
- A test that fails if the backend's compute units include the GPU or the Neural Engine.
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
- `RetrievalEvidencePolicy.default(for:)` has the P1 entry already (`eg2-text.768`: floor 0.69, three terms
  at 0.5). It ships with this backend and nothing selects it yet.
- Documents in a script other than Latin keep their own script's model. P1 measured Latin text only.
- A warm-up at the start of a turn, when the search-trained model is chosen and a vault is open: one tiny
  prediction off the main thread when the wake word fires or a question's first audio arrives, so pages
  iOS reclaimed in the background are read back while the wearer speaks (P0's 4.7 s first locked
  question).
- `SearchModelPhoneCheck` and its Developer row are replaced by the real backend's own check, or removed.
- Tests:
  - the role reaches the prefix;
  - a missing or partial download falls back with no re-index;
  - changing the choice re-indexes once, each way, and a choice whose model is missing falls back;
  - the old switch's stored value maps to Standard or Smarter;
  - the gate entry is picked by id;
  - a vault never answers on a model with no gate entry.
- Every other embedding user (`SemanticMemoryStore`, general documents, skills) stays on `Embedder()`.

**P2a built 2026-11-07 (headless).** Everything above except the organisation pin, which is P2b.
- **The choice.**
  - `ManualSearchModel` (`standard`, `smarter`, `searchTrained`) is stored as
    `Config.fieldAssistManualSearchModel`. Before a choice is stored it reads the old switch, and setting
    it keeps the old switch in step, so no install changes model on upgrade.
  - `Embedder.fieldAssist(choice:)` uses the search-trained model only when it is chosen, English and
    loaded; otherwise Smarter's model, otherwise Standard.
  - `VaultEmbeddingUpgrade` asks for the chosen model's asset whenever the target isn't on it yet.
  - At launch, a wearer on Search-trained loads the model before the first re-index pass, so a vault
    already on it isn't started towards the fallback during the load.
- **The download.**
  - `SearchModelBundle` points at the public Hugging Face repo `Skunk0/avenkin-search-eg2-text`: Apache
    2.0, with the package, tokenizer files, `LICENSE`, a `NOTICE` of the changes and a model card. It is
    306 MB, with checksums verified against the converted files. It was published 2026-11-07 with the
    owner's approval.
  - The download goes through the existing `ModelDownloader` (staged, verified, installed atomically), on
    a new model-asset route, `searchModelDownload`. It is allowed in local-only mode like the other model
    downloads, because it carries nothing about the wearer.
  - `HuggingFaceModelInstaller` gained a generic per-file fetch for any bundle. Kokoro's path is
    unchanged.
- **The runtime.** `SearchModelRuntime` loads once per process, off the main thread: it compiles the
  package to `compiled.mlmodelc` beside it on first use, then loads the tokenizer with `swift-transformers`.
  `ready` is nil until the load finishes.
- **The warm-up.** `handleWakeWordDetected` runs one tiny question embedding off the main thread when the
  search-trained model is chosen and loaded and a Field Assist session is open.
- **Settings › Field Assist › Manual Search** is a picker: Standard, Smarter, Search-trained. Choosing
  Search-trained shows a download row with the size. On a cellular or hotspot connection it says to
  connect to Wi-Fi instead. Once downloaded it can be removed. Every change re-indexes once.
- `SearchModelPhoneCheck` stays as the developer check P3 uses for its timings.
- **Tried on the owner's iPhone Air (Release build), 2026-11-07.**
  - The download completed from the public repo, and the package compiled and loaded on the phone.
  - **Search itself was not exercised.** The phone's document store held no manuals (0 documents). The
    bundled refrigeration vault carries reference notes only, which don't go through manual search, so
    the test questions were answered without it. P3 needs a vault or My Manuals with real manuals.
  - Progress sat at 0% and then jumped to 89%, because it moved per file and the weights are one 273 MB
    file. The search model's download now reports bytes as they arrive, in whole-percent steps; Kokoro's
    is unchanged.
  - An out-of-scope question (a car's wheel-nut torque) was answered from general knowledge. With no
    manuals indexed, no gate was involved.
  - **Importing a 44-manual vault froze the screen.** The store runs on the main actor and embedded each
    passage there, at about 40 ms each on the new model, against a few for Apple's. A backend now
    declares `isSafeOffMainThread`. Only `CoreMLEmbeddingBackend` does, so only it is embedded off the
    main thread in the store's passage loops: import, page import, re-chunk, table rows, the vault
    re-index and the non-vault re-index. Apple's models run exactly where they did, and a test pins
    both sides.
- **Tests.** `ManualSearchModelTests` (10) cover:
  - the old switch's mapping, and staying in step with it;
  - each choice's model ids;
  - the fallback until the model is loaded, and Standard never using it;
  - CPU-only compute units;
  - the bundle's required files;
  - the route's data class and its local-only rule;
  - when a warm-up runs;
  - the gate for a vault on the model, against the fallback's.

  The route and privacy guards list the new route.
- **Owed.**
  - A catalog sync for the new strings.
  - The phone pass (P3).

**P2b built 2026-11-07 (headless).**
- `SettingKey.organizationManualSearchModel` (profile-owned string: `standard`, `smarter` or
  `searchTrained`; any other value is a named drop). It is listed with the other owned keys.
- `Config.fieldAssistManualSearchModel` reads the organisation's pin first, then the wearer's own
  (`userManualSearchModel`). The setter only ever writes the wearer's own.
- Under a pin, Settings shows the model read-only with the managed-lock note, hidden from a technician as
  other pinned rows are. A pinned Search-trained still shows its download row, so the phone can fetch the
  model and leave Smarter.
- A profile applied, replaced or removed (`orgPolicyDidChange`) loads the model if needed and starts the
  one-time re-index, as the picker does.
- The licence-issuance tool's `ProfileContract` allows the key (`owned:string`) and refuses a model the
  app doesn't know, so an administrator finds out when minting rather than at enrolment.
- Tests:
  - app: the key's kind, an accepted pin that locks, a refused value that drops, and the wearer's own
    choice with no profile;
  - issuance tool: the allow-list entry, the three models accepted, and an unknown model and a wrong type
    refused.

### P3 — the phone (device)

- Question latency, peak memory and battery on the phone's CPU (P0 ruled out the Neural Engine).
- The first question after the phone has been locked for 10 and 30 minutes, with the glasses connected and
  the audio session running, with and without P2's warm-up.
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
