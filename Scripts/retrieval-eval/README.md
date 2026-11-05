# Local retrieval eval

Two measurements are read for every change to manual retrieval:

- **The Lennox calibration set.** The labelled questions in `RetrievalGateCalibrationTests`, over
  the example vault's two manuals. The test runs in the simulator when the manuals are in
  `examples/vaults/lennox-slp99/documents/` and skips otherwise.
- **Your own documents against your own answer key.** This might be a code book with the rule
  numbers your study material gives as answers, or a manual with the pages that answer your
  questions. You run it locally. It is never committed and never shared.

Each one runs on both embedding models. The simulator test measures the simulator's word-average
model (`nl-word`). The Mac runner in this folder measures the device's model (`nl-sentence`, or the
contextual model when asked). Both use the app's own `DocumentStore`, `DocumentChunker` and
`VaultRetriever`, and score with the same core (`OpenGlassesTests/RetrievalEval/RetrievalEvalCore.swift`).

## What a run prints

Counts only, never a question, a passage or a document title:

```
[EVAL] my code book embedder=nl-sentence.en scored=72 hit@1 11 (0.15) hit@4 30 (0.42)
[EVAL]   misses 42: recall (not in the top 30) 14 (33%) · ranking (in the top 30) 20 (48%) · …
[EVAL]   overlays: multi-rule or calculation 17 (11 missed) · answer in doubt 27 (14 missed)
```

Hit@1 and hit@4 count the questions where the first passage, or any of the four the model is handed,
holds the answer. A passage holds the answer when it prints an expected rule or table number, or
when it comes from an expected page. Misses are put in the first class that fits:

1. **Expected label not printed in these documents.** The answer key cites a number that these
   documents never print as a heading. It may come from another edition, or the key may be wrong.
2. **Chunk boundary.** The rule's continuation is in the top four without its number.
3. **Duplicates across documents.** Near-identical passages take the slots, and removing them
   would hit.
4. **Ranking.** The expected passage is in the top 30 candidates but is outranked.
5. **Recall.** The expected passage is not in the top 30 at all.

The overlays count questions flagged `multi` (several rules or a calculation, where a one-passage
test is the wrong test) and `doubt` (the expected answer itself is uncertain).

## The answer key

The answer key is a JSON-lines file, one question per line. Lines starting with `//` are comments.

```
{"q": "what does a sink socket need", "rules": ["99-200"]}
{"q": "which lamp may be used outdoors", "tables": ["Table 99"], "multi": false}
{"q": "how do I test the flame sensor", "pages": {"SLP99UHVK Service Manual": [34]}}
{"q": "what is the torque for the blower wheel set screw", "outOfScope": true}
```

- `rules` / `tables`: what a passage must print. Write rule numbers as printed, without subrules
  ("99-200", not "99-200(2)").
- `pages`: the document title as it appears in the vault manifest, mapped to the pages that answer.
- `outOfScope`: the documents don't answer the question, so the gate should refuse it.
- `multi`, `doubt`, `note`: optional.

Write questions the way a technician would ask them, not the way the book phrases its headings. If
your material is a workbook or an exam with worked answers, the questions and the cited rules make
the key. Keep the file outside the repository and delete it when you're done if the material is
licensed to you alone.

The Lennox set is already written for you in this form:
`examples/vaults/lennox-slp99/eval/calibration.jsonl`. `RetrievalGateCalibrationTests` keeps it
identical to the test's own lists.

## Running it

**On a Mac (the device's embedding model):**

```
RETRIEVAL_EVAL_VAULT=/path/to/vault \
RETRIEVAL_EVAL_ANSWER_KEY=/path/to/answers.jsonl \
RETRIEVAL_EVAL_WORKDIR=/path/outside/the/repo/eval-store \
RETRIEVAL_EVAL_LABEL="my code book" \
Scripts/retrieval-eval/run.sh
```

- `RETRIEVAL_EVAL_VAULT` is a vault folder: `manifest.json` plus its documents. A PDF is indexed
  as the phone indexes it: its text extracted once with `Scripts/extract-manual-text.swift` into the
  work folder, and its tables read with the app's own `PDFTableReader` (a `.md` document gets the
  tables of the PDF its manifest entry names as `source`). To measure one edition of a book loaded on its own, write a
  manifest that lists only that edition.
- `RETRIEVAL_EVAL_WORKDIR` holds the index between runs, so a long book is embedded once. Delete it
  when you're done.
- `RETRIEVAL_EVAL_EMBEDDER=contextual` measures the contextual model instead of the sentence model.
- `RETRIEVAL_EVAL_GATE="<min shared terms>,<shared fraction>"` (or `floor`) measures a candidate
  evidence gate instead of the shipped one, to calibrate a gate against both sets. The output line
  names the gate.
- `RETRIEVAL_EVAL_FULL_MATCH="<floor>[,<fewest question terms>]"` sets the lower similarity floor a
  passage clears when it shares every content term of a question of at least that many terms (4
  when not given), over whatever the gate above is; `off` switches it off. The sentence model ships
  0.10 for four terms or more, measured this way.

- `RETRIEVAL_EVAL_RECOGNISE=grid` (or `words`) reads the tables a PDF prints as pictures too, as
  an import on the phone does (Plan JN P1); `off`, the default, reads the text layer only. Give it
  its own `RETRIEVAL_EVAL_WORKDIR`.
- `RETRIEVAL_EVAL_TABLE_ROWS` says which routes search a table's row passages: `1` every route (as
  shipped), `0` none (as before tables), `token` the exact-token and table routes only, `table` the
  table route only. One index serves all four. A line counts the questions that name a table.
- `RETRIEVAL_EVAL_CHUNKER=spaces` or `linebreaks` indexes with an earlier chunking behaviour, to
  measure a chunking change against (in the simulator, `TEST_RUNNER_RETRIEVAL_EVAL_CHUNKER`). Give
  each variant its own `RETRIEVAL_EVAL_WORKDIR`: an index is built once and reused.
- Hit@1 and hit@4 are read off four passages, so they compare across rounds. An "as sent" line
  follows: the passages the app actually sends (six when the best passage is from a
  clause-numbered document, four otherwise), with the share of questions answered somewhere in
  them, how many passages and characters went, and the refusals on that path.
  `RETRIEVAL_EVAL_PASSAGES=4` leaves the line out.

- **Language groups (Plan JY P3).** Each document is indexed and searched with its own script's model
  (`RETRIEVAL_EVAL_EMBEDDER=contextual` picks Cyrillic, Arabic, Urdu or CJK as the app does), and a
  `documents:` line names each document's detected script, language and term rule. Candidate values for
  a group (`latinLight`, `latinHeavy`, `cyrillic`, `arabic`, `urdu`, `cjk`; never English):
  `RETRIEVAL_EVAL_PREFIX` (letters a prefix stem keeps), `RETRIEVAL_EVAL_MINLEN`, `RETRIEVAL_EVAL_ENDINGS`
  (`1`/`0`: strip one ending), `RETRIEVAL_EVAL_FOLD=1` (Cyrillic ё/ї/ґ), `RETRIEVAL_EVAL_CJK`
  (`kana`, `kopart`, joined with `+`, `none`, or `words` for `NLTokenizer` words),
  `RETRIEVAL_EVAL_GATE_GROUP="cjk=3,0.6;arabic=3,0.5"` and `RETRIEVAL_EVAL_PENDING="0.15"` or
  `"cyrillic=0.3"`. Each takes one value for every group or `group=value,…`. They are read by
  `Tuning.swift` under `-D RETRIEVAL_EVAL`, which only `run.sh` defines, so the app never sees them.
  `RETRIEVAL_EVAL_VECTORS=pending` measures documents in other scripts as searched while their model
  is missing (the index keeps its vectors; no script model answers). `RETRIEVAL_EVAL_DETAIL=1` prints
  each question's line number with the pages it expects and the pages it got — numbers only.

- **Structure in other languages (Plan JY P4).** `RETRIEVAL_EVAL_CHUNK_SCALE` scales a document's
  chunk targets by its language or group (`"zh-Hans=0.8,ja=1.3"`, `"cjk=0.6"`, `cyrillic`, `arabic`);
  give each value its own `RETRIEVAL_EVAL_WORKDIR`, since it changes the index. `RETRIEVAL_EVAL_P4_OFF`
  switches a P4 rule off to measure it (`captions`, `split`, `clauses`, joined with `,`);
  the extraction-side rules (fake bold, caption words and caseless headings in
  `extract-manual-text.swift`) are measured with a copy of the extractor named by
  `RETRIEVAL_EVAL_EXTRACTOR`. `RETRIEVAL_EVAL_PROSE_PASSAGES` sets the prose passage budget the "as
  sent" line uses (4 as shipped).

- **Remaining defects (Plan JY P5a).** `RETRIEVAL_EVAL_P5` switches on a measured candidate:
  `majority` (every language's chunks cite the page that holds most of them; `nomajority` none's),
  `split` (a chunk never crosses a page break), joined with `,`; `RETRIEVAL_EVAL_MAJORITY="0.67"`
  asks the page for that share of the chunk. `RETRIEVAL_EVAL_RELOCATE=1` re-chunks each indexed document and, where its text chunks as
  stored, rewrites only its pages, sections and figures (the app's location migration), so a change
  that moves only citations or sections is measured on the same index and vectors; the summary
  counts the documents whose text no longer chunks the same.

- **Ranking features (Plan KN P1).** `RETRIEVAL_EVAL_FEATURES=/path/outside/the/repo/features.jsonl`
  writes one JSON line for every candidate of every scored and out-of-scope question: the ungated
  retriever's candidates read 30 deep, the ones the miss classes read, in today's order. The run
  refuses a path inside this repository or any other git working tree, and the file's folder must
  exist. `RETRIEVAL_EVAL_FAMILY=<number>` stamps each line with a manual family's number (0 when
  not set). A line holds:
  - `q`, the question's line number among the key's questions (from 1), never its text;
  - `rank`, the candidate's place in today's order (from 0);
  - `label`, 1 when the passage holds the answer and 0 when it doesn't, `null` for an out-of-scope
    question, and `oos`;
  - `family`, `embedder` (the model id, the line's only string), `schema` (the feature schema's
    version, `RankingFeatures.schemaVersion`);
  - `doc`, the passage's document by its place in the manifest (from 1), and `chunk`, its chunk
    number; never the document's id or title;
  - the features, `RankingFeatures` in `VaultRetriever.swift`: the similarity's place among the
    question's candidates and its gap to the best, the BM25F or shared-term value the sort compared
    (`lexical`, `lexicalWeighed`), the shared-term count and share, whether the heading holds a
    question term, the matched codes and models, the model penalty, the passage kind (0 prose, 1
    table row, 2 diagram), recognised from a scan, manual or team learning (`isReference`), vector
    pending, assigned to the unit, table and clause match, the ranking group, the length in
    characters, and one flag per route that found it (`byMeaning`, `byToken`, `byClause`,
    `byTable`, `byWords`) with their count.

  The summary line counts the lines and the ones holding the answer. Like the index, the file is
  per-question results: keep it out of every repository and delete it when you're done.

Every run prints in-scope refusals beside the hits, because a gate that refuses more out-of-scope
questions usually refuses some in-scope ones too, and both numbers decide a gate.

**In the simulator (the simulator's model, through the session's own retriever):**

```
TEST_RUNNER_RETRIEVAL_EVAL_VAULT=/path/to/vault \
TEST_RUNNER_RETRIEVAL_EVAL_ANSWER_KEY=/path/to/answers.jsonl \
xcodebuild test … -only-testing:OpenGlassesTests/LocalManualEvalTests
```

The vault is imported exactly as a customer's would be, so PDFs work as they do in the app. The
`TEST_RUNNER_` prefix is how xcodebuild passes a variable to the test process. Without the
variables the test skips.

The Lennox calibration's production-path column (each question asked as a turn is, four passages
through the shipped gate) prints with the rest of `RetrievalGateCalibrationTests`.

## What never goes in the repository

Manuals, code books, extracted text, answer keys written from licensed material, index folders and
per-question results. The runners print only counts so their output is safe to paste into a plan or
a pull request.
