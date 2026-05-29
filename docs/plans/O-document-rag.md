# Plan O — Document RAG (chat with your files)

**Builds on:** [`SemanticMemoryStore`](../../OpenGlasses/Sources/Services/SemanticMemoryStore.swift) (SQLite + `NLEmbedding` + cosine, already shipped) and [`OCRService`](../../OpenGlasses/Sources/Services/Accessibility/OCRService.swift) (Plan A1). On-device LLM (Apple FoundationModels), `NLEmbedding` semantic search, and web search are **already in OpenGlasses**. The one genuine gap is *persistent, retrievable, chunked document knowledge* — "load a manual/PDF and ask questions about it across sessions."

**Strategic fit:** Consumer + B2B. Pairs naturally with Field Assist (Plan F vaults are curated; this is bring-your-own-doc, unstructured) and accessibility (scan a leaflet, then ask about it hands-free). Net-new capability, not a duplicate.

**Effort:** ~3-4 days.

---

## What already exists (reuse, do not rebuild)

- **Vector math + storage:** `SemanticMemoryStore` already has `embed()` (NLEmbedding word-vector average → `[Float]`), `cosineSimilarity()`, `vecToData`/`dataToVec` BLOB round-trip, a WAL SQLite handle, and the `exec(_:blob:)` helper. The RAG store reuses all of these.
- **Text extraction:** `OCRService.recognizeText(in:)` (Vision) already turns a glasses photo or image into text — the ingestion path for scanned docs. `DocumentScanTool` shows the capture→OCR flow.
- **Tool wiring:** `NativeToolRegistry` injects the shared store into tools (see lines 173–179 — `searchTool.memoryStore = memory`). A RAG tool follows the same pattern.

## The gap

`SemanticMemoryStore` is key/value + diary: short atomic facts, one embedding each. It cannot ingest a 20-page PDF, split it, retrieve the 3 relevant passages, and ground an answer with source attribution. That's what this adds.

## New work

**1. `DocumentChunker` (pure, testable)**
`Sources/Services/RAG/DocumentChunker.swift` — splits raw text into overlapping chunks (~600–800 chars, ~100-char overlap, prefer sentence/paragraph boundaries via `NLTokenizer(.sentence)` so we don't cut mid-sentence). No I/O, no embeddings → ideal unit-test target (table-driven, like `VaultValidator`).

**2. `DocumentStore`**
`Sources/Services/RAG/DocumentStore.swift` — `@MainActor`, mirrors `SemanticMemoryStore`'s SQLite style. Two new tables in **its own** `documents.sqlite` (keep it separate from `semantic_memory.sqlite` so doc bulk doesn't bloat the memory DB or trip its `trim()` budgets):

```
documents(id, name, source_type, namespace, created_at, chunk_count, char_count)
doc_chunks(id, document_id, chunk_index, text, embedding BLOB, created_at)
```
- `ingest(name:text:namespace:) async -> DocumentRef` — chunk → embed each chunk → batch-insert.
- `query(_:limit:namespace:docIds:) -> [Passage]` — embed query, cosine over `doc_chunks` (optionally filtered to a doc set), return top-k with `(docName, chunkIndex, text, similarity)`.
- `list() / forget(documentId:) / clearAll()`.
- Reuse `embed`/`cosineSimilarity` by extracting them into a small shared `Embedder` (see open questions) **or** copy the two methods — they're ~20 lines. Recommendation: extract `Embedder` so both stores share one implementation and a future quality upgrade lands in both.

**3. Ingestion off the main thread**
A large doc = hundreds of `NLEmbedding` lookups. `SemanticMemoryStore` embeds short strings synchronously, which is fine; document ingestion is not. Run chunk-embedding in a detached task (or batch with `await Task.yield()` between chunks), then hop back to `@MainActor` to batch-insert. Surface progress so the UI/TTS can say "indexed 12 of 40 pages."

**4. `DocumentRAGTool` (the agent surface)**
`Sources/Services/NativeTools/DocumentRAGTool.swift`, conforms to `NativeTool`. Actions:
- `ingest_scan` — capture via glasses camera → `OCRService` → `DocumentStore.ingest`. ("remember this document")
- `ingest_text` — ingest pasted/spoken text or a file already extracted.
- `query` — retrieve top-k passages, return them **as the tool result string with source attribution**; the LLM then answers grounded (same contract as every other tool — `execute` returns `String`). Do *not* answer inside the tool.
- `list` / `forget`.

Wire in `NativeToolRegistry.init()` behind the same `if let memory` style guard (gate on a `documentStore` dep), injecting the store like `MemorySearchTool`.

**5. System-prompt registration**
Add the tool description to the system prompts in **both** `LLMService.swift` and `GeminiLiveSessionManager.swift` (per CLAUDE.md "Adding a New Tool" step 3), plus the `project.pbxproj` entries (step 4) for each new file.

**6. Minimal management UI (optional for v1)**
`DocumentsView` — list ingested docs, ingest via Files picker / scan, per-doc delete. Voice-first works without it, but it mirrors `VaultManagerView` (Plan H) and makes storage visible/deletable. Defer if time-boxed.

## Retrieval-quality note (the one real tradeoff)

`SemanticMemoryStore` averages **word** vectors (`NLEmbedding.wordEmbedding`). For long chunks this is weak — averaging 600 chars of word vectors washes out meaning. `NLEmbedding.sentenceEmbedding(for: .english)` (iOS 14+) is markedly better for passage retrieval.

Recommendation: the new `Embedder` tries `sentenceEmbedding` first, falls back to word-average. **Scope guard:** apply the upgrade to *document chunks only* at first. Changing `SemanticMemoryStore`'s `embed()` would invalidate every stored memory vector (they'd need a re-embed migration) — out of scope here. Flag a follow-up to migrate memory embeddings once the document path proves the sentence model out.

## Build order

1. `DocumentChunker` + unit tests (pure, no deps).
2. `Embedder` (extract `embed`/`cosineSimilarity`; sentence-first with word fallback) + tests.
3. `DocumentStore` (tables, ingest, query, forget) + tests against a temp DB.
4. Async ingestion + progress.
5. `DocumentRAGTool`, registry wiring, system-prompt + pbxproj entries.
6. `DocumentsView` (optional).

## Open questions

- **Collections vs flat KB?** A per-session vector collection scopes retrieval tightly but adds bookkeeping. For a glasses agent a single global doc KB with optional `docIds` filtering is simpler and matches how `SemanticMemoryStore` uses `namespace`. *Recommendation: flat KB + per-persona namespace, `docIds` filter for "ask only about this doc".*
- **PDF ingest?** OCR handles scanned/image docs today. Native text PDFs would want `PDFKit` (`PDFDocument.string`) to avoid lossy OCR — no current `import PDFKit` in the tree. *Recommendation: v1 = scan + text; add PDFKit as a fast-follow.*
- **Storage caps / eviction?** Memory has char budgets + `trim()`. Docs are bigger and user-owned — silent eviction would be surprising. *Recommendation: no auto-evict; explicit `forget` + a visible total in `DocumentsView`, warn past a soft cap.*
- **HIPAA mode?** `SemanticMemoryStore` blocks gateway push under `Config.hipaaMode`. Document content is all-local already, but confirm no chunk text leaks to the OpenClaw gateway. *Recommendation: doc store is strictly on-device, never synced.*

## Dependencies

- `SemanticMemoryStore` patterns (shipped), `OCRService` (Plan A1, shipped). No new SPM packages for v1 (PDFKit is a system framework if/when added) — we reuse the raw-sqlite3 + NLEmbedding stack already in the repo rather than adding a third-party vector DB.
