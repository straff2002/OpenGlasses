# Plan EF — Scanned Manual Import (OCR for PDFs without a text layer)

**Status:** 🚧 P1 + P2 implemented 2026-09-03 (headless suite green; oldest-phone timing with a
real scanned OEM manual pending). What landed: `ScannedPageReader` seam with a Vision-backed
production reader; `VaultDocumentExtractor` decides per page (text layer where one exists, the
reader where not), keeps physical page numbers, and reports `ocrPages` / `lowConfidencePages`;
`ScanRenderPolicy` (200 dpi, 150 under thermal pressure, confidence floor 0.5) and
`PDFPageRasterizer` with a pixel cap; `OCRCheckpoint` keyed by content hash so an interrupted scan
resumes; the validator warns with page counts instead of refusing; the importer records
`vault_document_ocr` as the source type and the ledger carries the page counts; retrieval appends
a provenance note to recognised passages in both the prompt block and tool results; the Custom
Vaults row shows pages read by recognition and low-confidence pages, with a per-page progress
line during import. **Added beyond the draft:** `Scripts/extract-manual-text.swift`, a Mac-side
extractor (PDFKit + Vision) that writes Markdown with "Page N" markers the chunker reads as page
boundaries — so a pack author or a customer with a Mac can pre-extract once and the phone never
pays for recognition; verified on a mixed text/scan fixture.
**Origin:** Plan ED's P3 item, promoted to its own plan. The vault-building guide tells an author to
test every PDF by selecting a sentence; the ones that fail that test are exactly the manuals a
service company has most of — older OEM books that exist only as scans, photocopies, and the
PDFs a distributor emailed years ago. Refusing them by name is honest; it is not enough.
**Priority:** P2 for the Field Assist commercial track — the first pilot can start on text-layer
PDFs, but the second customer will hand over a binder of scans.
**Surfaces:** Phone import only. No change to sessions, tools, or the glasses.

---

## Product promise

"Drop the scan in the documents folder like any other manual. The phone reads it page by page,
and a citation still says which page."

## Verified starting point

- **The extractor already decides per document.** `VaultDocumentExtractor.extract(from:)` reads a
  PDF page by page through PDFKit, joins pages with a form feed so `DocumentChunker` keeps page
  numbers, and throws `.noTextLayer(file)` when no page yields text. The validator turns that into
  a refusal that names the file; `VaultImporter.syncDocuments` would throw the same way.
- **OCR is on-device and already in the app.** `OCRService.recognizeText(in cgImage:)` runs the
  Vision recognizer with a confidence floor and returns text plus per-observation confidence.
  Equipment lookup and the reading tools use it on camera frames today.
- **PDFKit renders pages.** `PDFPage.thumbnail(of:for:)` yields a `UIImage` at a chosen pixel size
  with no extra dependency. A letter-size page at roughly 200 dpi is about 1,700 × 2,200 pixels,
  which is what Vision wants for body text and small table type.
- **Ledger and chunking need nothing new.** A scanned document produces the same page-separated
  text as a text-layer one, so the ledger hash, the chunker, retrieval, and citations all work
  unchanged once the text exists. `DocumentStore` already records a `sourceType` per document.
- **Progress is already plumbed.** `VaultImporter.DocumentProgress` reports per-document chunk
  progress to the Custom Vaults screen; OCR needs a second, slower phase in front of it.

## Design

### Per-page decision, not per-document

A PDF is rarely all scan or all text. A manufacturer's reissue often has a typeset front section
and scanned appendices. The extractor therefore decides **per page**: use the text layer when the
page yields text, run OCR when it does not. The document keeps its physical page numbering either
way, so a citation to page 61 of a mixed manual is still page 61.

### `ScannedPageReader` seam

A small protocol with one method — page image in, recognised text and a confidence out — with the
Vision-backed implementation injected by the app and a table-driven fake used in tests. The pure
part is everything around it: which pages to send, how to assemble the result, what to do with a
low-confidence page, and how to report progress. This is what keeps the plan headless-testable
without a Vision run in the simulator being the arbiter of a passing suite.

### Confidence and honesty

- A page whose recognised text falls below the confidence floor is kept (a low-confidence page
  is still a better search target than nothing) but **counted**. The ledger entry records
  `ocrPages` and `lowConfidencePages`; the Custom Vaults row shows "412 sections · 38 pages
  read by OCR · 3 low confidence" so the author knows which manual to replace with a better scan.
- The document's `sourceType` becomes `vault_document_ocr` when any page was recognised, and the
  retrieval prompt block gains one line when a passage came from an OCR'd page: "(text recognised
  from a scan; verify figures against the printed page)". Numbers are where OCR fails quietly, and
  a technician reading back a torque value deserves to know its provenance.

### Cost and thermal behaviour

OCR at 200 dpi runs at a few pages per second on a recent phone and well under one page per second
on the oldest supported one. A 300-page scanned manual is minutes, not seconds, so:

- The importer OCRs in a background task that **yields between pages**, keeps the screen's
  progress bar moving with a page count, and survives the app going to the background by
  checkpointing recognised pages into a scratch file keyed by the document's content hash. A
  re-launch resumes from the last page, and the ledger only records the document once the last
  page is in.
- Rendering resolution is a policy, not a constant: 200 dpi by default, dropping to 150 when the
  device reports thermal pressure, so the import finishes rather than throttling to a crawl.
- The validator no longer refuses a scan. It **warns**: "RTU-500-service-manual.pdf has no text
  layer on 214 of 214 pages; it will be read by OCR at import, which takes several minutes." An
  author who sees the warning can decide to find the original PDF first.

## Build order

**P1 — pure core (one PR).**
- `ScannedPageReader` protocol; `VaultDocumentExtractor` gains a per-page policy over an injected
  reader, with `Extracted` reporting `ocrPages` and `lowConfidencePages`.
- Resolution policy as a pure function of thermal state.
- Ledger entry fields and the checkpoint file format (page index → text), with resume logic.
- Validator: `.noTextLayer` becomes a warning carrying the page counts.
- Prompt block provenance line for OCR-sourced passages.

**P2 — device edge (same PR if the simulator cooperates, else a follow-up).**
- `VisionScannedPageReader` over `OCRService`; PDFKit rendering; background task with
  progress and resume wired into `VaultImporter.syncDocuments` and the Custom Vaults screen.
- Timing on the oldest supported phone with a real scanned OEM manual; the number goes into the
  guide's sentence about how long to expect.

## Tests

- Mixed fixture: a three-page PDF with text on page 1, an image of text on page 2, and text on
  page 3 → the fake reader is called for page 2 only; the extracted text has two form feeds and
  page 2's recognised text in the right place; chunks cite page 2.
- All-scan fixture → every page goes to the reader; `ocrPages` equals the page count.
- Low-confidence page is kept and counted; a reader failure on one page yields an empty page and
  a count, never an abort.
- Checkpoint resume: a reader that fails after page 40 leaves a checkpoint; the next run starts at
  page 41 and produces the same text as an uninterrupted run.
- Resolution policy truth table over thermal states.
- Validator: scan → warning with counts, not an issue; the vault still installs.
- Prompt block includes the provenance line only for OCR-sourced passages.

## Non-goals

- Handwriting, annotations, or diagram understanding. Text only.
- Cloud OCR. On-device or it does not ship — the manuals are customer property.
- Fixing OCR mistakes in-app. The author replaces the scan with a better one.

## Open questions

- Resolved: pre-extraction is the primary path for packs. Three routes, in the guide's order:
  on-phone recognition for a customer importing a scan directly; any free OCR tool that writes a
  searchable PDF (OCRmyPDF, Acrobat, a scanner driver) on Windows, Mac or Linux — the PDF then
  takes the ordinary text-layer path with no recognition on the phone; and
  `Scripts/extract-manual-text.swift` on a Mac for authors who want editable Markdown, fetched
  from the public repository since it does not ship in the app. Whether a pack may *redistribute*
  extracted OEM text is Plan EG's licensing question, not a technical one.
- Language: Vision's recogniser is per-language; a French-language scan for a Canadian customer
  wants `["fr", "en"]`. A per-vault `language` manifest field serves both this plan and ED's
  embedding question.
