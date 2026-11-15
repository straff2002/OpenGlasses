# Plan MA — Reading Manuals Better (section levels from the bookmarks, a grade for every page, and a second reader that finds our mistakes)

**Status:** 📝 Drafted 2026-11-15 — nothing implemented.
**Track:** Manuals, for Field Assist and My Manuals alike: every PDF a vault or a personal library
imports, every scanned page and every photographed page.
**Builds on:**
- Plan [EK](EK-manual-structure-and-figures.md) and `ManualStructure`: headings and captions read off
  the type, written as the small grammar `DocumentChunker` reads, with a faithful copy in
  `Scripts/extract-manual-text.swift`.
- Plan [JN](JN-pictured-tables.md): `PictureRegion`, `PictureTableReader`, `VisionTableReader` and
  `CellCertainty`, and its rule that a value read from a picture says so.
- Plans [EF](EF-scanned-manual-import.md), [IF](IF-photographed-manuals.md) and
  [JY](JY-multilingual-manual-search.md) P5a: `ScannedPageReader`, `ScanRenderPolicy`'s low-confidence
  floor, `CapturedManualReview` and the pages printed as outlined glyphs.
- `Scripts/table-extract-eval`, `Scripts/retrieval-eval` and its paired comparison (PR 1069): local,
  counts-only measurement over manuals a developer holds.
- Plan [KQ](KQ-a-model-trained-to-search.md): a model measured on the Mac, decided on the phone
  (`SearchModelPhoneCheck`), and shipped as a download (`DownloadableModelBundle`, `ModelDownloader`).

**Sits beside:** Plan [LX](LX-reading-charts-on-manual-pages.md) (charts), Plan
[LY](LY-questions-about-a-whole-manual.md) (reading a whole manual by its sections), Plans
[JK](JK-my-manuals.md), [LR](LR-company-vaults-from-the-portal.md) and [LW](LW-vault-authoring.md)
(who imports a manual, and where they see how it went).

---

## Trigger

A technician asks about the condensate trap on a furnace. The answer cites *"Installation Manual, page
41, §General"*. The manual has eleven sections called *General*, one under every chapter, and the
technician has to page around to find which one. The PDF knew: its bookmarks list *Venting › General*,
and its headings are numbered *6* and *6.1*. Nothing reads either today; every heading is one flat
level.

The same technician's office imported a scanned service manual last month. Pages 40–44 are a poor
photocopy and came out as half-words. The vault row says *"212 pages read by recognition · 5 low
confidence"*, which nobody reads as *"the wiring sequence is missing"*. Retrieval treats those pages
like any others.

And when a rule in `ManualStructure` or `TableExtractor` is wrong on some page of a real manual, we find
out when a tester reports a bad answer. There is no second opinion that points at the page before a
technician does.

## Outcome

- **Citations name the right place.** *"page 41, §Venting › General"* when *General* alone is
  ambiguous in that manual; *"page 41, §Venting"* when it isn't. A manual whose signals disagree keeps
  today's flat headings.
- **Whoever imports a manual is told how it read.** *"Most pages read well. Pages 40–44 read poorly;
  check them."*, with the pages one tap away. A manual that read well says so in one line.
- **Answers from a poor page say so**, the way a recognised scan's passages already do.
- **A developer can ask a second reader** which pages of a test manual we read differently, and get a
  list of pages and kinds of disagreement, never text.
- **A small page-image model is measured**, on the Mac and then on the phone, for scanned and
  photographed pages. It ships only if it clearly wins; otherwise the measurement is the result.

## What exists, and what doesn't

**Exists (verified against `main` on 2026-11-15):**
- `ManualStructure` (`OpenGlasses/Sources/Services/Vault/ManualStructure.swift`): `TypedLine` (text,
  dominant size, bold), `TypedPage`, `bodySize(of:)`, `isHeading(_:bodySize:)` (bold or 1.2× body
  size, at least body size, short, not a label word, not a numbered list step per `numberedNonHeading`),
  `standsAlone`, `caption`, `isDiagramPage`, and `render`, which writes every heading as `## text` and
  every caption as `### Figure N — title`. There is one heading level.
- `DocumentChunker` (`Services/RAG/DocumentChunker.swift`): `## ` sets `section`, `### ` sets
  `figure`, `<!-- page: diagram -->` marks a drawing, **any other HTML comment is stripped and
  ignored**. A chunk carries `section: String?`, one name. A document with no `## ` gets lexical
  headings (numbered, Chapter, ALL CAPS), again one level.
- `DocumentStore` (`Services/RAG/DocumentStore.swift`) stores `section TEXT` per chunk (added by
  `ALTER TABLE`, as `page`, `kind`, `figure` and the page span were), and embeds `chunk.text` as it
  is (`embedPassage`).
- `VaultRetriever.Passage.citation` (`Vault/VaultRetriever.swift`): title, page or page span, then the
  figure for a drawing or a table row, else `§section`. `provenanceNote` is appended for recognised
  text. KR P3's section run (`sectionRunBudget`, `sectionRunChunks`) carries a named section on.
- `Scripts/extract-manual-text.swift` mirrors `ManualStructure`'s rules; `--self-check` runs the same
  cases as `OpenGlassesTests/ManualStructureTests.swift`, which also reads the script's source.
- **Nothing in the repository reads a PDF's outline.** `git grep` for `outlineRoot` and `PDFOutline`
  finds nothing in `OpenGlasses/Sources`, `Scripts` or the tests.
- `VaultDocumentExtractor` (`Vault/VaultDocumentExtractor.swift`): text layer first,
  `pagesNeedingRecognition` (no text layer, or furniture only over an inked body), recognition through
  `ScannedPageReader` with `OCRCheckpoint`, and `Extracted.ocrPages` / `lowConfidencePages` /
  `structuredHeadings` / `diagramPages`.
- `ScannedPageReader` (`Vault/ScannedPageReader.swift`): `VisionScannedPageReader` goes through
  `OCRService` (`VNRecognizeTextRequest`) and returns a mean block confidence; `ScanRenderPolicy`
  renders at 200 dpi (150 when hot) and counts a page under 0.5 as low confidence.
- `VisionTableReader` (`Vault/VisionTableReader.swift`): `RecognizeDocumentsRequest` for a grid,
  `RecognizeTextRequest` for words, language correction off. `CellCertainty` marks doubtful cells.
- `CapturedManualMedia` (`FieldAssist/CapturedManual/`) recognises photographed pages with
  `VNRecognizeTextRequest`; `CapturedManualReview` records `ocrPages`, `failedPages`,
  `lowConfidencePages` and per-page detail.
- `OverprintedText` (`Vault/OverprintedText.swift`) collapses doubled CJK glyphs and counts them.
- `VaultDocumentLedger.Entry` (`Vault/VaultDocumentLedger.swift`) records per document `ocrPages`,
  `lowConfidencePages`, `structuredHeadings`, `diagramPages` and `physicalPageCount`, all optional so
  older ledgers decode. `VaultManagerView` shows *"N pages read by recognition · M low confidence"*.
- `ManualLanguageReport` (`Vault/ManualLanguageReport.swift`): counts-only lines for the support
  report. `VaultIndexingMonitor` shows indexing progress app-wide. `ManualLibraryAdmission` gates
  what My Manuals installs. `ManualFigureSheet` opens a manual's page.
- `VaultEmbeddingUpgrade` re-indexes a vault onto a new embedding model in the background, keeping
  the old index until the new one is complete.
- `LocalLLMService` links MLX's vision factory (`VLMModelFactory`) for the local model.
- `Scripts/table-extract-eval` (counts of captioned tables read as grids, and why the rest failed) and
  `Scripts/retrieval-eval` (hit@1, hit@4, MRR with bootstrap intervals; a paired comparison against a
  baseline run's per-question outcomes, with a *better / worse / within noise* verdict). Both keep
  their work outside the repository and print counts only.

**Doesn't exist:** heading levels; a section path; any use of a PDF's bookmarks; a per-page measure of
how well a page was read, beyond recognition confidence; a grade shown at import; a passage label for
a badly read page; any second reading to compare ours with; any page-image model.

## Design

### 1 · A second reader on the Mac test bench

**What it is.** [Docling](https://github.com/docling-project/docling), an open-source document
converter (code under the MIT licence), run **on a Mac only, pinned to one exact version**, over the
same manuals our pipeline imports, the way Plan IS runs CoolProp as a pinned generator. It is never
linked into the app, never run in CI, never run on the licence service. Its job is to point at pages
where our reading and another careful reading differ. It is not ground truth.

**Where it lives.** `Scripts/second-reader/`:
- `requirements.lock`: every Python package at an exact version with its hash, installed with
  `pip install --require-hashes` into a venv **outside the repository**
  (`~/Library/Caches/og-second-reader-venv`, as IS keeps CoolProp's).
- `read.py`, run as `<venv>/bin/python -I Scripts/second-reader/read.py`: converts one PDF and writes
  its per-page structure to the work folder.
- `compare/main.swift`: compiles the app's `ManualStructure`, `PDFTableReader`, `TableExtractor`,
  `PictureRegion` and `CellCertainty` unchanged, as `table-extract-eval` compiles its sources, reads the
  same PDF our way, reads the second reader's file, and prints the comparison.
- `run.sh` and a `README.md` in the style of the other harnesses.

**Nothing leaves the Mac.** The converter calls no remote service unless a pipeline option enables
remote services explicitly; without it, a remote model option raises an error instead. `read.py` never
sets it and checks it is off before converting. Model weights are downloaded once, by the converter's
own prefetch command, at pinned revisions, into a folder outside the repository; runs then set the
model hub offline and point at that folder, so nothing downloads during a run.

**Models and licences.** The converter's code is MIT; its README says each model carries its own
licence. **One OCR preset the converter offers uses weights under a modified OpenRAIL-M licence, free
only for research, personal use and organisations under USD 5M of funding or revenue: the bench never
selects it.** The bench reads born-digital pages with the converter's text-layer parse, its layout
model and its table-structure model, with its heading-level option and picture classification on, and
uses only models whose weight licence has been read and recorded in the README. Scanned pages are
measured separately (§4). The candidate page-image model, **Granite-Docling-258M**, has an MLX build
the converter can run; the converter's repository does not state that model's licence, so **its model
card must be checked and recorded before any decision to ship it**, and before the bench is used on a
company's manuals.

**What it compares, per physical page:**
- **Headings:** each heading's normalised text (case-folded, numbering stripped, whitespace and
  punctuation collapsed) and level, matched between the two readers within the page.
- **Reading order:** blocks matched by the overlap of their word sets; the share of matched pairs the
  two readers put in a different order.
- **Tables:** found by both, by one only; rows and columns of each matched table; the share of matched
  cells whose normalised text differs.
- **Picture regions:** found by both, by one only, and whether matched regions overlap by at least half
  of their union.
- **Words:** words one reader got from the page that the other didn't, which catches a broken text
  layer.

**What it prints: counts and classes, never text** (the numbers below are an invented example):

```
[SECOND] pages=340 compared=338 skipped_no_text=2 seconds=412
[SECOND]   disagree: heading_missing_ours=14 heading_extra_ours=3 heading_level=22 heading_name=5 order=9
[SECOND]             table_missing_ours=4 table_missing_theirs=6 table_shape=3 cells=2 picture_missing_ours=7 words=1
[SECOND]   pages with any disagreement: 41 · worst 10 by classes: 40 41 42 43 44 88 120 201 202 260
```

Page numbers and class counts go to a per-page outcomes file in the work folder: the page's key (the
document's content hash and the physical page, hashed), and its count per class. The work folder must
be outside the repository and `run.sh` refuses one inside it (`SECOND_READER_WORKDIR`;
`SECOND_READER_LABEL` names a run, never the manual's title). The intermediate files there may hold
text from the manual and are deleted when the developer is done, under the same rules as
`Scripts/retrieval-eval/README.md`: licensed manuals are never committed, and nothing from a page goes
into a fixture, a plan or a PR.

**How disagreements are triaged.** The worst pages are opened by a developer on their own Mac, next
to the counts. Each page-and-class is marked in a local triage file (outside the repository, keyed by
the page key) as one of:
- **ours wrong**: a fixture is written with invented words that has the page's *shape* (never its
  content), the rule is fixed, and the fixture becomes a test;
- **theirs wrong**: recorded, and that page-and-class is left out of later reports;
- **both wrong, or a matter of taste** (is a bold lead-in a heading?): recorded, left out.

The share of triaged disagreements that were *ours wrong* is the number that says whether the bench is
worth running. If it stays low after three manuals, the bench is shelved (decision 1).

**How it fits the other harnesses.** `table-extract-eval` says whether a table came out as a grid; the
second reader says whether another reader saw the same grid; `retrieval-eval` says whether answers got
better. The second reader's output is cached by document content hash and converter version, so after
a change to our rules only our side runs again. With `SECOND_READER_BASELINE` naming an earlier run's
outcomes file, the change is judged the way `retrieval-eval` judges one: disagreements per page, B
minus A, a paired percentile bootstrap over pages (2,000 resamples), and a verdict. A change to
extraction is kept when it lowers *ours wrong* disagreements here and its `retrieval-eval` paired
interval doesn't show a loss.

**For Plan LX.** The converter can turn a bar or line chart into a table of its values. On the charts
in manuals a developer holds, that gives LX's P1 a second reading where no truth exists: LX's reading
and this one compared in LX's steps, pages where they differ by more than two steps listed for
checking by eye. Agreement makes neither reading right; LX's synthetic charts stay its truth. The
chart model's licence is checked like the others before it is used.

### 2 · Heading levels from three signals, decided per heading

**The signals, in order. For each heading, the first one that has something to say wins:**
1. **The PDF's own bookmarks** (`PDFDocument.outlineRoot`, a tree of `PDFOutline` entries, each with a
   label and a destination page and point). The tree's depth is the level. This is the author's own
   statement of the structure, so it comes first.
2. **Numbering at the start of the heading:** `4` is level 1, `4.1` level 2, `4.1.2` level 3;
   `Chapter 4`, `Part 2` and `Appendix A` level 1; `A.` and `A.1` count like `1.` and `1.1`; `(a)` and
   `(i)` sit one below the nearest numbered heading above them. Numbering never makes a line a heading:
   it only gives a depth to a line already accepted as one, so a numbered list step
   (`numberedNonHeading`) stays a step.
3. **Type:** today's rules decide what is a heading (bold or 1.2× body size, at least body size, stands
   alone). Among the document's headings, sizes are grouped into bands; the largest band is level 1,
   the next level 2, and so on to four. A document whose headings are all one size gives no level by
   type.

**Bookmarks matched to the page.** Each bookmark is matched to a line on its destination page:
normalised as in §1, a match when the texts are equal, when one is a prefix of the other of at least
twelve characters (a shortened bookmark), or when their words overlap by four fifths. With a
destination point, the nearest line at or below it wins. Then:
- **a matched line names the section**, in the words printed on the page, at the bookmark's level;
  a matched line the type rules didn't call a heading becomes one when it stands alone and isn't a
  caption or a label word;
- **a bookmark whose page has no matching line still starts a section** at its destination point (or
  the top of its page), named by the bookmark's title;
- **an outline that can't be trusted is ignored as a whole**: one entry, every entry on the first
  page, more than a fifth with no destination, or destinations that go backwards through the document.

**When the signals disagree, levels are off.** A wrong level is worse than none: it puts a section
under the wrong parent in every citation. Where two signals both speak on a heading, their levels are
compared (each signal's shallowest level counted as 1). If they agree on fewer than four in five of at
least five such headings, or more than a tenth of headings would go down more than one level at once,
the document keeps today's flat headings and the ledger records why. A document where only one signal
speaks uses it.

**What levels feed:**
- **A section path per chunk** (`sectionPath: [String]`, the ancestors' headings then the chunk's own),
  stored in a new `section_path TEXT` column beside `section`, which is unchanged.
- **Citations.** The leaf heading as today; its parent added only when the leaf's text names more than
  one section in that document: *"page 41, §Venting › General"*. Never more than two names.
- **Plan LY's sections.** `ManualSections` keeps a heading's children with it when they fit one group,
  instead of splitting at every subheading.
- **KR P3's section run.** When the turn names a parent section, the run carries on through its
  children in order, within the same character budget.
- **The lexical fallback.** A document with no `## ` (a recognised scan) gets levels from numbering
  only.

**The grammar.** `## ` stays the heading marker, so a document with any `## ` is still "structured".
The level travels as a comment on the line before: `<!-- level: 2 -->`. Today's chunker strips and
ignores it, so text written by a newer extractor reads as it does now on an older build, and older
extracted text (no comments) reads as level 1. `### ` stays the caption marker; using `###` and
`####` for depth would collide with it.

**Both producers agree.** The level rules live in `ManualStructure` and in its copy in
`Scripts/extract-manual-text.swift` (PDFKit reads bookmarks on the Mac too). `--self-check` gains the
same cases as the new tests, and `ManualStructureTests` checks the script carries the rule, as it does
for the drawing tag.

**Section path before embedding: measured only.** Prefixing each passage with its section path before
it is embedded (*"Venting › General: …"*) may help retrieval find the right *General*. It changes every
vector, so it needs a new embedding version and a re-index through `VaultEmbeddingUpgrade`. It is
built behind `retrieval-eval` (`RETRIEVAL_EVAL_SECTION_PREFIX=1`, its own work folder) and adopted only
if the paired comparison says *better* on hit@4 without a worse hit@1 (decision 4).

### 3 · A reading grade for every page, shown at import

**Measured per page during extraction (`PageReadingMeasure`, pure input):**
- **Text layer:** the share of characters that are replacement characters, private-use code points or
  controls (an unmapped font); doubled glyphs `OverprintedText` collapsed; a furniture-only page whose
  body was inked (outlined glyphs).
- **Recognised or text layer:** which one the page came from, and for a recognised page its mean
  confidence (`ScannedPageText.confidence`) or, for a photographed page, `CapturedManualReview`'s
  per-page detail.
- **Layout:** the share of the page's words that fell into no region: not a prose line, heading or
  caption, not a table cell, not inside a picture region.
- **Tables:** the share of a recognised table's cells `CellCertainty` marked uncertain, and captioned
  tables on the page that gave no grid.
- **Pictures:** captioned figures whose region `PictureRegion` didn't find.

**Graded (`PageReadingGrade`, `DocumentReadingGrade`, pure):**
- Each component maps to a score from 0 to 1 by fixed breakpoints, and the score to **poor, fair, good
  or excellent**. A component that doesn't apply (no tables on the page) is left out. **A page's grade
  is its lowest component's**: a page with a perfect text layer and an unreadable table is not a good
  page.
- **A document has two grades:** the *mean* of its page scores, and a *low* grade from the page at the
  5th percentile (the worst page, under 20 pages), so one bad stretch isn't averaged away.
- **Poor pages as ranges** (`PoorPageRanges`): consecutive poor pages joined, at most three ranges
  shown, then *"and 12 more pages"*.

**Shown to whoever imports the manual:** in My Manuals, in the vault manager row (replacing *"M low
confidence"* with the grade), at LW's *Add manual*, and in LW's vault check:
- *"Read well."* when both grades are good or better;
- *"Most pages read well. Pages 40–44 read poorly; check them."*, each range opening the page in
  `ManualFigureSheet`;
- *"Much of this manual read poorly. Answers from it will say so."* when the mean is poor.

For a company vault each company imports its own copies (LV), so each company's phone grades its own.

**Recorded with the document.** `VaultDocumentLedger.Entry` gains an optional `readingGrade`: both
grades, the poor ranges and counts per component, never text. Older entries decode with none and are
graded at their next re-index.

**Used by retrieval.** A passage from a poor page carries a note to the model the way recognised text
carries `provenanceNote` (*"this page read poorly; verify figures against the printed page"*); a passage
with both notes carries one. Fair pages carry none.

**Support report:** a counts line beside `ManualLanguageReport`'s (*"reading: 4 excellent, 1 good, 1
poor (low poor)"*), never a title or a page.

### 4 · A small page-image model, measured before anything ships

**What it would do.** Read a rendered page image into structured text, headings and tables included,
for the pages we recognise today: scanned pages (`VisionScannedPageReader`), pictured tables
(`VisionTableReader`) and photographed pages (`CapturedManualMedia`). The candidate is the model named
in §1. It would be one more `ScannedPageReader`, so everything around it (checkpoints, progress, the
grade) is unchanged.

**Measured on the Mac first, as a filter** (P4 has the details): our readers and the model over the same
page images, judged by a paired bootstrap per page and per question. Then the deciding numbers on an
iPhone: memory, seconds per page and heat.

**If it ships** (decision 6), the import is unchanged: every page is read by Vision as today, so the
manual is searchable at once. Then, **in the foreground only**, the model re-reads the recognised pages
graded poor or fair, and those pages' chunks are replaced. MLX runs on the GPU, which iOS forbids in the
background, and an MLX call made there ends the app with no chance to catch it: the reader checks the
app is active before loading and before every page, and stops between pages when the app leaves the
foreground, keeping what it finished. A cell the model reads is certain only when Vision's words in
the same cell agree (`CellCertainty`), since the model gives no confidence of its own. A page whose
reply repeats or runs to the token cap keeps Vision's reading.

**Delivered as a download**, never bundled: a `DownloadableModelBundle` through `ModelDownloader` on a
new route, with its size shown first, like the search model. The privacy copy says what it does; it
sends nothing anywhere.

## Decisions for Greig

1. **The second reader.** *Recommended:* run it on the Mac only, pinned, offline after the one-time
   model download, never in the app, CI or the service; shelve it if fewer than one in four triaged
   disagreements are ours after three manuals. *Alternative:* no second reader, and rely on answer keys
   and tester reports.
2. **What the bench may write.** *Recommended:* counts, classes and hashed page keys in the output and
   the outcomes file; text only in a work folder outside the repository, deleted after use.
3. **Heading levels by default.** *Recommended:* on for every document, decided per document, off where
   the signals disagree (fewer than four in five agreeing, or more than a tenth of levels jumping).
   *Alternative:* off by default and switched on per vault, which leaves most manuals flat.
4. **The section path before embedding.** *Recommended:* measure it in `retrieval-eval` and adopt it
   only on a *better* hit@4 with no worse hit@1, accepting one background re-index of every vault.
   *Alternative:* adopt it with the levels, without measuring.
5. **The reading grade.** *Recommended:* a page's grade is its worst component; the document shows a
   mean and a 5th-percentile low grade; the importer sees ranges to check; passages from poor pages are
   labelled for the model. Breakpoints set in P3 so that poor pages are where the bench finds us wrong.
   *Alternative:* a single document score, which hides the bad stretch.
6. **The page-image model.** *Recommended:* a measured go/no-go. Go only if the paired interval shows it
   better on character error and on retrieval hit@4 for recognised pages, it fits the iPhone's memory
   and time, and its licence is confirmed. If go, it re-reads only poor and fair recognised pages, in the
   foreground, as a download. *Alternative:* replace Vision for every recognised page, which makes
   every import slower and foreground-bound.
7. **Who sees the grade.** *Recommended:* whoever imports or manages the manual (My Manuals, the vault
   manager, LW's authoring); a technician using a company vault sees only the labelled passages.
   *Alternative:* show it to everyone who opens the manual.

## Phases

### P0 — the deterministic cores (headless)

Every input is hand-built: typed lines, outline entries, page measurements, two readers' page
structures.

- **Heading levels:** `PDFOutlineEntries` (the pure part: label, depth, page, point), `OutlineTrust`,
  `OutlineMatch`, `HeadingNumbering`, `HeadingStyleLevels`, `HeadingLevels.assign` and
  `HeadingLevelAgreement`; `ManualStructure.render` writing `<!-- level: n -->`; `DocumentChunker`
  reading it into `sectionPath`; `Passage.citation` adding the parent when the leaf is ambiguous; the
  same cases in `extract-manual-text.swift --self-check`.
- **Reading grade:** `PageReadingMeasure`, `PageReadingGrade`, `DocumentReadingGrade`,
  `PoorPageRanges`, `ReadingGradeCopy`.
- **The bench's comparison:** `ReadingComparison` over two per-page structures (headings, order,
  tables, regions, words) and its disagreement classes, in the test target so the Mac runner compiles it
  unchanged.

Tests:
- `OutlineMatchTests`: an exact title, a shortened bookmark, numbering stripped, the nearest line below
  a destination point, no matching line (a section start named by the bookmark), a matched line
  promoted, a caption never promoted.
- `OutlineTrustTests`: one entry, all on page 1, missing destinations, destinations going backwards.
- `HeadingNumberingTests`: `4`, `4.1`, `4.1.2`, `Chapter 4`, `Appendix A`, `A.1`, `(a)` under `4.1`;
  a numbered list step gets no level.
- `HeadingStyleLevelsTests`: three size bands; one size gives nothing.
- `HeadingLevelsTests`: per-heading precedence (bookmark over numbering over type); a half outline
  filled in by numbering.
- `HeadingLevelAgreementTests`: agreement switches levels on; disagreement and jumps switch them off.
- `DocumentChunkerTests` (extended): the level comment read into `sectionPath`; text without comments
  reads as level 1; a comment before a caption ignored.
- `SectionPathCitationTests` (new): a unique leaf cites alone; an ambiguous leaf cites its parent; a
  drawing and a table row cite as today.
- `ManualStructureTests` (extended): the Mac script carries the level rules.
- `PageReadingGradeTests`: each component's breakpoints; the lowest component wins; a component that
  doesn't apply left out.
- `DocumentReadingGradeTests`: mean and 5th-percentile low; a short document's worst page; one bad
  stretch in a good manual gives a good mean and a poor low grade.
- `PoorPageRangesTests` and `ReadingGradeCopyTests`: ranges joined, three shown then a count; each
  sentence in English and one other UI language.
- `ReadingComparisonTests`: a heading missing on one side, a level differing, two blocks swapped, a table
  with a different column count, a region overlapping by less than half, words only one side got.

### P1 — the second reader on the Mac (local, counts only)

`Scripts/second-reader/` as in §1: the lock file, the venv outside the repository, `read.py` under
`python -I`, the Swift comparison runner, `run.sh`, the README with each model's licence as read. A
first run over the manuals a developer holds, the worst pages triaged, the *ours wrong* share and the
class counts recorded in this plan as aggregates. LX's P1 gets its chart reference here.

### P2 — heading levels live

The outline read with PDFKit at import and in the Mac extractor; levels written and read; the
`section_path` column; citations, LY's sections and KR's section run using the path; the ledger
recording which signal decided and why levels were off. Measured with `retrieval-eval`'s paired
comparison (levels off against on) and the second reader's heading classes before and after. The
section-path prefix measured as its own variant (decision 4).

### P3 — the reading grade live

Measurements collected during extraction and capture; the ledger field; the import and manager rows,
the ranges opening their pages; the passage note; the support report line. Breakpoints set from P1's
triage: the pages graded poor should be where the bench found us wrong.

### P4 — the page-image model, measured (go/no-go)

**On the Mac, as a filter.** Granite-Docling-258M, at a pinned revision of its MLX build, run through
the same Swift MLX library the app links, so the Mac measures the code path the phone would run; the
converter's own run of the model is kept as a reference output only.
- **Character error, with truth for free:** born-digital pages rendered to images, then degraded
  (blur, skew, low resolution, JPEG) to look like scans and photographs; the text layer is the truth.
  Vision's readers and the model, paired by page, compared with the bootstrap; table cells compared
  the same way.
- **Retrieval:** `retrieval-eval` with a new `RETRIEVAL_EVAL_RECOGNISE=page-model` beside `grid` and
  `words`, over the developer's scanned manuals, in its own work folder, paired against Vision.
- Repetition and token-cap runs counted per page.

**On the phone, deciding.** A developer check in the style of `SearchModelPhoneCheck`: files copied by
hand, nothing in the product. It reports peak memory, seconds per page at 200 dpi, heat over 50 pages,
and that the reader stops cleanly when the app leaves the foreground. Counts and timings only. The
go/no-go and its numbers are recorded in this plan; the model's licence is confirmed from its model
card before a go.

### P5 — only on a go: the page-image model ships

The download route and Settings row, the reader re-reading poor and fair recognised pages in the
foreground, the cell cross-check, the privacy copy, `AIFeature` registration.

### P6 — device pass (owed)

On the phone with manuals the owner holds: a vault with bookmarks and one without, citations checked
against the pages; a scanned manual's grade and its ranges opened; a passage from a poor page in an
answer; with a P4 go, the model re-reading pages and the app sent to the background part-way.

## Risks

- **A wrong level.** Worse than none, so levels switch off per document on disagreement, and P2 measures
  them against the second reader and retrieval before they stay on.
- **The bench as a false authority.** It points; a developer decides. *Theirs wrong* is a triage
  outcome, and the bench is shelved if it mostly finds its own mistakes.
- **Licensed content.** The bench prints counts and hashed page keys; text stays in a work folder
  outside the repository; fixtures copy a page's shape in invented words, never its content.
- **A grade nobody trusts.** Breakpoints are set from triaged pages, not guessed, and the grade names
  pages a person can open and check.
- **A model that crashes the app in the background.** Foreground only, checked before every page.

## Out of scope

- **Running the second reader on the licence service for vault authoring.** Each company's manuals are
  sealed and the service never reads one; LW's decision 1 (drafting on the phone) stands.
- **New import formats such as Word, PowerPoint or EPUB.** A separate question about what manuals
  arrive as, not about how well a PDF is read.
- **Replacing our chunker.** Levels extend its grammar; packing, overlap and the clause rules stay.
- **Running the bench in CI.** It needs manuals that are licensed to individuals.
