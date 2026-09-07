# Plan EK — Manual Structure and Figures (headings from type, diagrams as pictures)

**Status:** 📋 Planned 2026-09-07. Stacked on [Plan EJ](EJ-manual-retrieval-fidelity.md) (PR #425).
**Origin:** EJ P1 tightened the lexical heading rules and left a residue it could not reach: an
ALL-CAPS wiring-diagram fragment (`§BOTH SENSOR`, `§1- DATA LOW CONNECTION`, `§PRESS TO RESET`,
`§TEST B`) is indistinguishable by any rule over letters from a real heading like
`BOTTOM RETURN AIR`. Probing the Lennox SLP99 PDFs with PDFKit's attributed string (2026-09-07)
showed why, and showed the fix: the real headings in these manuals are **bold at body size**
(`Turning Off Gas to Unit`, `Failure To Operate`, `Pressure Switches (Two)`) — mixed case and
unnumbered, invisible to every lexical rule — while a diagram page is mostly 8-point labels under a
bold `FIGURE 58` caption (page 44 of the installation instructions: 967 characters at 8 pt, 119 at
10 pt). Type carries the structure the words do not.
**Priority:** P1 for the Field Assist commercial track. A wiring question is the commonest question
a furnace technician asks a manual, and today its answer is prose retrieved from a bag of terminal
labels with a nonsense section in the citation.
**Surfaces:** Extraction, chunking, retrieval, one per-turn image. No schema break, no new
dependency, no UI beyond an existing settings toggle's scope. Pairs with
[Plan EL](EL-equipment-identity.md), which is independent of it.

---

## Verified starting point

- **PDFKit gives type per run, on both platforms.** `PDFPage.attributedString` returns an
  `NSAttributedString` whose `.font` runs carry point size and bold trait. On the Lennox pair the
  document-wide body size is 10 pt; section headings are 10 pt bold; figure and table captions are
  10 pt bold and match `^(FIGURE|TABLE)\s+\d+`; diagram labels are 8 pt regular; notes and warnings
  are bold but start with a label word. Nothing in the app reads the attributed string today:
  `VaultDocumentExtractor.textLayerPages` uses `page.string`, and the extractor script does the same.
- **The chunker's input is a plain string.** `DocumentChunker.chunk(_:)` detects pages from form
  feeds and whole-line `Page N` markers, and sections from `detectHeading` (EJ P1). It does not
  recognise Markdown headings, so the `## ` lines a vault author or the extractor script writes
  carry no weight. A chunk has `page` and `section`; nothing says what kind of page it came from.
- **Storage has the pattern for new columns.** `DocumentStore.createTables` adds `page`,
  `section` and `embedding_version` with `ALTER TABLE … ADD COLUMN`, swallowing the error when the
  column exists. `Passage` carries `page` and `section`; `VaultRetriever.Passage.citation` renders
  `Title, page N, §section`.
- **Retrieval has two paths.** `DocumentStore.query` (embedding) and
  `passages(containingToken:)` (exact whole token). EJ ranks token hits first. Diagram-page chunks
  are indistinguishable from prose in both.
- **One image per turn.** `LLMService.sendMessage(_:… imageData: Data? …)` carries a single image
  to every provider; `FieldSessionService.shared.promptContext(turn:)` is consulted inside
  `buildSystemPrompt`. The camera frame, when present, is that image. `PDFPageRasterizer.image(for:dpi:maxPixels:)`
  already renders a PDF page (EF, for recognition) and `LLMImagePreparer.prepared(_:)` is the one
  outbound size policy. On-device models must not be handed a rendered page as a matter of course
  (they run in the foreground only and vision costs them dearly); cloud providers already accept one.
- **The example pair is the fixture.** `examples/vaults/lennox-slp99/` (EJ) with the manuals present
  locally, plus the source PDFs alongside (`source-pdfs/`, local only, excluded from git) so the
  in-app PDF route is exercised as well as the Markdown route. `ExampleVaultLennoxTests` and
  `RetrievalGateCalibrationTests` already import it.

## Product promise

"A citation names the section a technician would see in the book. A wiring question gets the
wiring diagram, as a picture, with its figure number and page."

## Design

### 1 · One structured text format for both routes

Both the in-app PDF extractor and `Scripts/extract-manual-text.swift` emit the same
Markdown-flavoured text, so the chunker has one input grammar and a hand-written vault document
gets the same treatment as a machine-extracted one:

- `Page N` on its own line opens a page (EJ rule, unchanged).
- `## Heading` sets the section for what follows. The heading text stays in the chunk (it is
  content); the hashes do not.
- `### Figure 58 — Integrated Control` (or `### Table 16 — …`) records a figure or table caption:
  the chunk gains `figure = "Figure 58"`, the section is unchanged.
- `<!-- page: diagram -->` immediately after a page marker tags the page as a diagram. The line is
  stripped from the text. Any other HTML comment is stripped and ignored, so authors can annotate.

Structural detection, from type, per PDF (shared logic, one implementation in the app and a
faithful copy in the script with a `--self-check` case per rule):

- **Body size** is the character-weighted modal point size across the whole document, not the
  page — a diagram page's mode is its labels.
- **Heading**: a line whose dominant run is bold, at least body size, ≤ 80 characters, not a
  label (`FIGURE|TABLE|NOTE|WARNING|CAUTION|DANGER|IMPORTANT`), not ending in a sentence terminator,
  and not a bare number (the `1 2 3 4` callouts on the tubing figure are bold). Two consecutive
  heading lines merge when the second is parenthetical (`PRESSURE SWITCH TUBING INSTALLATION` +
  `(shown in upflow position)`).
- **Caption**: a bold line matching `^(FIGURE|TABLE)\s+\d+`; the following line, when it is also
  bold and not a caption, is its title.
- **Diagram page**: ≥ 60 % of the page's characters are below body size **and** fewer than one
  sentence terminator per 200 characters. A table page (`TABLE 16` on p.44 is also 8 pt) meets the
  first test and often the second; that is acceptable — a table is read as a figure too, and its
  rows still reach token search. A page that is all prose at body size is never a diagram.
- **Lexical fallback**: when a document yields no structural headings at all (plain text, EPUB,
  a PDF whose fonts are all one size and weight, the Markdown route without `##`), `detectHeading`
  from EJ applies. When it yields any, lexical detection is off for that document — the fragment
  problem ends there.

### 2 · Chunks and storage know the kind

`DocumentChunker.Chunk` gains `kind: Kind` (`prose`, `diagram`) and `figure: String?`.
`DocumentStore` adds `kind TEXT` and `figure TEXT` to `doc_chunks` by the existing `ALTER` pattern;
`Passage` carries both. Existing rows read back as `prose`/nil and keep working; no re-index is
forced (chunk boundaries are unchanged for prose; a diagram page's text was already one or two
chunks).

### 3 · Retrieval treats a diagram as a diagram

- `DocumentStore.query` excludes `diagram` chunks from the semantic candidates by default (a bag
  of labels embeds to noise and crowds the top four); `passages(containingToken:)` includes them
  (`W951`, `DS`, `LGWP1` are exactly what is asked about). A `kinds:` parameter keeps both
  behaviours explicit and testable.
- `VaultRetriever.Passage.citation`: `Title, page N, Figure 58` when `figure` is set;
  `Title, page N (diagram)` for a diagram chunk without a caption; `Title, page N, §Section` only
  from a `##` heading; `Title, page N` otherwise. `DocumentRAGTool` renders the same fields.
- The `MANUAL PASSAGES` block labels a diagram passage as such (`[2] (wiring diagram, Figure 58,
  page 44) …`) so the model reads terminal labels as labels.

### 4 · The figure reaches the model as a picture

- `FieldSessionService` records, per turn, the best diagram/figure passage among the evidence as
  `figureForTurn: (documentId, page, figure)`. A new `manual_figure` tool lets the model (or the
  technician, by voice: "show me figure 65") request a specific figure or page; the tool resolves
  it from the ledger and stages it the same way, answering in text what it staged.
- In `LLMService.sendMessage`, when `imageData` is nil and the active field session has a staged
  figure whose source document is a PDF in the vault baseline, render that page with
  `PDFPageRasterizer` at a bounded DPI, pass it through `LLMImagePreparer`, and send it as the
  turn's image. The prompt block says `Figure 58 (page 44) is attached as this turn's image`. A
  camera frame, when the turn has one, wins the single slot and the figure stays a citation.
- The Markdown route has no page to render: the citation still names the figure, and the tool
  says the figure is not available as a picture from this document. That is the honest limit and
  a reason to import the PDF rather than the extracted text.
- Gating: on for cloud providers, off for on-device models (`LLMService.isOnDevice`), following
  the existing vision choice for a session; no new settings string in P1/P2.
- The rendered page is manual content, not a camera frame, so it does not pass the privacy filter,
  and it leaves the device only where the passages' text already does.

## Phases

- **P1 — pure core (one PR).** §1 structured extraction in `VaultDocumentExtractor` (attributed
  string → Markdown-flavoured text; per-page kind; body-size mode), the chunker grammar (`##`,
  `###`, HTML comments, `kind`/`figure`), storage columns, retrieval kinds, citation rendering,
  lexical fallback rule, and the extractor script brought to the same output with self-checks.
  Tests: a font-bearing fixture PDF built with `UIGraphicsPDFRenderer` (bold and small runs);
  chunker grammar tests; `ExampleVaultLennoxTests` asserting real section names
  (`Pressure Switches (Two)`, `Turning Off Gas to Unit`), no `§FIGURE`/`§TABLE`/fragment citations,
  page 44 of the installation instructions as a diagram with `Figure 58`, and a token query for a
  terminal label reaching a diagram chunk with a figure citation; the PDF route exercised through
  the local `source-pdfs/` when present (skip otherwise), and the extractor script re-run on both
  PDFs to confirm zero numbering warnings and headings that match the in-app route.
- **P2 — the picture (one PR).** §4: figure staging, `manual_figure` tool, the `sendMessage`
  seam, provider gating, prompt wording, audit-log line naming the figure sent. Headless tests use
  a fixture PDF and a fake provider; the live edge is a device turn against a cloud provider,
  recorded when run.
- **P3 — deferred.** Region-cropped figures (render only the figure's bounding box, not the whole
  page), and per-manual heading lists for PDFs whose type carries no structure.

## Acceptance

- On the Lennox pair, `ExampleVaultLennoxTests` finds no citation whose section starts with
  `FIGURE`, `TABLE`, `WARNING`, `CAUTION` or a list step, and at least the two named bold
  headings appear as sections.
- Page 44 of the installation instructions is stored as `diagram` with `figure = "Figure 58"`; a
  semantic query never returns it; a token query for one of its terminal labels does, cited
  `SLP99UHVK Installation Instructions, page 44, Figure 58`.
- A document with no structural headings still gets EJ's lexical sections (`ScannedManualImportTests`
  and the Reading Companion suite stay green).
- `Scripts/extract-manual-text.swift --self-check` covers heading, caption and diagram rules; the
  script's output on the pair matches the in-app route's headings.
- P2: a turn without a camera frame whose evidence includes a figure sends that page as the image
  and says so in the prompt; a turn with a camera frame does not; an on-device model never receives
  a rendered page.

## Risks and non-goals

- **Fonts lie in some PDFs.** Scanned-then-OCR'd manuals have one font; some typesetters use size
  not weight for headings. The body-size rule plus "bold or larger" covers the second; the first
  falls back to the lexical rules, as it should.
- **Diagram false positives on table pages.** Accepted: a table page cited as a table with its
  caption is still right, and its rows remain token-searchable.
- **Not in scope.** Multi-image turns, cropping to the figure's bounds, OCR of diagram raster
  labels (EF's path applies if the page has no text layer at all), and changes to the live
  (Gemini Live / OpenAI Realtime) sessions, which already stream camera frames on their own path.
