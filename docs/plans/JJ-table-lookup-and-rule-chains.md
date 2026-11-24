# Plan JJ — Table Lookup and Rule Chains (a cell from the book, and the rules that use it, chained)

**Status:** ✅ every phase built, P5 added and built 2026-10-21 (draft PR); the device checks owed are named under P4. P0 shipped 2026-10-20: a captioned table in an organisation's own loaded PDF is
extracted at import into rows, header paths, cells (number, unit, footnote markers) and notes,
stored beside the document's passages, and each row is searchable as a passage; stored manuals get
their tables by the location migration. Measured privately on the loaded test book's PDF: 94
captioned tables found, 33 extracted to a grid (0.35), 51 with too few rows, 8 with varying
column counts, 2 with merged cells (see "What shipped in P0"). 🚧 P1 built 2026-10-20 (draft
PR): `table_lookup` returns one cell with its headers, units, notes and printed page, both rows
when a number falls between them, and a question back when the words fit more than one row,
column, table or book; a question naming a table ranks that table first; "show me the table"
opens the cited page with the row marked. Measured privately: row passages cost the code book one
question (hit@1 / hit@4 0.39 / 0.56 → 0.38 / 0.55), all of it through the table route; cell
correctness not yet measured (see "What shipped in P1"). 🚧 P2 built 2026-10-20 (draft PR): an
organisation writes rule chains in its vault's `chains.md` — `ask`, `lookup` (row or cell, rule
`exact`, `at_least` or `at_most`), `calc`, `convert`, `check`, `cite`, `say` — checked line by line
at import, with a chain naming a table the vault lacks warned of and kept; `rule_chain` runs one
step at a time with the current question in the prompt, stops at a step it cannot complete with
the page to show, and files the read-back, a citation per step, on the job as a reading; cable
sizing both ways and voltage drop ship as the invented example (see "What shipped in P2"). 🚧 P3
built 2026-10-20 (draft PR): for a question no authored chain answers, the model retrieves the
clauses and proposes a chain in the P2 syntax with `propose_chain`, checked against the passages
retrieved on the job (a `cite` on every lookup and check, every lookup's passage one that was
retrieved, every cited rule printed in one) and read back for go, a changed step, or stop; it runs
through the same runner and files its read-back marked "proposed, unreviewed"; one that ran to a
result is kept **on the phone** first, offered there only, shared by the share sheet as a
`chains.md` fragment with no office needed, and also filed for review through the team-learning
bundle when the organisation has the office app; a running chain survives a relaunch; a table named by title words now needs the
whole title, which brings the code book's key back to hit@1 / hit@4 0.39 / 0.56 (see "What
shipped in P3"). ✅ P4 built 2026-10-21 (draft PR): an electrical starter vault, bundled and offered
like the other starters and importable as a template once an organisation adds its own code PDFs,
ships safety rules, empty fault-code and parts files and a `chains.md` holding the schema and the
guide's invented example, and no standard's text, table or rule; voltage drop is `domain_calc`'s
electrical domain (single- and three-phase, metric and imperial, resistance or factor supplied,
never assumed) and a chain `calc` with `sqrt( )` reaches the same number; `Scripts/chains-validate/`
checks a vault's chains against its own PDFs' tables. Run on the partner's test vault: 11 chains,
0 problems, 43 lookups of which 4 reach a read table (see "What shipped in P4"). Owed on a device:
the starter offered and chosen, voltage drop by voice in both unit systems, the trade split, and
the partner's chains imported and run to a read-back. ✅ P5 built 2026-10-21 (draft PR): labels
keep a letter beside the number ("Table 95A", "Table Q7") in the extractor, the passages and the
lookup; a table carried onto a page with no caption, cells that are marks, groups side by side,
headings stacked deep or printed as numbers, a list of tables and a caption at a page's foot are
read; a table printed with no text is said to be one; a chain's column or row is matched by its
words, units aside, or a printed range. Designed from an anonymised shape report and measured
privately: 70 → 133 captions read to a grid on the partner's two PDFs, and of the chains' 43
lookups 4 → 16 on a read table and 0 → 15 resolving throughout; the code book's key at hit@1 /
hit@4 0.39 / 0.56 → 0.39 / 0.58 (see "What shipped in P5").
Decisions confirmed 2026-10-20. Field Assist first; every phase is a headless core with the live
edge last. Written for the partner's electricians, whose stated priority
after the first round of code-book testing is **table lookup**: "those tables contain much of the
information electricians actually need", with cable sizing as the example — select a conductor for a
load and an installation, or check whether an existing cable's size and type are right — which "can
require tables and several rules together". The same partner also said testers cannot be expected to
know which rule applies or how to split a question: finding that is part of the assistant's value.

## Why a separate plan

Plan IN made a code book's **clauses** findable and showable: a clause chunked as one rule, found by
its number, cited, and opened on the page with the passage marked. Plan IV measured and tuned how
clause passages rank. Neither touched **tables**, and the first field reports show why that matters:

- **A table page is a picture to the retriever.** `ManualStructure` tags a page of labels and
  numbers as a drawing (`<!-- page: diagram -->`), and a `TABLE N` caption names it, so the page can
  be *shown* on request and even auto-opened. But the words sent to the model are PDFKit's
  flattened run of cells with no rows and no columns, so "what is the rating of this conductor in
  that column" cannot be answered from it, and what the model does answer is read off a jumble.
- **A cell is not a passage.** The embedder ranks a flattened table low against a question about
  one of its cells; the exact-token route finds a number only when the question says it (and a job
  number once opened a vent-length table because one cell held it — `ManualTurnScope`).
- **Nothing chains.** Cable sizing is a sequence: a load, a correction or two from other tables, a
  rule that says which rating column applies, a lookup, and a check. Today each step is a separate
  question the technician has to know to ask, and the answer to one is never carried into the next.
- **The answer must stay verifiable.** Plan IN's acceptance — the technician hears the answer with its
  source and can open the page — has to hold for a table cell (which table, which row, which column,
  which note) and for every step of a chain.

This plan gives the app tables as data it extracted from the organisation's own loaded copy, a
lookup that returns a cell with its provenance, and chains of lookups and arithmetic that run step by
step, read back, and cite. It ships no table content, no rule content and no code text, for the same
reason Plan IN decision 6 ships no standard: the organisation loads its own licensed copy.

## Verified starting point (`main` @ `79d563bd4`, 2026-10-20)

- **Extraction keeps pages and type, not positions.** `VaultDocumentExtractor` extracts each PDF
  page, joins them with a form feed, and reads printed page labels. `ManualStructure.TypedLine`
  carries `raw`, `text`, `size` and `bold` per line — enough to find headings and captions, not
  enough to know which column a word sits in. `ManualStructure.caption` recognises `FIGURE N` and
  `TABLE N` captions and `render` hoists the page's caption to name a drawing page.
- **Chunks have a kind and a figure, not a shape.** `DocumentChunker.Chunk` is `prose` or `diagram`,
  with `figure` ("Table 16") when a caption names its place. A table's cells are chunk text like any
  other, overlapped and sentence-packed. There is no table row anywhere in `DocumentStore`.
- **Clause-numbered documents are detected and chunked at each clause** (IV P3,
  `DocumentChunker.clauseHeadingLines`), and a clause is found by its printed number ahead of the
  token and semantic routes (IN P3a, `ClauseReference`, `DocumentStore.passages(clause:)`).
  `ManualPassageLimit` hands the model six passages when the best one is a clause.
- **Showing a page.** `show_source` resolves "show me" against the last answer's citations;
  `manual_figure` opens a figure or a page; `FigureAutoOpenPolicy` opens a captioned page when the
  technician asks for a page, figure, diagram or table by word, and only attaches it to the model
  otherwise (`.tableNotAskedFor`). `PassageHighlight` marks a located passage; a drawing page is
  never highlighted.
- **Arithmetic exists, chaining does not.** `calculate` evaluates an expression; `convert_units`
  converts; `domain_calc` reads bundled refrigerant saturation tables generated by a script and
  checked in (Plan IS P0) — the one precedent for a table the app answers from, and the precedent
  that a shipped table must be generated from a source the app may ship. Nothing runs a sequence of
  steps, carries a value from one to the next, or reads a chain back.
- **Electrical vault.** `VaultManifest` knows the trade `electrical`; no electrical vault template,
  calculator or standard-kind handling exists. IN P3 (the `standard` document kind, printed-page
  citations, the answer rules for a standard, the starter electrical vault with a voltage-drop
  calculator) is drafted and unbuilt. JG (regulation practice) and JI (apprentice support) are
  drafted and reuse the vault's own copy of the code the same way this plan does.
- **Licensed material is testing-only.** The partner-supplied code books never enter the repo;
  retrieval was measured against a private answer key on a Mac runner (Plan IV) and reported as
  aggregates. Every fixture in this plan is invented, with invented table numbers, designations and
  values, and nothing in a test, comment or plan is a fact from a book.

## Decisions (confirmed 2026-10-20)

1. **Tables are extracted on the phone from the organisation's own loaded PDF, at import.** The app
   ships a table extractor and no tables. A vault pack, export, bundle or link never carries an
   extracted table of a `standard` or a manual, exactly as it never carries the document
   (IN decision 6, Plan EG).
2. **A lookup returns a cell with its provenance, and never decides a rule.** `table_lookup` gives
   the cell at a row and column with the table's caption and title, the row's and column's full
   header path, the units, and the notes the cell or its column references. When the asked value
   falls between rows it returns both bracketing rows and says so; it never interpolates, never
   rounds, and never picks "the next size up" on its own. Which row a rule wants — at least, at
   most, exact — is a chain step's parameter or the technician's call, said out loud.
3. **Rule chains are authored in the vault, not in the app.** A chain is a short declarative
   sequence in a vault core file (`chains.md`): inputs to ask for, lookups by table and header,
   arithmetic, a comparison, what to say. The organisation writes chains against the table and
   rule numbers of *its* code and edition, so the app stays jurisdiction-neutral and ships no rule.
   The app ships the schema, the runner and an invented example. The partner's chains are written
   for the partner's testing by the owner, outside the repo, like the test books themselves.
4. **The model may propose a chain; only the technician runs one.** For a question with no
   authored chain, the model retrieves the clauses (IN/IV) and proposes the steps it reads there
   — which tables, which corrections, which rule picks the column. The technician hears the
   proposal and says go, changes a step, or stops. A proposed chain runs through the same runner,
   reads back the same way, and can be kept for the organisation through the team-learning path
   (Plan FP) where it is reviewed before anyone else sees it. A chain is never run silently.
5. **Every chain answer is read back step by step with a citation per step.** Inputs as heard,
   each lookup as "Table 99, row QXRT, column for the third rating group: 40 — page 12", each
   arithmetic step with its numbers, the comparison, the result. A step whose table could not be
   extracted stops the chain, says so, and shows the page; it never continues from a guessed cell.
   The read-back goes on the job record like a reading.
6. **Cable sizing is the first chain family, both ways.** Forward: a load and an installation to a
   conductor size and type. Inverse: an existing cable's size and type to whether it carries the
   load. Voltage drop is the arithmetic step (IN P3's calculator line moves here). Nothing about
   which corrections a jurisdiction applies is in the app; the chain says.
7. **Table questions run on a cloud or local model.** Following PR 801, a job turn never runs on
   Apple's on-device model when another configuration exists. `table_lookup` is small enough for
   the on-device set and is offered there; chains are not.
8. **One exception to "ships no table": voltage drop by wire gauge (owner, 2026-11-23, Plan MQ
   P3).** A small on-device model can't turn "14 gauge copper" into an area or a resistance, so
   `voltage_drop` takes `wire_awg` (18 to 4/0), or `area_mm2`, with `material` (copper or
   aluminum). The figures ship as electrical trade reference data, like the refrigerant tables:
   `Resources/Electrical/conductors.json` (`ConductorTable`) carries the standard AWG areas in
   circular mils (a gauge's definition, not a code's table) and each metal's factor with its
   temperature, 12.9 and 21.2 Ω·cmil/ft and 0.02097 and 0.03453 Ω·mm²/m (the IEC 60028 and IEC
   60889 resistivities at 20 °C, corrected to 75 °C), credited in Attributions. A file that does
   not load refuses the path and asks for the figures, never falls back to constants. The metal is
   never assumed. The answer names the figures and their source and says a figure from the
   organisation's own book wins, and a resistance, factor or area the technician gives wins over
   them. The vault's `conductors.md` points the model at `domain_calc`, never memory. No other
   table, rule or code constant ships.

## Phases (one PR each)

### P0 — A table as data (headless core) ✅ (2026-10-20)

- **Positioned text.** `VaultDocumentExtractor` gains, for each page, the words with their
  bounds (`PDFPage.characterBounds(at:)` over the page's attributed string, grouped into words and
  lines), kept only long enough to extract tables; chunk text and stored passages are unchanged.
  A page with no text layer (a scanned book, or Plan IF's photographed pages) yields nothing here
  and is reported as such.
- **`TableExtractor` (pure).** Input: a page's typed lines and positioned words, and the caption
  `ManualStructure` found. Output: a `ManualTable` — `label` ("Table 99"), `title`, `page` (physical
  and printed, IN P0's labels), `columns` as a header tree (a group heading over several columns
  becomes a path, "Rating group 2 › 75"), `rows` as a header path too (a row's first cell, plus a
  group row above it), `cells` as text with a parsed number and unit where one parses, `notes`
  (footnote markers and the note text found under the table), and `continuedFrom` when the caption
  reads "(Continued)". Column boundaries come from clustering word x-origins across the body rows;
  header rows are the lines between the caption and the first body row; a row is the words that
  share a baseline. A page that does not resolve to a consistent grid (fewer than three rows, or
  columns that change count row to row) extracts nothing, so a wiring diagram with numbers on it
  is never a table.
- **Continued tables merge** by label across consecutive pages into one `ManualTable` with the
  first page's headers, each row keeping its own page.
- **Storage.** `DocumentStore` gains a `doc_tables` row per table (document id, label, JSON of the
  table), written at import with the chunks and re-extracted by the location migration
  (`locationVersion` 2 → 3) for stored vault documents, under the same document id. Tables are
  excluded from `VaultExporter` and every pack, bundle and link, alongside the document.
- **Row passages for retrieval.** Each body row is also rendered as one sentence ("Table 99
  (Conductor ratings), row QXRT, three conductors: 30 in rating group 1, 35 in rating group 2, 40
  in rating group 3 — page 12") and stored as a chunk of a new kind `.tableRow` with `figure` set,
  so the embedder and BM25F can find a cell by its row header and the token route by its label.
  Row passages are capped per table and never auto-open a page (they are not drawings).
- **Exit tests (invented fixtures):** a simple grid extracts with the right headers and cells; a
  two-level column header gives the right paths; a table continued over two pages merges with each
  row's page; footnote markers attach to cells and the note text is kept; a table with units in the
  header parses numbers; a drawing page with numbers extracts nothing; a page with a caption but no
  grid extracts nothing and says so; row passages render and chunk as `.tableRow`; export omits
  tables. Measured privately on the loaded test book and reported as aggregates: the share of
  captioned tables that extract to a consistent grid, by table, with the failures classified
  (merged cells, rotated headers, no text layer).

#### What shipped in P0 (2026-10-20)

- **Positioned words, only where a table is.** `PDFTableReader` reads a page's words with their
  boxes from PDFKit (`PDFPage.selection(for:)` over each run of non-space characters in the page's
  string, cut where the type size changes so a raised footnote digit stays apart from its number),
  and only for a page whose text mentions a table. `characterBounds(at:)` was tried first and
  dropped: its index does not count the newlines PDFKit's own string contains, so boxes drift a
  character per line. Positions live only while the page is read. `VaultDocumentExtractor.extract`
  is untouched, so chunk text, page separators and labels are byte-for-byte what they were. The
  reader builds on macOS too, so a measurement reads a PDF exactly as an import does.
- **`TableExtractor` (pure, `Sources/Services/Vault/`).** Positioned words and a page in, one
  outcome per caption out: a `ManualTable` or a `Failure` (`no_text_layer`, `caption_not_found`,
  `too_few_rows`, `varying_column_count`, `merged_cells`, `rotated_headers`). The caption is read
  off the positioned lines, which replaces the typed-lines input the bullet above names. On a
  page that sets anything in bold it is the rule `ManualStructure.caption` applies to typed lines
  (bold, `TABLE N`), so every caption that names a chunk's `figure` is a caption here with the
  same label (a test holds that one direction). On a page whose text layer carries no bold at all
  — the loaded code book is set in one font, with no weight anywhere in its text layer — the
  caption is a line that begins `Table N` in any case and stands on its own: at most twelve
  words, no sentence ended before the last. The grid that must follow keeps a short prose line
  beginning with a table reference from extracting anything. `ManualStructure.caption` is
  unchanged: it names passages and decides which pages open, as Plan IV measured. The header is
  the leading run of bold lines under the caption and its title. On a plain page it is the lines
  before the first row whose cells after the first are mostly numbers (at most four), after up to
  three single-phrase lines of a long title that wrapped under the caption. The body runs until a
  note, a paragraph or a wide gap. Columns are the union of the body cells' horizontal extents over the rows with the
  modal cell count, and must come out as many as those rows have cells. More than 15 % of rows
  off the grid refuses the page. A header phrase heads the columns whose centres fall in its
  region (its extent widened symmetrically to the midpoint with its neighbours), which makes a
  group heading a path level ("Rating group 2 › Band B"). Leading text-only columns are row headers,
  and a row header printed once is carried down to the rows that leave it blank. A single phrase
  alone at the left heads a row group. Cells keep their printed text and parse a number (decimal
  comma, thousands separator, typeset minus) and a unit, their own or their column's bracketed
  one. Markers (`*`, daggers, raised digits, `(a)`) are kept on the cell, and notes under the
  table are kept with their markers. A "(Continued)" caption merges into the previous page's table
  of the same label when the column count agrees, each row keeping its own page. A continuation
  with nothing before it stays marked `continues`.
- **Storage.** `doc_tables` (document id, index, label, pages, the table as JSON) is written at
  import beside the chunks. `forget`, the checked forget, `clear(namespace:)` and `clearAll` take
  it. The tables come from the document when it is a PDF, else from the original a text import
  was made from when the vault carries it; with neither, the import logs `tables_no_pdf` and goes
  on. `locationVersion` 2 → 3: `PassageLocationMigration` reads the same PDF for stored vault
  documents and adds their tables through `DocumentStore.replaceTables`. Text chunks are compared
  without the row passages and only re-located when unchanged, so their ids, text and embeddings
  stay as they were. A recognised manual is still left alone.
- **Never leaves the phone.** Tables live only in the document store, which no export, pack,
  bundle or link path reads. A test imports a vault with a table, exports it and finds none of its
  values in any exported file, and a source scan holds the exporter and the pack, link, archive
  and publisher files away from the table types.
- **Row passages.** `TableRowPassage` renders each body row as one sentence ("Table 99 (Conductor
  ratings), row QXRT, three conductors: 30 in Rating group 1, 35 in Rating group 2, 40 in Rating
  group 3 — page 12", the printed page when known). Each is stored as a chunk of the new
  `DocumentChunker.Kind.tableRow` (`table_row`) with `figure` set, numbered after the document's
  own text and embedded the normal way, at most 400 per table, with what the cap left out logged
  as a count. The rows are searched by the token route (as before, all kinds), and also by
  `query` and `passages(sharingTermsWith:)`, whose default kinds are now prose and table rows.
  They are left out of the document's own text (`fullText`, `pageTexts`, the stored text the
  clause and back-of-book detectors read). They cite their table ("Manual, page 12, Table 99"),
  and the model is told "(table row, Table 99, page 12)". `FigureAutoOpenPolicy` gains
  `PassageKind.tableRow`: attached to the model on a question, opened only when the technician
  asks for the page, never by a number. `ManualPassageLimit` is unchanged.
- **Tests (37, invented fixtures).** `TableExtractorTests` (26): a simple grid, a two-level
  header, units in the header and in a cell, footnotes and notes, a continued table merged (and a
  lone continuation kept apart), a figure drawing, a drawing under a table caption, a caption over
  prose, an empty page, merged cells refused, every `ManualStructure` table caption being an
  extractor caption, cell parsing, row sentences and the cap, JSON round trip. On a page with no
  bold: a plain caption over a grid extracts, a wrapped title is read as the title, the same
  caption line on a page with bold elsewhere is not a caption, and prose beginning "Table 95
  shows …" extracts nothing. The PDF
  tests draw the same layouts into a real PDF and read them through PDFKit: printed page labels,
  a merge across two PDF pages, raised footnote digits, a scanned page counted as having no
  text layer, and a PDF whose text layer has no bold. `TableStorageTests` (11): stored at ingest after the text, found by token, figure,
  terms and query, capped with the table kept whole, forgotten and cleared, migrated without
  touching the text chunks (and a second launch idle), read from a text import's original, a
  text-only import skipped, imported then exported with no value in the export, the source scan,
  the auto-open policy, and the citation.
- **Measured privately** with `Scripts/table-extract-eval/` on the loaded test book's PDF
  (aggregates only; the runner compiles `PDFTableReader` and `TableExtractor` unchanged and prints
  nothing from inside a table):

  | | bold caption rule only | plain captions | plain captions + wrapped titles (shipped) |
  |---|---|---|---|
  | Captioned tables found | 0 | 94 | 94 |
  | Extracted to a consistent grid | 0 | 7 (0.07) | **33 (0.35)** |
  | Too few rows | — | 79 | 51 |
  | Varying column count | — | 7 | 8 |
  | Merged cells | — | 1 | 2 |
  | Rotated headers / no text layer | — | 0 / 0 | 0 / 0 |
  | Pages without a text layer | 0 | 0 | 0 |

  Of the 33: median 7 rows (max 23), median 2 value columns (max 9), 15 with notes, none
  continued over pages, 0.83 of filled cells numeric, about 14 s for the whole book on a Mac.
  The book's text layer is set in one font and carries no bold, so the bold rule alone found
  nothing. The remaining failures are mostly "too few rows". The runner does not say why a body
  ended early, so the next lever is a counts-only breakdown of where each body stopped. A vault
  that carries the code book only as extracted text (the test copy first measured was one) gets
  no tables until its original PDF is beside it.
- **Not known yet.** Whether the 33 grids are right. A consistent grid is not a correct one, and
  checking that needs an answer key of cells, which P1's measurement adds. The row passages add
  candidates to every manual search in a vault with tables; their effect on IV's code-book
  numbers is not yet measured.
  "Show me" on a row passage opens its page unmarked ("The passage couldn't be marked on this
  page."), because the row sentence is the app's text, not the page's. Marking the row is P1.

### P1 — `table_lookup`, and "show me the table" 🚧 (built 2026-10-20, draft PR)

- **`table_lookup` tool.** Arguments: `table` (label or title words), `row` (a header value or
  the words of one), `column` (a header path or words of one), and optionally `document`. It
  resolves the table by label first and title words second, the row by exact header then number
  then nearest words, the column by path; it returns the cell with its row and column paths, units,
  the notes it references, and the citation (document, table, printed page). With a numeric row
  key between two rows it returns both and says "between"; with an ambiguous row or column it lists
  the candidates and asks, never guessing. A result is a `Citation` the chips can open.
- **Retrieval.** A question that names a table ("table 99", "the ratings table") takes the lookup
  route ahead of the clause route, the way a clause number does; a question that names a row header
  value reaches the row passage. `ManualPassageLimit` treats a table row as a clause for the limit.
- **Showing it.** `show_source` resolves "show me the table" against the last answer's table
  citation; the page opens and `PassageHighlight` marks the row's text when it is located on the
  page (IN decision 3: found, never guessed; a rotated or image table opens unmarked with the plain
  line). `FigureAutoOpenPolicy` is unchanged.
- **Exit tests:** lookup by label, by title words, by row number, by row words; between-rows
  returns both; ambiguity asks; the citation opens the right table in the right document when two
  books are loaded; a question naming a table ranks the lookup first; an on-device profile offers
  `table_lookup` and not `rule_chain`. Measured privately: a set of single-cell questions on the
  loaded book, answered from the cell with the right citation, as a rate.

#### What shipped in P1 (2026-10-20)

- **`TableLookup` (pure, `Sources/Services/Vault/`).** The stored tables in, one outcome out:
  `found` (the rows and columns read, with `between` set when an asked number fell between two
  rows), `ambiguous` (document, table, row or column, with the candidates to say), `notFound` (with
  what does exist), `notExtracted` (a caption whose grid could not be read, with its page) or
  `noTables`. The table resolves by label ("Table 99", "tbl 99", "table ninety-nine", "No. 99"),
  then by title words; the same label in two books asks which book. The column resolves by its
  path or the end of it ("Band B" under one group), then by words, every number in the words
  having to be in the heading. The row resolves by its header or a run of its headers ("QXRT three
  conductors"), then by number (a numeric key equal to it, or a printed range holding it, "8" in
  "7-9"; else the two rows either side, said as "between"; outside the rows, the range they run
  over), then by its nearest words. Without a column the whole row is read, unless the table has
  one value column. The notes are those a marker on the cell, its row's headers or its column's
  headings keys, and the table's unmarked notes. Nothing is interpolated, rounded or moved to a
  neighbouring row; the rendered text says so, and ends with a `Source:` line in the form
  `VaultRetriever` writes ("Book, page 12 (printed 10), Table 99"), which `CitationLineParser`
  reads into a chip for that table's page in that book. Pages are said by their printed number, else
  as "PDF page N".
- **Unreadable captions are kept.** `ManualTable.failure`: a caption whose page did not resolve
  to a grid is stored by its label, title and page (`PDFTableReader.Result.unextracted`), so a
  lookup says the table is there and could not be read, and names the page to show. Location
  version 3 → 4: a document version 3 already located only has its tables read again; its text,
  ids and embeddings are untouched.
- **`table_lookup` tool** (`NativeTools/TableLookupTool.swift`): registered, in
  `FieldToolProfile.names` and `AppleOnDeviceToolSet.fieldAssistPriority` (decision 7), a read in
  `ToolEffectClassification`, local in `OfflineToolPolicy`, titled in `ActivityTitler`. It reads
  the vault's manuals still in the vault, newest edition unless the words reach past it or a book is
  named, and notes what it cited for "show me the table".
- **Retrieval.** `TableReference` (pure) recognises a table a question names by number, printed,
  abbreviated or spoken, or by its title words when the question says "table" and one title fits
  best; "table saw", "timetable 9", "TBL99X" and "table 99X" are not references. `VaultRetriever`
  has a table route (`DocumentStore.passages(table:)`: the table's row passages, else the page of a
  caption that could not be read) and ranks a named table's passages above the clause groups, its
  rows before its page. A row key printed as a range ("7-9") was split at the dash by the tokenizer
  and never searched; `CodeTokenizer.rangeKeys` keeps it whole and it counts, like a designation,
  only when the manuals print it. A designation ("QXRT") already reached its row. `ManualPassageLimit`
  asks for six when a searched manual has table rows and keeps six when the best passage is a row.
- **Showing it.** `show_source` takes "table", "the tables" and a table label against the last
  answer's citations. A table row's anchor carries the row as printed (`TableRowPassage.printedRuns`),
  and `PassageLocator` marks the first run found exactly once on the page, as the same words; a row
  printed twice, or not found, opens its page unmarked with the existing plain line.
  `FigureAutoOpenPolicy` is as P0 left it.
- **Tests (invented fixtures; the exit tests committed before any run on licensed material, the table of words added after the counts-only breakdown below).** `TableLookupTests`
  (21) and `TableLookupSessionTests` (5): lookup by label, spoken and abbreviated label, title words,
  row number, a range holding the number, row words; between rows returns both and prints no other
  value; ambiguity asks for the row, the column and the book; an unread table names its page;
  `TableReference` recognition and non-matches; range keys; row marking (once, never twice, same
  words); the passage limit; the on-device set offers `table_lookup` and not `rule_chain`, and its
  definition fits beside `field_session`; and, over two invented books both printing a Table 99,
  the citation opens the right table in the right book, "show me the table" marks that row and
  not the one above, a question naming a table ranks it first (by number, by title words, spoken),
  a row header reaches its row, and the migration keeps the unread caption without touching the
  text.
- **Measured privately** (aggregates only), the code book's newest-edition answer key (66 scorable
  questions) on the contextual model, the PDF-backed vault indexed by the Mac runner, which now
  reads a PDF's text and tables as an import does (`RETRIEVAL_EVAL_TABLE_ROWS` = `0`, `1`, `token`,
  `table`):

  | Row passages | hit@1 | hit@4 | as sent | in-scope refused |
  |---|---|---|---|---|
  | Excluded (as before P0) | 0.39 | 0.56 | 0.61 | 0 |
  | Included, every route (shipped) | 0.38 | 0.55 | 0.59 | 0 |
  | Token and table routes only | 0.38 | 0.55 | 0.59 | 0 |
  | Table route only | 0.38 | 0.55 | 0.59 | 0 |
  | Plan IV P7, for reference | 0.39 | 0.56 | 0.61 | 0 |

  One question is lost, and it is the table route's: one question in the key names a table, by its
  title words; it hits with the route off and misses with it on. Keeping the rows out of the
  semantic default changes nothing, so they are not gated there. Ranking a title-word table with
  the token hits rather than above them was tried and did not bring the question back, so it was
  not kept. The cost is one question of 66 against a tool and a route a technician can now use by
  table number.
- **Too few rows, broken down** (`Scripts/table-extract-eval/`, counts only, on the 2024 PDF): of
  51 captions with too few rows, 35 read no body row of two or more cells, 13 one and 3 two; 30
  have no run of three such lines anywhere under the caption, 16 have one within seven lines and 5
  further down; of the 21 runs, 18 are text in the first cell of every row and 13 text in every
  cell. The general shape that was being refused, a table of words on a page set in one weight
  (no row of numbers to find its body by), is now read: the first run of rows heads the grid with
  its first line, and in a table of words only the first column heads the rows. Before → after:
  extracted 33 → 35, too few rows 51 → 45, varying column count 8 → 12, merged cells 2 → 2. The 30
  with no run of rows at all (cells that set close enough to read as one phrase, or rows that wrap)
  are the next lever and are not addressed.
- **Not known yet.** Whether the cells are right. A starter answer key of cells was written beside
  the book for the partner's electrician to check, and is unchecked; P1 does not score against it,
  and the rate of single-cell questions answered from the right cell is owed once it is checked.

### P2 — Rule chains, authored 🚧 (built 2026-10-20, draft PR)

- **`chains.md` in the vault.** Each chain is a heading with a short declarative body: `ask` steps
  (what to ask the technician, with units and plausible range), `lookup` steps (table by label,
  row and column from earlier values, and the row rule: `exact`, `at_least`, `at_most`), `calc`
  steps (an expression over named values, with units), `convert` steps, `check` steps (a
  comparison with what to say either way), `cite` lines naming the rule each step follows, and
  `say` for the result. The vault validator checks the schema and that every table a chain names
  exists in the vault's extracted tables, and reports the ones that don't at import.
- **`ChainRunner` (pure).** Runs one step at a time over a `ChainState` (values with units and
  provenance), returning what to ask or say next; a lookup step calls the P1 resolver with the row
  rule applied; a `calc` step uses `calculate`'s evaluator; a `check` step records the verdict. It
  never continues past a step it could not complete, and every value it holds knows which step
  made it and from which cell.
- **`rule_chain` tool.** `list` (chains the vault offers, by what they answer), `start`, `answer`
  (the technician's reply to an `ask`), `status`, `stop`. The current step and what it needs are in
  the system prompt the way the active procedure is (`procedure_runner`), so the model asks in its
  own words and the runner keeps the state. A chain started on a job records its read-back on the
  job as a reading with every citation.
- **Cable sizing, both ways, as the shipped example** over invented tables (Table 99 conductor
  ratings with rating groups, Table 98 correction factors) in the test vault: the forward chain
  and the inverse check, the voltage-drop `calc` step, and a `check` that says "carries it" or
  "does not carry it, the next row is …".
- **Exit tests:** the schema round-trips; a chain over the fixture tables runs forward to the
  expected size and inverse to the expected verdict; `at_least` and `at_most` pick the right rows;
  a missing table stops the chain with the page shown; the read-back names every step with its
  citation; a chain that names a table the vault lacks is reported at import.

#### What shipped in P2 (2026-10-20)

- **`chains.md` (`ChainDefinition`, `ChainParser`, `VaultChains`, `Sources/Services/Vault/`).** A core
  file the organisation writes by hand and lists in `files`. Each chain is a `##` heading (its
  name), an `Answers:` line (else its first line of prose), and steps one per line in a fenced
  block, as list items, or indented. The vocabulary, as the parser accepts it:

  ```text
  ask <name> (<unit>) range <a>..<b>: <what to ask>      a number; unit and range optional
  ask <name> (text): <what to ask>                        words, no range
  lookup <name> = <table> row <row> [column <column>] rule <exact|at_least|at_most>
  lookup <name> = <table> column <column> cell <number> rule <exact|at_least|at_most>
  calc <name> [(<unit>)] = <expression>                   + - * / ( ), names and numbers
  convert <name> = <name, or a number with its unit> to <unit>
  check <expression> <op> <expression> ? "<if true>" : "<if false>"   <, <=, >, >=, ==, !=
  cite <the rule as printed>                              attaches to the step above
  say "<sentence with {name}>"
  ```

  Names are identifiers, set once, used only after the step that sets them. `{name}` fills a
  value into a row, a column, a cell number or a sentence; a lookup's value also has `{name.row}`,
  `.column`, `.table`, `.page` and `.next` (the row printed after it, with its cell), and any value
  `{name.unit}`. The table is named as printed, never from a value, so the import can check it.
  `exact` takes the row whose key is the number or a printed range that holds it; `at_least` that
  row, else the first above; `at_most` that row, else the last below; in the `cell` form the
  smallest cell at or above, the largest at or below. Problems name their line and chain (unknown
  step, a step that does not read, a range that runs backwards, a name used before it is set or set
  twice, an attribute a value does not have, an unknown rule or unit, `cite` with nothing above
  it, a chain that says nothing, an unclosed block); a chain with a problem is not offered.
  `ChainParser.render` writes chains back, and a file round-trips. `chains.md` is left out of the
  prompt's core text and of the model index: the session offers its chains by name instead.
- **At import.** `VaultValidator.chainIssues`: a step that does not read is an issue
  (`chains.md line N: <chain>: …`) and refuses the import, as a procedure that does not decode
  does. A chain naming a table that no manual in the vault prints is a warning, and the chain is
  kept; `rule_chain list` marks it "needs Table N", and it stops at that step. The labels are every
  caption the PDF table reader finds, read or not (`PDFTableReader.Result.stored`), so a table
  stored as a failure counts as present and the chain stops on it with its page. The validator
  reads the PDFs' tables only when a chain names a table. The vault guide has a new section,
  "Tables and chains (optional)", after Step 4, with the vocabulary, the row rules, what the import
  says, the three example chains and a read-back. The import table in "If the import refuses"
  gains its two messages. The section is unnumbered so the later steps other plans cite keep their
  numbers; the site page and PDF are regenerated.
- **`ChainRunner` (pure).** `advance(chain, state:, answer:, tables:) -> ChainStep` runs lookups,
  arithmetic, conversions, checks and sentences as it reaches them and returns at every `ask`
  (`.ask`, with why the last answer was not taken), at the end (`.finished`) or where it could not
  go on (`.stopped(ChainStop)`: the reason, the step, and the table page as a `Source:` line and
  citations when there is one). It stops on a table that is not there, one whose grid was not read
  (with its page), a row or column that does not resolve, a number between two rows under `exact`,
  an empty cell, a lookup whose column is not named on a table with several, arithmetic that fails,
  and a value that is words where a number is needed. A stopped chain stays stopped. An answer that
  is not a number, or is outside the range, is asked again and never taken; a unit the converter
  knows said in place of the asked one (°F for °C) is converted, and the read-back says what was
  said. `ChainState` holds each value with its number, text, unit, the step that made it and its
  source (said, a lookup's cell with its row, column, notes, page and citation, a calculation with
  the numbers it ran on, a conversion). `TableLookup` gained `resolveTable` (factored out of
  `resolve`), `resolve(_:rule:in:)`, `search(_:value:rule:in:)` and `nextRow`. Arithmetic goes
  through `ArithmeticExpression`, a small parser in doubles which `calculate` now uses too, in place
  of `NSExpression`. That parser raised an uncatchable exception on "2 +" and divided whole numbers
  as whole numbers (7 / 2 was 3). `convert` goes through `UnitConversionTool.convert`. Numbers are
  said to two places and handed to a lookup to six. A cell is said as printed.
- **`rule_chain` tool.** `list`, `start` (by name, or words of it, asking which when several
  fit), `answer`, `status`, `stop`. It needs an open job. The current question, what it needs and
  the values so far are in the system prompt (`ACTIVE RULE CHAIN — …`, beside the active
  procedure). With no chain running, the prompt names the chains the vault offers and what each
  answers. A chain that finishes or stops files its read-back on the job as a reading
  (`chain: <name>`, method `rule_chain`, the steps with their citations as the value), attached
  where a spoken reading is. One the technician stops files nothing. The work record prints these
  under "Rule chains worked on this job:", every step, apart from the readings the technician
  said. A spoken correction never lands on one, and the on-device prompt's last reading skips them.
  Each lookup's citation is noted the way `table_lookup`'s is (`TableLookupTool.rowPassages`), so
  "show me the table" opens the pages with the rows marked, and the tool's reply ends with the
  `Source:` lines. Registered in `FieldToolProfile.names`, `.local()` in `ToolEffectClassification`,
  `list` and `status` as reads in `ActivityTitler`, local in `OfflineToolPolicy`, and **not** in
  `AppleOnDeviceToolSet` (decision 7).
- **The shipped example** (`RuleChainFixtures`, the guide's example, held equal by a test): size a
  conductor for a load (load, ambient, conductors in the run, rating group → Table 90 band
  `exact` → Table 98 factor `at_least` on the ambient band → corrected load → Table 99 `cell`
  `at_least` in the rating group's column → the size); check an installed conductor (its size and
  the same inputs → its rating `exact` × the factor → "carries it", or "does not carry it, the next
  row is …"); voltage drop (feet converted to metres, Table 97's drop, two `calc` steps, a `check`
  against a limit the example sets). All over invented tables: P0's Tables 99, 98 and 97 and a new
  invented Table 90 of grouping bands (`TableFixtureLayouts.groupingBands`). The rule numbers
  (`Rule QR-12` and so on) are invented.
- **Tests (invented fixtures).** `RuleChainTests` (18): the fixture tables extract; the schema
  round-trips; a list reads as a fenced block; bad steps reported by line (unknown step, a range
  backwards, used before set, an unknown rule, `cite` first, nothing said, set twice, an attribute
  on an ask, an unclosed block); forward to QMX90 with two conductors; inverse to "does not carry
  it, the next row is …" and to "carries it"; voltage drop with its conversion; `at_least` and
  `at_most` on ranges, between rows, below and above every row, and in a column, and `exact`
  stopping between rows with the page; an out-of-range or non-number answer asked again; °F
  converted to °C; an unread table stopping with its page and an absent one without; a column the
  table lacks stopping with its page; the read-back line by line with every citation and `Source:`
  line; the evaluator and `calculate`; the on-device set offering `table_lookup` and not
  `rule_chain`; the guide's example equal to the fixture. `RuleChainSessionTests` (4), over an
  imported invented book: a chain naming a table the vault lacks is warned of at import, kept and
  marked in `list`; a bad step refuses the import with its line; a chain run on the job by the tool
  (the prompt carrying the current step and the asked-again note, `status`), its read-back filed as
  a reading and printed in the work record, never corrected by a spoken correction, and its tables
  opened by "show me"; a stopped chain filed with why, a stopped-by-the-technician chain filing
  nothing; an unknown name, a second start, and no job.
- **Not known yet.** How an electrician gets on writing a chain from the guide, and whether the
  model asks the questions in its own words without supplying values. Both are device and partner
  checks. A running chain is held in memory, so a relaunch mid-chain loses it (nothing is filed
  until it ends). The partner's own chains are written outside the repo (decision 3).

### P3 — Chains the model proposes, the technician runs, the organisation keeps 🚧 (built 2026-10-20, draft PR)

- **`propose_chain`.** For a question no authored chain answers, the model is told (in the
  Field Assist prompt, standards section) to retrieve the clauses first and then propose a chain
  in the P2 schema from what they say — never from memory of a code. The proposal is read back as
  steps with each clause cited, and the technician says go, changes a step, or stops. Running it
  goes through `ChainRunner` unchanged.
- **Keeping one.** A proposed chain that ran to a result can be kept. Amended 2026-10-20 by the
  owner's standing rule that a technician can do everything from the phone without the office
  app: it is kept on the phone first, offered there only, marked "unreviewed", and shared as a
  `chains.md` fragment by the share sheet for the organisation to paste in by hand; the
  team-learning path (Plan FP) is an addition when the organisation has the office app, never a
  prerequisite. A reviewed chain in `chains.md` with the same name supersedes the kept one when the
  vault next arrives.
- **Exit tests:** a proposal must cite a clause per lookup step or it is refused; a proposed chain
  runs through the same runner and reads back the same; an unreviewed chain is offered only on its
  origin phone; the review hand-off carries the proposal and its citations and nothing else from
  the job.

#### What shipped in P3 (2026-10-20)

- **`ChainProposal` (pure, `Sources/Services/Vault/`).** The model's text in (one chain in the P2
  syntax, under a `##` heading or with `name` and `answers` beside it, steps fenced or bare), with
  `sources`, the `Source:` line of the passage each lookup came from in the order the lookups are
  written; the passages retrieved on the job, the labels of the tables the vault's manuals print
  (read or not) and the names already offered beside it. It goes through `ChainParser` unchanged
  and is refused, by a named reason the model is told, when it does not read as exactly one chain,
  takes an offered chain's name, nothing has been retrieved on the job, it cites nothing, a lookup
  or a check has no `cite`, a lookup has no source or its source is not a retrieved passage (by
  document and physical page, as `CitationLineParser` reads it), or a cited rule is not printed in
  any retrieved passage. A rule is matched by its first numbered token ("QR-14" in "Rule QR-14(2)")
  as a whole token of a passage's text or section heading, so "Rule QR-1" is not "QR-12"; a rule
  with no number by its words. A lookup naming a table the vault lacks is accepted and marked
  "needs Table N". The read-back numbers every step in words with the rule it follows and the
  passage it came from, headed "(proposed, unreviewed)". `changing(step:to:source:)` replaces one
  step ("ask me the ambient instead") and checks the whole chain again; a lookup it removes takes
  its source with it, and a lookup it adds needs one.
- **`propose_chain` tool** (`NativeTools/ProposeChainTool.swift`): `propose`, `change`, `show`,
  `withdraw`. It reads the passages from the session's source memory (what `manual_lookup` and the
  per-turn retrieval noted on this job, `AnswerSourceMemory.retrieved`), so a proposal can only
  cite what was actually retrieved. An accepted proposal is held on the session (`PROPOSED RULE
  CHAIN — …` in the prompt) for the technician's go; nothing runs. Registered, in
  `FieldToolProfile.names`, `.local()`, local offline, titled; **not** in `AppleOnDeviceToolSet`.
- **The prompt.** `chainPromptContext` adds, whenever the vault offers chains or a manual in it has
  table rows, "PROPOSING A CHAIN": retrieve the clauses with `manual_lookup` (and the cells with
  `table_lookup`) first, propose only what those passages say with a `cite` on every lookup and
  check and each lookup's `Source:` line, never a step, rule, table or value from memory of any
  code, read the proposal back and start it only on go. This is the Field Assist session prompt,
  where the chains are offered; `SystemPromptBuilder` has no standards section of its own.
- **Running it.** `rule_chain start` takes the proposal by name, beside the vault's chains and the
  kept ones (`FieldSessionService.offeredChains`). It runs through `ChainRunner` unchanged. The run
  carries its origin (`ChainOrigin`: authored, proposed, kept) and its lookups' sources: the
  prompt's `ACTIVE RULE CHAIN` line, `start`, `status` and the finished reply say "(proposed,
  unreviewed)" or "(unreviewed — kept on this phone)", and the reading filed on the job is
  `chain: <name> (proposed, unreviewed)` with the runner's read-back marked in its first line and a
  second line, "Proposed from the passages retrieved: …". An authored chain's reading is byte for
  byte as P2 files it.
- **Keeping one, on the phone first.** `rule_chain keep` keeps the last proposed chain that ran to
  a result on this job (one that stopped is not kept) in `_kept_chains.json` in the vault's overlay
  folder (`KeptChains`), beside `chains.md`: not a manifest file, so never in the prompt, an export,
  a pack or a link; untouched by a vault update; removed with the vault. `list` offers it marked
  "[unreviewed — kept on this phone: offered on this phone only]" and it runs like any other
  chain. A chain the vault's `chains.md` has under the same name supersedes it (it is no longer
  offered). `rule_chain share` stages a `DeliveryRequest` (new payload `.ruleChains`, attachment
  kind `chains_markdown`, filed under no job) on the share sheet with the fragment as `chains.md`
  and in the body: a title, a paragraph saying what the chains are and that nobody has reviewed
  them, and each chain with a line saying when and on which job it was kept and the passage each
  lookup was read from — prose to `ChainParser`, so the file imports as it is. No office, endpoint
  or queue is involved. **With the office app** (`AppState.officeIsReportDestination`), keeping also
  files the fragment as a team-learning candidate (`LearningCandidateService.noteRuleChain`): the
  fragment as the finding and nothing else from the job — no machine, no evidence counts, no
  symptom or fix, only the contract's binding — so it rides the next candidates bundle
  (`LearningBundleOutbox`) to the reviewer. The bundle's closed contract is unchanged; the reviewer
  adds a reviewed chain to `chains.md` by hand.
- **A running chain survives a relaunch.** The job record carries `ruleChainRun`
  (`PersistedChainRun`: the chain as `chains.md` writes it, its origin, its sources and every answer
  given, taken or not), written as each question is asked and cleared when the chain ends or is
  stopped. After a relaunch, `activeChain` rebuilds the run by replaying the answers through the
  runner against the vault's tables, so it resumes at the same step with the same values and the
  same "asked again" note, and nothing is filed until it ends. No table cell is written into the
  job record before the read-back.
- **The guide.** "Tables and chains" gains "When no chain answers: a proposed chain": the
  proposal and its checks, go / change / stop, keeping on the phone, sharing the `chains.md` file
  with no office, the office's review as an addition, and a reviewed chain replacing the kept one.
  The site page and PDF are regenerated.
- **Tests (invented fixtures, committed before any run against licensed material).**
  `ChainProposalTests` and `ChainProposalSessionTests`, over P2's invented tables and three
  invented passages for invented Rules QR-12, QR-14 and QR-17: a proposal with a citation per
  lookup accepted and read back with every rule and passage; one with a lookup or a check and no
  `cite` refused; one citing nothing refused; one citing a rule not in the passages refused (and
  "QR-1" not taken for "QR-12", a subrule taken for its rule); a source not retrieved, a missing
  source and nothing retrieved refused; a table the vault lacks accepted and marked; a changed step
  ("ask me the ambient instead") re-parsed and run to its result; on a job, the proposal read back,
  changed, started, run through the runner and filed marked "proposed, unreviewed" with its
  passages, in the work record; `keep` saving on the phone and `list` offering it marked
  unreviewed, on a later job too; the share-sheet fragment a `chains.md` the P2 parser accepts;
  with no office, keeping and sharing working and no candidate or bundle; with the office, the
  fragment also in the candidates bundle with nothing else from the job; a reviewed chain of the
  same name superseding the kept one; a running chain (authored, and proposed) surviving a
  simulated relaunch at the same step and filing nothing until it ends; and the on-device set
  offering neither `propose_chain` nor `rule_chain`.
- **Retrieval (item 4, measured privately, kept).** One change, after every fixture and test was
  committed: a table named by its title words (`TableReference.titled`) now needs every content
  word of the title and at least two, where it took half the title and one word. A table named by
  its number is unchanged. On the code book's newest-edition answer key (66 scorable questions),
  the contextual model and the PDF-backed vault, aggregates only:

  | | hit@1 | hit@4 | as sent | in-scope refused | misses |
  |---|---|---|---|---|---|
  | Before (P2 as merged) | 0.38 | 0.55 | 0.59 | 0 | 30 |
  | Stronger title match (shipped) | **0.39** | **0.56** | **0.61** | 0 | 29 |

  The question P1 lost is back and no longer counts as naming a table; every other count is
  unchanged except that one miss (ranking 18 → 17, multi-rule misses 16 → 15). The P1 test that
  routed "the ratings table" to a table titled "Conductor ratings" now asks for "the conductor
  ratings table" and holds that half a title is not routed.
- **Not known yet.** Whether a model proposes chains well from real passages, and asks before
  running them: a device and partner check. Whether a reviewer wants the kept chains in the
  office's own review surface (Plan FP P4) rather than as a pasted file: open question 4.

### P4 — The electrical starter vault ✅ (built 2026-10-21, draft PR)

- A vault template for the trade `electrical` with no standard's text: a slot for the
  organisation's code PDFs (`standard` kind when IN P3 lands; a manual otherwise), an empty
  `chains.md` with the schema and the invented example commented, the voltage-drop calculator as
  a `calc` step and as `domain_calc`'s electrical domain, and the vault guide's new step, "Tables
  and chains". The partner's chains are not in it.
- **Exit tests:** the template validates; the guide's example chain validates against the
  template's fixture tables.

#### What shipped in P4 (2026-10-21)

- **The electrical starter** (`Resources/Vaults/electrical/`, `VaultRegistry`): a bundled vault
  "Electrical Service", offered wherever the refrigeration and IT vaults are (the default-vault
  list, reference-file editing, the manuals shelf, the mode tab), gated like them on Field Assist
  (`field_assist_electrical`), and the first bundled vault to declare a trade (`electrical`). Its
  prompt rules are the house style: never fabricate a rating, size, table value or rule; cite the
  rule, table or page; never guess a rating, size, setting or limit; before opening a panel,
  isolate, lock off and prove dead with a tester checked on a known source. `safety.md` says the
  same at more length and states no distances or PPE levels (the organisation's and the
  jurisdiction's). `error_codes.md` and `parts.md` hold a heading and a line saying what goes
  there. `chains.md` holds the step vocabulary as an indented reference before the first chain, a
  paragraph on the voltage-drop expression form, and the guide's three worked chains, renamed
  "Example: …", their `Answers:` lines saying they are invented, with `//` comments in the
  blocks; it parses with zero problems and its steps are the guide's (held equal by a test). The
  folder also carries `manifest.json` — the same files, rules and trade under the id
  `electrical_starter` with `enterprise` gating, so an imported copy never shadows the bundled
  vault — and `documents/README.md`, one paragraph on putting the organisation's own code PDFs
  there. No standard's text, table or rule ships (decision 1, IN decision 6): a test holds that no
  PDF is in the folder, that every table label in it is one of the invented 90, 97, 98 and 99, and
  that every `cite` is an invented `Rule QR-`. The bundled vault, having no book, lists the
  example chains as needing their tables.
- **Voltage drop** (`FieldAssist/Electrical/VoltageDrop.swift`, pure; `domain_calc` operation
  `voltage_drop`): 2 × I × L × R single-phase, √3 × I × L × R three-phase line to line, from the
  phase (never assumed), the current, the one-way length in m or ft, and the resistance per km,
  m, 1000 ft or ft, or a factor over the conductor's area (Ω·mm²/m over mm², Ω·cmil/ft over cmil).
  The answer gives the drop in volts and, with the supply, as a percentage, echoes every input,
  and says it is resistance only. Nothing in it is a constant from a code: a missing phase,
  resistance, factor or area is asked for, and a value at or below zero refused. (Since 2026-11-23,
  decision 8: an AWG size, or an area in mm², with its metal also gives the area and factor, from
  the bundled conductor file, and says so.) `domain_calc` no
  longer requires a refrigerant for every operation. The trade gate now splits a tool by
  operation (`FieldTradeGate.operationTrades`): `domain_calc` is offered while either trade is on,
  its saturation math is redirected on an electrical-only phone and its voltage drop on a
  refrigeration-only one (the router passes the operation), and the prompt's routing rule for a
  hidden electrical trade names voltage drop. The arithmetic evaluator gained `sqrt( )`, so a
  chain writes the same calculation over named values (`calc volts (V) = sqrt(3) * current *
  length * resistance / 1000`), and the guide documents the forms. Not on the on-device set,
  which is unchanged.
- **`Scripts/chains-validate/`**: `run.sh <vault folder> [chains.md]` compiles `ChainParser`,
  `TableLookup`, `TableReference`, `TableExtractor`, `PDFTableReader` and the evaluator unchanged
  with `swiftc` and PDFKit, reads the tables of every PDF the manifest lists (or the original of a
  text document) as an import does, and prints counts and line-numbered findings through the pure
  core `OpenGlassesTests/ChainsValidate/ChainsValidateCore.swift`: the chains parsed and with
  problems, steps and lookups per chain, every parse problem with its line and kind, and for every
  lookup — in a chain with a problem too, found by `ChainParser.lookupStep` — whether its table is
  read, unread or missing, and whether its row, column and cell number resolve (resolved,
  ambiguous, between rows, unresolved, a pattern a heading fits, a value only a run can check, no
  column on a wide table), and whether the manifest lists the chains file. Names are printed only
  from the chains file; `CHAINS_VALIDATE_NAMES=0` prints none. The build directory must be outside
  the repository. The guide gains "The electrical starter" and "Voltage drop, in a chain and on its
  own"; the site page and PDF are regenerated.
- **Tests (invented fixtures, committed before the private run).** `ElectricalStarterVaultTests`
  (6): bundled and offered with its trade and gating, the template manifest agreeing; the prompt
  rules; the template validating at import with the three missing-table warnings and its chains
  parsing clean, equal in steps to the guide's; no book, label or rule beyond the invented ones;
  `rule_chain list` on the starter naming the example chains as needing their tables; and the
  template with an invented book of the fixture tables in `documents/` validating with no chain
  warning and running the example to QMX90 on a job. `VoltageDropTests` (10): single- and
  three-phase in both unit systems and both forms, a value at or below zero refused, the phase
  read from words, the tool's answer with its inputs echoed, a missing resistance, factor, area,
  phase or length refused, no refrigerant needed, a chain `calc` reaching the tool's number
  through named values, a chain looking a resistance up in an invented Table 96 then computing
  it, `sqrt` and nothing else new, and the on-device set unchanged. `ChainsValidateCoreTests`
  (5): on the P2 fixture tables, a missing table, an unresolved row, an unresolved column, an
  unread table, a parse problem by its line and kind, and a manifest not listing the file; names
  only from the chains file and none in counts mode; the guide's example resolving throughout
  with the parser's own lookups; a column not named and a number between rows; every parser
  problem having a kind. `FieldTradeGateTests` updated for the split tool.
- **Run on the partner's test vault** (after every fixture and test was committed; counts only,
  the full output kept off-repo for the electrician): two PDFs read in 69 s,
  189 captions stored (70 read to a grid, 119 not); 11 chains, all 11 parsed, **0 problems**, so
  the hand-written file's four assumptions (several `check` steps in one chain, a `cite` straight
  after an `ask`, a decimal in an `ask` range, `{name.row}` inside a `row`) are all accepted by
  the parser as written, and none needed a parser change; steps per chain 8, 14, 13, 16, 8, 9, 17,
  15, 8, 11 and 12. Of 43 lookups, 4 name a table that was read, 25 one whose caption was found and
  grid not read, and 14 a label no caption carries. On the 4 read tables, rows: 1 resolved, 3 from
  a value; columns: 3 ambiguous, 1 unresolved. 0 of 43 resolve throughout. The vault's manifest
  does not list `chains.md` (the file is kept apart from the vault), so it has to be copied in and
  listed before the import reads it. The unread tables are P0's extraction limit (the "too few
  rows" captions), not the chains; the missing labels and the ambiguous columns are the
  electrician's to check against the book, with the named output
- **Owed on a device:** the starter offered and chosen as the default vault, its chains listed as
  needing their tables; voltage drop asked by voice in both unit systems, the assistant asking
  for the phase and the resistance rather than supplying them; a refrigeration-only phone
  redirecting voltage drop and an electrical-only one the refrigerant operations; the partner's
  vault imported with its chains and a chain run to its read-back.

### P5 — Extraction coverage ✅ (built 2026-10-21, draft PR)

P4's validator, run on the partner's test vault, found 189 captions across its two PDFs, 70 read
to a grid, and of the chains' 43 lookups 4 on a read table, 25 on a caption whose grid was not
read and 14 on a label no caption carries: none resolved to a cell. Three causes: labels with a
letter, layouts the extractor did not read, and names a chain gives a row or column that did not
match the headings as extracted.

- **Labels as printed.** A caption's label keeps a letter beside its number ("Table 95A", "Table
  Q7"), in the extractor, in the chunker's caption rule for passages and in the Mac text
  extractor it mirrors, so two tables that share a number are two tables and "(Continued)"
  joins only its own label. `TableReference` and `TableLookup` read the same labels printed,
  spaced ("table 95 B") and spoken ("table five A", "table Q seven"); a lower-case "a" or "i"
  after the number is a word unless the vault prints that table.
- **Layouts, designed from counts only.** `Scripts/table-extract-eval/` gains an anonymised shape
  report of every caption that read no grid — by index, counts only — and the fixes are the
  shapes it showed, each with an invented fixture and kept only when the runner's count rose:
  a table continued onto a page with no caption, cells that are marks, groups side by side under
  one caption, plus what the shapes made obvious (below).
- **Names said the way a chain says them.** A column by its full path, its last heading when
  unique, or its words in any order, ignoring case, punctuation and bracketed units; a row by its
  key, a number inside a printed range, or its words; ambiguity still asks.
- **Measured last**, after every fixture and test was committed: extraction on each PDF, the
  validator on the partner's chains, a new cell-key scorer, and the retrieval key.
- **Exit tests (invented fixtures only):** "Table 95A" and "Table 95B" never merge, "Table Q7" is
  a label, a continuation of 95A joins 95A and not 95; a caption-less continuation on the same
  columns merges and one on other columns does not; mark cells extract as text; side-by-side
  groups read; columns by last part, by words in any order, ignoring units and case; rows by range
  and by words; ambiguity asks; the shape report runs on fixture PDFs and prints counts only; the
  cell-key scorer scores an invented key over invented tables; P0–P4 tests pass unchanged but one.

#### What shipped in P5 (2026-10-21)

- **Labels** (`TableExtractor.labelPattern`): a number with one letter after it or one or two
  capitals before it, kept as printed; a letter run into a word ("16Wiring") is not the label's.
  `ManualStructure.caption` and `Scripts/extract-manual-text.swift` read the same label (mirrored
  self-check cases). `TableExtractor.merge` compares labels without case. `TableReference` reads
  "95A", "95 B", "five A", "Q7", "Q seven"; `labels(in:among:)` takes "a" or "i" after the number
  as the letter only when the vault holds that label, and `references(in:catalogue:)` and the
  lookup's table resolution pass the vault's labels. "table 99X" is now the label Table 99X, never
  Table 99 (the P1 test that held it was no reference is changed to say so). A bare "95A" or "Q7"
  asked as the table resolves.
- **A table carried on with no caption** (`TableExtractor.Grid`, `continuation`): a read table
  keeps the grid it was laid on while the next page is read; a page whose first lines, after at
  most three lines of furniture and the headings printed again, sit on the same columns (every
  phrase over exactly one) carries the table on, each row keeping its page, a row header or group
  carried across. The same reads a "(Continued)" page that did not read on its own. The reader now
  also reads positions on the page after a table, and on the page after a caption at a page's foot.
- **Marks in the cells** (`sparseSegments`): a grid whose rows leave cells blank (a cross, a tick
  or a dash in some columns only) takes its columns from every row, accepted only when the lowest
  heading line stands one phrase over each column and no other; marks stay text with no number.
- **Groups side by side** (`sideBySideGroups`, `lay`): two or three runs of columns of equal width
  whose headings read alike column for column — by the heading under which nothing else is
  printed, or by all of a column's heading words, since a heading stretched to a gap can land on a
  neighbour's path (the shape the partner's book showed) — read as one table, the right group's
  rows after the left's; groups told apart by a heading over each keep it on their rows.
- **What else the shapes showed**, each with its invented fixture: headings stacked deeper than a
  short header (rows of numbers up to 18 lines under the caption, under at most 12 heading
  lines); a heading row of numbers under a heading spanning several columns, read as the columns'
  headings when most columns have none of their own (the last may be words, "4 or more"); an entry
  in a list of tables, not counted as a caption where the document captions the label elsewhere
  (`PDFTableReader.Result.listedEntries`); a caption at the foot of a page heading the grid at the
  top of the next (`startingOnNextPage`); and a new failure, `no_text_in_table`, for a caption
  whose page's text stops under it for at least 15 lines' height with no grid above — the table is
  printed with no text the PDF gives, most likely as a picture — which `table_lookup` says in those
  words, with the page to show. Location version 4 → 5: stored documents have their tables read
  again, their text untouched.
- **Names** (`TableLookup`): columns matched by path or its end with bracketed units left out on
  both sides when they do not decide, then by words with units, then without
  (`TableLookup.withoutUnits`); rows keyed by printed ranges with "to", "through", "from … to",
  units on either end, and "over A up to B" (above A, up to and including B). The validator prints
  why an unread table was not read (`unread_because=`) and a read one's size (`grid=RxC`,
  `unnamed_columns=`), counts only.
- **Runners.** The shape report (`OpenGlassesTests/TableExtractEval/TableShapeReport.swift`, in
  `Scripts/table-extract-eval/`); `Scripts/table-lookup-eval/`, a cell-key scorer
  (`OpenGlassesTests/TableLookupEval/TableLookupEvalCore.swift`) that prints questions, tables
  read / unread / missing / ambiguous, rows and columns resolved, cells, between-rows and asks
  matched, and why a key line was not read, all as counts, and says "against the unchecked key"
  until told the key is checked.
- **Tests (invented fixtures, committed before each run against licensed material).**
  `TableCoverageTests` (26): every exit test above, the table route lifting only the unread
  caption's passage that prints the label, and deep headings, numbered headings, a list
  of tables, a caption at the foot, split side-by-side headings and a table with no text.
  `ManualStructureTests` gains the lettered labels, `TableLookupTests` its changed "99X" case.
  Full suite: 12,269 tests, 0 failures (16 skipped).
- **Measured privately** (counts only; both PDFs; the runners compile the app's sources):

  | | before (P4) | after (P5) |
  |---|---|---|
  | Captions (older + newer edition) | 189 (95 + 94) | 300 (161 + 139), 6 list entries left out |
  | Read to a grid | 70 (0.37) | **133 (0.44)** |
  | Too few rows / varying columns / merged | 83 / 22 / 2 | 110 / 30 / 3 |
  | Rotated headings / no text in the table | 12 / — | 16 / 8 |
  | Pages with a read table | 52 | 114 (none read before is lost) |

  The new captions are the letter labels the digits-only rule missed (letters before the number)
  or recorded under their digits: of the captions read, 60 are digits only, 20 have a letter after
  and 57 letters before. Of the 167 still unread, most are tables of words whose rows wrap over
  several lines (the shape report's largest class: one cell on most lines, text in nearly every
  cell), the next lever and not addressed; the shape report marks 31 failed captions as entries in
  a list of tables, 6 of them left out because the label is captioned elsewhere.

  The partner's chains (`Scripts/chains-validate/`, 11 chains, 43 lookups; the named output kept
  off-repo for the electrician):

  | | before | after |
  |---|---|---|
  | Lookups on a read table | 4 | **16** |
  | … on a caption not read | 25 | 25 (24 `no_text_in_table`, 1 too few rows) |
  | … on a label no caption carries | 14 | 2 (both a letter label) |
  | Rows: resolved / from a value | 1 / 3 | 1 / 14 |
  | Columns: resolved / pattern / ambiguous / unresolved | 0 / 0 / 3 / 1 | 9 / 6 / 0 / 1 |
  | Lookups resolving throughout | 0 of 43 | **15 of 43** |

  Of the 16 lookups on a read table, 15 resolve throughout. The 24 on a table with no text name
  two tables (one of them by 19 lookups), each printed so in both editions: the caption page
  prints a paragraph and nothing more until the footer, so the grid is most likely a picture and
  only a recogniser (Plan IF) could read it.

  The cell key (`Scripts/table-lookup-eval/`, against the unchecked key: 30 questions, 3 more
  lines naming no row and not scored): tables read 9 → 12, unread 11 → 13, missing 3 → 5,
  ambiguous 7 → 0; on a read table rows resolved 5 → 12, columns 0 → 9; **cells matching the key
  0 → 9 of 29**; the one ask in the key is not asked (0 → 0).

  Retrieval (`Scripts/retrieval-eval/`, the code book's answer key, 66 scorable questions, on the
  PDF-backed vault, contextual model):

  | | hit@1 | hit@4 | as sent | in-scope refused | misses |
  |---|---|---|---|---|---|
  | Before (P4 as merged) | 0.39 | 0.56 | 0.61 | 0 | 29 |
  | P5 extraction only (P4's table names) | 0.39 | 0.58 | 0.61 | 0 | 28 |
  | P5 with lettered table names, first cut | 0.38 | 0.58 | 0.61 | 0 | 28 |
  | P5 as shipped | **0.39** | **0.58** | **0.61** | 0 | 28 |

  The extra row passages bring one question into the four. Reading lettered labels in questions
  makes one question name a table by number for the first time (a table its edition does not
  read), and the table route then ranked every passage of that caption's page above the clauses,
  taking the first place from the one that answered. The route now lifts only a page passage that
  prints the table's label (`VaultRetriever.prints`); the page's other passages are ranked as
  any other. That brings the first place back with nothing lost.
- **Not known yet.** Whether the cells now read are right: the cell key is unchecked, and a cell
  matching it is agreement, not proof. The pictured tables are outside text extraction (open
  question 3). The two missing labels and the one unresolved column are the electrician's to
  check against the book with the named output.

## Acceptance

- The partner's electrician asks for a conductor for a stated load and installation and hears
  the answer read back as steps: what was assumed, each table and cell used with its page, the
  arithmetic, the result — and can open any step's page. Asked whether an existing cable is right,
  he hears the same chain the other way round.
- Asked for one cell, he hears the cell, its headers, its units, its notes and its page, or that it
  sits between two rows, or a question back. He never hears an interpolated or guessed value.
- A chain never continues past a step it could not complete.
- No table, chain or clause text from a loaded book leaves the phone in any export, pack, bundle
  or link.
- The tester need not know which rules apply: for a question with no authored chain, the assistant
  proposes the steps from the clauses it found, with each clause cited, and asks before running.

## Open questions for the owner

1. Which chains first, beyond cable sizing both ways: breaker or overcurrent-device sizing, conduit
   fill, grounding-conductor sizing, voltage drop on its own? The partner should name three.
2. Who authors the partner's `chains.md` for testing — the owner, from the partner's own code copy
   and outside the repo, or the partner's lead electrician with the guide? The schema is designed so
   an electrician can write one.
3. Tables with no text layer (image-only pages in an otherwise text PDF) — extract through Plan
   IF's recognition path in P0, or report them and leave them for IF?
4. Does P3's "keep a chain" need the office review surface (Plan FP P4, blocked on q7 there) before
   it is useful, or is "unreviewed, this phone only" enough for the partner's test?
5. Measurement: the private table-question set has to be written against the loaded test book,
   like Plan IV's answer key, and stays off-repo. Who writes it, and how many questions?
