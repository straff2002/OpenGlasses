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
    }

    // MARK: - Published

    @Published private(set) var documents: [DocumentRef] = []

    // MARK: - Private

    private var db: OpaquePointer?
    private let dbURL: URL
    private let chunker: DocumentChunker
    private let embedder: Embedder
    private let minSimilarity: Float = 0.05
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
        PrivacyLog.store(.ragDocuments, .opened, count: documents.count)
    }

    // MARK: - Public API

    /// Chunk, embed, and store a document. Yields between chunks so a large ingest doesn't
    /// monopolise the main actor. `progress` reports (completedChunks, totalChunks).
    @discardableResult
    func ingest(name: String,
                text: String,
                sourceType: String = "text",
                namespace: String = "global",
                progress: ((Int, Int) -> Void)? = nil) async -> DocumentRef? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let chunks = chunker.chunk(cleaned)
        guard !chunks.isEmpty else { return nil }

        let docId = UUID().uuidString
        let now = Date().timeIntervalSince1970
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name

        insertDocument(id: docId, name: safeName, sourceType: sourceType, namespace: namespace,
                       createdAt: now, chunkCount: chunks.count, charCount: cleaned.count)

        let versionTag = embedder.version.tag
        for chunk in chunks {
            let embedding = embedder.embed(chunk.text)
            insertChunk(documentId: docId, index: chunk.index, text: chunk.text,
                        embedding: embedding.map(vecToData), page: chunk.page, section: chunk.section,
                        createdAt: now, version: embedding != nil ? versionTag : nil)
            progress?(chunk.index + 1, chunks.count)
            await Task.yield()
        }

        refresh()
        // The document's name is its title — of a scanned letter, a report, a prescription — and
        // the chunk text is the document itself. What an ingest fault needs is how many chunks
        // came out of how much text.
        PrivacyLog.store(.ragDocuments, .ingested, count: chunks.count,
                         characters: cleaned.count, detail: PrivacyToken(sourceType))
        return documents.first { $0.id == docId }
    }

    /// Retrieve the most relevant passages for a query, optionally scoped to a namespace and/or
    /// a specific document set.
    func query(_ text: String, limit: Int = 4, namespace: String? = nil, documentIds: [String]? = nil) -> [Passage] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let qv = embedder.embed(trimmed) else { return [] }

        let current = embedder.version
        let rows = fetchChunks(namespace: namespace, documentIds: documentIds)
        let scored = rows.compactMap { row -> Passage? in
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
                           page: row.page, section: row.section)
        }
        return Array(scored.sorted { $0.similarity > $1.similarity }.prefix(limit))
    }

    /// Passages containing `token` as a whole word (case-insensitive), optionally scoped. No
    /// embedding involved — this is how a bare fault code or model number reaches a passage when
    /// the embedder has no vector for it. Ordered by document then chunk so results are stable.
    func passages(containingToken token: String, namespace: String? = nil,
                  documentIds: [String]? = nil, limit: Int = 8) -> [Passage] {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let rows = fetchChunks(namespace: namespace, documentIds: documentIds)
            .filter { CodeTokenizer.contains($0.text, token: token) }
            .sorted { ($0.documentName, $0.chunkIndex) < ($1.documentName, $1.chunkIndex) }
        return rows.prefix(max(limit, 1)).map {
            Passage(documentId: $0.documentId, documentName: $0.documentName, chunkIndex: $0.chunkIndex,
                    text: $0.text, similarity: 0, page: $0.page, section: $0.section)
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
            .sorted { $0.chunkIndex < $1.chunkIndex }
            .map(\.text)
        guard !chunks.isEmpty else { return nil }
        return DocumentReconstructor.deOverlap(chunks)
    }

    func forget(documentId: String) {
        let id = escapedSQL(documentId)
        exec("DELETE FROM doc_chunks WHERE document_id = '\(id)'")
        exec("DELETE FROM documents WHERE id = '\(id)'")
        refresh()
    }

    func clearAll() {
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

    // MARK: - Embedding migration

    /// The version stamp the active embedder produces. Chunks tagged differently are "outdated" and
    /// will be re-embedded on access (or eagerly via `reindexOutdated`).
    var currentEmbeddingVersionTag: String { embedder.version.tag }

    /// How many stored chunks were embedded by a model other than the active one (or are unstamped).
    /// Drives a "re-index now" affordance and lets tests assert migration progress.
    var outdatedChunkCount: Int {
        let current = embedder.version
        return fetchChunks(namespace: nil, documentIds: nil).reduce(0) { acc, row in
            row.embedding == nil ? acc
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
        let rows = fetchChunks(namespace: nil, documentIds: nil)
            .filter { $0.embedding != nil &&
                EmbeddingMigrationPolicy.action(stored: EmbeddingVersion(tag: $0.embeddingVersion),
                                                current: current) == .reembed }
        var done = 0
        for row in rows {
            if let fresh = embedder.embed(row.text) {
                writeBackEmbedding(chunkId: row.id, vector: fresh, versionTag: current.tag)
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
        // One-time backfill: rows ingested before the stamp were produced by the *current* model (this
        // migration doesn't change the model), so tag them as current — no re-embed needed. A genuine
        // model change later is what flips these to outdated. Only when a usable model is present.
        if embedder.dimension > 0 {
            exec("UPDATE doc_chunks SET embedding_version = '\(escapedSQL(embedder.version.tag))' "
                 + "WHERE embedding_version IS NULL AND embedding IS NOT NULL")
        }
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
                             page: Int?, section: String?, createdAt: Double, version: String?) {
        let sql = "INSERT INTO doc_chunks (id, document_id, chunk_index, text, embedding, page, section, created_at, embedding_version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
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
        _ = sqlite3_step(stmt)
    }

    // MARK: - Fetches

    private struct ChunkRow {
        let id: String
        let documentId: String
        let documentName: String
        let chunkIndex: Int
        let text: String
        let embedding: [Float]?
        let page: Int?
        let section: String?
        let embeddingVersion: String?
    }

    private func fetchChunks(namespace: String?, documentIds: [String]?) -> [ChunkRow] {
        var sql = """
        SELECT c.id, c.document_id, d.name, c.chunk_index, c.text, c.embedding, c.page, c.section, c.embedding_version
        FROM doc_chunks c JOIN documents d ON c.document_id = d.id
        """
        var clauses: [String] = []
        if let ns = namespace { clauses.append("d.namespace = '\(escapedSQL(ns))'") }
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
            rows.append(ChunkRow(id: id, documentId: docId, documentName: name, chunkIndex: idx, text: text,
                                 embedding: emb, page: page, section: section, embeddingVersion: version))
        }
        return rows
    }

    private func refresh() {
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
