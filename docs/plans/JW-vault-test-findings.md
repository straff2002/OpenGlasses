# Plan JW — Vault Test Findings (revised tables, printed pages, "show me", chains that stop)

**Status:** 🚧 P0 built 2026-10-27 (PR 861) (all seven items, headless); P1a built 2026-10-28 (the
three open items: page reads are not camera turns, table values through `table_lookup` and "show
me" marking only the cited table's rows; a rename on launch measured and left out); P1b built 2026-10-28
(finding a table from plain words: a table directory scored on titles, headings and units names one
or two tables beside a value question that names none, and `table_lookup` reads title words through
it); P1 = partner re-run. Follow-up 2026-11-07 (with Plan [KA](KA-model-kinds-across-providers.md) P3): with manuals to search, a turn naming a fault code ("E4 error", "error 21") or the manuals takes no frame (`SmartCameraPolicy.asksToLookUpInManuals`) — "tell me what that is" after a code had matched the deictic `"that is"`. Drafted 2026-10-27 from the partner's three
structured vault test sessions on build 564 (2026-10-26). No later build changes any of it:
nothing merged between 564 and 570 touches table reading, page labels, `show_source`, the smart
camera or `rule_chain`.
**Track:** Field Assist first (the partner's code-book vault), app-wide underneath: any vault PDF
whose captions carry a margin mark, any book that prints its page number beside other footer
text, any Direct-mode turn that says "show me".
**Related:** Plan [JJ](JJ-table-lookup-and-rule-chains.md) (`TableExtractor`, `PDFTableReader`,
`table_lookup`, `rule_chain`, `ChainRunner`), Plan [JN](JN-pictured-tables.md) (pictured tables;
its P1 finding is revisited below), Plan [IN](IN-verifiable-code-lookup.md) (printed page labels,
`show_source`, `ShowSourceCenter`), Plan [FD](FD-camera-readiness-and-durable-actions.md) (visual evidence freshness), Plan
[DM](DM-privacy-safe-production-logging.md) (counts only in logs).

---

## Why

The partner ran three sessions against the code-book vault: tables asked for by number, the same
questions in plain words, and the rule chains end to end. Correction-factor tables worked, with
and without the table's number, including a missing input, a value between two printed rows and
a cell printed as a dash. The two rating tables never answered, both chains that were tried
stopped, and "show me the table" paid for a camera it did not use.

Everything below was read from the support reports and checked against the code and against the
private copy of the book on the Mac (which never enters the repo).

## Findings and causes

### 1. A revision mark beside a caption hides the table (cause confirmed)

The book marks a revised table with a small triangle in the margin, printed on the caption's own
line. `TableExtractor.caption(of:)` requires the line to begin with `TABLE` (and, on a page that
sets anything in bold, its first word to be bold), so the mark's word comes first and the line is
not a caption. In the newer edition that is most of the revised tables, including both rating
tables and the two the conduit-fill chain names (the import warning "needs tables … which the app
could not find"). The correction-factor tables carry no mark, which is why they work.

`ManualStructure.caption`, which names passages and decides which pages open, applies the same
rule to typed lines, so a passage on the table's grid page is not named for the table either.

**Plan JN revisited.** JN P1 found "nothing printed under the two captions" on the book's two
failing tables and concluded the copy held for measurement lacked the pictures. With the grid
page's caption invisible, the only caption JN's reader saw for each table was the one on the
continuation page, which carries notes and no grid. The grids are text and read once the caption
is found. JN's picture reader is still right for books that do print tables as pictures; its
"owed: a copy that prints the tables" item is closed by this plan, pending the measurement below.

### 2. "(Concluded)" is not read as a continuation (cause confirmed)

A table that runs over two pages is captioned "(Continued)" on the second page in some books and
"(Concluded)" in this one. `continuedPattern` knows only the first. A concluding page is read as
a table of its own with the same label. Today it is the only one found, so `table_lookup` cites
it and `show_source` opens it: the notes page, never the grid. Once finding 1 is fixed the two
would compete for one label.

### 3. Printed page numbers are not read for this book (cause confirmed)

`PrintedPageBand.label(in:)` accepts a header or footer line that is only a number. This book
prints the page number at the end of the footer line, after the date and the copyright notice, so
no page gets a printed label. `manual_figure`'s `page` is a printed page, and with no label it
falls back to the physical page. "Open printed page N" therefore opens PDF page N, which in this
book is the table index, a few pages before the table. That is what the partner saw when asking
for a rating table in plain words.

### 4. "Show me the table" starts the glasses camera (cause confirmed)

`VisionIntentDetector` lists "show me" as a vision phrase. With smart camera on, every "show me
the table" grabs a frame before the model is called. The glasses were added but not connected, so
the grab ran the three-attempt Meta permission check (about 8 seconds) and was then rejected.
That is most of the reported 24-second wait. Inside a Field Assist session whose last answer cited
manual pages, "show me …" means those pages: `show_source`'s job, not the camera's.

Separately, smart camera tries the glasses when the glasses link is down. The connection rule
("connected means `linkState == .connected`") says that capture cannot succeed, so the attempt
should not be made.

The camera that opened on "read the row on this page" was the model choosing `look_closely` for
"this page". The tool descriptions should say that a page shown from a manual is read with
`table_lookup` / `manual_lookup`, never the camera.

### 5. The highlight stays on the previous row (cause found in P0)

After a lookup that cited two rows (a value between two printed rows), `show_source` ran twice and
the page kept the row marked by the answer before. The model said the new rows were marked. P0
finds where the table lookup's rows are noted for "show me" (`ShowSourceCenter.noteTableLookup`)
and why an answer with two cited rows did not replace them. `show_source`'s result must also say
which rows it marked, so the model cannot claim rows it did not mark.

**Cause (P0).** Not the memory: `noteTableLookup` replaced the first answer's row with the two
rows of the between-rows lookup, keyed by the same table citation, and `show_source` staged the
page with both rows. The viewer dropped them. A sheet on screen was identified by its citation
alone (`AppState.ManualFigureRequest.id`), so the same table on the same page with other rows
was taken for the sheet already open: SwiftUI kept it, `ManualFigurePresentation` handed back the
controller cached under that id (whose model carried the first answer's marks), and the PDF
viewer's coordinator marks a page once and skipped the new passages. `show_source` running twice
changed nothing further — the second request was the same again. It only shows while the sheet
from the first "show me" is still up, which is how the partner asked.

### 6. Chains: rejected answers, a stopped chain that keeps asking, and a start that fails

The report's per-call character counts match the tool's fixed messages exactly, so the sequence
can be read:

- **An answer with its unit was refused.** A size said with its unit (e.g. "12 <unit>") was not
  taken where the chain asks for a size "as the table prints it"; the bare "12" was. The size
  matcher should drop a unit or size word the row keys do not carry (a unit name, "mm", "No.",
  "#").
- **The chain stopped at its table step, and the model kept collecting values.** The step's table
  was unreadable (finding 1), so the chain stopped and filed its read-back. The model then asked
  for the next value anyway, and later restarted the chain without saying so. The stop message
  must say plainly that the chain has ended, name the table it could not read, tell the model not
  to ask for further values, and say how to run it again.
- **"Start the chain called X" while another was running.** The tool said the conduit-fill chain was
  still running, the model stopped it, started the second chain, stopped that too, and told the
  technician to try again later. A technician who names a different chain to start means it. So
  `start` stops the running chain (nothing recorded, as `stop` does) and starts the named one,
  saying both.
- **A chain whose tables cannot be read is started anyway.** `list` already marks it ("needs …,
  it will stop at that step"). `start` does not, and the chain asks its questions before stopping.
  `start` refuses such a chain up front, naming the tables and offering to show their pages.
- **"List the chains" was summarised.** `list` returns every chain with its "answers" text, and
  the model summarised it as categories. The result should lead with the names, one per line, and
  tell the model to read the names out, since the technician starts a chain by name.

### 7. Smaller: several rows marked, two passages "couldn't be marked"

In the first session, "show me" on a correction-factor answer marked three ranges and reported that
two passages could not be marked. It did not recur in the second session. P0 checks whether it
is the same mechanism as finding 5. If not, it stays open here for P1.

**P0: a different mechanism, left open for P1.** Five passages on one page, three located, is not
a stale sheet. The likely path: the answer's `Source:` line named the page without the table's
label, so the citation had no `figure` and `AnswerSourceMemory.retrieved(for:)` fell back to every
passage the turn retrieved on that page (row passages and prose), not the rows the lookup read.
Two of those are prose or rows whose printed runs are not unique on the page, so they are not
located. Not reproduced from the report alone; P1 checks the turn's Source line in the partner's
re-run before changing which passages a page-only citation marks. `show_source` now names the
rows it marked and those it could not (item 5), so a repeat is visible in the report.

## Phases

### P0 — Headless fixes (this PR)

Deterministic, unit-tested, with invented fixtures only (a `Table 99` with a margin mark, a
footer line that ends with the folio):

1. **Margin marks before a caption.** `TableExtractor.caption(of:)` and `ManualStructure.caption`
   skip leading marks on the caption's line: a word with no letter or digit (a triangle, a bar, an
   arrow, a bullet) standing apart from the word `TABLE`. The bold rule applies to the first word
   after the marks. A sentence that merely begins with a symbol still has to pass every other
   caption rule.
   **✅ Built.** One rule, `TableExtractor.droppingMarginMarks` / `captionHead(of:)`: leading words
   of no letter or digit (or a lone Greek capital delta, which is how the triangle reaches the
   text layer) are skipped, and a mark glued to the word is cut; a bracket, a quote and a footnote
   marker are never marks. `TableExtractor.caption(of:)` reads the bold rule and the plain-page
   word limit from the first word after the marks; the figure stop in `layout` uses the same head;
   `ManualStructure.caption` (and its copy in `Scripts/extract-manual-text.swift`, self-checked)
   drops the marks before its pattern. Everything downstream reads labels, not line text.
2. **"(Concluded)" continues.** `continuedPattern` reads "concluded" (and "cont'd" / "continued"
   as now). A concluding piece with no grid joins the table it concludes and never stands in for
   it. Its notes join the table's notes where the reader already joins notes.
   **✅ Built.** `continuedPattern` reads "concluded". In `PDFTableReader.scan`, a continuing
   caption with no grid under it (too few rows, or no text) joins the last read table of its
   label — its notes (`TableExtractor.notes(under:words:)`) added when it is within two pages —
   and is otherwise left out when that table's own caption was kept unread; neither is a table or
   a failure (`Result.concludingPieces` counts them). The picture under it is still tried first,
   so a continuation whose rows are printed as a picture reads as before. A continuing caption
   with nothing before it is kept as before, and a continuation with rows merges as before.
3. **A folio that shares its footer line.** `PrintedPageBand` also takes a number at the outer end
   (first or last word) of a header or footer line. It is trusted for a document only when it runs
   in step with the physical page (a constant offset, held over a run of neighbouring pages), so a
   year or an edition number in the same footer is never read as a page. A lone-number line still
   wins as now.
   **✅ Built.** `PrintedPageBand.labels(bands:pdfLabels:)`, pure over each page's band text: the
   publisher's label, else a lone number (unchanged), else a number at a band line's first or last
   word whose offset from the physical page is held by a page within two either side and by at
   least three pages in the document; competing offsets go to the one more pages hold, a tie to
   none. `VaultDocumentExtractor.pageLabels(of:)` and the retrieval runner read through it. Every
   consumer (table pages, `manual_figure`'s printed page, `show_source`, `PageLabelMap`) reads the
   stored labels and is unchanged.
4. **"Show me" in a session with cited pages is not a camera turn.** While a Field Assist session
   is active and the last answer cited manual pages, a "show me / show the / open the" turn about
   a page, table, figure, row, source or passage does not trigger smart camera. Smart camera never
   starts the glasses capture while the glasses link is not connected (no frame, no 8-second
   permission attempts); the phone camera is not taken in its place without the wearer asking.
   The `look_closely` and `vision_assess` descriptions say a page open from a manual is read with
   the manual tools.
   **✅ Built.** `SmartCameraPolicy` (pure): with the last answer's citations in `ShowSourceCenter`
   for the active session (or the personal library's scope), a turn that puts a page, table,
   figure, row, source, passage, clause or diagram on screen ("show", "open", "bring up", "pull
   up", "go to", "highlight"), or a bare "show me (that)", takes no frame of any kind: routing
   (`expectsCameraImage`) and the grab (`smartCameraImageData`, cooldown follow-up included) both
   ask it first. Words naming the camera or the world in front ("in front of me", "look at",
   "what do you see") keep a camera turn. `smartCameraCapture` returns no image at once when
   `CameraService.isGlassesLinkUp()` is false (no phone swap), and its start now runs inside
   `CameraPermissionRequestPolicy.startedByApp`, so an automatic start never leaves for Meta AI.
   "Read the row on this page" is not covered: it names no show verb, and the model chose
   `look_closely` for it; the two descriptions now say a page open on the phone is read with
   `table_lookup` / `manual_lookup`. 4 tests in `SmartCameraPolicyTests`.
5. **Stale highlight.** Fix what finding 5 finds. `show_source` says which rows it marked.
   **✅ Built.** The sheet's identity is its citations plus what each page marks
   (`StagedFigure.marksKey`, `ManualFigureRequest.identity(of:)`), so other marks on the same page
   are a new sheet with a fresh controller; the same marks still do not blink it. The PDF viewer
   also re-marks when the passages it is handed change (`remarkCurrentPage`). `show_source` names
   the rows marked and those that could not be ("Marked on the page: row 7-9; row 10-12. Say only
   that these rows are highlighted.") from `TableRowPassage.rowName(ofSentence:)` and the locator,
   in place of the generic line. Tests: `TableLookupTests` (a between-rows lookup after a one-row
   one on the same page, end to end) and `ManualFigurePresentationTests`.
6. **Chains.** Unit words dropped from a size answer; an explicit stop message; `start` replaces
   a running chain; `start` refuses a chain whose tables cannot be read; `list` leads with names.
   **✅ Built.** `ChainRunner` retries a row lookup that found no row (not found, ambiguous, or a
   key read unclearly) once without the unit or size words no row key prints
   (`withoutSizeWords(_:keptBy:)`), taking the retry only when it finds the row; the read-back
   keeps what was said. A stop says the chain has ended and is not running, names the table of the
   step, and tells the model to ask for no more values and to 'start' it again only when asked.
   `start` with another chain running stops it (nothing recorded) and says both; the same chain
   again carries on and repeats its question; a chain whose tables are absent or unread
   (`RuleChainTool.unreadableTables`) is refused before anything starts, the unread table's page
   noted for `show_source`. `list` is the names, one per line, with short marks and a line to read
   them out (no "answers" text: the prompt carries it). Tests: 2 in `RuleChainTests`, 1 new and 3
   extended in `RuleChainSessionTests`, `ChainProposalSessionTests` updated for the list.
7. **Re-reading tables already imported.** The fix changes what is read from a PDF already in a
   vault, so the partner's vault must re-read its tables. P0 checks whether reindexing a manual
   (or re-importing the pack) re-reads them. If an automatic re-read on a reader change is small,
   it lands here; otherwise the release note tells the tester to reindex the code books, and an
   automatic re-read moves to P1.
   **✅ Built (automatic).** "Re-index manuals" and re-importing the same pack re-read nothing: the
   ledger skips a manual whose file hash is unchanged. The location migration already re-reads a
   stored manual's tables on launch when `DocumentStore.locationVersion` rises (JJ P1/P5, JN P1),
   so it goes to 7, and its tables-only path now also re-reads a PDF manual's printed page labels.
   The partner's vault re-reads both on the first launch of the new build, the text untouched. What
   it does not refresh is the passages' own figure names (the text is not re-chunked); a passage
   on a marked table's grid page is named for it only after the vault is removed and imported
   again. The table's row passages, which carry the label, are rewritten by the migration.

**Measurement (local only, never committed).** The private Mac runner reads the private book
before and after the fix. It reports, in counts only: captions found, tables extracted, pages with
a printed label, and the lookups that resolve on the partner's question set. The plan records the
counts, never a label, a title or a cell.

**What shipped (items 1, 2, 3, 7).** 21 new unit tests with invented fixtures (`Table 99` with a
margin mark on bold and one-weight pages, `Table 98A` concluded by a notes page, footers ending
"Example Standards Body N"): 11 in `TableExtractorTests`, 2 in `ManualStructureTests`, 7 in
`PassageLocationTests`, 1 in `TableStorageTests`. Measured on the private Mac copies, before →
after (counts only):

| Book | Captions found | Tables read | Captions not read | Pages with a printed label |
|---|---|---|---|---|
| Older edition | 161 → 172 | 77 → 88 | 84 → 84 | none → over 99% of pages |
| Newer edition | 139 → 179 | 56 → 87 | 83 → 92 | under 1% → over 99% of pages |

Every label read in both books has one offset from the physical page. One of the two tables of
finding 1 that never answered now reads, cited on its grid page with no second entry under its
label, the concluding page's notes joined. The other, and the two tables the conduit-fill chain
names, still did not read after P0: they needed the follow-up below. "Captions not read" rises in
the newer edition because marked captions the reader never saw are now counted, some over grids
the extractor still refuses (varying column counts, rows too few); those are P1 material, not
regressions. The lookups on the partner's question set were not re-run in P0.

**Follow-up (after P0).** A private re-measurement after P0 found three tables the partner needs
still unread, for two reasons the margin mark had hidden:

- *A one-weight page whose header the rule misread* (the second rating table). Its title wraps
  three lines with a long bracketed cross-reference under them, which the header rule read as
  prose; and its value columns are headed by quantities with a unit, printed on the same lines as
  a row-header heading wrapped over three lines, which read as rows of numbers. The body was looked
  for above the rows, and the caption failed for too few rows.
- *A landscape page the PDF turns to show* (both conduit-fill tables). In the page's own space
  every word of the table, its caption included, is on its side, so the caption was never seen.
  Read as shown, they also needed a first row printed mostly as dashes, a row of numbers heading
  the columns with words under it, a footer drawn the page's own way up beside the rows, and a text
  layer that lost the space between a row key and the dash beside it.

The fix is general: `PDFTableReader.positionedWords` reads a page with a `/Rotate` as it is shown
(`displayed`), marks the words still drawn the page's own way as `sideways` (left out of the lines
and of the rotated-headings reason), and cuts a word whose lost space the text layer split between
two letters (`cuts`); no picture is read on a turned page, since the region is drawn unturned.
`TableExtractor`'s one-weight header rule reads a bracketed line under a three-line title as part
of the title (`plainBracketMaximumLines`), passes up to two lines of headings printed as quantities
over rows of bare numbers (`pastUnitHeadings`), counts a dash for neither side of a row of
numbers, and reads a rising row of numbers with heading words under it as the columns' headings
(`numberedHeadingsAbove`); the body carries on past a wider space between bands of rows that print
in the same columns (`continuesBand`); and the section sign, double bar and pilcrow mark notes and
cells as the dagger does. 11 new tests in `TableExtractorTests`, all on invented fixtures
(`TableFixtureLayouts.quantityHeadings`, `numberedColumnHeadings`, `sparseFirstRow`, `bandedRows`,
and `turnedTable` drawn on a page turned a quarter). Measured privately, after P0 → after the
follow-up (counts only):

| Book | Captions found | Tables read | Captions not read |
|---|---|---|---|
| Older edition | 172 → 231 | 88 → 118 | 84 → 113 |
| Newer edition | 179 → 227 | 87 → 113 | 92 → 114 |

All three tables now read, in both editions, each with its rows on its grid page; no table that
read before stops reading. A few that read already change shape: header lines that had been
read as rows are dropped, and a first row printed mostly as dashes is kept. The new captions are all on turned pages, none of which was read before: about half of
them read (24 of 48 in the newer edition, 28 of 59 in the older), and most of the rest fail for
columns that do not agree — P1 material, not regressions. The lookups on the partner's question
set were not re-run.

### P1 — Partner pass and what P0 leaves

A build with P0 goes to the partner with the same three sessions. Then:

- reindex or re-import, then the two rating tables by number and in plain words;
- "open printed page N" and "find the table" land on the grid page;
- "show me the table" carries no camera event in the report;
- both chains that stopped run to a result;
- finding 7, if P0 did not explain it;
- an automatic re-read of a vault's tables on a reader change, if P0 deferred it.

### P1a — The open items (headless)

Three things the P0 round left open, each found in the partner's sessions or in the P0 write-up.
Invented fixtures only (`Table 99`, `Table 98`, made-up rows and wording).

1. **"Read … on this page" is not a camera turn, enforced.** After an answer opened a manual page,
   "read the row in the Rating B column on this page" sent the model to `look_closely` and then
   `vision_assess` — P0 only changed their descriptions.
   **✅ Built.** `SmartCameraPolicy.asksToReadManualPage`: a word that reads or asks for a value
   ("read", "what does … say", "look up", "value", "which", "find") with a page, table, row, column
   or cell is the manual's turn while the last answer cited pages or, new, while a manual page sheet
   is open on the phone (`Context.manualPageOnScreen`, read from `AppState.manualFigureRequest`).
   Camera words keep a camera turn, and so do words naming something physical in front of the
   wearer ("nameplate", "label", "gauge", "sticker", "screen"…), so "read this nameplate" and "read
   the table on this nameplate" still look. Smart camera takes no frame for such a turn (routing and
   grab, as for "show me"). The tools enforce it: `look_closely` and `vision_assess` ask
   `SmartCameraPolicy.cameraToolReply` before anything else, with the wearer's own words
   (`TurnUtteranceScope`, Direct mode) or, without them (a live session), the reason/note the model
   passed, and the same context (`AppState.smartCameraContext`, now shared); a manual-page turn
   returns a short reply pointing at `table_lookup` (table, row, column), `manual_lookup` and
   `show_source`, with no capture. 3 tests in `SmartCameraPolicyTests`, 2 in `LookCloselyToolTests`
   (no capture or injection for an open page; a nameplate is still captured), 2 in
   `VisionAssessToolTests`.
2. **Table values go through `table_lookup`; "show me" marks only the answer's rows.** A table
   question answered from the row passages in the turn's retrieved context made no lookup, so
   `show_source` fell back to every passage retrieved on the page — finding 7's "2 of the passages
   couldn't be marked".
   **✅ Built.** The passages block (per turn, and `manual_lookup`'s result) adds one sentence
   whenever it carries a `(table row …)` passage: a value from a table is read with `table_lookup`
   before it is said, never quoted from those (`VaultRetriever.tableRowRule`, about 200 characters,
   only on turns that retrieved a row). `AnswerSourceMemory` keeps each retrieved passage's figure
   and whether it is a row, and the Direct-mode answer's text; `marking(_:)` answers a table's
   citation that no lookup answered with that table's own passages only: the rows the answer names
   (every word of the row heading and one of the row's values, `TableRowPassage.values`), else every
   row of that table retrieved on the page, else the passages named for the table — never prose or
   another table's rows from the same page. `show_source` stages only the passages found on the
   page when some are (`ShowSourceTool.check`), so the sheet no longer counts unmarkable ones; the
   reply still names rows not marked, counts other passages not marked, and, for rows retrieved
   rather than looked up, says so and how to mark one row. A page-only citation is unchanged
   (finding 7's remaining question for the partner re-run). 5 tests in `ShowSourceTests`.
3. **Passages renamed on launch, without re-import.** P0's migration re-read tables and printed
   pages, not the passages' own names.
   **Measured, not shipped.** A rename on launch (a version-8 migration that re-reads each PDF
   manual's text with the current `ManualStructure` rules and rewrites only the chunks' section and
   figure names, no re-chunking, no re-embedding) was built and tested, then left out of the PR:
   on the partner's books it renames nothing (below), and it would have every phone re-read every
   PDF manual's text once on first launch. It is worth bringing back only for a vault whose captions
   are set in bold and carry a margin mark. Kept from that work: `VaultRetriever.sharingMostWords`
   typed step by step (it took seconds to type-check).

**Measured privately (counts only).** Both editions' text was extracted with the Mac extractor
before P0's caption rule and after it: identical in both books — neither prints a caption the
type rules read (no bold caption and no type-marked heading anywhere; under 80 pages in each read as
drawings). So the rename would rename **0 passages in each book** (none of the stored passages; none
named for a table before or after, and a fresh import would name 0 too). The re-import note in P0
item 7 does not apply to these books: their passages are found by the table route and the row
passages, not by a caption name.  A private set of three plain-words questions on one rating table (no
table number said), run through the retrieval eval over the newer edition with its tables read:
the table's passages are in the top four for 1 of 3 (one more in the top 30 but outranked, one not
in the top 30 — the one worded the way the partner asked). The rename would not change that: a passage's figure only ranks for a question that names its
table. Finding
a table from plain words alone stays open for P1; item 2 sends any value the model does find to
`table_lookup`.

### P1b — Finding a table from plain words (headless)

A technician asks for a tabulated value without the table's number. The row passages are mostly
numbers, so the passage search rarely brings the table's own rows; the words that tell one table
from another are in its title, its column and row-key headings and its units. Invented fixtures
only (widgets, housings, sprockets).

**✅ Built.** `TableDirectory` (pure) scores every read table of the searched manuals against the
question on those words alone: [[LexicalSupport]] content terms with "-ies" read as "-y" (a plural
title meets a singular question), a number with its unit as one term ("30 °C" = "30 degrees") and a
unit named on its own; each shared term weighed by how few of the tables print it (inverse document
frequency over the tables, scaled so a term only one table prints weighs 1 in a vault of any size),
a heading or unit word at 0.6 of a title word, and "table" itself left out. `candidates(for:in:)`
offers the best when it scores at least 0.65 with two or more shared terms, and the next when it
clears the same and scores at least 0.6 of the best — never more than two; each carries its score
and margin. A table continued under the same caption is one table. `TableReference.Entry` now
carries the document name and the headings (`init(table:documentName:)`); recognising a table a
question names still reads the label and title only, so retrieval is unchanged.

- **Per-turn hint.** `TableDirectory.asksForValue` (generic words: "how many/much/far/deep",
  "what size", "good for", "rating", "factor", "size", "maximum", "minimum", "fill", a number with
  a unit …) and no table named (`TableReference.references`) → `FieldSessionService.manualPassagesContext`
  appends one line after the passages: "Tables that may answer this: Table N — <title> (…); …. Read
  the value with table_lookup (table, row, column), and ask the technician for any input the table
  needs." Titles lose a trailing "(See …)" cross-reference and are cut at 90 characters on a word;
  the document is named only when the tables come from more than one. Nothing when no table clears
  the threshold. The catalogue is read only for a value question.
- **`table_lookup` by words.** A `table` given as words resolves through the same score
  (`TableLookup.byTitle`): the best table, or the existing ambiguous outcome listing every table
  within 0.9 of the best; words the score cannot weigh (short words, bare numbers) fall back to the
  old shared-title-word count. The tool description is unchanged.

11 tests in `TableDirectoryTests` (ranking, threshold and margin, plural/unit folding, continued
captions, the value detector, hint format and length, the document named only for several books,
no hint for a named table / a non-value turn / nothing fitting, title shortening, lookup by words
and its ambiguity) and 1 in `TableLookupTests` (the hint in the per-turn block of a session, absent
for a named table and a non-value turn).

**Measured privately (counts only)** over the newer edition with its tables read (113 of 227
captions), questions written privately the way an electrician asks:

| Set | Questions | Passages carry the table, top four (before) | Directory: first / top two (after) | Hint names it | Hint fires |
|---|---|---|---|---|---|
| New plain-words set (13 tables) | 14 | 11 | 11 / 12 | 12 | 14 of 14 |
| Earlier table-cells set, no table named | 26 | 15 | 21 / 23 | 23 | 25 of 26 |
| P1a's three questions | 3 | 1 | 2 / 3 | 3 | 3 of 3 |

"Passages carry the table" is the retrieval eval's hit@4: a passage printing the table's label,
prose that cites it included — so it overstates what the model is handed of the table itself. The
hint fires on none of the 5 questions that are not table questions (one reads as a value question;
no table clears the threshold) and on none of the 13 that name a table (6 new, 7 earlier). It
averages about 300 characters. The misses are tables whose titles barely describe them (a factor
table titled after the tables it corrects) or a neighbouring table whose title shares the question's
words. Retrieval is unchanged by construction (the hint is appended after the passages; recognising
a named table reads the title only), and the retrieval eval agrees: the code book's answer key (66 scored), the three sets above and the 13 questions naming a table give the same hit@1 and hit@4 before and after (66: 26 / 35). Not measured: a
model's turn end to end, or `table_lookup` with words a model would pass.

**Both editions loaded** (as the partner's vault has them): at first the same table's other edition
took the second place, and the hint named the expected table for 11 of the 14 new questions. Two
editions are now one candidate per label, naming every edition that prints it, and the hint names
the expected table for 12 of 14, the same as with one edition (P1a's three: 3 of 3). It averages
about 350 characters with the editions named. One test in `TableDirectoryTests` covers it.

## Owner decisions taken (reversible)

- **`start` replaces a running chain** rather than refusing. The technician named the chain; the
  replaced chain records nothing, exactly like `stop`.
- **A chain whose tables cannot be read does not start.** Asking the technician three questions
  and then stopping is worse than saying up front which table is missing and offering its page.

## Privacy and licensed material

Fixtures use invented labels, values and wording. No table number, value, page number or phrase
from the partner's book appears in code, tests, this plan or the PR. Logs stay counts only.
