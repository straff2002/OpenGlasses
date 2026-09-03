# Plan ED — Vault Manual Retrieval (OEM manuals as a retrieved tier in Field Assist)

**Status:** 🚧 P1 + P2 implemented 2026-09-03 (headless suite green; P3 device edge pending). What
landed: `VaultManifest.documents` / `documents_dir` with a hand-written decoder so every existing
manifest still decodes; `VaultDocumentExtractor` (per-page PDF joined by form feeds, EPUB, Markdown,
text; scanned PDFs refused with a named reason); `CodeTokenizer` hoisted out of equipment lookup;
`VaultRetriever` + `RetrievalEvidencePolicy` with a **second retrieval path the plan did not
anticipate** — `DocumentStore.passages(containingToken:)`, an exact whole-token scan, because a bare
fault code like "ZX9" has no word vector and the semantic query returns nothing for it;
`VaultDocumentLedger` (`_documents.json` in the overlay; content-hash diff; re-import idempotent);
validator document checks + core-budget warning; `VaultImporter.syncDocuments` (async, entitlement-
gated, ledgered) and store-aware uninstall; `DocumentStore.clear(namespace:)` with the consumer
Documents screen hiding `vault:*` namespaces; `FieldSessionService.promptContext(turn:)` appending a
`MANUAL PASSAGES` block (or the explicit none-retrieved sentence); `manual_lookup` tool; equipment
lookup fall-through; exporter copies documents; Custom Vaults screen lists manuals with section
counts, indexes on install, re-indexes on demand, shows validator warnings.
**Origin:** A prospective Canadian HVAC / industrial integration partner asked to evaluate Field
Assist against the workflow "look at a nameplate, wiring mark, or fault code, ask by voice, get an
answer grounded in approved OEM manuals with its source, or a clear statement that the manual does
not cover it." The bundled vaults demonstrate that workflow; a real OEM service manual does not fit
the current vault design at all.
**Priority:** P1 for the Field Assist commercial track — the first paid pilot depends on it.
**Surfaces:** Phone import + spoken answers. No HUD dependency. Pairs with the licensing work in
[Plan EE](EE-field-assist-commercial-licensing.md), which it does not depend on.

---

## Product promise

"Load the manuals you trust. Ask about what you are looking at. Every answer names its page, and
when the manual is silent the assistant says so instead of guessing."

A vault gains a second tier. The **core** tier is what ships today: curated markdown (safety rules,
error-code tables, PT charts) loaded whole into the system prompt on every turn. The **reference**
tier is new: whole documents (OEM service manuals, wiring diagrams as text, installation guides)
that are chunked and embedded on-device at import and **retrieved per turn**, so only the handful of
passages relevant to the question reach the model, each carrying a page and section locator.

The citation stops being a model claim. The passages injected are the only reference material the
model sees for that turn, the locator is attached by the retriever rather than recalled by the
model, and a deterministic evidence gate produces the "insufficient information" answer when nothing
scores above threshold — before the model gets a chance to be helpful.

## Verified starting point

The retrieval substrate is already shipped and tested; the gap is that vaults cannot see it.

- **Whole-vault injection.** `VaultPromptBuilder.promptContext(for:)` concatenates every file the
  manifest lists into the system prompt; `FieldSessionService.promptContext()` appends the procedure
  runner's context and `LLMService.buildSystemPrompt` includes the result on every turn. The two
  bundled Field Assist vaults total ~23 KB of markdown, which is near the practical ceiling for
  voice latency and per-turn cost. One OEM service manual is 100–300 pages.
- **Document RAG (Plans O, P, AM) is shipped.** `DocumentStore` chunks, embeds, and stores documents
  in `documents.sqlite` with a `namespace` column, per-chunk `page` and `section`, a versioned
  embedding tag with `reindexOutdated` migration, `query(_:limit:namespace:documentIds:)`, and
  `forget(documentId:)`. `DocumentChunker` is pure and deterministic: sentence-aware ~700-char chunks
  with overlap, pages detected from form feeds and "Page N" markers, sections from numbered / ALL-CAPS
  headings. `Embedder` prefers the sentence model and the transformer `NLContextualEmbedding` when its
  assets are present, with a word-average fallback so retrieval never silently returns nothing.
- **Citations render already.** `DocumentRAGTool` returns numbered passages with a speakable
  locator ("page 42, §5.3 Fault codes") and instructs the model to answer using only those passages.
- **PDF extraction exists but flattens pages.** `BookFileExtractor.extract(from:)` handles PDF (via
  PDFKit), EPUB, and text — but it reads `PDFDocument.string`, which drops page boundaries, so the
  chunker's page detection never fires on a PDF. Per-page extraction with a form-feed separator is a
  small change and the difference between "page 42" and "chunk 117".
- **The consumer import path takes plain text only.** `DocumentsView`'s file importer allows
  `.plainText` / `.text`; PDFs enter only through the Reading Companion.
- **Equipment lookup is markdown-only.** `EquipmentLookupTool` OCRs the nameplate through
  `OCRService`, extracts code-like tokens (`candidateTokens(from:)`), and substring-searches the
  vault's markdown. A code that lives only in a manual misses, and the tool's miss message tells the
  model to "identify the code from the text above and look it up" — with nothing to look it up in.
- **Vault import is a validated folder.** `VaultImporter.install(from:)` copies `manifest.json`, the
  listed markdown, and `procedures/` into a baseline directory plus a `_registry` manifest;
  `VaultValidator.validate(directory:)` refuses missing files and broken procedure graphs;
  `VaultExporter` round-trips the folder. `VaultManifest` has no notion of documents.
- **Gating is one boolean today.** Custom vaults carry `gating.iap = "enterprise"` and
  `VaultRegistry.isUnlocked` routes that to `FieldAssistEntitlement.shared.isGranted`, which a solo
  one-time purchase satisfies. [Plan EE](EE-field-assist-commercial-licensing.md) P1 makes the
  entitlement tiered; the document tier is a **team** capability and gates on
  `isGranted(atLeast: .team)` at import and at retrieval. Bundled vaults and their markdown core
  stay solo. If ED lands before EE P1, the document tier gates on the existing boolean and the
  tier check is a one-line follow-up named in EE.
- **One hazard to design around.** `DocumentStore` is a single database shared with the consumer
  "chat with your files" feature. `clearAll()` is reachable from the consumer surface and would wipe
  a customer's manuals along with their personal documents. Vault documents must live in their own
  namespace **and** the consumer clear must become namespace-scoped in the same PR.

## Design

### Manifest: an optional `documents` tier

```json
{
  "id": "hvac_acme",
  "name": "Acme HVAC Service",
  "version": "1.0.0",
  "files": ["safety.md", "error_codes.md"],
  "procedures_dir": "procedures",
  "documents_dir": "documents",
  "documents": [
    { "file": "RTU-500-service-manual.pdf", "title": "RTU-500 Service Manual", "kind": "service_manual" },
    { "file": "RTU-500-wiring.pdf",         "title": "RTU-500 Wiring",         "kind": "wiring" }
  ],
  "gating": { "iap": "enterprise" },
  "prompt_rules": ["Never fabricate equipment data, error codes, or procedures.", "…"]
}
```

`files` stays the always-loaded core. `documents` is retrieved. A vault with only `files` behaves
exactly as today; a vault with only `documents` gets the rules and citation requirement but no
inline content. Accepted document formats: PDF (text layer), EPUB, Markdown, plain text. Scanned
PDFs without a text layer are P3 (OCR per page).

### Import: idempotent, ledgered, reversible

`VaultImporter.install` gains a document step after validation succeeds:

1. Extract page-aware text with a new `VaultDocumentExtractor` — per-page PDFKit iteration joined
   with `\u{0C}` so `DocumentChunker` sees page boundaries; EPUB and text pass through
   `BookFileExtractor` unchanged.
2. Ingest into `DocumentStore` under namespace `vault:<id>` with `sourceType` = the manifest `kind`.
3. Write `_documents.json` in the vault overlay: `{ file, title, documentId, contentHash, chunkCount }`
   per document. Re-import with an unchanged hash is a no-op; a changed hash forgets the old
   `documentId` and ingests anew; a document removed from the manifest is forgotten. Vault deletion
   forgets every ledgered document. This keeps the SQLite store and the folder in agreement without
   the folder ever being the source of truth for chunks.
4. Validation adds two checks and one warning: every `documents[].file` exists under
   `documents_dir`; the extractor yields non-empty text (a scanned PDF fails with a message that
   names the file and says why); and a **core budget warning** when the concatenated `files` exceed
   a threshold (start at 32 KB), because the right fix for an oversized core is to move content to
   the reference tier, and the validator is where the author will see it.

Ingest is async and yields between chunks (it already does); the manager UI shows per-document
progress and chunk counts. Export copies the source documents so the folder round-trips.

### Retrieval: hybrid, gated, deterministic

`VaultRetriever` (pure over an injected `DocumentStore` query function, so tests never touch
SQLite or embeddings):

- **Query composition.** The spoken turn, plus any OCR tokens from the current equipment lookup,
  plus the active procedure step title when a procedure is running. Each part is a separate query;
  results are merged by document + chunk index.
- **Hybrid scoring.** Embedding similarity from `DocumentStore.query` plus an exact-token boost for
  code-like tokens ("E5", "30RB", "T02") found verbatim in a passage. Embeddings handle "the unit
  short-cycles on a call for cooling" and handle "E5" badly; the boost handles the fault-code case
  that is the whole point of the workflow. `EquipmentLookupTool.candidateTokens(from:)` is hoisted
  into a shared `CodeTokenizer` so both tools agree on what a code looks like.
- **Evidence policy.** `RetrievalEvidencePolicy.decide(passages)` returns `.sufficient([Passage])`
  or `.insufficient(reason)`. The threshold is a similarity floor **and** a minimum count of one; a
  token boost alone can satisfy it (an exact fault-code hit is strong evidence even at a low cosine).
  The insufficient case renders a fixed sentence — "The loaded manuals do not cover this. Ask the
  technician for the model number, or recommend escalation." — that the prompt rules already
  instruct the model to relay rather than improve on.
- **Citation format.** `Source: <title>, page <n>` with `§<section>` appended when present. Page
  and section come from the passage, never from the model. The vault's
  `source_attribution_format` continues to govern the core tier; the reference tier's format is
  fixed because it is machine-attached.

### Where retrieval runs

Two entry points, sharing one retriever:

- **Per-turn pre-retrieval.** `FieldSessionService.promptContext()` gains a `turn:` parameter (the
  same shape `VoiceSkillStore.promptContext(for:)` uses) and appends a `MANUAL PASSAGES` block of at
  most four passages for the current turn. When the evidence policy says insufficient, the block
  states that explicitly so the model does not fall back to general knowledge silently. This is the
  path that makes "ask by voice, get a grounded answer" work without the model choosing to call a
  tool.
- **Explicit tool.** A new `manual_lookup` native tool (`query`, optional `document`, optional
  `use_camera`) for follow-ups ("what does the manual say about the pressure switch?") and for the
  model to widen a search on its own. It returns the same passage rendering `DocumentRAGTool` uses.
- **Equipment lookup falls through.** After the markdown miss, `EquipmentLookupTool` queries the
  reference tier with the OCR tokens before rendering its miss message, so a nameplate model number
  that exists only in the manual now resolves.

### Budget and latency

Retrieval is one embedding of a short query plus a cosine scan over the vault's chunks — a
300-page manual is roughly 1,500 chunks, well within a few milliseconds on-device. The system
prompt shrinks for any vault that moves content out of the core, which is a latency and cost win on
every turn, not just manual turns. The oldest supported phone is the P3 measurement target.

## Build order

**P1 — pure core, headless-tested (one PR).**
- `VaultManifest.documents` / `documentsDir` (Codable, optional, backwards-compatible with every
  existing manifest and the two built-ins).
- `VaultDocumentExtractor` with per-page PDF output; a fixture PDF proves page markers survive.
- `CodeTokenizer` hoisted from `EquipmentLookupTool`; existing tests move with it.
- `VaultRetriever` + `RetrievalEvidencePolicy` over an injected query function.
- `VaultDocumentLedger` (read/write/diff of `_documents.json`).
- `VaultValidator` document checks + core budget warning.

**P2 — wiring (same PR, or a second one if P1 review is slow).**
- `VaultImporter` ingest/forget via the ledger; `VaultExporter` copies documents.
- `DocumentStore`: namespace-scoped clear; the consumer `DocumentsView` calls the scoped version.
- `FieldSessionService.promptContext(turn:)` and the `LLMService` call site.
- `ManualLookupTool` registered in `NativeToolRegistry`; `EquipmentLookupTool` fall-through.
- `VaultManagerView`: documents section per vault with title, chunk count, ingest progress,
  re-index, and the validator's warnings surfaced inline.

**P3 — device edge (follow-up PR).**
- Scanned-PDF fallback: per-page render → `OCRService` → the same extractor output.
- Latency on the oldest supported phone with a 300-page manual loaded; `NLContextualEmbedding`
  asset availability offline (the word-average fallback must be visibly reported, not silent).
- A real OEM manual from the pilot partner as the acceptance fixture, run through the recall
  benchmark (`EmbeddingBenchmark.recallAtK`) with a labelled set of fault-code and free-text
  queries.

## Tests

- Manifest decode with and without `documents`; both built-ins still decode.
- Extractor: page markers present for a three-page fixture PDF; EPUB/text unchanged.
- Chunker fed extractor output yields chunks whose `page` matches the fixture.
- `CodeTokenizer` parity with the current `candidateTokens` cases.
- Retriever: token boost outranks a higher-cosine passage without the token; merge de-duplicates
  across query parts; procedure step title participates only when a runner is active.
- Evidence policy truth table: below floor → insufficient; single exact-token hit → sufficient;
  empty → insufficient with the fixed sentence.
- Ledger: unchanged hash is a no-op; changed hash forgets then ingests; removed entry forgets;
  vault delete forgets all.
- Validator: missing document file, empty extraction, core over budget (warning, not failure).
- Namespace-scoped clear leaves `vault:*` documents intact.
- Prompt context: passages block present with citations; insufficient block present when policy
  says so; absent when no session.
- Equipment lookup fall-through resolves a model number that exists only in the reference tier.
- A solo-only entitlement cannot ingest documents and gets no `MANUAL PASSAGES` block; a team
  entitlement does (provider injected, no StoreKit).

## Privacy and data handling

Manuals are customer intellectual property and stay on-device: `DocumentStore` is local SQLite,
never synced to the gateway, and the `PrivacyLog` entries it already writes record counts and a
source-type token, never content. Spotlight donation does not index documents (Field Assist
donation is metadata-only and per-vault opt-in today; this plan adds nothing to it). Vault export
includes the source documents because the customer owns them and needs the round trip; the
exported folder is theirs to secure.

## Non-goals

- Cloud or hosted vector search. Retrieval is on-device or it does not ship.
- Cross-vault retrieval. A session searches its own vault's namespace only.
- Diagram understanding. Wiring diagrams retrieve as text (labels, legends, table rows). Asking
  the vision model to read a diagram page is a separate plan.
- Editing manuals in-app. Import, re-import, delete.
- Entitlement or pricing changes beyond consuming the team-tier check —
  [Plan EE](EE-field-assist-commercial-licensing.md).

## Open questions

- **Tables.** Sentence-aware chunking can split a fault-code table across chunks. A table-aware
  pass (keep a markdown or PDF table row-block intact up to `maxChars`) is probably worth it for
  service manuals specifically; decide after the P3 fixture shows how often it bites.
- **Procedure anchors.** Should a procedure step be able to cite a document page
  (`"source": {"document": "RTU-500 Service Manual", "page": 42}`) so the step's own citation is
  machine-attached too? Cheap once the ledger exists; leaning yes in P2.
- **Embedding language.** Vaults are English today; a French-language manual for a Canadian
  customer would want `NLContextualEmbedding(language: .french)`. A per-vault `language` manifest
  field is a one-line addition; decide when the first non-English vault appears.
