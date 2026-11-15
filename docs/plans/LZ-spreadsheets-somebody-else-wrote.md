# Plan LZ — Spreadsheets Somebody Else Wrote (a supplier's list or the office's stock sheet, read the way a person reads it)

**Status:** 📝 Drafted 2026-11-15 — nothing implemented.
**Track:** Field Assist, van stock. Every path that reads a workbook into stock: the import, the
takeover of a van, and base's baseline.
**Builds on:** Plan [IH](IH-van-stock.md) §6 and §8: `XLSXReader`, `VanStockSheet` (the proposal, its
refusals, `headerSynonyms`), `VanStockImportService` and the review sheet, `VanStockHandover`'s takeover
and baseline. **IH's contract is kept as it is:** an import is a proposal the technician sees, and one
tap applies it as one batch that one undo takes back.
**Sits beside:** Plan [JJ](JJ-table-lookup-and-rule-chains.md)'s PDF tables (`TableExtractor`,
`TableLookup`), which this plan looks at and leaves alone (§8).

---

## Trigger

`VanStockSheet` reads "a sheet this app did not write" by its header words. That works for a sheet
somebody typed in a hurry: one header row at the top, one row per part. Workbooks from a wholesaler,
a supplier's price list or the office rarely look like that. A typical one:

```
row 1   Northside Supply — Stock list                      (merged across the sheet)
row 2   Prices ex GST. Updated 1 Nov.
row 3
row 4   Part        Description           Stock              Unit
row 5                                     On hand   Min
row 6   FITTINGS
row 7   QMX90-12    Flare nut 3/8         14        5         each
row 8   QMX90-16    Flare nut 1/2         TBD       5         each
row 9   QMX90-20    Flare union 5/8       -         2         each
row 10  Total fittings                    14
row 11
row 12  CAPACITORS
...
row 40  Grand total                       212
row 43  Part        Description           Price
row 44  (a price table)
```

(Invented example.) Read today:
- **The header isn't found** if the title and notes push it below row 10 (`header(in:)` looks at the
  first ten rows only), and a two-row header (*Stock* over *On hand*) is not found at all, because each
  row alone lacks a figure column. The import fails with *no recognisable header*.

And where a header is found (a sheet like this one with its header on one row near the top):
- **"TBD" and "-" refuse the whole row** (`.notAWholeNumber`), so a part the office hasn't counted yet
  never arrives, not even as a new line without a count.
- **"FITTINGS" becomes a stock line** called FITTINGS with no count.
- **"Total fittings" and "Grand total" become stock lines**, with quantities 14 and 212 that are the
  sums of real lines.
- **The price table further down** is read as more stock rows.
- **Merged cells** are invisible: `XLSXReader` returns a merged range's text in its first cell and
  empty cells after it, so a header merged across two columns names one.

The technician sees a proposal with phantom lines and missing ones, and has to spot them.

## Outcome

- The sheet above imports as the stock lines it holds, under the headers *Part*, *Description*,
  *Stock On hand*, *Stock Min*, *Unit*.
- Above the proposal the review sheet says, in plain lines:
  - *"The table starts at row 4. Rows 1–2 were read as the sheet's title and notes."*
  - *"2 counts read as empty: row 8 'TBD', row 9 '-'."*
  - *"Rows 6 and 12 are section names (Fittings, Capacitors), not parts."*
  - *"Rows 10 and 40 are totals and were left out."*
  - *"A second table on rows 43–60 has no stock columns and wasn't read."*
- The title and notes show under the file name: *Northside Supply — Stock list · Prices ex GST.
  Updated 1 Nov.*
- Nothing applies until the technician taps once, as today. A workbook this app wrote is read exactly
  as today.

## What exists, and what doesn't

**Exists (verified against `main` on 2026-11-15):**
- `XLSXReader` (`OpenGlasses/Sources/Services/FieldAssist/VanStock/XLSXReader.swift`): reads shared,
  inline and formula-string text and the cached value of a number. No formula is evaluated, no style
  is read. `Sheet` is `name`, `isHidden` and `rows: [[String]]`. It doesn't read merged ranges or note
  which cells hold formulas. Bounds: 2 MB file, 5,000 data rows, 64 columns; macro workbooks refused.
- `VanStockSheet` (`…/VanStock/VanStockSheet.swift`):
  - `rows(from:)` picks the sheet named *Van stock*, else the first visible sheet;
  - `header(in:)` takes the first of the first ten rows in which a cell exactly matches a
    `headerSynonyms` phrase for a part or description and another for a figure;
  - `wholeNumber` turns `""` into absent, a whole number into a value, and anything else into a
    `.notAWholeNumber` refusal of the whole row (except *On order*);
  - a row with words where the part number goes becomes a description;
  - `proposal(from:log:)` makes counts, new lines, edits, missing lines (own sheets only) and refusals.
- `VanStockImportService` (`…/VanStock/VanStockImportService.swift`) and the review sheet
  (`OpenGlasses/Sources/App/Views/Job/VanStockImportReviewSheet.swift`).
- `VanStockHandover.takeover(from:…)` and `baseline(from:log:)` (`…/VanStock/VanStockHandover.swift`)
  read through the same `VanStockSheet.rows(from:)`.
- IH principle 2: a real `.xlsx`, never CSV.

**Checked and not affected:**
- `PartsOrder`, `TaskClosePolicy` and `UnitLedger` read no spreadsheets, and nothing in them sums
  imported quantities.
- Vault import (`Services/Vault`) takes no spreadsheet.
- `ExpertLedger` and `ExpertStatement` write a *Total* row into their own exports; those workbooks
  are never read back as stock.

**Doesn't exist:** a table found below a title; a header over two rows; placeholders read as empty;
section labels; total rows; a second table; merged cells; any warning about how a sheet was read.

## Design

Everything below is pure and works on a grid of cells. Only §1 touches the file.

### 1 · The grid (`XLSXReader`, extended)

`Sheet` keeps `rows: [[String]]` for every caller and gains `cells: [[SheetCell]]`:
- `SheetCell`: the shown text, a kind (`number`, `text`, `boolean`, `error`, `empty`), whether the cell
  holds a formula, the formula's function name when it is `SUM` or `SUBTOTAL` with the range it names
  (read as text, never evaluated), and whether a formula has no saved value;
- `merges: [SheetRange]`, read from the sheet's `mergeCell` elements. Merged ranges are **not**
  filled into the grid. The layout reader decides where filling makes sense (§3).

The bounds and refusals stay as they are.

### 2 · What a cell is (`CellKind`, `SheetPlaceholder`, pure)

A cell is a number, a date, text, empty, or a **placeholder**: *TBD, TBA, tbc, n/a, N/A, na, -, --,
– (en dash), — (em dash), ?, x, call, POA, pending, …*, and a bound such as *<10* or *>100*. A
placeholder counts as **empty** wherever a figure is expected, so one *TBD* never makes a quantity
column look like text and never refuses a row. Every placeholder read as empty is listed in the
warnings with its row, column and text. A bound is never a count, so *<10* is empty too.

*On hand* left empty in a sheet we didn't write already means "no count given" in IH's proposal. That
doesn't change.

### 3 · Where the table is (`SheetLayout.find`, pure)

Read top to bottom, within the first 200 rows:
1. **Banner rows** (one filled cell that is a wide merge, long text, or alone in a row above anything
   tabular) are the sheet's title and notes. So are **key–value rows** at the left (*Supplier,
   Northside*; *Updated, 1 Nov*). Both are kept as context, never as headers.
2. **The body's signature.** For each column, the kind most rows below share (number, text, empty),
   placeholders counted as empty. The **first data row** is the first row that fits the signature and
   is confirmed by the row below it.
3. **The header band** is the non-blank, non-banner rows directly above the first data row, at most
   three, each with more text cells than number cells. Section labels between the band and the data
   (step 5) don't belong to it. A last band row whose cells are all units (*each, m, box*) or all in
   brackets is a **units row**.
4. **Column names.** The band's cells are joined per column, top to bottom (*Stock* + *On hand* →
   *Stock On hand*), with merged cells filled across **inside the band only**. The full text is kept per
   column; the name is what `headerSynonyms` is matched against (§6).
5. **In the data:**
   - a row whose only filled cell is text in the first used column, written in capitals or ending in a
     colon, or above rows that fit the signature, is a **section label**. Its text is carried down as
     the rows' section until the next label;
   - a row starting *Note*, *Source*, `*` or `(1)` is a note and joins the context;
   - a row repeating the header (a page break in the source) is skipped;
   - vertical merges in the first columns are filled down;
   - blank rows are skipped.
6. **A second table.** After a blank row, a header-like row (text over columns that hold numbers below
   it) starts a new table, read by the same steps. Below the last row that fits, text is footnotes.

### 4 · Totals (`TotalRows`, pure)

A row is a **total** when any of these holds:
- **By its label:** its first text cell, or its part or description cell, is a total word as the whole
  cell, or starts or ends with one (*Total*, *Totals*, *Subtotal*, *Sub-total*, *Grand total*, *Sum*,
  *Overall*: *"Total fittings"*, *"Fittings total"*). A total word inside a description (*"Total-flex
  hose"*) doesn't count, because the cell must start or end with the whole word and a space or the
  cell's edge.
- **By its formula:** a figure cell holds `SUM` or `SUBTOTAL` over a range of the same column.
- **By its arithmetic:** the row has **no part number**, and its quantity equals the sum of the rows
  since the last section label or total (at least two of them). A grand total equals the sum of the
  subtotals above it.

A total row is **never a stock line**: not a new line, not matched to an item, not counted. It's
listed in the warnings. A row **with** a part number whose quantity equals the sum above it is kept,
because a real part can hold that number by chance, and warned about (decision 3).

### 5 · Two readings, the better kept (`SheetReading.choose`, pure)

Every sheet is also read the simple way: the first row that names a part or description and a figure,
as `header(in:)` does today but without the ten-row limit, everything below it data. Both readings are
scored:

`score = 0.5 × fit + 0.3 × header + 0.2 × kept`
- **fit:** the share of data rows whose cells match their column's kind;
- **header:** the share of the reading's columns whose name matched a synonym, and 0 when it has no
  part-or-description column or no figure column;
- **kept:** the reading's data rows as a share of the larger of the two readings' rows.

The higher score wins, a tie goes to the layout reading, and when the simple reading wins the warnings
say so. Both scores show in the Developer panel. Both under 0.5 adds *"This sheet's layout wasn't
clear: check the rows below before applying."* The weights are a starting point. P1 tunes them on
hand-built grids only.

### 6 · Matching headers

A column's name matches a synonym when the whole name is the synonym, or when the band's **last** row
is. *Stock On hand* matches *on hand* through its last row. The most specific synonym wins. A name
that also holds another column's word (*Min qty*, *Order qty*) is not *On hand*. A column two synonyms
claim equally isn't used, and the warnings say which.

### 7 · The warnings (`SheetReadWarning`, pure)

An enum with row numbers, each rendered as one plain line:
`tableStartsBelow(row:)`, `headerOverRows(_:)`, `placeholdersAsEmpty([cell])`,
`sectionLabels([row: text])`, `totalsLeftOut(rows:)`, `secondTable(rows:read:)`,
`formulaWithoutValue([cell])` (*"open the file in your spreadsheet app and save it, so the figures
are saved with it"*), `mergedHeaderFilled(range)`, `columnNotUsed(name:reason:)`,
`simpleReadingChosen(scores)`, `layoutUnclear`.

`VanStockSheet.Proposal` gains `warnings` and `context` (title and notes). The review sheet shows the
context under the file name and up to six warnings above the proposal, with **Show all**. Warnings
never block an import; *no recognisable header* still fails, as now.

### 8 · Who gets this, and who doesn't

- **The import, the takeover and the baseline** all read through `VanStockSheet.rows(from:)`, so all
  three get the layout reading, totals left out and the warnings.
- **A workbook this app wrote** (the *Avenkin* meta sheet, an *Item ID* column) is read by today's path
  exactly, so the round trip IH tested doesn't move (decision 5).
- **Section labels** group the proposal's lines in the review sheet. They aren't stored: a stock line
  has no section field and gains none here (decision 1).
- **A second table** is read on its own. If it has stock columns it joins the proposal, its rows
  labelled with where they came from. Otherwise it's listed as not read (decision 4).
- **PDF tables** (`TableExtractor`, `TableLookup`): a *Total* row in a printed table is a real row a
  technician may ask for (*"what's the total connected load?"*), and nothing sums a table's rows, so
  there's nothing to double-count. No change. If a chain ever sums rows, `TotalRows`' label rule is
  there to reuse, and that belongs in the chain's own plan.
- **Company vaults** take no spreadsheets, so nothing here applies.

## Decisions for Greig

1. **Section labels.** *Recommended:* group the review by them and store nothing. *Alternative:* store
   the section on each line, which needs a new field and a place to show it.
2. **Placeholders.** *Recommended:* the list in §2, bounds included, read as empty and listed.
   *Alternative:* refuse such rows as today, which loses lines the office hasn't counted yet.
3. **A summing row with a part number.** *Recommended:* keep it and warn. *Alternative:* leave it
   out, which could drop a real part whose count happens to equal the sum.
4. **A second table.** *Recommended:* read it; propose its rows if it's a stock table, otherwise say it
   wasn't read. *Alternative:* read only the first table, saying the rest wasn't read.
5. **Our own workbooks.** *Recommended:* read exactly as today. *Alternative:* send them through the
   layout reader too, which should give the same result and risks changing the round trip for nothing.
6. **How far down a header may be.** *Recommended:* 200 rows.
7. **Other languages.** *Recommended:* total and placeholder words in English first; the other UI
   languages as each translation is reviewed, the same way private-conversation phrases are added.
8. **CSV.** *Recommended:* still out, as IH principle 2 decided. The layout reader works on any grid,
   so adding CSV later would be a reader, not a redesign.

## Phases

### P0 — the pure core (headless)

`SheetCell`, `CellKind` and `SheetPlaceholder`, `SheetLayout.find` (banners, key–value rows, the
signature, the header band and units row, column names with merges inside the band, section labels,
notes, repeated headers, a second table, footnotes), header matching (§6), `TotalRows`,
`SheetReading.choose` and its score, `SheetReadWarning`. Every test builds its grid by hand, cell by
cell. No supplier's file is used or committed.

Tests:
- `SheetPlaceholderTests`: every placeholder empty in a number column; a placeholder doesn't turn a
  number column into text; *<10* empty; a real word (*Capacitor*) not a placeholder.
- `SheetLayoutTests`: a title and notes above the header; a header over two rows, and over three with
  a units row; a merged header filled inside the band only; a merged title not taken as a header;
  key–value rows above the table; section labels in capitals and with a colon; a note row; a repeated
  header skipped; a second table after a blank row; footnotes; a clean one-row sheet read as today.
- `HeaderMatchingTests`: *Stock On hand* is On hand; *Min qty* and *Order qty* aren't; two equal claims
  leave the column unused.
- `TotalRowsTests`: each label form; *"Total-flex hose"* not a total; a `SUM` formula; an arithmetic
  subtotal and a grand total; a part-numbered row equal to the sum kept and warned; a total never a
  stock line.
- `SheetReadingChoiceTests`: the layout reading wins on the example sheet; the simple reading wins on a
  plain sheet with an odd first row; a tie keeps the layout reading; both low gives `layoutUnclear`.
- `SheetReadWarningTests`: each warning's line.

### P1 — the reader and the import (headless, plus the review sheet)

`XLSXReader` reads `mergeCell` and marks formula cells (tests over hand-written sheet XML in a small
zipped workbook built in the test). `VanStockSheet.rows(from:)` uses the layout reader for workbooks
this app didn't write; `Proposal` gains `warnings` and `context`; the takeover and baseline pass them
on; the review sheet shows them.
- `VanStockSheetImportTests` and the handover tests pass **unchanged**: own workbooks and plain sheets
  read as before.
- `VanStockForeignSheetTests` runs the example in *Trigger* end to end: the right new lines and counts,
  no phantom lines, the warnings in order.

### P2 — hand check on the phone (owed)

Real workbooks the owner has (a supplier's list, an office stock sheet, a sheet saved by another
spreadsheet app) opened on the phone; each warning read against the file by eye; apply and undo.
Nothing from them is committed.

## Risks

- **A clean sheet read differently.** The simple reading and today's path for own workbooks are the
  guards; P1 requires the existing import tests to pass unchanged.
- **A real line taken for a total or a section.** Totals need a label, a formula or a sum with no part
  number; sections need a single text cell above fitting rows. Both are listed, so the technician sees
  them before applying.
- **A placeholder list that hides a typo.** Every placeholder read as empty is listed by row.

## Out of scope

- CSV, and spreadsheet formats other than `.xlsx` (IH principle 2).
- Prices, and any use of a supplier's price column.
- Evaluating formulas.
- PDF tables and company vaults (§8).
- Writing merged cells or totals into our own exports.
