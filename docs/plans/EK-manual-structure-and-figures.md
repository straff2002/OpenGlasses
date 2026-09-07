# Plan EK — Manual Structure and Figures (headings from type, diagrams as pictures)

**Status:** 🚧 P1–P3 implemented 2026-09-07 (headless); a device turn against a cloud provider is
pending. Stacked on [Plan EJ](EJ-manual-retrieval-fidelity.md) (PR #425). What each phase found —
including two rules the design did not have, one measured cost, the P1 rule P2 had to work around,
and the route mistake P3 nearly shipped — is in **P1 findings**, **P2 findings** and **P3 findings**
below.
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

### 4 · The figure reaches the model as a picture, and the technician as a page

- `FieldSessionService` records, per turn, the best diagram/figure passage among the evidence as
  `figureForTurn: (documentId, page, figure)`. A new `manual_figure` tool lets the model (or the
  technician, by voice: "show me figure 65", "show that figure again") request a specific figure or
  page; the tool resolves it from the ledger and stages it the same way, answering in text what it
  staged. The last figure stays on the session so it can be reopened.
- In `LLMService.sendMessage`, when `imageData` is nil and the active field session has a staged
  figure whose source document is a PDF in the vault baseline, render that page with
  `PDFPageRasterizer` at a bounded DPI, pass it through `LLMImagePreparer`, and send it as the
  turn's image. The prompt block says `Figure 58 (page 44) is attached as this turn's image`. A
  camera frame, when the turn has one, wins the single slot and the figure stays a citation.
- **The phone shows the page.** Speech cannot read a drawing back, and the model seeing it does not
  help the technician see it. A figure sheet on the phone, opened from the answer (and by the voice
  requests above), shows the rendered page with pinch-zoom, the citation as its title, and a jump
  to that page in the source PDF through PDFKit's own viewer — which is free with PDFKit and beats a
  static image for a dense diagram. The audit log records which figure was shown. When a Display
  device is connected, the lens gets a one-line cue (`Figure 58, page 44, on your phone`) and nothing
  else: the HUD screen model has no image type and a lens display cannot make a wiring diagram
  legible. No general manual browser.
- The Markdown route has no page to render: the citation still names the figure, the sheet and the
  tool say the figure is not available as a picture from this document. That is the honest limit and
  a reason to import the PDF rather than the extracted text; the vault guide says so.
- Gating: on for cloud providers, off for on-device models (`LLMService.isOnDevice`), following
  the existing vision choice for a session; no new settings string in P2.
- The rendered page is manual content, not a camera frame, so it does not pass the privacy filter,
  and it leaves the device only where the passages' text already does.
- Two P1 follow-ups ride with P2: `NOTICE` joins the label list (an isolated bold `NOTICE` banner
  is not a heading), and a **prose** chunk under a caption cites its `§Section` rather than the
  figure — the figure names a drawing, the section names prose; a diagram chunk keeps `Figure N`.

### 5 · Every citation is a door to the page it came from (P3)

An answer's `Source:` lines are machine-attached by the retriever, never recalled by the model, so
they are safe to make tappable. P3 turns them into the human-in-the-loop check a manufacturer's SOP
needs: the technician sees the page the answer was drawn from, in the manufacturer's own document
when it is present, and the session records that they did.

- **Citation chips.** Under each assistant message on the phone, one chip per `Source:` line —
  manual title, page, and figure or section — parsed from the message text. Tapping opens the P2
  sheet at that page. Core-file citations (`Source: error_codes.md`) open that section in the
  existing vault file editor, so a technician can check and an author can correct on the spot. By
  voice, "open page 20" / "show me that source" route through `manual_figure` with a page argument.
- **Two routes, one sheet, honest header.** PDF route: the sheet shows the manufacturer's page and
  the header says so — `Manufacturer's document · page 20 of 85 · unmodified since import`, the last
  clause checked against the ledger's content hash, not asserted. Markdown route: the sheet shows the
  page's stored text, rendered, and the header says `Extracted text · page 20` and whether the
  original is bundled (below).
- **The original alongside the extract.** A Markdown document in the manifest may name its
  original: `"source": "SLP99UHVK-service-manual.pdf"` (a PDF in the same `documents_dir`, copied at
  install, hashed in the ledger, never indexed — the text is what is searched, so an author's
  corrections still count). When present, the sheet offers **Open manufacturer's page** at the same
  page; when absent, the header says the original is not in this vault, which a compliance reviewer
  wants to know. An optional `"source_url"` per document offers the manufacturer's published copy,
  opened outside the app. Both fields optional; existing manifests untouched; the validator checks
  `source` exists and is a PDF.
- **Paging.** PDF route: PDFKit's viewer pages by swipe; the title shows `page N of M` and one tap
  returns to the cited page. Markdown route: the store knows every chunk's page, so the sheet pages
  through stored text by page number with the same title and the same return tap.
- **Pretty Markdown.** The chat renderer parses inline Markdown and fenced code today and nothing
  else; the vault files are headings and pipe tables. P3 extends the app's own block parser with
  headings, bullet and numbered lists, and pipe tables drawn as a grid in the design kit's type, and
  uses it for the core-file section view, the Markdown-route page view, and the chat transcript. No
  new dependency.
- **The audit trail says what was verified.** `citation_opened` (title, page, from which chip or
  voice request) and `page_verified` with a `source` of `manufacturer_pdf`, `extracted_text` or
  `external_url`; every page swiped to is a `page_viewed`. The session export lists, per answer,
  which citations were opened and against what. That is the double trust: the answer, and the page
  in the manufacturer's book the technician read.
- **Guide.** Step 1 gains: for anything a manufacturer requires as an SOP, import the PDF or bundle
  it as `source` beside the extracted text. Step 6 gains the citation-chip check.
- **Not in scope.** Highlighting the passage inside the PDF page (glyph mapping is fragile; the
  printed book is page-granular anyway), HUD beyond the one-line cue, and any manual browser beyond
  paging from a citation.

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
- **P2 — the picture (one PR). Done 2026-09-07.** §4: figure staging, `manual_figure` tool, the `sendMessage`
  seam, provider gating, prompt wording, the phone figure sheet with PDFKit page jump, the lens cue,
  audit-log lines naming the figure sent and shown, the two P1 follow-ups. Headless tests use a
  fixture PDF and a fake provider; the sheet's view model is tested without SwiftUI; the live edge
  is a device turn against a cloud provider, recorded when run.
- **P3 — citations as doors (one PR). Done 2026-09-07.** §5: citation chips, the two-route sheet header with the
  ledger-hash check, `source` / `source_url` manifest fields with validator and importer support, paging
  on both routes, the Markdown block renderer, the three audit events and the export lines, guide
  edits. Headless tests for the chip parser, the header decision, the manifest/validator/importer
  changes, the Markdown block parser (tables, lists, headings), the paging model, and the audit
  events; the sheet's view model without SwiftUI.
- **P4 — deferred.** Region-cropped figures (render only the figure's bounding box, not the whole
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

## P1 findings (2026-09-07)

Measured on the Lennox pair (78 + 85 pages) through both routes.

**The type carries the structure, and the rules in the design were not enough to read it.** Body
size came out at 10 pt on both manuals, as the probe said. Two rules had to be added before the
headings were usable, and both are about the same thing — this manual sets whole *paragraphs* in
bold, so "bold at body size" on its own is not a heading:

- **A heading stands alone.** A bold line whose neighbour above or below is also bold at body size
  is one line of a bold paragraph, not a place. Without this the installation instructions yielded
  316 "headings", most of them wrapped warning text (`§EQUIPMENT MAY EXPERIENCE PREMATURE COM-`).
  With it, 117 — and they read like the book's own contents list. A figure caption and the
  parenthetical qualifier a heading absorbs are not neighbours for this purpose, and neither is the
  publisher's running page header, which is set in the same bold directly above the first heading on
  every page.
- **A numbered list step is a step whatever weight it is set in.** `4 - Go to setup / system devices
  / thermostat / edit` is bold, body size and stands alone; EJ's `numberedNonHeading` screen, which
  the lexical path already had, applies to the structural path too.

Shape rules that also earned their place: a heading starts with a capital or a digit and does not
end on a broken word or an unfinished clause (`stallation in mobile homes, recreational vehicles or`
is the middle of a sentence), and a parenthetical line is never a heading on its own — it belongs to
the line above it.

**The two routes agree on 470 of 471 grammar lines.** Running the script on the Mac and
`VaultDocumentExtractor` on the phone over the same two PDFs and diffing the `## `/`### `/diagram
lines: the service manual is identical (237/237); the installation instructions differ by one line
(234 vs 235). The cause is not a rule but the platforms: `BLOWER DATA` on p.56 is set in a font
whose weight macOS's PDFKit reports as bold and iOS's reports as regular, so the Mac marks it a
heading and the phone leaves it as text. Both manuals still report **0 pages printed a page number
that disagreed with the PDF page**, and both give 11 diagram pages.

**A drawing's figure names the page, not a point inside it.** Page 44 of the installation
instructions prints `FIGURE 58` and then `TABLE 16`, `TABLE 17` and `TABLE 18` over the same
drawing. Taking each caption in turn would cite the `24VAXC` row as `Table 18`, and the page's
extracted text starts before any caption at all, so the first chunk would carry no figure. Both
producers therefore write the page's own caption — its `FIGURE` if it has one, else its first
`TABLE` — at the top of a diagram page, and the chunker lets the first caption on a drawing stand
for the whole page. This is what makes the plan's acceptance sentence true (`SLP99UHVK Installation
Instructions, page 44, Figure 58`) and it is the right shape for P2, which will send the *page* as
the image. Per-table precision inside one drawing is P3 territory (cropping) rather than something
to fake with metadata.

**Prose and a drawing never share a chunk.** A chunk takes its kind and figure from its first
sentence, so the tail of a prose page packing into the top of a wiring diagram would cite a page of
terminal labels as prose. The chunker now closes the chunk when the kind changes, and carries no
overlap across that seam. Nothing moves in a document that is all one kind, which is every document
without a diagram page — the existing chunking tests are untouched.

**A caption outranks a section in a citation, and that costs something.** `Title, page N, Figure 58`
comes before `Title, page N, §Section` as the plan specified, so a prose passage that sits below a
caption is cited by the caption rather than by the section it is in — `page 12, Figure 16` rather
than `page 12, §Discharge Air Temperature Sensor`. A `## ` heading clears the figure (a new section
is new material), which keeps this to passages that really do sit under the caption, but it is a
judgement the plan should own rather than a detail: the figure is the thing a technician can point
at, the section is the thing they can look up.

**The gate, re-measured on the restructured corpus** (`RetrievalGateCalibrationTests`, `nl-word.en`,
701 chunks, the same 17 in-scope / 16 out-of-scope questions as EJ §2). Excluding drawings from the
semantic candidates and re-chunking the text moves recall; the gate itself was not retuned.

| variant | recall@4 | insufficiency recall | in-scope refused |
|---|---|---|---|
| floor 0.30 (the pre-P2 gate) | 0.706 | 0.000 | 0.000 |
| floor 0.30 + terms ≥ 3 | 0.706 | 0.750 | 0.176 |
| **default (terms ≥ 3, fraction 0.75)** | **0.765** | **0.750** | **0.118** |

Against EJ's table on the same set the adopted default's recall@4 falls from 0.824 to 0.765;
insufficiency recall (0.750) and in-scope refusals (2 of 17) are unchanged, and the ordering of the
variants is unchanged, so every assertion in the calibration test still holds. The similarity ranges
still overlap completely (in-scope 0.645–0.919, out-of-scope 0.649–0.897), which is why a 0.06 shift
in recall@4 is a reshuffle among passages that all score about the same rather than a signal.

**The visible cost of that reshuffle**, recorded rather than tuned away: *"what is the manifold
pressure on high fire"* reached Service Manual p.65 at rank 3 before this plan and reaches no anchor
page at any limit after it, while the short form a technician actually says — *"high fire manifold
pressure"* — answers from p.67 at rank 1. `ExampleVaultLennoxTests` asserts the short form and
prints the sentence form, so the cost stays on screen instead of disappearing into a passing test.

**What EJ's residue looks like now.** The four fragments EJ named (`§BOTH SENSOR`, `§1- DATA LOW
CONNECTION`, `§PRESS TO RESET`, `§TEST B`) are gone: they are diagram-page labels, the pages they
sit on are tagged as drawings, and lexical detection is off for any document whose type carried
structure. What replaces them are the manuals' own headings — `Turning Off Gas to Unit`,
`Pressure Switches (Two)`, `Failure To Operate`, `Priming Condensate Trap`. The residue that
remains is cover-page and banner furniture set as isolated bold lines (`NOTICE`, `Dallas, Texas
USA`, `FRONT VIEW`): harmless, page-1-ish, and not worth a rule that would cost real headings.
EJ's "two words or more" check in `ExampleVaultLennoxTests` is gone with them — one-word sections
are now `General`, `Filters` and the diagnostic codes, each a real place in the book.

## P2 findings (2026-09-07)

**The figure goes to the model and to the technician from one staging.** Retrieval happens once,
inside `manualPassagesContext`, so that is where the turn's drawing is staged: the best diagram (or
figure-bearing) passage among the evidence, cleared by the next turn that finds none. Everything
downstream reads that one published value — `LLMService` decides the image slot, the phone opens the
sheet, the lens flashes its line — so nothing searches the manuals twice and the three surfaces
cannot disagree about which drawing this turn is about.

**The prompt says "attached" only after the page has rendered.** The plan has the sentence appended
to the `MANUAL PASSAGES` block, which is built before anything is rendered; a render that then
failed (a missing baseline file, a page out of range) would leave the prompt promising a picture the
model never got, which is exactly the class of lie the whole retrieval design exists to prevent. The
sentence is therefore appended to the end of the system prompt, after the render returns bytes. The
cost is adjacency: it no longer sits directly under the passages it refers to, so it names the
citation explicitly and says the page is a manual page rather than a camera photo — which it had to
say anyway, because the vision block above it describes the glasses camera.

**A chunk takes its figure from its first sentence, so a caption below a heading is invisible to
it.** P1's rule (a chunk's kind and figure come from where it starts) means a text manual written as
`## Section` then `### Figure 9` then prose stores that chunk with no figure at all — the chunk
starts at the heading, where no figure was in force. Nothing here is wrong for the PDF route, where
a producer writes the page's own caption at the top of a drawing, but a hand-written vault document
has to put the caption above the prose it captions for the figure to be stored. The test fixture
does; the vault guide's `### ` example already reads that way.

**Two citations changed under the P1 follow-up**, both for the better — prose printed under a table
caption now cites the section it is in: `SLP99UHVK Service Manual, page 29, §Soft Disable` (was
`page 29, Table 19`) and `SLP99UHVK Installation Instructions, page 64, §High Altitude Information`
(was `page 64, Table 38`). No other citation in the Lennox pair moved, and no drawing's did — a
diagram still cites its figure, which is the whole point of the rule.

**What is still device-pending.** No turn has gone to a cloud provider with a rendered page attached:
the seam, the decision, the render, the prompt line and the audit event are tested headlessly and the
sheet's content is decided by a view model with no SwiftUI in it, but whether a 150-dpi letter page
is legible *enough* to a given model for 8-point terminal labels is a question only a real turn
answers. If it is not, the answer is P3's crop rather than a higher DPI: the whole page at a
readable label size is a much larger image than the drawing at one.

## P3 findings (2026-09-07)

**The route is a property of the document, not of what happens to be on disk.** The first cut of the
sheet chose its route by asking "is there a PDF to show?" — which answers *yes* for a Markdown manual
whose original is bundled beside it, and would have opened the transcription's page under the header
`Manufacturer's document`. That is precisely the lie the header exists to prevent, and no test of the
PDF route would have caught it, because on that route the two questions have the same answer. The
route now comes from the document (`documentIsPDF`) and the bundled original is a switch the
technician makes; the extracted-text tests are what fail when it regresses.

**A swapped original is changed content, even when the text is byte-identical.** The ledger diff
compares the original's hash as well as the extracted text's, so re-importing a vault with a new PDF
re-ingests that document. It costs a re-index of text that did not change — and the alternative is
worse: the ledger keeps the hash it recorded at import, so leaving it stale would have the header
check the file on screen against the hash of a file that is no longer there and report the
manufacturer's own copy as *changed since import*.

**A citation cannot be split on its commas.** `Title, page 44, Figure 58` and
`error_codes.md, models.md` are the same punctuation meaning two different things. Splitting reads
one of them wrong whichever way it is written, so the parser groups instead: a part naming a page, a
`§section` or a `Figure N` belongs to the citation before it, and anything else starts a new one.
One rule reads both shapes, and a part that belongs to nothing — `Source: page 4` — is dropped rather
than promoted to a document.

**The extracted-text route pages through what the store holds, not 1…N.** A chunk carries the page
its *first* sentence is on (P1), so a short page swallowed whole by a chunk that began on the page
before has no stored text of its own. Paging over the pages the store actually holds — sparse, in
order — is therefore the honest offering; a cited page the store has nothing for opens the nearest
page it does have rather than a blank. On the Lennox pair the loss is small and real: the service
manual's 85 pages hold stored text on 83 and the installation instructions' 78 on 76 — two pages each
with no text of their own, either swallowed by the chunk before them or carrying nothing extractable.
`ExampleVaultLennoxTests` prints both numbers rather than asserting one, because they are a property
of the manuals' typesetting rather than of the code.

**What P3 deliberately did not do with the bundled original.** A Markdown document with a `source`
now has a page that could be rendered for the *model* as well as for the technician, but
`ManualFigureAttachment` still asks whether the imported document is a PDF. Left alone: P2's decision
is tested against that question, the plan's §5 is about the sheet, and widening the model's image
slot is a change to what leaves the device — which belongs in its own phase with its own test, not in
a paragraph of a UI phase.

**The chat renderer changed for every answer, not only Field Assist ones.** Headings, lists and pipe
tables are parsed app-wide because `MessageContentView` is one view; a fault-code table in a vault
answer and a table in a general chat reply are the same text going through the same parser. That is
the intent of §5's "pretty Markdown" and it is worth naming rather than discovering: the surface it
touches is larger than the plan's other work.

**A chip's visibility is a cheap check, not a resolution.** `canOpenCitation` is asked once per
citation per drawn message, so it asks whether this vault has a reference tier (or a core file of
that name) rather than resolving the document — which reads the ledger off disk. The tap resolves,
and a citation that resolves to nothing opens nothing and logs nothing, because an audit line saying
a page was opened when it was not is worse than a chip that does nothing.
