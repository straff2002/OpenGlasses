# Plan P — Page & section citations for Document RAG

**Builds on:** [`DocumentChunker`](../../OpenGlasses/Sources/Services/RAG/DocumentChunker.swift), [`DocumentStore`](../../OpenGlasses/Sources/Services/RAG/DocumentStore.swift), and [`DocumentRAGTool`](../../OpenGlasses/Sources/Services/NativeTools/DocumentRAGTool.swift) — all shipped in Plan O. The retrieval path works; what it can't do is tell the user *where* in a document an answer came from.

**Strategic fit:** Voice-first. A glasses assistant that says *"that's in §5.3 of the safety manual, page 42"* is far more useful hands-free than one that cites an opaque chunk index. Pairs with Field Assist (Plan F) and accessibility (scan a leaflet, ask about it) — both benefit from grounded, locatable answers. Cross-pollinated from the qaeros RAG chunker (`server/core/data/documentChunker.js`), which already tracks page + heading per chunk; this ports that idea back into the Swift on-device path. Pattern reuse only.

**Effort:** ~half a day.

---

## What already exists (reuse, do not rebuild)

- **Sentence-aware packing:** `DocumentChunker` packs whole sentences (NLTokenizer), with sentence-aligned overlap and word/char hard-split fallback. Keep all of it — this plan layers metadata on top, it does not touch packing behaviour.
- **Storage + retrieval:** `DocumentStore` (SQLite, `Embedder` sentence vectors, cosine top-k, namespaces) and `Passage` are the surfaces that carry attribution back to the tool.
- **Citation surface:** `DocumentRAGTool.runQuery` renders each `Passage` into the tool-result string the LLM grounds on — today `(chunk N, score X)`.

## The gap

Chunks carry only `chunk_index`. A chunk index spoken aloud is meaningless. qaeros's chunker detects page boundaries (form-feed `\f`, "Page N" / "- N -") and section headings (numbered `5.3 …`, `Chapter/Part/Section/Article N`, ALL-CAPS lines) and records, per chunk, the page of its first word and the nearest heading. We have none of that. PDFs and multi-page extracted text carry exactly these markers; OCR'd glasses scans (single image) carry none — so detection must degrade gracefully to `nil`.

## New work

**1. `DocumentChunker` — tag chunks with page + section**
`Chunk` gains `page: Int?` and `section: String?`.
- One pass over the (trimmed) text builds offset-keyed breakpoints: form-feed and "Page N" / "- N -" → page number; heading lines (`detectHeading`, ported from qaeros) → current section.
- Tokenise sentences with their start offsets (new internal `taggedSentences`), look up the active page/heading at each sentence's offset.
- A chunk's `page`/`section` = the values active at its **first** sentence (matches qaeros semantics). Packing, overlap, and hard-split are unchanged; overlap tail carries tagged sentences. Plain text with no markers → both `nil`, identical chunk text to today (existing tests stay green).
- `detectHeading` is pure → add table-driven cases to the chunker tests (numbered §, Chapter N, ALL-CAPS, and negatives like a normal sentence).

**2. `DocumentStore` — persist & return the metadata**
- `doc_chunks` gains `page INTEGER` and `section TEXT`. New install: add to `CREATE TABLE`. Existing install: guarded `ALTER TABLE doc_chunks ADD COLUMN …` (ignore the duplicate-column error via the existing silent `exec`) so a doc indexed under Plan O isn't lost.
- `insertChunk` binds page (nullable int) / section (nullable text); `ChunkRow` + `fetchChunks` SELECT them; `Passage` gains `page: Int?`, `section: String?` and `query` threads them through.

**3. `DocumentRAGTool` — speakable citations**
`runQuery` attribution becomes locator-aware, degrading cleanly:
- page + section → `From "Safety Manual" (page 42, §5.3 Safety Requirements, score 0.81)`
- page only → `(page 42, score …)`; section only → `(§5.3 …, score …)`; neither → `(chunk N, score …)` as today.
Update the trailing instruction so the model is told it may cite the page/section when present.

**4. No new tool, no registry change, no system-prompt edit**
This extends an existing tool's output only — `document_knowledge`'s schema and registration are unchanged, so steps 3–4 of CLAUDE.md "Adding a New Tool" don't apply. XcodeGen auto-includes the edited files; no `.pbxproj` work.

## Out of scope
- No re-chunk/migration of already-ingested docs — new metadata applies on next ingest; old chunks simply return `nil` page/section and fall back to chunk-index citation. Flag a follow-up if re-indexing proves worthwhile.
- No embedding/retrieval changes — purely the chunk-production + attribution path.
- BM25/hybrid retrieval stays out (the qaeros direction); OpenGlasses' on-device semantic path is deliberate.
