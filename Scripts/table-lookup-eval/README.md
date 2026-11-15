# Scoring the table lookup against a key of cells

Scores the app's table lookup against a key of cells on a Mac: for each question in the key, the
table, row and column it names, looked up in the tables a vault's own PDFs print, and compared with
what the key expects. It compiles the app's `TableLookup`, `TableReference`, `TableExtractor`,
`PDFTableReader` and the picture readers (`PictureTableReading`, `VisionTableReader`) unchanged, with `OpenGlassesTests/TableLookupEval/TableLookupEvalCore.swift` doing
the scoring, and reads each PDF as an import on the phone does. Use it on a vault folder anywhere
on the Mac, your own licensed books included, with a key you wrote against them. Nothing it reads
is written anywhere; the one file it can write, an outcomes file you ask for, holds numbers and
hashes only (see "Is a change real?" below).

```
Scripts/table-lookup-eval/run.sh /path/to/vault-folder /path/to/key.jsonl
```

The tables come from every document the manifest lists that is a PDF, or whose `source` original
is one; a folder with no `manifest.json` has every PDF in it read.
`TABLE_LOOKUP_EVAL_BUILD_DIR` sets where the runner is compiled (outside the repository; it
defaults to `$TMPDIR/table-lookup-eval-build`). `TABLE_LOOKUP_EVAL_LABEL` names the run in the
output, so choose a name that is not a book's title. The output says "against the unchecked key"
unless `TABLE_LOOKUP_EVAL_KEY_CHECKED=1`: set it only once someone who knows the book has checked
every expected cell. PDFKit writes diagnostics of its own to standard error; add `2>/dev/null` to
keep a saved report to the report.

## Tables printed as pictures (Plan JN P1)

`TABLE_LOOKUP_EVAL_RECOGNISE` reads the tables a PDF prints as pictures too, as an import on the
phone does: `off` (the default) reads the text layer only, as before; `grid` recognises each region
under a caption the text layer gives no grid for with Vision's document reading (the app's
`VisionTableReader`); `words` with its word reading laid out by the text extractor's own rules.
`TABLE_LOOKUP_EVAL_FLOOR` (default the app's `PictureTableReading.floor`) is the least word
confidence a clear cell may have. Vision on a Mac can read differently from the phone's; the
numbers that decide are confirmed by an import on the phone. With a reading on, the run adds:

```
[CELLS] document 1: stored tables differing from the text layer alone=1
[CELLS] recognise=document_grid floor=0.5: tables read from a picture=1 unclear_in_picture=0 uncertain cells=2 keys=0 headings=0
[CELLS]   pictured table 1: rows=12 columns=4 cells=48 uncertain=2 uncertain keys=0 uncertain headings=0
[CELLS] vault on tables read from a picture: questions=6 resolved=5 unclear=1 cells expected=6 matched=5
[CELLS]   wrong certain cells: on a pictured table=0 anywhere=0 wrong between rows=0
```

- **wrong certain cells**: a single cell the lookup gave as certain whose text is not the key's —
  on a table read from a picture (the number that blocks a reading), and on any table.
- `TABLE_LOOKUP_EVAL_DIAGNOSE=1` prints, per region recognised, its size, how many words and
  tables the recogniser read there, their mean confidence and what the reading came to, as counts
  and the extractor's own failure names.

## The key

One JSON object per line; blank lines and lines starting `//` are skipped.

```
{"q": "the invented rating", "table": "Table 99", "row": "QXRT three conductors", "column": "Rating group 2", "expect": "35"}
{"q": "a number between rows", "table": "Table 97", "row": "3", "expect": {"below": "2.5", "above": "4"}}
{"q": "a row that fits twice", "table": "Table 99", "row": "QXRT", "column": "Rating group 1", "expect": {"ask": true, "candidates": ["QXRT two conductors", "QXRT three conductors"]}}
```

- `table`, `row`: as a technician or a chain would say them; `column` is optional.
- `expect`: the cell as printed (a string or a number); `{"below", "above"}` for a number that
  falls between two rows, each the row's key or its cell; or `{"ask": true, "candidates": […]}`
  when the lookup should ask which.
- `edition`: optional; picks the books whose name holds it.
- `q`, `unit`, `notes`, `page`, `confidence`: optional and not scored.

## What a run prints

Counts only (the numbers below are an example, not a measurement):

```
[CELLS] documents=2 unreadable=0 tables=120 read=60 seconds=30.1
[CELLS] vault against the unchecked key: questions=40 unreadable_lines=0
[CELLS]   tables: read=30 unread=8 missing=2 ambiguous=0
[CELLS]   on a read table: rows resolved=22 columns resolved=27
[CELLS]   cells: expected=34 matched=18 (0.53)
[CELLS]   between rows: expected=3 matched=2
[CELLS]   asks: expected=3 asked=3 candidates_agree=2
[CELLS]   95% intervals over 34 questions (bootstrap, 2000 resamples): cells 0.53 [0.35, 0.71] · between rows 0.67 [0.00, 1.00] (n=3) · asks 1.00 [1.00, 1.00] (n=3)
```

- **tables**: the table each question names is `read` to a grid, `unread` (its caption was found
  and its grid was not), `missing` (no caption carries the label), or `ambiguous` (the same label
  in two books the edition did not tell apart).
- **rows resolved / columns resolved**: on a read table, the row named one row (not two either side
  of a number), and the column named one column.
- **cells matched**: the lookup gave one cell whose text is the expected text (case, spacing and the
  kind of dash aside) or the same number.
- **between rows matched**: the lookup said the number falls between two rows, and they are the ones
  the key names.
- **asks**: the lookup asked which, and whether every candidate the key lists is among those it
  offered.

## Is a change real? Intervals and comparing two runs

A key of a few dozen cells moves the matched share by a few points per question, so the run prints
a **95% interval** for each share it can: cells matched, between rows matched and asks asked, each
over the questions of its kind (`n=` when that differs from the first). It is the percentile
bootstrap over questions (2,000 resamples drawn with replacement, a fixed seed, so a run is
reproducible): the range the share would land in on another key of that size. With three
questions, the interval is nearly everything, and that is the honest answer.

To compare a change with what came before, pair the two runs question by question:

1. Run A with `TABLE_LOOKUP_EVAL_OUTCOMES=/path/outside/the/repo/a.jsonl`. It writes one line per
   question: its place in the key, the first 16 hex digits of a SHA-256 of its fields (never the
   fields), and whether it matched. The folder must exist and must not be inside a git working tree.
2. Make the change and run B with `TABLE_LOOKUP_EVAL_BASELINE=/path/outside/the/repo/a.jsonl` (and
   its own `TABLE_LOOKUP_EVAL_OUTCOMES` if a later run will compare with it).

B pairs questions with A's by hash and prints, for each share, the difference B − A with a paired
bootstrap interval and a verdict:

```
[CELLS]   vs baseline: paired 40 of 40 (unmatched: 0 here, 0 in the baseline)
[CELLS]   vs baseline, change 95% paired interval: cells +0.09 [+0.03, +0.15] better · between rows +0.00 [+0.00, +0.00] within noise (n=3) · asks +0.00 [+0.00, +0.00] within noise (n=3)
```

`better` and `worse` mean the interval excludes 0, `within noise` that it does not. Below 80% of the
questions in both runs, the key changed too much and the runs are not compared; a question with any
field edited is a new question. **A change whose paired interval includes 0 has not been shown to
help.** Delete outcomes files with the key when you're done.

**Nothing from the key or the book is printed**: no question, label, row, column, cell or
document name. A matched cell is only as right as the key; an unchecked key measures agreement,
not correctness.
