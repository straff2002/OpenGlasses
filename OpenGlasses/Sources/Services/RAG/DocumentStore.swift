import Foundation
import SQLite3

/// On-device document knowledge base for retrieval-augmented answering.
///
/// Ingested documents are split into overlapping chunks ([[DocumentChunker]]), each embedded
/// ([[Embedder]]) and stored in a dedicated `documents.sqlite` — kept separate from
/// `semantic_memory.sqlite` so document bulk never bloats the memory store or trips its trim budgets.
/// All content is strictly on-device; nothing here is synced to the gateway.
@MainActor
final class DocumentStore: ObservableObject {

    // MARK: - Types

    struct DocumentRef: Identifiable, Equatable {
        let id: String
        let name: String
        let sourceType: String   // "scan", "text", "file"…
        let namespace: String
        let createdAt: Date
        let chunkCount: Int
        let charCount: Int
    }

    struct Passage: Equatable {
        let documentId: String
        let documentName: String
        let chunkIndex: Int
        let text: String
        let similarity: Float
        let page: Int?
        let section: String?
        /// What kind of page the chunk came off. Rows stored before the column existed read back
        /// as prose, which is what they were treated as.
        var kind: DocumentChunker.Kind = .prose
        /// The figure or table that names the chunk's place ("Figure 58"), when it has one.
        var figure: String?
        /// Which corpus the passage came from (Plan FP P2). The store never sets it — every row it
        /// returns is just a row — and the retrieval factory that queried a namespace tags what it
        /// got back, so a team learning cannot be mistaken for a manual page downstream.
        var source: RetrievalSource = .manual
        /// For a team-learning passage, the entry's model by identity (`subject.modelToken`), or
        /// nil for a practice entry. Set by the same factory; `ModelScope` scores a learning by this
        /// rather than by scanning its prose (contract §7.2).
        var subjectModelToken: String?
        /// Supplemental label only; `page` remains the physical capture index.
        var printedPage: Int?
        /// The edition this passage's document is, set by the retrieval factory when a turn reaches
        /// past the newest edition (Plan IV P2). The store never sets it.
        var editionLabel: String?
        /// Set by a clause search only (Plan IN P3a): how this chunk relates to the clause it was
        /// found for. Carried rather than recomputed because a continuation chunk need not print
        /// the clause number at all.
        var clauseMatch: ClauseReference.Match?
        /// The rule the passage's document is read with (Plan JY P0), from its
        /// [[DocumentLanguageProfile]]: a question is compared with this passage under the same
        /// rule. Set by the store; a passage made anywhere else is read with today's rule.
        var termRule: TermRule = .english
        /// The passage has no vector its question can be compared with because its document's
        /// script model is not on the phone yet, or has not re-indexed it (Plan JY P1). The gate
        /// judges it by its words alone, under a stricter rule (`RetrievalEvidencePolicy`). Never
        /// set for a Latin document's passage.
        var vectorPending = false
    }

    // MARK: - Published

    @Published private(set) var documents: [DocumentRef] = []

    // MARK: - Private

    private var db: OpaquePointer?
    private let dbURL: URL
    private let chunker: DocumentChunker
    private let embedder: Embedder
    private let minSimilarity: Float = 0.05
    /// Captures are never a global/personal corpus. Only the Field Assist source factory grants
    /// access to an explicitly selected, currently eligible capture namespace.
    var capturedNamespaceAllowed: (String) -> Bool = { _ in false }
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Init

    /// `directory` is injectable so tests can point at a temp folder.
    init(directory: URL? = nil, chunker: DocumentChunker = DocumentChunker(), embedder: Embedder = Embedder()) {
        let docs = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        dbURL = docs.appendingPathComponent("documents.sqlite")
        self.chunker = chunker
        self.embedder = embedder
        openDatabase()
        createTables()
        refresh()
        StoreProtection.applyDatabase(at: dbURL)
        PrivacyLog.store(.ragDocuments, .opened, count: documents.count)
    }

    deinit { sqlite3_close(db) }

    // MARK: - Public API

    /// Chunk, embed, and store a document. Yields between chunks so a large ingest doesn't
    /// monopolise the main actor. `progress` reports (completedChunks, totalChunks).
    @discardableResult
    func ingest(name: String,
                text: String,
                sourceType: String = "text",
                namespace: String = "global",
                pageLabels: [PageLabel] = [],
                tables: [ManualTable] = [],
                progress: ((Int, Int) -> Void)? = nil) async -> DocumentRef? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // The document's language sizes its chunks (Plan JY P4) and its script picks its model.
        let profile = DocumentLanguageProfile.detect(cleaned)
        let textChunks = chunker.sized(for: profile, text: cleaned).chunk(cleaned)
        guard !textChunks.isEmpty else { return nil }
        // A table's rows follow the document's own text (Plan JJ P0), numbered after it, so the
        // text chunks are numbered exactly as they would be without any table.
        let rows = TableRowPassage.chunks(for: tables, startingAt: textChunks.count)
        let chunks = textChunks + rows.chunks

        // The document's script picks its model (Plan JY P1). A manual in a script whose model is
        // not on the phone asks for it and waits a bounded time for a download under way; then it
        // is indexed either way, by its words if the model has not come.
        let script = EmbeddingScript(profile: profile)
        if script != .latin, Self.isVaultNamespace(namespace), scriptEmbedder(for: script) == nil,
           let scriptModelRequest {
            await scriptModelRequest(script)
        }

        let docId = UUID().uuidString
        let now = Date().timeIntervalSince1970
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name

        insertDocument(id: docId, name: safeName, sourceType: sourceType, namespace: namespace,
                       createdAt: now, chunkCount: chunks.count, charCount: cleaned.count)
        recordLanguageProfile(profile, documentId: docId)

        // A vault manual is embedded with the model its vault is served by (Plan IV P4), so it
        // never joins an index another model built; everything else keeps the store's embedder.
        // A document in another script uses its script's model, or none (Plan JY P1).
        let chunkEmbedder = ingestEmbedder(namespace: namespace, script: script)
        let versionTag = chunkEmbedder?.version.tag
        let started = Date()
        for chunk in chunks {
            let embedding = chunkEmbedder?.embed(chunk.text)
            insertChunk(documentId: docId, index: chunk.index, text: chunk.text,
                        embedding: embedding.map(vecToData), page: chunk.page, section: chunk.section,
                        kind: chunk.kind, figure: chunk.figure,
                        createdAt: now, version: embedding != nil ? versionTag : nil, location: chunk)
            progress?(chunk.index + 1, chunks.count)
            await Task.yield()
        }
        if !pageLabels.isEmpty { setPageLabels(pageLabels, documentId: docId) }
        if !tables.isEmpty { setTables(tables, documentId: docId) }
        lastTableRowsDropped = rows.dropped

        refresh()
        // The document's name is its title — of a scanned letter, a report, a prescription — and
        // the chunk text is the document itself. What an ingest fault needs is how many chunks
        // came out of how much text.
        PrivacyLog.store(.ragDocuments, .ingested, count: chunks.count,
                         characters: cleaned.count, detail: PrivacyToken(sourceType))
        if Self.isVaultNamespace(namespace) {
            PrivacyLog.store(.ragDocuments, .indexed, count: chunks.count,
                             detail: PrivacyToken(Self.indexDetail(modelId: chunkEmbedder?.modelId, script: script)),
                             durationMs: Int(Date().timeIntervalSince(started) * 1000))
        }
        return documents.first { $0.id == docId }
    }

    /// Retrieve the most relevant passages for a query, optionally scoped to a namespace and/or
    /// a specific document set.
    ///
    /// Drawings are left out by default. A wiring-diagram page is a bag of terminal labels: it
    /// embeds to noise, scores like everything else on a manual-wide embedder, and crowds out the
    /// prose that answers the question. It is reached instead by `passages(containingToken:)`,
    /// which is what a technician asking about `W951` or `24VAXC` actually needs.
    ///
    /// A table's row passages are searched beside the prose (Plan JJ P0): each is one sentence
    /// naming the table, the row and its values, which is what a question about a cell reads like.
    func query(_ text: String, limit: Int = 4, namespace: String? = nil, documentIds: [String]? = nil,
               kinds: Set<DocumentChunker.Kind> = DocumentStore.searchedKinds) -> [Passage] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let rows = fetchChunks(namespace: namespace, documentIds: documentIds).filter { kinds.contains($0.kind) }
        let vaultQuery = QueryVectors(text: trimmed, store: self)
        let qv = rows.contains { !Self.isVaultNamespace($0.namespace) && $0.embeddingScript == .latin }
            ? embedder.embed(trimmed) : nil
        var scriptModels: [EmbeddingScript: Embedder?] = [:]

        let current = embedder.version
        let scored = rows.compactMap { row -> Passage? in
            // A vault manual's chunk is compared with the question embedded by the model that
            // embedded the chunk (Plan IV P4) and is never re-embedded here: its re-index runs in
            // the background into a separate column and swaps in whole. The model must be one of
            // the chunk's own script (Plan JY P1).
            if Self.isVaultNamespace(row.namespace) {
                guard let emb = row.embedding,
                      let q = vaultQuery.vector(forVersionTag: row.embeddingVersion, script: row.embeddingScript) else { return nil }
                let sim = Embedder.cosineSimilarity(q, emb)
                guard sim > minSimilarity else { return nil }
                return Passage(documentId: row.documentId, documentName: row.documentName,
                               chunkIndex: row.chunkIndex, text: row.text, similarity: sim,
                               page: row.page, section: row.section, kind: row.kind, figure: row.figure,
                               termRule: row.termRule)
            }
            // Any other document in another script (Plan JY P1): its script's model when it is on
            // the phone — healed lazily from the text, like the store's own — and no similarity
            // otherwise. Its words still reach it.
            if row.embeddingScript != .latin {
                let model: Embedder?
                if let known = scriptModels[row.embeddingScript] { model = known } else {
                    model = scriptEmbedder(for: row.embeddingScript)
                    scriptModels[row.embeddingScript] = .some(model)
                }
                guard let model else { return nil }
                let tag = model.version.tag
                let vector: [Float]?
                if let stored = row.embedding, row.embeddingVersion == tag {
                    vector = stored
                } else if let fresh = model.embed(row.text) {
                    writeBackEmbedding(chunkId: row.id, vector: fresh, versionTag: tag)
                    vector = fresh
                } else {
                    vector = nil
                }
                guard let vector, let q = vaultQuery.vector(forVersionTag: tag, script: row.embeddingScript) else { return nil }
                let sim = Embedder.cosineSimilarity(q, vector)
                guard sim > minSimilarity else { return nil }
                return Passage(documentId: row.documentId, documentName: row.documentName,
                               chunkIndex: row.chunkIndex, text: row.text, similarity: sim,
                               page: row.page, section: row.section, kind: row.kind, figure: row.figure,
                               termRule: row.termRule)
            }
            guard let qv else { return nil }
            // A chunk embedded by a different model can't be compared against `qv`. Re-embed it from
            // its text with the active model and persist the result, so the store self-heals after a
            // model swap (lazy migration). Compatible chunks use their stored vector as-is.
            let stored = EmbeddingVersion(tag: row.embeddingVersion)
            let vec: [Float]?
            switch EmbeddingMigrationPolicy.action(stored: stored, current: current) {
            case .reuse:
                vec = row.embedding
            case .reembed:
                if let fresh = embedder.embed(row.text) {
                    writeBackEmbedding(chunkId: row.id, vector: fresh, versionTag: current.tag)
                    vec = fresh
                } else {
                    vec = nil
                }
            }
            guard let emb = vec else { return nil }
            let sim = Embedder.cosineSimilarity(qv, emb)
            guard sim > minSimilarity else { return nil }
            return Passage(documentId: row.documentId, documentName: row.documentName,
                           chunkIndex: row.chunkIndex, text: row.text, similarity: sim,
                           page: row.page, section: row.section, kind: row.kind, figure: row.figure,
                           termRule: row.termRule)
        }
        vaultQuery.logTimings()
        return Array(scored.sorted { $0.similarity > $1.similarity }.prefix(limit))
    }

    /// Passages containing `token` as a whole word (case-insensitive), optionally scoped. No
    /// embedding involved — this is how a bare fault code or model number reaches a passage when
    /// the embedder has no vector for it. Ordered by document then chunk so results are stable.
    func passages(containingToken token: String, namespace: String? = nil,
                  documentIds: [String]? = nil, limit: Int = 8,
                  kinds: Set<DocumentChunker.Kind> = Set(DocumentChunker.Kind.allCases)) -> [Passage] {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let rows = fetchChunks(namespace: namespace, documentIds: documentIds)
            .filter { kinds.contains($0.kind) && CodeTokenizer.contains($0.text, token: token) }
            .sorted { ($0.documentName, $0.chunkIndex) < ($1.documentName, $1.chunkIndex) }
        return rows.prefix(max(limit, 1)).map {
            Passage(documentId: $0.documentId, documentName: $0.documentName, chunkIndex: $0.chunkIndex,
                    text: $0.text, similarity: 0, page: $0.page, section: $0.section,
                    kind: $0.kind, figure: $0.figure, termRule: $0.termRule, vectorPending: $0.vectorPending)
        }
    }

    /// Passages sharing the most [[LexicalSupport]] content terms with `text`, most first, ties
    /// broken by embedding similarity — the lexical route beside `query(_:)`, for the passage an
    /// embedder cannot see. A sentence model reads a long run of manual text poorly: on the device
    /// the Lennox flame-sensor section, which uses nearly every word of "how to test the flame
    /// sensor readings or signal", scored below a page of diagnostic-code rows (build 497).
    ///
    /// Prose and table rows, like `query`, and a passage must share at least one term. Its `similarity` is
    /// the real cosine where the stored vector is current (0 otherwise, which the next `query`
    /// heals), so the evidence gate judges it exactly as it judges a semantic hit.
    func passages(sharingTermsWith text: String, limit: Int = 8, namespace: String? = nil,
                  documentIds: [String]? = nil,
                  kinds: Set<DocumentChunker.Kind> = DocumentStore.searchedKinds) -> [Passage] {
        // The question's terms under every rule, each row compared under its own document's (Plan
        // JY P0): a Chinese manual's passage with the question cut into bigrams, an English one's
        // with today's terms.
        let question = LexicalSupport.QueryTerms(text)
        guard !question.isEmpty else { return [] }
        let current = embedder.version
        let rows = fetchChunks(namespace: namespace, documentIds: documentIds).filter { kinds.contains($0.kind) }
        let vaultQuery = QueryVectors(text: text, store: self)
        let qv = rows.contains { !Self.isVaultNamespace($0.namespace) && $0.embeddingScript == .latin }
            ? embedder.embed(text) : nil
        let scored = rows
            .compactMap { row -> (row: ChunkRow, shared: Int, similarity: Float)? in
                let shared = LexicalSupport.sharedTermCount(text: row.text, question: question, rule: row.termRule)
                guard shared > 0 else { return nil }
                var similarity: Float = 0
                if Self.isVaultNamespace(row.namespace) || row.embeddingScript != .latin {
                    // Compared only with a question vector from the chunk's own script's model
                    // (Plan JY P1); a chunk awaiting that model scores 0 and is `vectorPending`.
                    if !row.vectorPending, let vector = row.embedding,
                       let q = vaultQuery.vector(forVersionTag: row.embeddingVersion, script: row.embeddingScript) {
                        similarity = Embedder.cosineSimilarity(q, vector)
                    }
                } else if let qv, let vector = row.embedding,
                   EmbeddingMigrationPolicy.action(stored: EmbeddingVersion(tag: row.embeddingVersion),
                                                   current: current) == .reuse {
                    similarity = Embedder.cosineSimilarity(qv, vector)
                }
                return (row, shared, similarity)
            }
            .sorted { $0.shared != $1.shared ? $0.shared > $1.shared : $0.similarity > $1.similarity }
        return scored.prefix(max(limit, 1)).map {
            Passage(documentId: $0.row.documentId, documentName: $0.row.documentName,
                    chunkIndex: $0.row.chunkIndex, text: $0.row.text, similarity: $0.similarity,
                    page: $0.row.page, section: $0.row.section, kind: $0.row.kind, figure: $0.row.figure,
                    termRule: $0.row.termRule, vectorPending: $0.row.vectorPending)
        }
    }

    /// Passages that carry a clause number (Plan IN P3a), the clause's own text first: chunks that
    /// start it, then chunks that start a subclause of it, then the chunk after each of those and
    /// the rest of its section, then the chunks that cite it — within a group, the chunk that holds
    /// the number earliest first (see `ClauseReference.offset`), then document order.
    ///
    /// The order is the point. A code book cites its busiest clauses dozens of times, and the
    /// token search's document order would fill the limit with the contents page and early
    /// cross-references before it reached the clause.
    func passages(clause: String, namespace: String? = nil,
                  documentIds: [String]? = nil, limit: Int = 8) -> [Passage] {
        guard !clause.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let rows = fetchChunks(namespace: namespace, documentIds: documentIds)
        var matched: [String: (row: ChunkRow, match: ClauseReference.Match)] = [:]
        for row in rows {
            if let match = ClauseReference.match(clause, in: row.text, section: row.section) {
                matched[row.id] = (row, match)
            }
        }
        // The chunk after one that starts the clause carries its text on, whether or not it prints
        // the number again.
        let byPosition = Dictionary(rows.map { ("\($0.documentId)#\($0.chunkIndex)", $0) },
                                    uniquingKeysWith: { first, _ in first })
        for (_, hit) in matched where hit.match >= .startsSubclause {
            guard let next = byPosition["\(hit.row.documentId)#\(hit.row.chunkIndex + 1)"] else { continue }
            if (matched[next.id]?.match ?? .cites) <= .cites { matched[next.id] = (next, .continues) }
        }
        return matched.values
            .sorted {
                if $0.match != $1.match { return $0.match > $1.match }
                let a = ClauseReference.offset(of: [clause], in: $0.row.text)
                let b = ClauseReference.offset(of: [clause], in: $1.row.text)
                if a != b { return a < b }
                return ($0.row.documentName, $0.row.chunkIndex) < ($1.row.documentName, $1.row.chunkIndex)
            }
            .prefix(max(limit, 1))
            .map {
                Passage(documentId: $0.row.documentId, documentName: $0.row.documentName,
                        chunkIndex: $0.row.chunkIndex, text: $0.row.text, similarity: 0, page: $0.row.page,
                        section: $0.row.section, kind: $0.row.kind, figure: $0.row.figure,
                        clauseMatch: $0.match, termRule: $0.row.termRule, vectorPending: $0.row.vectorPending)
            }
    }

    /// Chunks whose stored caption is `label` ("Figure 58"), case-insensitively — how a figure a
    /// technician names by number is found again (Plan EK P2). Drawings first, then document and
    /// chunk order, so the page's own drawing outranks the prose that merely cites it.
    func passages(figure label: String, namespace: String? = nil,
                  documentIds: [String]? = nil, limit: Int = 4) -> [Passage] {
        let needle = label.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return ordered(fetchChunks(namespace: namespace, documentIds: documentIds)
            .filter { ($0.figure ?? "").lowercased() == needle }, limit: limit)
    }

    /// Chunks off one page, drawings first. The page is the PDF's own (physical, 1-based) page,
    /// which is not always the number the manual prints on it: a printed page goes through
    /// `pageLabels(documentId:)` first (Plan KD P0).
    func passages(onPage page: Int, namespace: String? = nil,
                  documentIds: [String]? = nil, limit: Int = 4) -> [Passage] {
        ordered(fetchChunks(namespace: namespace, documentIds: documentIds).filter { $0.page == page },
                limit: limit)
    }

    /// Drawings first, then document then chunk order — a stable, embedding-free ordering for the
    /// lookups above, which are exact rather than scored.
    private func ordered(_ rows: [ChunkRow], limit: Int) -> [Passage] {
        rows.sorted {
            $0.kind != $1.kind ? $0.kind == .diagram
                : ($0.documentName, $0.chunkIndex) < ($1.documentName, $1.chunkIndex)
        }
        .prefix(max(limit, 1)).map {
            Passage(documentId: $0.documentId, documentName: $0.documentName, chunkIndex: $0.chunkIndex,
                    text: $0.text, similarity: 0, page: $0.page, section: $0.section,
                    kind: $0.kind, figure: $0.figure, termRule: $0.termRule, vectorPending: $0.vectorPending)
        }
    }

    /// Every printed page of a document with the text stored for it, ascending — what the figure
    /// sheet shows and pages through when a manual was imported as extracted text rather than as a
    /// PDF (Plan EK P3).
    ///
    /// Its own query rather than `fetchChunks`, which decodes every chunk's embedding blob: a page
    /// of text has no use for a vector, and a 300-page manual would pay for all of them on the main
    /// actor while the model is still answering.
    ///
    /// A chunk carries the page its first sentence is on, so a short page swallowed whole by the
    /// chunk before it has no entry here. That is why the sheet pages over these rather than over
    /// 1…N: offering a page the store holds nothing for would show a blank.
    func pageTexts(documentId: String) -> [(page: Int, text: String)] {
        if documentId.hasPrefix("captured:"), !capturedNamespaceAllowed(documentId) { return [] }
        let sql = """
        SELECT page, text FROM doc_chunks
        WHERE document_id = '\(escapedSQL(documentId))' AND page IS NOT NULL AND \(Self.notTableRow)
        ORDER BY chunk_index ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var byPage: [Int: [String]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(stmt, 1) else { continue }
            byPage[Int(sqlite3_column_int(stmt, 0)), default: []].append(String(cString: raw))
        }
        return byPage.keys.sorted().compactMap { page in
            let text = DocumentReconstructor.deOverlap(byPage[page]!)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (page, text)
        }
    }

    func list() -> [DocumentRef] { documents }

    /// Documents in a single namespace (project scope, Plan AN).
    func list(namespace: String) -> [DocumentRef] {
        documents.filter { $0.namespace == namespace }
    }

    /// Count of documents in a namespace — used to gate the knowledge-base tool
    /// advertisement so we don't offer retrieval over an empty project (Plan AN).
    func documentCount(namespace: String) -> Int {
        documents.reduce(0) { $1.namespace == namespace ? $0 + 1 : $0 }
    }

    /// Resolve a document by name (exact then substring, case-insensitive).
    func document(named name: String) -> DocumentRef? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return documents.first { $0.name.lowercased() == needle }
            ?? documents.first { $0.name.lowercased().contains(needle) }
    }

    /// Resolve a document by name, restricted to an allowed set of namespaces (project scope,
    /// Plan AN). Callers that reach documents by name — e.g. the teleprompter — must pass
    /// `{active project, "global"}` so a chat can never read another project's document text.
    func document(named name: String, namespaces: [String]) -> DocumentRef? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        let allowed = Set(namespaces)
        let scoped = documents.filter { allowed.contains($0.namespace) }
        return scoped.first { $0.name.lowercased() == needle }
            ?? scoped.first { $0.name.lowercased().contains(needle) }
    }

    /// Reconstruct a document's continuous text from its (overlapping) chunks, in order.
    /// Used by sources that need the whole document, e.g. the teleprompter.
    func fullText(documentId: String) -> String? {
        let chunks = fetchChunks(namespace: nil, documentIds: [documentId])
            .filter { $0.kind != .tableRow }
            .sorted { $0.chunkIndex < $1.chunkIndex }
            .map(\.text)
        guard !chunks.isEmpty else { return nil }
        return DocumentReconstructor.deOverlap(chunks)
    }

    func forget(documentId: String) {
        let id = escapedSQL(documentId)
        exec("DELETE FROM doc_page_labels WHERE document_id = '\(id)'")
        exec("DELETE FROM doc_tables WHERE document_id = '\(id)'")
        exec("DELETE FROM doc_chunks WHERE document_id = '\(id)'")
        exec("DELETE FROM documents WHERE id = '\(id)'")
        refresh()
    }

    /// What went wrong deleting one document. `forget(documentId:)` above reports none of this —
    /// it cannot tell a delete that removed nothing from a delete SQLite refused — which is why a
    /// caller that has to *know* the rows are gone uses the checked form below.
    enum DeletionError: LocalizedError, Equatable {
        /// SQLite refused a statement. The transaction was rolled back; nothing was deleted.
        ///
        /// Codes rather than SQLite's own message, which quotes the statement it failed on — and
        /// the statements here carry document ids.
        case sqlite(code: Int32, extended: Int32)
        /// The document is in a different namespace than the caller expected, so deleting it would
        /// reach outside the caller's scope. Nothing was deleted.
        case wrongNamespace(expected: String, actual: String)
        /// The delete ran but rows survived it. The transaction was rolled back.
        case rowsRemain(documents: Int, chunks: Int)

        var errorDescription: String? {
            switch self {
            case .sqlite(let code, let extended):
                return "The document index refused the delete (SQLite \(code)/\(extended))."
            case .wrongNamespace(let expected, let actual):
                return "That document belongs to \(actual), not \(expected)."
            case .rowsRemain(let documents, let chunks):
                return "The delete left \(documents) document row(s) and \(chunks) chunk(s) behind."
            }
        }
    }

    /// Delete one document and its chunks, in a transaction, refusing to reach outside `namespace`.
    ///
    /// Three differences from `forget(documentId:)`, all of them the reason a vault manual removal
    /// uses this one: a SQL failure propagates rather than being swallowed, the row's namespace is
    /// checked before anything is deleted (a vault's removal can never take a personal document or
    /// another vault's manual), and success is *verified* — the rows are counted again inside the
    /// transaction and a survivor rolls the whole thing back. So "it returned" means the metadata
    /// and the chunks are both absent, which is what removal has to be able to promise.
    ///
    /// Idempotent: a document that is already gone deletes nothing and returns 0 rather than
    /// throwing, so a retry after a half-finished removal completes instead of failing.
    @discardableResult
    func forget(documentId: String, inNamespace namespace: String) throws -> Int {
        let id = escapedSQL(documentId)
        // The row the delete will touch, read from the table rather than from the published list,
        // so the namespace check sees what is actually there.
        guard let actual = storedNamespace(documentId: documentId) else {
            // Already absent. Sweep any orphaned chunks so a half-finished delete cannot leave
            // retrievable text behind a missing document row, then report nothing removed.
            let orphans = chunkCount(documentId: documentId)
            if orphans > 0 {
                try transaction {
                    try execChecked("DELETE FROM doc_tables WHERE document_id = '\(id)'")
                    try execChecked("DELETE FROM doc_chunks WHERE document_id = '\(id)'")
                }
                refresh()
            }
            return orphans
        }
        guard actual == namespace else {
            throw DeletionError.wrongNamespace(expected: namespace, actual: actual)
        }

        let chunks = chunkCount(documentId: documentId)
        try transaction {
            try execChecked("DELETE FROM doc_page_labels WHERE document_id = '\(id)'")
            try execChecked("DELETE FROM doc_tables WHERE document_id = '\(id)'")
            try execChecked("DELETE FROM doc_chunks WHERE document_id = '\(id)'")
            try execChecked("DELETE FROM documents WHERE id = '\(id)' AND namespace = '\(escapedSQL(namespace))'")
            let remainingDocuments = storedNamespace(documentId: documentId) == nil ? 0 : 1
            let remainingChunks = chunkCount(documentId: documentId)
            guard remainingDocuments == 0, remainingChunks == 0 else {
                throw DeletionError.rowsRemain(documents: remainingDocuments, chunks: remainingChunks)
            }
        }
        refresh()
        PrivacyLog.store(.ragDocuments, .cleared, count: chunks)
        return chunks
    }

    /// The namespace stored for a document id, read straight from the table rather than from the
    /// published list — the check has to see the row the delete will touch, including one written
    /// by another instance since this one last refreshed.
    private func storedNamespace(documentId: String) -> String? {
        let sql = "SELECT namespace FROM documents WHERE id = '\(escapedSQL(documentId))'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: raw)
    }

    /// How many chunk rows a document still has. Counted rather than trusted from `chunk_count`,
    /// which records what an ingest wrote and not what is there now.
    func chunkCount(documentId: String) -> Int {
        let sql = "SELECT COUNT(*) FROM doc_chunks WHERE document_id = '\(escapedSQL(documentId))'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Run `body` between BEGIN IMMEDIATE and COMMIT, rolling back on any throw. Nested use is not
    /// supported and is not needed: the one caller is the checked delete above.
    private func transaction(_ body: () throws -> Void) throws {
        try execChecked("BEGIN IMMEDIATE")
        do {
            try body()
            try execChecked("COMMIT")
        } catch {
            exec("ROLLBACK")
            throw error
        }
    }

    /// `exec` that reports the failure instead of discarding it. The message SQLite offers is
    /// deliberately not read: it quotes the statement, and these statements name documents.
    private func execChecked(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK else { return }
        throw DeletionError.sqlite(code: sqlite3_errcode(db), extended: sqlite3_extended_errcode(db))
    }

    func clearAll() {
        exec("DELETE FROM doc_page_labels")
        exec("DELETE FROM doc_tables")
        exec("DELETE FROM doc_chunks")
        exec("DELETE FROM documents")
        refresh()
        PrivacyLog.store(.ragDocuments, .cleared)
    }

    /// Delete every document in one namespace and nothing outside it. The consumer surfaces
    /// operate on their own namespaces; a Field Assist vault's manuals live in `vault:<id>` and
    /// must never be swept by a personal-documents clear.
    func clear(namespace: String) {
        let ns = escapedSQL(namespace)
        exec("DELETE FROM doc_page_labels WHERE document_id IN (SELECT id FROM documents WHERE namespace = '\(ns)')")
        exec("DELETE FROM doc_tables WHERE document_id IN (SELECT id FROM documents WHERE namespace = '\(ns)')")
        exec("DELETE FROM doc_chunks WHERE document_id IN (SELECT id FROM documents WHERE namespace = '\(ns)')")
        exec("DELETE FROM documents WHERE namespace = '\(ns)'")
        refresh()
        PrivacyLog.store(.ragDocuments, .cleared)
    }

    // MARK: - Vault namespaces

    nonisolated static let vaultNamespacePrefix = "vault:"

    /// Namespace holding a Field Assist vault's reference-tier documents.
    nonisolated static func vaultNamespace(_ vaultId: String) -> String { vaultNamespacePrefix + vaultId }

    nonisolated static func isVaultNamespace(_ namespace: String) -> Bool { namespace.hasPrefix(vaultNamespacePrefix) }

    // MARK: - Team-learning namespaces (Plan FP P2)

    nonisolated static let learningNamespacePrefix = "learning:"

    /// Namespace holding the approved team learnings published for one vault: one document per
    /// entry. It sits beside the vault's own namespace and outside its manifest, baseline, ledger
    /// and manual removal, so a pack update, a re-import or a manual removal never touches it.
    nonisolated static func learningNamespace(_ vaultId: String) -> String { learningNamespacePrefix + vaultId }

    nonisolated static func isLearningNamespace(_ namespace: String) -> Bool { namespace.hasPrefix(learningNamespacePrefix) }

    /// Every document except a team-learning corpus — what a person's own surfaces (reading
    /// references, study decks) may list. A learning is the organisation's, read only through
    /// retrieval with its disclosure, never picked from a personal list.
    func listExcludingTeamLearnings() -> [DocumentRef] {
        documents.filter { !Self.isLearningNamespace($0.namespace) && !$0.namespace.hasPrefix("captured:") }
    }

    /// The personal documents surface: neither a vault's manuals nor a team-learning corpus. Both
    /// are managed from Field Assist, and neither is the wearer's to delete from a document list.
    func personalDocuments() -> [DocumentRef] {
        documents.filter { !Self.isVaultNamespace($0.namespace) && !Self.isLearningNamespace($0.namespace) && !$0.namespace.hasPrefix("captured:") }
    }

    /// Store `text` as exactly one chunk under a caller-chosen id, replacing whatever that id held
    /// (Plan FP P2). A team learning is a few hundred characters and is cited whole — splitting one
    /// would let half a finding answer without the other half — so it bypasses the chunker.
    /// Idempotent: storing the same id again replaces the row and its one chunk.
    @discardableResult
    func ingestWhole(documentId: String, name: String, text: String,
                     sourceType: String, namespace: String) -> DocumentRef? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !documentId.isEmpty else { return nil }
        let id = escapedSQL(documentId)
        exec("DELETE FROM doc_chunks WHERE document_id = '\(id)'")
        let now = Date().timeIntervalSince1970
        insertDocument(id: documentId, name: name, sourceType: sourceType, namespace: namespace,
                       createdAt: now, chunkCount: 1, charCount: cleaned.count)
        let profile = DocumentLanguageProfile.detect(cleaned)
        recordLanguageProfile(profile, documentId: documentId)
        // Another script's text is embedded with its own model if it is here, else not at all.
        let model = ingestEmbedder(namespace: namespace, script: EmbeddingScript(profile: profile))
        let embedding = model?.embed(cleaned)
        insertChunk(documentId: documentId, index: 0, text: cleaned,
                    embedding: embedding.map(vecToData), page: nil, section: nil,
                    kind: .prose, figure: nil,
                    createdAt: now, version: embedding != nil ? model?.version.tag : nil)
        refresh()
        PrivacyLog.store(.ragDocuments, .ingested, count: 1, characters: cleaned.count,
                         detail: PrivacyToken(sourceType))
        return documents.first { $0.id == documentId }
    }

    /// IF's page-aware ingestion uses a deterministic source id. Prepare before the SQL
    /// transaction, recheck cancellation after each yield, then publish all rows atomically.
    /// A photographed manual's tables (Plan JN P4) are published in the same transaction: their
    /// row passages numbered after the pages' text, and the tables replacing any the document had,
    /// so the text and its tables appear, and go, together.
    @discardableResult
    func ingestPages(documentId: String, name: String, pages: [(number: Int, text: String)],
                     sourceType: String, namespace: String, tables: [ManualTable] = [],
                     stillAllowed: () -> Bool) async -> Bool {
        guard let db, stillAllowed(), !Task.isCancelled else { return false }
        // A photographed manual in another script is sized for its language (Plan JY P4), asks for
        // its model like an uploaded one, and is embedded with it or not at all (Plan JY P1).
        let joined = pages.map(\.text).joined(separator: "\n")
        let profile = DocumentLanguageProfile.detect(joined)
        let textChunks = chunker.sized(for: profile, text: joined).chunkPages(pages)
        let rows = TableRowPassage.chunks(for: tables, startingAt: textChunks.count)
        let chunks = textChunks + rows.chunks
        let script = EmbeddingScript(profile: profile)
        if script != .latin, scriptEmbedder(for: script) == nil, let scriptModelRequest {
            await scriptModelRequest(script)
            guard stillAllowed(), !Task.isCancelled else { return false }
        }
        let model = script == .latin ? embedder : scriptEmbedder(for: script)
        var vectors: [Data?] = []
        for chunk in chunks {
            guard stillAllowed(), !Task.isCancelled else { return false }
            vectors.append(model?.embed(chunk.text).map(vecToData))
            await Task.yield()
        }
        guard stillAllowed(), !Task.isCancelled,
              sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        exec("DELETE FROM doc_chunks WHERE document_id = '\(escapedSQL(documentId))'")
        let now = Date().timeIntervalSince1970
        insertDocument(id: documentId, name: name, sourceType: sourceType, namespace: namespace,
                       createdAt: now, chunkCount: chunks.count, charCount: pages.reduce(0) { $0 + $1.text.count })
        guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else { return false }
        recordLanguageProfile(profile, documentId: documentId)
        for (index, chunk) in chunks.enumerated() {
            insertChunk(documentId: documentId, index: index, text: chunk.text, embedding: vectors[index],
                        page: chunk.page, section: chunk.section, kind: chunk.kind, figure: chunk.figure,
                        createdAt: now, version: vectors[index] == nil ? nil : model?.version.tag,
                        location: chunk)
            guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else { return false }
        }
        setTables(tables, documentId: documentId)
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { return false }
        committed = true
        lastTableRowsDropped = rows.dropped
        refresh()
        return true
    }

    // MARK: - Embedding migration

    /// The version stamp the active embedder produces. Chunks tagged differently are "outdated" and
    /// will be re-embedded on access (or eagerly via `reindexOutdated`).
    var currentEmbeddingVersionTag: String { embedder.version.tag }

    /// The active embedding model's stable id (`nl-word.en`, `nl-sentence.en`, `nl-contextual.…`).
    /// Similarity means something different on each, so a consumer that thresholds on similarity —
    /// [[RetrievalEvidencePolicy]] — picks its defaults from this rather than assuming one backend.
    var embeddingModelId: String { embedder.modelId }

    /// How many stored chunks were embedded by a model other than the active one (or are unstamped).
    /// Drives a "re-index now" affordance and lets tests assert migration progress.
    /// A document in another script (Plan JY P1) counts when its script's model is here and the
    /// chunk is not on it — never against the store's own model, which cannot read it.
    var outdatedChunkCount: Int {
        let current = embedder.version
        return fetchChunks(namespace: nil, documentIds: nil).reduce(0) { acc, row in
            if Self.isVaultNamespace(row.namespace) { return acc }
            if row.embeddingScript != .latin { return row.vectorPending && scriptEmbedder(for: row.embeddingScript) != nil ? acc + 1 : acc }
            return row.embedding == nil ? acc
                : EmbeddingMigrationPolicy.action(stored: EmbeddingVersion(tag: row.embeddingVersion),
                                                  current: current) == .reembed ? acc + 1 : acc
        }
    }

    /// Eagerly re-embed every chunk whose stamp doesn't match the active model and persist the result.
    /// Use after a deliberate model change for an explicit "re-index now" with progress. Returns the
    /// number of chunks re-embedded. Yields between chunks so a large re-index doesn't block.
    @discardableResult
    func reindexOutdated(progress: ((Int, Int) -> Void)? = nil) async -> Int {
        let current = embedder.version
        // A vault's manuals have their own model and their own re-index (`upgradeVaultEmbeddings`).
        // A document in another script is re-embedded only with its own script's model, when it
        // is here (Plan JY P1).
        let all = fetchChunks(namespace: nil, documentIds: nil).filter { !Self.isVaultNamespace($0.namespace) }
        let scriptModels = Dictionary(uniqueKeysWithValues: Set(all.map(\.embeddingScript)).subtracting([.latin])
            .compactMap { script in scriptEmbedder(for: script).map { (script, $0) } })
        let rows = all.filter { row in
            row.embeddingScript == .latin
                ? row.embedding != nil && EmbeddingMigrationPolicy.action(stored: EmbeddingVersion(tag: row.embeddingVersion),
                                                                           current: current) == .reembed
                : row.vectorPending && scriptModels[row.embeddingScript] != nil
        }
        var done = 0
        for row in rows {
            let model = row.embeddingScript == .latin ? embedder : scriptModels[row.embeddingScript]
            if let model, let fresh = model.embed(row.text) {
                writeBackEmbedding(chunkId: row.id, vector: fresh, versionTag: model.version.tag)
            }
            done += 1
            progress?(done, rows.count)
            await Task.yield()
        }
        // The embedder's version tag is a build constant, not a property of what was embedded.
        if done > 0 {
            PrivacyLog.store(.ragDocuments, .reembedded, count: done,
                             detail: PrivacyToken(current.tag))
        }
        return done
    }

    /// Force every chunk to be treated as outdated (clears the stamp) so the next query/reindex
    /// re-embeds it. The honest way to invalidate vectors after changing the embedding model.
    func invalidateEmbeddings() {
        exec("UPDATE doc_chunks SET embedding_version = NULL")
    }

    /// Persist a freshly-computed vector + stamp for one chunk (lazy-migration write-back).
    private func writeBackEmbedding(chunkId: String, vector: [Float], versionTag: String) {
        let sql = "UPDATE doc_chunks SET embedding = ?, embedding_version = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let data = vecToData(vector)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) }
        sqlite3_bind_text(stmt, 2, versionTag, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, chunkId, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    // MARK: - A document's own subject index (Plan IV P5)

    private var indexCache: [String: (chunks: Int, index: BackOfBookIndex?)] = [:]

    /// The document's back-of-book index, parsed from its stored text, or nil when it has none.
    /// Parsed once per document (and again if its chunks change), and held in memory only: an
    /// index's entries are the publisher's text, read where they are stored and never copied.
    func backOfBookIndex(documentId: String) -> BackOfBookIndex? {
        let count = chunkCount(documentId: documentId)
        if let cached = indexCache[documentId], cached.chunks == count { return cached.index }
        let index = BackOfBookIndex.parse(storedText(documentId: documentId), rule: termRule(documentId: documentId))
        indexCache[documentId] = (count, index)
        return index
    }

    // MARK: - A document's shape (Plan IV P6)

    private var clauseNumberedCache: [String: (chunks: Int, value: Bool)] = [:]

    /// Whether the document is clause-numbered — P3's detector (`DocumentChunker.isClauseNumbered`)
    /// run on its stored text, whose chunks keep their line breaks since P3's re-chunk. Derived, not
    /// stored, so no re-index: read once per document (and again if its chunks change).
    func isClauseNumbered(documentId: String) -> Bool {
        let count = chunkCount(documentId: documentId)
        if let cached = clauseNumberedCache[documentId], cached.chunks == count { return cached.value }
        let value = DocumentChunker.isClauseNumbered(storedText(documentId: documentId))
        clauseNumberedCache[documentId] = (count, value)
        return value
    }

    /// Whether a retrieval whose best passage comes from this document carries the larger passage
    /// budget (`ManualPassageLimit.clauseNumbered`): a clause-numbered document (Plan IV P6), or one
    /// in a CJK or Arabic script (Plan JY P4). Measured on the P3 sets with P4's chunking, six
    /// passages answered CJK 255 → 260 of its in-scope questions as sent and Arabic script 41 → 44
    /// (five: 258 and 41), at 1,395 → 1,857 and 1,533 → 1,955 characters a question, still under
    /// English's 2,200 with four. Latin and Cyrillic documents keep four.
    func usesClausePassageBudget(documentId: String) -> Bool {
        if isClauseNumbered(documentId: documentId) { return true }
        let script = languageProfile(documentId: documentId).script
        return script.isCJK || script == .arabic
    }

    // MARK: - A document's language (Plan JY P0)

    private var languageProfileCache: [String: DocumentLanguageProfile] = [:]

    /// The document's language profile: the one recorded when it was indexed, or — for a document
    /// indexed before profiles were, or under an older detection — detected now from its stored
    /// text and recorded, so the backfill happens once per document and needs no re-index. Held
    /// in memory until the store next changes.
    func languageProfile(documentId: String) -> DocumentLanguageProfile {
        if let cached = languageProfileCache[documentId] { return cached }
        let stored = rows("SELECT language_profile FROM documents WHERE id = '\(escapedSQL(documentId))'") { stmt in
            sqlite3_column_text(stmt, 0).map { String(cString: $0) }
        }.first ?? nil
        let decoded = stored.flatMap { try? JSONDecoder().decode(DocumentLanguageProfile.self, from: Data($0.utf8)) }
        let profile: DocumentLanguageProfile
        if let decoded, decoded.version == DocumentLanguageProfile.currentVersion {
            profile = decoded
        } else {
            profile = DocumentLanguageProfile.detect(storedText(documentId: documentId))
            writeLanguageProfile(profile, documentId: documentId)
        }
        languageProfileCache[documentId] = profile
        return profile
    }

    /// The rule the document's passages are read with.
    func termRule(documentId: String) -> TermRule {
        languageProfile(documentId: documentId).termRule
    }

    /// The model family the document's passages are embedded with (Plan JY P1).
    func embeddingScript(documentId: String) -> EmbeddingScript {
        EmbeddingScript(profile: languageProfile(documentId: documentId))
    }

    /// Detect and record the profile of a document's text at ingest or re-index. The cache is
    /// left to the next read: a write that rolls back must not leave its profile behind.
    private func recordLanguageProfile(of text: String, documentId: String) {
        recordLanguageProfile(DocumentLanguageProfile.detect(text), documentId: documentId)
    }

    private func recordLanguageProfile(_ profile: DocumentLanguageProfile, documentId: String) {
        writeLanguageProfile(profile, documentId: documentId)
        languageProfileCache[documentId] = nil
    }

    private func writeLanguageProfile(_ profile: DocumentLanguageProfile, documentId: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(profile), let text = String(data: json, encoding: .utf8) else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE documents SET language_profile = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, documentId, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    // MARK: - A corpus's word statistics (Plan IV P7)

    private var termStatisticsCache: [String: (stamp: [Int], statistics: LexicalSupport.TermStatistics)] = [:]

    /// The term statistics BM25F ranks a retrieval's candidates with, over every chunk in
    /// `namespaces` (nil: the whole store). Read once per namespace from the stored text — again
    /// only when its chunks change — and held in memory: derived, never stored, so no re-index.
    func termStatistics(namespaces: [String]?) -> LexicalSupport.TermStatistics {
        (namespaces?.map(Optional.some) ?? [nil]).reduce(LexicalSupport.TermStatistics()) { $0 + termStatistics(namespace: $1) }
    }

    private func termStatistics(namespace: String?) -> LexicalSupport.TermStatistics {
        let scope = namespace.map { "JOIN documents d ON c.document_id = d.id WHERE d.namespace = '\(escapedSQL($0))'" } ?? ""
        // The chunk count and the text's length: a manual added, removed or replaced moves one.
        let stamp = rows("SELECT COUNT(*), TOTAL(LENGTH(c.text)) FROM doc_chunks c \(scope)") { stmt in
            [Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_double(stmt, 1))]
        }.first ?? []
        let key = namespace ?? "*"
        if let cached = termStatisticsCache[key], cached.stamp == stamp { return cached.statistics }
        var statistics = LexicalSupport.TermStatistics()
        // Each chunk is counted under its document's rule (Plan JY P0), as it is scored. The rules
        // are read first: a profile not yet recorded is written, and not under an open read.
        let documentIds = rows("SELECT DISTINCT c.document_id FROM doc_chunks c \(scope)") { stmt in
            sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        }
        let rules = Dictionary(documentIds.map { ($0, termRule(documentId: $0)) }, uniquingKeysWith: { first, _ in first })
        _ = rows("SELECT c.text, c.section, c.document_id FROM doc_chunks c \(scope)") { stmt in
            let documentId = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let rule = rules[documentId] ?? .english
            statistics.add(text: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "",
                           heading: sqlite3_column_text(stmt, 1).map { String(cString: $0) }, rule: rule)
        }
        termStatisticsCache[key] = (stamp, statistics)
        return statistics
    }

    /// Each row of `sql`, read by `read`.
    private func rows<T>(_ sql: String, _ read: (OpaquePointer?) -> T) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(read(stmt)) }
        return out
    }

    /// A document's chunk texts in order, one per line. The overlap between chunks is left in;
    /// both readers above count distinct lines, so a repeated one does no harm.
    private func storedText(documentId: String) -> String {
        let sql = "SELECT text FROM doc_chunks WHERE document_id = ? AND \(Self.notTableRow) ORDER BY chunk_index ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
        var texts: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) {
            texts.append(String(cString: raw))
        }
        return texts.joined(separator: "\n")
    }

    // MARK: - A vault's own embedding model (Plan IV P4)

    /// The model a vault's manuals are indexed with going forward — `Embedder.fieldAssist()` in
    /// the app (the contextual model when it is switched on and present), injected by tests. Nil
    /// means the store's own embedder. Every other namespace always uses the store's embedder.
    var fieldAssistEmbedder: Embedder?

    /// The model new vault manuals are indexed with.
    var vaultTargetEmbedder: Embedder { fieldAssistEmbedder ?? embedder }

    /// The models a vault chunk's version can be matched to, for embedding a question the same way.
    private var knownEmbedders: [Embedder] {
        var list = [embedder]
        if let fieldAssistEmbedder { list.append(fieldAssistEmbedder) }
        list.append(standardEmbedder)
        return list
    }

    private lazy var standardEmbedder = Embedder(preference: .standard)

    // MARK: Models by script (Plan JY P1)

    /// A script's contextual model when its asset is on the phone. A seam: the tests stand in a
    /// model per script, and make one "arrive" by starting to return it.
    var scriptEmbedderProvider: (EmbeddingScript) -> Embedder? = { Embedder.contextual(for: $0) }

    /// Asks for a script's model and waits briefly for it, before a manual in that script is
    /// indexed. Set at launch to `ScriptModelAssets.requestAndWait`; nil — the default, and the
    /// tests' — indexes at once. Only manuals ask (vault and photographed ones): the Documents
    /// library, team learnings and every other namespace use a model only if it is already here.
    var scriptModelRequest: ((EmbeddingScript) async -> Void)?

    /// The model that reads `script`'s text, when it is on the phone; nil for `.latin`, whose
    /// models are the ones above.
    func scriptEmbedder(for script: EmbeddingScript) -> Embedder? {
        guard script != .latin, let model = scriptEmbedderProvider(script), model.isAvailable,
              model.script == script else { return nil }
        return model
    }

    /// An embedder that produces `tag`, or nil when none of the known models does — a chunk the
    /// question cannot be compared with, which is left out of the similarity search (the exact-
    /// token and lexical routes still reach it). The Latin models first, then each script's model
    /// that is on the phone (Plan JY P1).
    func embedderProducing(versionTag tag: String?) -> Embedder? {
        guard let tag else { return nil }
        if let latin = embedderProducing(versionTag: tag, script: .latin) { return latin }
        for script in EmbeddingScript.allCases where script != .latin {
            if let model = embedderProducing(versionTag: tag, script: script) { return model }
        }
        return nil
    }

    /// An embedder of `script` that produces `tag`: one of the Latin models for a Latin document,
    /// that script's own model for any other. A chunk is never compared with a question embedded
    /// by another script's model — including a chunk an older build embedded with the Latin model,
    /// which reads as having no vector until its own model re-indexes it.
    func embedderProducing(versionTag tag: String?, script: EmbeddingScript) -> Embedder? {
        guard let tag else { return nil }
        guard script != .latin else { return knownEmbedders.first { $0.isAvailable && $0.version.tag == tag } }
        guard let model = scriptEmbedder(for: script), model.version.tag == tag else { return nil }
        return model
    }

    /// The documents of `namespace` whose passages `script`'s model embeds.
    func documentIds(namespace: String, script: EmbeddingScript) -> [String] {
        rows("SELECT id FROM documents WHERE namespace = '\(escapedSQL(namespace))' ORDER BY id") { stmt in
            sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        }.filter { !$0.isEmpty && embeddingScript(documentId: $0) == script }
    }

    /// The scripts a namespace's documents are embedded under, in `EmbeddingScript` order.
    func embeddingScripts(namespace: String) -> [EmbeddingScript] {
        let ids = rows("SELECT id FROM documents WHERE namespace = '\(escapedSQL(namespace))'") { stmt in
            sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        }
        let present = Set(ids.filter { !$0.isEmpty }.map { embeddingScript(documentId: $0) })
        return EmbeddingScript.allCases.filter(present.contains)
    }

    /// A document's language and how its passages are searched, for My Manuals, the Developer
    /// panel and the support report (Plan JY P1). Counts and labels only, never its text.
    struct LanguageDiagnostic: Equatable {
        let documentId: String
        /// A vault or photographed manual, rather than a document of the Documents library.
        let isManual: Bool
        let profile: DocumentLanguageProfile
        let script: EmbeddingScript
        /// The family of the model whose vectors answer ("contextual", "sentence", "word"), or
        /// "none" when no chunk has a vector the question can be compared with.
        let modelClass: String
        let chunksWithVectors: Int
        let chunks: Int

        /// A document in another script that is searched, at least in part, by its words alone
        /// until its script's model downloads and re-indexes it.
        var searchesByWords: Bool { script != .latin && chunksWithVectors < chunks }

        /// The document's language group has not been measured on both a parallel baseline and a
        /// technical document (Plan JY P3), so its search values are less certain.
        var isLessTested: Bool { profile.termRule.group.isLessTested }

        /// "manual · han zh-Hans 0.97 · CJK model contextual · vectors 0/42 · words only".
        var line: String {
            let language = profile.language.map { "\($0) \(String(format: "%.2f", profile.confidence))" } ?? "language unsure"
            var parts = [isManual ? "manual" : "document", "\(profile.script.rawValue) \(language)",
                         "\(script.diagnosticLabel) model \(modelClass)", "vectors \(chunksWithVectors)/\(chunks)"]
            if searchesByWords { parts.append("words only") }
            if isLessTested { parts.append("less tested") }
            return parts.joined(separator: " · ")
        }
    }

    /// One document's diagnostic, or nil when it is not stored.
    func languageDiagnostic(documentId: String) -> LanguageDiagnostic? {
        let found = rows("SELECT namespace FROM documents WHERE id = '\(escapedSQL(documentId))'") { stmt in
            sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        }
        guard let namespace = found.first else { return nil }
        let script = embeddingScript(documentId: documentId)
        let counts = rows("""
            SELECT embedding_version, COUNT(*), SUM(CASE WHEN embedding IS NULL THEN 0 ELSE 1 END)
            FROM doc_chunks WHERE document_id = '\(escapedSQL(documentId))' GROUP BY embedding_version
            """) { stmt -> (tag: String?, chunks: Int, vectors: Int) in
            (sqlite3_column_text(stmt, 0).map { String(cString: $0) },
             Int(sqlite3_column_int(stmt, 1)), Int(sqlite3_column_int(stmt, 2)))
        }
        let total = counts.reduce(0) { $0 + $1.chunks }
        let usable: [(tag: String?, chunks: Int, vectors: Int)]
        if script == .latin {
            usable = counts.filter { $0.vectors > 0 }
        } else {
            let tag = scriptEmbedder(for: script)?.version.tag
            usable = counts.filter { tag != nil && $0.tag == tag && $0.vectors > 0 }
        }
        let withVectors = usable.reduce(0) { $0 + $1.vectors }
        let majority = usable.max { $0.vectors < $1.vectors }?.tag
        let family = withVectors > 0 ? Self.modelClass(EmbeddingVersion(tag: majority)?.modelId ?? "") : "none"
        return LanguageDiagnostic(documentId: documentId,
                                  isManual: Self.isVaultNamespace(namespace) || namespace.hasPrefix("captured:"),
                                  profile: languageProfile(documentId: documentId), script: script,
                                  modelClass: family, chunksWithVectors: withVectors, chunks: total)
    }

    /// Every document's diagnostic but a team learning's (the organisation's, and many tiny
    /// entries), newest first.
    func languageDiagnostics() -> [LanguageDiagnostic] {
        documents.filter { !Self.isLearningNamespace($0.namespace) }.compactMap { languageDiagnostic(documentId: $0.id) }
    }

    /// `c.document_id IN (…)` for a list of ids.
    private func documentIdClause(_ ids: [String]) -> String {
        "c.document_id IN (" + ids.map { "'\(escapedSQL($0))'" }.joined(separator: ", ") + ")"
    }

    /// The version most of a namespace's Latin chunks carry: the index that answers for them now.
    func servingVersionTag(namespace: String, excluding documentId: String? = nil) -> String? {
        servingVersionTag(namespace: namespace, script: .latin, excluding: documentId)
    }

    /// The version most of a namespace's chunks under `script` carry (Plan JY P1). A vault keeps
    /// one model per index **per script**: a library holding an English and a Chinese manual is
    /// served by the Latin model for the one and the CJK model for the other.
    func servingVersionTag(namespace: String, script: EmbeddingScript, excluding documentId: String? = nil) -> String? {
        let ids = documentIds(namespace: namespace, script: script).filter { $0 != documentId }
        guard !ids.isEmpty else { return nil }
        let sql = """
        SELECT c.embedding_version, COUNT(*) AS n FROM doc_chunks c
        WHERE \(documentIdClause(ids)) AND c.embedding IS NOT NULL AND c.embedding_version IS NOT NULL
        GROUP BY c.embedding_version ORDER BY n DESC LIMIT 1
        """
        return rows(sql) { stmt in sqlite3_column_text(stmt, 0).map { String(cString: $0) } }.first ?? nil
    }

    /// The model id that answers for a namespace now — what the evidence gate is chosen by. Read
    /// over all of the namespace's chunks, whatever their script: the gate's defaults are chosen
    /// by model family, and every script model is contextual (Plan JY P3 calibrates per group).
    func servingModelId(namespace: String) -> String {
        guard Self.isVaultNamespace(namespace) else { return embedder.modelId }
        let sql = """
        SELECT c.embedding_version, COUNT(*) AS n FROM doc_chunks c JOIN documents d ON c.document_id = d.id
        WHERE d.namespace = '\(escapedSQL(namespace))' AND c.embedding IS NOT NULL AND c.embedding_version IS NOT NULL
        GROUP BY c.embedding_version ORDER BY n DESC LIMIT 1
        """
        let tag = rows(sql) { stmt in sqlite3_column_text(stmt, 0).map { String(cString: $0) } }.first ?? nil
        if let version = EmbeddingVersion(tag: tag) { return version.modelId }
        return vaultTargetEmbedder.modelId
    }

    /// The embedder a document joining `namespace` is embedded with: a vault's serving model while
    /// the vault has an index and that model is here, its target otherwise; the store's embedder
    /// for every other namespace. A vault mid-way through a re-index keeps one model per index.
    func ingestEmbedder(namespace: String, excluding documentId: String? = nil) -> Embedder {
        guard Self.isVaultNamespace(namespace) else { return embedder }
        if let tag = servingVersionTag(namespace: namespace, excluding: documentId),
           let serving = embedderProducing(versionTag: tag, script: .latin) {
            return serving
        }
        return vaultTargetEmbedder
    }

    /// The embedder a document in `script` joining `namespace` is embedded with (Plan JY P1): the
    /// one above for a Latin document; for any other, the vault's serving model for that script
    /// while it is here, else that script's model, else nil — the document is stored with no
    /// vectors and searched by its words until the model lands and the self-heal embeds it.
    func ingestEmbedder(namespace: String, script: EmbeddingScript, excluding documentId: String? = nil) -> Embedder? {
        guard script != .latin else { return ingestEmbedder(namespace: namespace, excluding: documentId) }
        if Self.isVaultNamespace(namespace),
           let tag = servingVersionTag(namespace: namespace, script: script, excluding: documentId),
           let serving = embedderProducing(versionTag: tag, script: script) {
            return serving
        }
        return scriptEmbedder(for: script)
    }

    /// The question embedded once per model a vault's chunks use, for one search.
    struct QueryVectors {
        let text: String
        let store: DocumentStore
        private final class Cache {
            var vectors: [String: [Float]?] = [:]
            var byTag: [String: [Float]?] = [:]
            var milliseconds: [String: Int] = [:]
        }
        private let cache = Cache()

        init(text: String, store: DocumentStore) {
            self.text = text
            self.store = store
        }

        /// The question embedded by the model that produced `tag`, when that model reads
        /// `script`'s text (Plan JY P1) — once per model for the whole search, so a library mixing
        /// English, Cyrillic and Chinese manuals compares each passage with a question vector from
        /// its own model.
        @MainActor func vector(forVersionTag tag: String?, script: EmbeddingScript = .latin) -> [Float]? {
            guard let tag else { return nil }
            let key = "\(script.rawValue) \(tag)"
            if let known = cache.vectors[key] { return known }
            guard let embedder = store.embedderProducing(versionTag: tag, script: script) else {
                cache.vectors[key] = .some(nil)
                return nil
            }
            if let same = cache.byTag[tag] {
                cache.vectors[key] = same
                return same
            }
            let started = Date()
            let vector = embedder.embed(text)
            cache.vectors[key] = vector
            cache.byTag[tag] = vector
            cache.milliseconds[tag] = Int(Date().timeIntervalSince(started) * 1000)
            return vector
        }

        /// How many times the question was embedded: one per model. For the tests.
        var embeddedModelCount: Int { cache.byTag.count }

        /// One line per model used: how long embedding the question took. Never the question.
        @MainActor func logTimings() {
            for (tag, ms) in cache.milliseconds {
                PrivacyLog.store(.ragDocuments, .queryEmbedded,
                                 detail: PrivacyToken(DocumentStore.modelClass(EmbeddingVersion(tag: tag)?.modelId ?? "")),
                                 durationMs: ms)
            }
        }
    }

    /// The model family for a log line — a closed set, never the full identifier.
    nonisolated static func modelClass(_ modelId: String) -> String {
        if modelId.hasPrefix("none") { return "none" }
        if modelId.hasPrefix("nl-contextual") { return "contextual" }
        if modelId.hasPrefix("nl-sentence") { return "sentence" }
        if modelId.hasPrefix("nl-word") { return "word" }
        return "other"
    }

    /// An index log line's model detail: the family alone for a Latin document, as before; the
    /// family and the script for any other ("contextual.cjk", "none.cyrillic").
    nonisolated static func indexDetail(modelId: String?, script: EmbeddingScript) -> String {
        let family = modelClass(modelId ?? "none")
        return script == .latin ? family : "\(family).\(script.rawValue)"
    }

    /// How a vault re-index went.
    enum UpgradeOutcome: Equatable {
        /// Every chunk already carries the target model's vectors.
        case current
        /// The new index was completed and swapped in.
        case completed(chunks: Int)
        /// Stopped part-way (the app went to the background, the setting changed); the vectors
        /// built so far are kept, and the next run carries on from them.
        case interrupted(done: Int, total: Int)
    }

    /// Re-index a vault's manuals with `target`, resumably, without disturbing search.
    ///
    /// New vectors go into a pending column chunk by chunk; the index that answers is untouched
    /// until every chunk of the vault has its new vector, and then all of them swap in one
    /// transaction. A run that stops part-way keeps what it built, and the next run embeds only
    /// what is still missing. `progress` reports (manual title, chunks done, chunks to do).
    ///
    /// Per script (Plan JY P1): only the manuals `script`'s model embeds are re-indexed, and only
    /// theirs swap, so a library's English and Chinese manuals each keep the index that answers
    /// for them until their own new one is complete. `target` must read `script`'s text.
    func upgradeVaultEmbeddings(namespace: String, script: EmbeddingScript = .latin, to target: Embedder,
                                progress: ((String, Int, Int) -> Void)? = nil,
                                shouldContinue: () -> Bool = { true }) async -> UpgradeOutcome {
        guard Self.isVaultNamespace(namespace), target.isAvailable, target.script == script else { return .current }
        let tag = target.version.tag
        let started = Date()
        var embedded = 0
        for _ in 0..<3 {
            let todo = pendingWork(namespace: namespace, script: script, targetTag: tag)
            if todo.total == 0 {
                let ids = documentIds(namespace: namespace, script: script)
                if !ids.isEmpty {
                    exec("UPDATE doc_chunks SET pending_embedding = NULL, pending_version = NULL WHERE "
                         + documentIdClause(ids).replacingOccurrences(of: "c.document_id", with: "document_id"))
                }
                return embedded > 0 ? .completed(chunks: embedded) : .current
            }
            var done = todo.total - todo.missing.count
            for row in todo.missing {
                guard shouldContinue(), !Task.isCancelled else { return .interrupted(done: done, total: todo.total) }
                writePending(chunkId: row.id, vector: target.embed(row.text), versionTag: tag)
                done += 1
                embedded += 1
                progress?(row.title, done, todo.total)
                await Task.yield()
            }
            guard shouldContinue(), !Task.isCancelled else { return .interrupted(done: done, total: todo.total) }
            // Swap only if nothing joined the vault meanwhile; otherwise go round and embed it too.
            if pendingWork(namespace: namespace, script: script, targetTag: tag).missing.isEmpty {
                guard swapPending(namespace: namespace, script: script, targetTag: tag) else {
                    return .interrupted(done: done, total: todo.total)
                }
                refresh()
                PrivacyLog.store(.ragDocuments, .reembedded, count: embedded, total: todo.total,
                                 detail: PrivacyToken(Self.indexDetail(modelId: target.modelId, script: script)),
                                 durationMs: Int(Date().timeIntervalSince(started) * 1000))
                return .completed(chunks: embedded)
            }
        }
        return .interrupted(done: embedded, total: embedded)
    }

    /// The vault's chunks under `script` not yet on `targetTag`, and of those, the ones with no
    /// pending vector.
    private func pendingWork(namespace: String, script: EmbeddingScript,
                             targetTag: String) -> (total: Int, missing: [(id: String, title: String, text: String)]) {
        let ids = documentIds(namespace: namespace, script: script)
        guard !ids.isEmpty else { return (0, []) }
        let sql = """
        SELECT c.id, d.name, c.text, c.pending_version FROM doc_chunks c JOIN documents d ON c.document_id = d.id
        WHERE d.namespace = ? AND (c.embedding_version IS NULL OR c.embedding_version != ?) AND \(documentIdClause(ids))
        ORDER BY d.name, c.chunk_index
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, []) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, namespace, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, targetTag, -1, SQLITE_TRANSIENT)
        var total = 0
        var missing: [(id: String, title: String, text: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            total += 1
            let pending = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 3))
            guard pending != targetTag else { continue }
            missing.append((String(cString: sqlite3_column_text(stmt, 0)), String(cString: sqlite3_column_text(stmt, 1)),
                            String(cString: sqlite3_column_text(stmt, 2))))
        }
        return (total, missing)
    }

    private func writePending(chunkId: String, vector: [Float]?, versionTag: String) {
        let sql = "UPDATE doc_chunks SET pending_embedding = ?, pending_version = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        if let vector {
            let data = vecToData(vector)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) }
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_text(stmt, 2, versionTag, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, chunkId, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    /// Every pending vector of the vault's manuals under `script` becomes their index, in one
    /// transaction.
    private func swapPending(namespace: String, script: EmbeddingScript, targetTag: String) -> Bool {
        let ids = documentIds(namespace: namespace, script: script)
        guard !ids.isEmpty, exec("BEGIN IMMEDIATE") else { return false }
        let inVault = "document_id IN (SELECT id FROM documents WHERE namespace = '\(escapedSQL(namespace))') AND "
            + documentIdClause(ids).replacingOccurrences(of: "c.document_id", with: "document_id")
        let tag = escapedSQL(targetTag)
        let ok = exec("""
            UPDATE doc_chunks SET embedding = pending_embedding,
                embedding_version = CASE WHEN pending_embedding IS NULL THEN NULL ELSE pending_version END,
                pending_embedding = NULL, pending_version = NULL
            WHERE \(inVault) AND pending_version = '\(tag)'
            """)
        guard ok, exec("COMMIT") else { exec("ROLLBACK"); return false }
        return true
    }

    /// How far a vault's re-index has got: chunks on the target model or with a pending vector
    /// for it, of all its chunks. For the indexing screen and the tests.
    /// For the manuals under `script` (Plan JY P1); Latin by default.
    func upgradeProgress(namespace: String, script: EmbeddingScript = .latin, targetTag: String) -> (done: Int, total: Int) {
        let work = pendingWork(namespace: namespace, script: script, targetTag: targetTag)
        let all = documentChunkCount(namespace: namespace, script: script)
        return (all - work.missing.count, all)
    }

    private func documentChunkCount(namespace: String, script: EmbeddingScript) -> Int {
        let ids = documentIds(namespace: namespace, script: script)
        guard !ids.isEmpty else { return 0 }
        let sql = """
        SELECT COUNT(*) FROM doc_chunks c JOIN documents d ON c.document_id = d.id WHERE d.namespace = ? AND \(documentIdClause(ids))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, namespace, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - Passage locations (Plan IN P0)

    /// Bumped when what the chunker records about a chunk's place changes, so stored rows are
    /// located again — the `EmbeddingVersion` pattern, for positions rather than vectors. 2: the
    /// chunker keeps line breaks between sentences and chunks a clause-numbered document at its
    /// clause headings (Plan IV P3), so a stored document whose text now chunks differently is
    /// re-chunked under its own id by `PassageLocationMigration`, and one that chunks the same only
    /// has its positions rewritten. 3: a stored vault document's tables are extracted from its PDF
    /// and their row passages added (Plan JJ P0); its text chunks are only re-located, never
    /// re-chunked, when their text is unchanged. 4: a caption whose page did not resolve to a grid
    /// is kept too, by its label and page (Plan JJ P1); a document whose text version 3 already
    /// located only has its tables read again. 5: tables are read again for the labels a letter
    /// belongs to, the pages a table carries on to with no caption, cells that are marks and groups
    /// printed side by side (Plan JJ P5) — again the tables only. 6: tables printed as pictures
    /// are read from the page's recognition (Plan JN P1) — the tables only, the text untouched.
    /// 7: a caption with a revision mark in its margin, a "(Concluded)" page and a folio printed at
    /// the end of the footer line are read (Plan JW P0) — the tables again, and a PDF document's
    /// printed page labels with them; the text untouched. 8: the text is read again (Plan JY P4) —
    /// a folio printed alone on a line no longer renumbers a page, and a book in another language
    /// gets its captions, headings without case, collapsed fake bold, CJK splitting and chunk size.
    /// A document whose text chunks the same row for row keeps its rows, its ids and its vectors,
    /// and only has its page, section and figure rewritten (which is all an English document can
    /// get: none of its rules changed); one whose text changed is re-chunked under its own id.
    /// 9 (Plan JY P5a): the text is read again once more — a chunk cites the page holding most of
    /// it (`DocumentChunker.creditsMajorityPage`), dotted caption labels are whole, a two-pair
    /// fake bold is read off the glyphs, and a recognised manual is read from the pages its import
    /// kept. Text that chunks as stored keeps its rows and vectors; only its places move.
    nonisolated static let locationVersion = 9
    /// The location version at which a document's text was last read again, below which the
    /// migration re-reads it rather than only its tables.
    nonisolated static let textReadVersion = 9

    /// The oldest location version among a document's own text chunks (its table rows left out),
    /// or nil when it has none. A never-located row counts as 0.
    func textLocationVersion(documentId: String) -> Int? {
        let sql = """
        SELECT COUNT(*), MIN(COALESCE(location_version, 0)) FROM doc_chunks
        WHERE document_id = ? AND \(Self.notTableRow)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_int(stmt, 0) > 0 else { return nil }
        return Int(sqlite3_column_int(stmt, 1))
    }

    /// Stamp every chunk of a document with the current location version, its places unchanged:
    /// what a location bump that changed nothing about the text leaves behind.
    func markLocated(documentId: String) {
        exec("UPDATE doc_chunks SET location_version = \(Self.locationVersion) "
             + "WHERE document_id = '\(escapedSQL(documentId))'")
    }

    /// One chunk's text and place, for the highlight. Its own query rather than `fetchChunks`,
    /// which decodes every embedding in the namespace to answer for one row.
    ///
    /// A table's row passage (Plan JJ P1) is the app's sentence, not the page's words, so its
    /// anchor carries the row as printed (`TableRowPassage.printedRuns`), read from the stored
    /// table, and the locator marks the row's own line.
    func anchor(documentId: String, chunkIndex: Int) -> PassageAnchor? {
        if documentId.hasPrefix("captured:"), !capturedNamespaceAllowed(documentId) { return nil }
        let sql = """
        SELECT text, page, page_start, page_end, sentences, kind, figure FROM doc_chunks
        WHERE document_id = ? AND chunk_index = ? LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(chunkIndex))
        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { return nil }
        func optionalInt(_ column: Int32) -> Int? {
            sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, column))
        }
        func optionalText(_ column: Int32) -> String? {
            sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, column))
        }
        let text = String(cString: raw)
        let page = optionalInt(1), pageStart = optionalInt(2), pageEnd = optionalInt(3)
        let sentences = optionalText(4)
        var runs: [String] = []
        if optionalText(5) == DocumentChunker.Kind.tableRow.rawValue {
            let figure = optionalText(6)
            runs = TableRowPassage.row(forPassage: text, figure: figure, in: tables(documentId: documentId))
                .map { TableRowPassage.printedRuns(of: $0.row) } ?? []
            // A row that cannot be read back is matched only as its own sentence, which no page
            // prints: the page opens unmarked rather than marked by a piece of the sentence.
            if runs.isEmpty { runs = [text] }
        }
        return PassageAnchor(documentId: documentId, chunkIndex: chunkIndex, text: text,
                             page: page, pageStart: pageStart, pageEnd: pageEnd,
                             sentenceStarts: PassageAnchor.decode(sentences), printedRuns: runs)
    }

    /// Whether any of a document's chunks were stored before the current location version.
    func needsLocation(documentId: String) -> Bool {
        let sql = """
        SELECT COUNT(*) FROM doc_chunks WHERE document_id = ?
        AND (location_version IS NULL OR location_version < \(Self.locationVersion))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0
    }

    /// Write freshly computed places onto a document's existing rows, matched by chunk index, in
    /// one transaction. Only when the re-chunked text is the stored text, row for row: then the
    /// document id, the text and the embedding stay exactly as they were, and everything keyed on
    /// them — a ledger entry, a citation, an evidence label — is untouched. The page, section and
    /// figure are written too (Plan JY P4): a printed folio no longer moves a page, and a book in
    /// another language gains its captions and headings, without its text changing. Returns false (and
    /// writes nothing) when the texts disagree, which is the caller's cue to re-chunk instead.
    /// A table's row passages are not the document's text and are left out of the comparison;
    /// `replaceTables(_:documentId:)` rewrites them.
    func writeLocations(documentId: String, chunks: [DocumentChunker.Chunk]) -> Bool {
        let sql = "SELECT chunk_index, text FROM doc_chunks WHERE document_id = ? AND \(Self.notTableRow) ORDER BY chunk_index"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
        var stored: [(index: Int, text: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            stored.append((Int(sqlite3_column_int(stmt, 0)), String(cString: sqlite3_column_text(stmt, 1))))
        }
        sqlite3_finalize(stmt)
        guard !stored.isEmpty, stored.count == chunks.count,
              zip(stored, chunks).allSatisfy({ $0.index == $1.index && $0.text == $1.text }) else { return false }
        guard exec("BEGIN IMMEDIATE") else { return false }
        let update = """
        UPDATE doc_chunks SET page_start = ?, page_end = ?, sentences = ?, location_version = ?,
        page = ?, section = ?, figure = ?
        WHERE document_id = ? AND chunk_index = ?
        """
        for chunk in chunks {
            var row: OpaquePointer?
            guard sqlite3_prepare_v2(db, update, -1, &row, nil) == SQLITE_OK else { exec("ROLLBACK"); return false }
            bindLocation(chunk, to: row, from: 1)
            if let page = chunk.page { sqlite3_bind_int(row, 5, Int32(page)) } else { sqlite3_bind_null(row, 5) }
            if let section = chunk.section { sqlite3_bind_text(row, 6, section, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(row, 6) }
            if let figure = chunk.figure { sqlite3_bind_text(row, 7, figure, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(row, 7) }
            sqlite3_bind_text(row, 8, documentId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(row, 9, Int32(chunk.index))
            let result = sqlite3_step(row)
            sqlite3_finalize(row)
            guard result == SQLITE_DONE else { exec("ROLLBACK"); return false }
        }
        return exec("COMMIT")
    }

    /// Replace a document's chunks with a fresh chunking under the same document id, re-embedding
    /// them — for a document whose text no longer chunks the way it was stored (the extractor
    /// changed since import). The id is kept so the ledger, citations and evidence still name it.
    @discardableResult
    func rechunk(documentId: String, chunks: [DocumentChunker.Chunk]) async -> Bool {
        guard !chunks.isEmpty, let namespace = storedNamespace(documentId: documentId) else { return false }
        let profile = DocumentLanguageProfile.detect(chunks.filter { $0.kind != .tableRow }.map(\.text).joined(separator: "\n"))
        let chunkEmbedder = ingestEmbedder(namespace: namespace, script: EmbeddingScript(profile: profile), excluding: documentId)
        var vectors: [Data?] = []
        for chunk in chunks {
            vectors.append(chunkEmbedder?.embed(chunk.text).map(vecToData))
            await Task.yield()
        }
        guard exec("BEGIN IMMEDIATE") else { return false }
        exec("DELETE FROM doc_chunks WHERE document_id = '\(escapedSQL(documentId))'")
        let now = Date().timeIntervalSince1970
        for (index, chunk) in chunks.enumerated() {
            insertChunk(documentId: documentId, index: chunk.index, text: chunk.text, embedding: vectors[index],
                        page: chunk.page, section: chunk.section, kind: chunk.kind, figure: chunk.figure,
                        createdAt: now, version: vectors[index] == nil ? nil : chunkEmbedder?.version.tag,
                        location: chunk)
        }
        exec("UPDATE documents SET chunk_count = \(chunks.count) WHERE id = '\(escapedSQL(documentId))'")
        recordLanguageProfile(profile, documentId: documentId)
        guard exec("COMMIT") else { exec("ROLLBACK"); return false }
        refresh()
        return true
    }

    /// Replace the printed page labels recorded for a document.
    func setPageLabels(_ labels: [PageLabel], documentId: String) {
        exec("DELETE FROM doc_page_labels WHERE document_id = '\(escapedSQL(documentId))'")
        let sql = "INSERT OR REPLACE INTO doc_page_labels (document_id, page, label, source) VALUES (?, ?, ?, ?)"
        for label in labels {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(label.page))
            sqlite3_bind_text(stmt, 3, label.label, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, label.source.rawValue, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// The printed page labels recorded for a document, as a two-way map.
    func pageLabels(documentId: String) -> PageLabelMap {
        let sql = "SELECT page, label, source FROM doc_page_labels WHERE document_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return PageLabelMap([]) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
        var labels: [PageLabel] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            labels.append(PageLabel(page: Int(sqlite3_column_int(stmt, 0)),
                                    label: String(cString: sqlite3_column_text(stmt, 1)),
                                    source: PageLabel.Source(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .printed))
        }
        return PageLabelMap(labels)
    }

    // MARK: - The Documents library's structure (Plan JY P5a)

    /// The personal documents (`personalDocuments()`) stored before the current location version,
    /// with their profiles. The Documents library has no file to read again; its text is rebuilt
    /// from its chunks (`reconstructedText`).
    func libraryDocumentsNeedingLocation() -> [(id: String, profile: DocumentLanguageProfile)] {
        personalDocuments().filter { needsLocation(documentId: $0.id) }
            .map { (id: $0.id, profile: languageProfile(documentId: $0.id)) }
    }

    /// A document's own text rebuilt from its stored chunks, its table rows left out: each chunk's
    /// sentences (`sentences`, the offsets the chunker recorded) in order, with the line break or
    /// space that stood before each, the sentences a chunk repeats from the one before
    /// (`DocumentChunker.overlapChars`) dropped, and a page break written where a chunk's page moves
    /// on. Nil when the document has no chunks. What the chunker read is not stored, so this is its
    /// text as the chunks hold it: a row's page markers and grammar lines were never in a chunk.
    func reconstructedText(documentId: String, overlapCharacters: Int = 200) -> String? {
        struct Row { let text: String; let page: Int?; let starts: [Int] }
        let stored: [Row] = rows("""
            SELECT text, page, sentences FROM doc_chunks WHERE document_id = '\(escapedSQL(documentId))'
            AND \(Self.notTableRow) ORDER BY chunk_index ASC
            """) { stmt in
            let page = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 1))
            let sentences = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            return Row(text: String(cString: sqlite3_column_text(stmt, 0)), page: page,
                       starts: PassageAnchor.decode(sentences))
        }
        guard !stored.isEmpty else { return nil }
        var sentences: [(text: String, separator: String)] = []
        var page = stored.first?.page
        var out = ""
        for row in stored {
            var characters = Array(row.text)
            if row.starts.isEmpty, !out.isEmpty {
                // A row stored before its sentences were recorded: its overlap is cut by characters,
                // the longest start of it that ends what is already rebuilt.
                let tail = Array(out.suffix(overlapCharacters))
                var cut = 0
                for length in stride(from: min(tail.count, characters.count), through: 1, by: -1)
                    where Array(tail.suffix(length)) == Array(characters.prefix(length)) {
                    cut = length
                    break
                }
                characters = Array(characters.dropFirst(cut)).drop(while: \.isWhitespace).map { $0 }
                guard !characters.isEmpty else { continue }
            }
            let starts = (row.starts.isEmpty ? [0] : row.starts).filter { $0 < characters.count }
            var pieces: [(text: String, separator: String)] = []
            for (k, start) in starts.enumerated() {
                let end = k + 1 < starts.count ? max(start, starts[k + 1] - 1) : characters.count
                let text = String(characters[start..<min(end, characters.count)])
                // A chunk's first sentence has nothing before it to say: a line break, which every
                // whitespace rule reads as one and CJK text, which has no spaces, needs.
                let separator = start == 0 || characters[start - 1] == "\n" ? "\n" : " "
                pieces.append((text, separator))
            }
            // The longest run of this chunk's first sentences that ends what is already rebuilt,
            // within the overlap a chunk carries.
            var overlap = 0
            var k = min(pieces.count, sentences.count)
            while k > 0 {
                let carried = pieces.prefix(k).reduce(0) { $0 + $1.text.count + 1 }
                if carried <= overlapCharacters,
                   zip(sentences.suffix(k), pieces.prefix(k)).allSatisfy({ $0.text == $1.text }) { overlap = k; break }
                k -= 1
            }
            let fresh = pieces.dropFirst(overlap)
            guard !fresh.isEmpty else { continue }
            if let rowPage = row.page, let open = page, rowPage > open {
                out += String(repeating: "\u{0C}", count: rowPage - open)
                page = rowPage
            }
            for piece in fresh {
                if !out.isEmpty, !out.hasSuffix("\u{0C}") { out += piece.separator }
                out += piece.text
                sentences.append(piece)
            }
        }
        return out
    }

    // MARK: - Tables (Plan JJ P0)

    /// The kinds `query` and `passages(sharingTermsWith:)` search by default: prose and the row
    /// passages of extracted tables. Drawings are reached by token and by figure.
    nonisolated static let searchedKinds: Set<DocumentChunker.Kind> = [.prose, .tableRow]

    /// SQL that leaves a table's row passages out of a document's own text.
    private static let notTableRow = "(kind IS NULL OR kind != '\(DocumentChunker.Kind.tableRow.rawValue)')"

    /// Row passages the last `ingest` left out at `TableRowPassage.rowCap`, for the caller's log.
    private(set) var lastTableRowsDropped = 0

    /// What a table write stored.
    struct TableWrite: Equatable {
        var tables = 0
        var rowPassages = 0
        /// Rows past `TableRowPassage.rowCap` in some table: kept in the table, given no passage.
        var rowsDropped = 0
    }

    /// The tables extracted from a document, in the order they were stored.
    func tables(documentId: String) -> [ManualTable] {
        if documentId.hasPrefix("captured:"), !capturedNamespaceAllowed(documentId) { return [] }
        let sql = "SELECT json FROM doc_tables WHERE document_id = ? ORDER BY table_index ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
        let decoder = JSONDecoder()
        var tables: [ManualTable] = []
        while sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) {
            if let table = try? decoder.decode(ManualTable.self, from: Data(String(cString: raw).utf8)) {
                tables.append(table)
            }
        }
        return tables
    }

    /// A stored table and the document it came from (Plan JJ P1).
    struct StoredTable: Equatable {
        let documentId: String
        let documentName: String
        let table: ManualTable
        /// The rule the table's document is read with (Plan JY P0), so its title and headings are
        /// compared with a question the way its passages are.
        var termRule: TermRule = .english
    }

    /// Every table stored for the documents of `namespace` (or of `documentIds` within it), the
    /// captions that could not be read included, by document title then storage order — what
    /// `table_lookup` resolves against and what a question naming a table is recognised by.
    func storedTables(namespace: String?, documentIds: [String]? = nil) -> [StoredTable] {
        if let namespace, namespace.hasPrefix("captured:"), !capturedNamespaceAllowed(namespace) { return [] }
        let scope = namespace.map { "d.namespace = '\(escapedSQL($0))'" } ?? "d.namespace NOT LIKE 'captured:%'"
        var sql = "SELECT t.document_id, d.name, t.json FROM doc_tables t JOIN documents d ON t.document_id = d.id "
            + "WHERE \(scope)"
        if let ids = documentIds {
            guard !ids.isEmpty else { return [] }
            sql += " AND t.document_id IN (" + ids.map { "'\(escapedSQL($0))'" }.joined(separator: ", ") + ")"
        }
        sql += " ORDER BY d.name ASC, t.table_index ASC"
        let decoder = JSONDecoder()
        return rows(sql) { stmt -> StoredTable? in
            guard let id = sqlite3_column_text(stmt, 0), let name = sqlite3_column_text(stmt, 1),
                  let json = sqlite3_column_text(stmt, 2),
                  let table = try? decoder.decode(ManualTable.self, from: Data(String(cString: json).utf8)) else {
                return nil
            }
            return StoredTable(documentId: String(cString: id), documentName: String(cString: name), table: table)
        }.compactMap { $0 }.map { stored in
            var stored = stored
            stored.termRule = termRule(documentId: stored.documentId)
            return stored
        }
    }

    /// Whether any document of `documentIds` has a table row passage — what asks the retriever
    /// for the larger passage limit (`ManualPassageLimit`, Plan JJ P1).
    func hasTableRows(documentIds: [String]) -> Bool {
        guard !documentIds.isEmpty else { return false }
        let list = documentIds.map { "'\(escapedSQL($0))'" }.joined(separator: ", ")
        return !rows("SELECT 1 FROM doc_chunks WHERE document_id IN (\(list)) "
                     + "AND kind = '\(DocumentChunker.Kind.tableRow.rawValue)' LIMIT 1") { _ in true }.isEmpty
    }

    /// The passages of one table by its label (Plan JJ P1): the chunks its caption names — its row
    /// passages, and a drawing or prose chunk of its page when the caption named one — or, for a
    /// table whose grid could not be read and whose caption names no chunk, the chunks of the page
    /// it is printed on, so the route still reaches the page the technician can be shown.
    func passages(table label: String, namespace: String?, documentIds: [String]? = nil) -> [Passage] {
        let named = passages(figure: label, namespace: namespace, documentIds: documentIds, limit: Int.max)
        guard named.isEmpty else { return named }
        var out: [Passage] = []
        for stored in storedTables(namespace: namespace, documentIds: documentIds)
        where stored.table.label.caseInsensitiveCompare(label) == .orderedSame {
            for page in stored.table.pages.map(\.physical) {
                out += passages(onPage: page, namespace: namespace, documentIds: [stored.documentId], limit: Int.max)
                    .filter { $0.kind != .tableRow }
            }
        }
        return out
    }

    /// Replace the tables recorded for a document. The row passages are written by the caller.
    private func setTables(_ tables: [ManualTable], documentId: String) {
        exec("DELETE FROM doc_tables WHERE document_id = '\(escapedSQL(documentId))'")
        let sql = "INSERT OR REPLACE INTO doc_tables (document_id, table_index, label, pages, json) VALUES (?, ?, ?, ?, ?)"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (index, table) in tables.enumerated() {
            guard let json = try? encoder.encode(table), let text = String(data: json, encoding: .utf8) else { continue }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(index))
            sqlite3_bind_text(stmt, 3, table.label, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, table.pages.map { String($0.physical) }.joined(separator: ","), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, text, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Replace a stored document's tables and their row passages, leaving every other chunk — its
    /// id, text, embedding and place — exactly as it is. The row passages are numbered after the
    /// document's last text chunk and embedded with the model the vault is served by. For the
    /// location migration, which brings tables to documents indexed before there were any; an
    /// empty list takes them away.
    @discardableResult
    func replaceTables(_ tables: [ManualTable], documentId: String) async -> TableWrite {
        guard let namespace = storedNamespace(documentId: documentId) else { return TableWrite() }
        let sql = "SELECT MAX(chunk_index) FROM doc_chunks WHERE document_id = ? AND \(Self.notTableRow)"
        var stmt: OpaquePointer?
        var next = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                next = Int(sqlite3_column_int(stmt, 0)) + 1
            }
        }
        sqlite3_finalize(stmt)

        let rows = TableRowPassage.chunks(for: tables, startingAt: next)
        let chunkEmbedder = ingestEmbedder(namespace: namespace, script: embeddingScript(documentId: documentId))
        var vectors: [Data?] = []
        for chunk in rows.chunks {
            vectors.append(chunkEmbedder?.embed(chunk.text).map(vecToData))
            await Task.yield()
        }
        // The document may have been removed while the rows were embedded.
        guard storedNamespace(documentId: documentId) == namespace, exec("BEGIN IMMEDIATE") else { return TableWrite() }
        exec("DELETE FROM doc_chunks WHERE document_id = '\(escapedSQL(documentId))' "
             + "AND kind = '\(DocumentChunker.Kind.tableRow.rawValue)'")
        let now = Date().timeIntervalSince1970
        for (index, chunk) in rows.chunks.enumerated() {
            insertChunk(documentId: documentId, index: chunk.index, text: chunk.text, embedding: vectors[index],
                        page: chunk.page, section: chunk.section, kind: chunk.kind, figure: chunk.figure,
                        createdAt: now, version: vectors[index] == nil ? nil : chunkEmbedder?.version.tag,
                        location: chunk)
        }
        setTables(tables, documentId: documentId)
        exec("UPDATE documents SET chunk_count = (SELECT COUNT(*) FROM doc_chunks WHERE document_id = "
             + "'\(escapedSQL(documentId))') WHERE id = '\(escapedSQL(documentId))'")
        guard exec("COMMIT") else { exec("ROLLBACK"); return TableWrite() }
        refresh()
        return TableWrite(tables: tables.count, rowPassages: rows.chunks.count, rowsDropped: rows.dropped)
    }


    // MARK: - SQLite setup

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            PrivacyLog.store(.ragDocuments, .openFailed,
                             error: .sqlite(code: sqlite3_errcode(db),
                                            extended: sqlite3_extended_errcode(db)))
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
    }

    private func createTables() {
        exec("""
        CREATE TABLE IF NOT EXISTS documents (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            source_type TEXT NOT NULL DEFAULT 'text',
            namespace TEXT NOT NULL DEFAULT 'global',
            created_at REAL NOT NULL,
            chunk_count INTEGER NOT NULL DEFAULT 0,
            char_count INTEGER NOT NULL DEFAULT 0
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS doc_chunks (
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            chunk_index INTEGER NOT NULL,
            text TEXT NOT NULL,
            embedding BLOB,
            page INTEGER,
            section TEXT,
            created_at REAL NOT NULL
        )
        """)
        // Bring pre-existing databases (created before page/section citations) up to schema.
        // ALTER fails harmlessly if the column already exists; exec swallows the error.
        exec("ALTER TABLE doc_chunks ADD COLUMN page INTEGER")
        exec("ALTER TABLE doc_chunks ADD COLUMN section TEXT")
        // Embedding version stamp (see [[EmbeddingVersion]]) — lets a later model swap re-embed rather
        // than silently compare across embedding spaces.
        exec("ALTER TABLE doc_chunks ADD COLUMN embedding_version TEXT")
        // What kind of page a chunk came off, and the figure that names it (Plan EK). Rows stored
        // before these columns existed read back as prose with no figure, which is how they were
        // already being treated — no re-index is forced.
        exec("ALTER TABLE doc_chunks ADD COLUMN kind TEXT")
        exec("ALTER TABLE doc_chunks ADD COLUMN figure TEXT")
        // One-time backfill: rows ingested before the stamp were produced by the *current* model (this
        // migration doesn't change the model), so tag them as current — no re-embed needed. A genuine
        // model change later is what flips these to outdated. Only when a usable model is present.
        if embedder.dimension > 0 {
            exec("UPDATE doc_chunks SET embedding_version = '\(escapedSQL(embedder.version.tag))' "
                 + "WHERE embedding_version IS NULL AND embedding IS NOT NULL")
        }
        // Where each chunk sits on its page (Plan IN P0). Rows stored before these columns read back
        // with no location; `PassageLocationMigration` fills them in from the vault's own file on a
        // later launch, keeping the document id, the chunk text and the embedding as they are.
        exec("ALTER TABLE doc_chunks ADD COLUMN page_start INTEGER")
        exec("ALTER TABLE doc_chunks ADD COLUMN page_end INTEGER")
        exec("ALTER TABLE doc_chunks ADD COLUMN sentences TEXT")
        exec("ALTER TABLE doc_chunks ADD COLUMN location_version INTEGER")
        // A vault manual's next index, built beside the one that answers until it is complete
        // (Plan IV P4).
        exec("ALTER TABLE doc_chunks ADD COLUMN pending_embedding BLOB")
        exec("ALTER TABLE doc_chunks ADD COLUMN pending_version TEXT")
        // The printed page each physical page carries, where the PDF or its header says (decision 4).
        exec("""
        CREATE TABLE IF NOT EXISTS doc_page_labels (
            document_id TEXT NOT NULL,
            page INTEGER NOT NULL,
            label TEXT NOT NULL,
            source TEXT NOT NULL,
            PRIMARY KEY (document_id, page)
        )
        """)
        // The tables extracted from a vault document's PDF (Plan JJ P0): one row per table, the
        // whole table as JSON. Derived from the organisation's own loaded copy and, like the
        // document, never exported, packed or linked.
        exec("""
        CREATE TABLE IF NOT EXISTS doc_tables (
            document_id TEXT NOT NULL,
            table_index INTEGER NOT NULL,
            label TEXT NOT NULL,
            pages TEXT NOT NULL,
            json TEXT NOT NULL,
            PRIMARY KEY (document_id, table_index)
        )
        """)
        // Each document's language profile (Plan JY P0), as JSON: its script, its language and how
        // sure the detection was. Null for a document indexed before the column, which
        // `languageProfile(documentId:)` fills in from the document's stored text on first use.
        exec("ALTER TABLE documents ADD COLUMN language_profile TEXT")
        exec("CREATE INDEX IF NOT EXISTS idx_chunk_doc ON doc_chunks(document_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_doc_ns ON documents(namespace)")
    }

    // MARK: - Inserts

    private func insertDocument(id: String, name: String, sourceType: String, namespace: String,
                                createdAt: Double, chunkCount: Int, charCount: Int) {
        let sql = "INSERT OR REPLACE INTO documents (id, name, source_type, namespace, created_at, chunk_count, char_count) VALUES (?, ?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, sourceType, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, namespace, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, createdAt)
        sqlite3_bind_int(stmt, 6, Int32(chunkCount))
        sqlite3_bind_int(stmt, 7, Int32(charCount))
        _ = sqlite3_step(stmt)
    }

    private func insertChunk(documentId: String, index: Int, text: String, embedding: Data?,
                             page: Int?, section: String?, kind: DocumentChunker.Kind, figure: String?,
                             createdAt: Double, version: String?, location: DocumentChunker.Chunk? = nil) {
        let sql = "INSERT INTO doc_chunks (id, document_id, chunk_index, text, embedding, page, section, created_at, embedding_version, kind, figure, page_start, page_end, sentences, location_version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, documentId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(index))
        sqlite3_bind_text(stmt, 4, text, -1, SQLITE_TRANSIENT)
        if let data = embedding {
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 5, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) }
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let page { sqlite3_bind_int(stmt, 6, Int32(page)) } else { sqlite3_bind_null(stmt, 6) }
        if let section { sqlite3_bind_text(stmt, 7, section, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 7) }
        sqlite3_bind_double(stmt, 8, createdAt)
        // Only stamp a version when there is actually an embedding to tag.
        if let version, embedding != nil { sqlite3_bind_text(stmt, 9, version, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 9) }
        sqlite3_bind_text(stmt, 10, kind.rawValue, -1, SQLITE_TRANSIENT)
        if let figure { sqlite3_bind_text(stmt, 11, figure, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 11) }
        bindLocation(location, to: stmt, from: 12)
        _ = sqlite3_step(stmt)
    }

    /// Binds a chunk's place on its page to four consecutive parameters: start, end, sentences and
    /// the location version. A chunk without a location (a team learning stored whole) binds nulls,
    /// and a null version is what tells the migration a row was never located.
    private func bindLocation(_ chunk: DocumentChunker.Chunk?, to stmt: OpaquePointer?, from first: Int32) {
        guard let chunk else {
            for offset in 0..<Int32(4) { sqlite3_bind_null(stmt, first + offset) }
            return
        }
        if let start = chunk.pageStart { sqlite3_bind_int(stmt, first, Int32(start)) } else { sqlite3_bind_null(stmt, first) }
        if let end = chunk.pageEnd { sqlite3_bind_int(stmt, first + 1, Int32(end)) } else { sqlite3_bind_null(stmt, first + 1) }
        sqlite3_bind_text(stmt, first + 2, PassageAnchor.encode(chunk.sentenceStarts), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, first + 3, Int32(Self.locationVersion))
    }

    // MARK: - Fetches

    private struct ChunkRow {
        let id: String
        let documentId: String
        let documentName: String
        var namespace: String = ""
        let chunkIndex: Int
        let text: String
        let embedding: [Float]?
        let page: Int?
        let section: String?
        let embeddingVersion: String?
        let kind: DocumentChunker.Kind
        let figure: String?
        /// The document's rule (Plan JY P0), set once the rows are read.
        var termRule: TermRule = .english
        /// The model family that embeds the document (Plan JY P1), set once the rows are read.
        var embeddingScript: EmbeddingScript = .latin
        /// A chunk of a document in another script with no vector from that script's model —
        /// the model is not on the phone, or has not re-indexed it yet. Never set for Latin.
        var vectorPending = false
    }

    private func fetchChunks(namespace: String?, documentIds: [String]?) -> [ChunkRow] {
        if let namespace, namespace.hasPrefix("captured:"), !capturedNamespaceAllowed(namespace) { return [] }
        var sql = """
        SELECT c.id, c.document_id, d.name, c.chunk_index, c.text, c.embedding, c.page, c.section,
               c.embedding_version, c.kind, c.figure, d.namespace
        FROM doc_chunks c JOIN documents d ON c.document_id = d.id
        """
        var clauses: [String] = []
        if let ns = namespace { clauses.append("d.namespace = '\(escapedSQL(ns))'") }
        else { clauses.append("d.namespace NOT LIKE 'captured:%'") }
        if let ids = documentIds, !ids.isEmpty {
            let list = ids.map { "'\(escapedSQL($0))'" }.joined(separator: ", ")
            clauses.append("c.document_id IN (\(list))")
        }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }

        var rows: [ChunkRow] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let docId = String(cString: sqlite3_column_text(stmt, 1))
            let name = String(cString: sqlite3_column_text(stmt, 2))
            let idx = Int(sqlite3_column_int(stmt, 3))
            let text = String(cString: sqlite3_column_text(stmt, 4))
            var emb: [Float]? = nil
            if sqlite3_column_type(stmt, 5) != SQLITE_NULL, let ptr = sqlite3_column_blob(stmt, 5) {
                let len = sqlite3_column_bytes(stmt, 5)
                emb = dataToVec(Data(bytes: ptr, count: Int(len)))
            }
            let page = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 6)) : nil
            let section = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil
            let version = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 8)) : nil
            let kindTag = sqlite3_column_type(stmt, 9) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 9)) : nil
            let figure = sqlite3_column_type(stmt, 10) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 10)) : nil
            let rowNamespace = sqlite3_column_type(stmt, 11) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 11)) : ""
            rows.append(ChunkRow(id: id, documentId: docId, documentName: name, namespace: rowNamespace,
                                 chunkIndex: idx, text: text,
                                 embedding: emb, page: page, section: section, embeddingVersion: version,
                                 kind: kindTag.flatMap(DocumentChunker.Kind.init(rawValue:)) ?? .prose,
                                 figure: figure))
        }
        var profiles: [String: DocumentLanguageProfile] = [:]
        var scriptTags: [EmbeddingScript: String?] = [:]
        for index in rows.indices {
            let documentId = rows[index].documentId
            let profile = profiles[documentId] ?? languageProfile(documentId: documentId)
            profiles[documentId] = profile
            rows[index].termRule = profile.termRule
            let script = EmbeddingScript(profile: profile)
            rows[index].embeddingScript = script
            guard script != .latin else { continue }
            // Whether the chunk has a vector its own script's model made, the model being here.
            let tag: String?
            if let known = scriptTags[script] { tag = known } else {
                tag = scriptEmbedder(for: script)?.version.tag
                scriptTags[script] = .some(tag)
            }
            rows[index].vectorPending = rows[index].embedding == nil || tag == nil || rows[index].embeddingVersion != tag
        }
        return rows
    }

    private func refresh() {
        // Every write ends here, so a document replaced, re-indexed or removed is read afresh.
        languageProfileCache.removeAll()
        var refs: [DocumentRef] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, name, source_type, namespace, created_at, chunk_count, char_count FROM documents ORDER BY created_at DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { documents = refs; return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            refs.append(DocumentRef(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                name: String(cString: sqlite3_column_text(stmt, 1)),
                sourceType: String(cString: sqlite3_column_text(stmt, 2)),
                namespace: String(cString: sqlite3_column_text(stmt, 3)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                chunkCount: Int(sqlite3_column_int(stmt, 5)),
                charCount: Int(sqlite3_column_int(stmt, 6))
            ))
        }
        documents = refs
    }

    // MARK: - Helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func escapedSQL(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    private func vecToData(_ vec: [Float]) -> Data { vec.withUnsafeBytes { Data($0) } }

    private func dataToVec(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
