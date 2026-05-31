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
        NSLog("[DocumentStore] Init — %d documents", documents.count)
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

        for chunk in chunks {
            let embedding = embedder.embed(chunk.text)
            insertChunk(documentId: docId, index: chunk.index, text: chunk.text,
                        embedding: embedding.map(vecToData), page: chunk.page, section: chunk.section, createdAt: now)
            progress?(chunk.index + 1, chunks.count)
            await Task.yield()
        }

        refresh()
        NSLog("[DocumentStore] Ingested '%@' — %d chunks, %d chars", safeName, chunks.count, cleaned.count)
        return documents.first { $0.id == docId }
    }

    /// Retrieve the most relevant passages for a query, optionally scoped to a namespace and/or
    /// a specific document set.
    func query(_ text: String, limit: Int = 4, namespace: String? = nil, documentIds: [String]? = nil) -> [Passage] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let qv = embedder.embed(trimmed) else { return [] }

        let rows = fetchChunks(namespace: namespace, documentIds: documentIds)
        let scored = rows.compactMap { row -> Passage? in
            guard let emb = row.embedding else { return nil }
            let sim = Embedder.cosineSimilarity(qv, emb)
            guard sim > minSimilarity else { return nil }
            return Passage(documentId: row.documentId, documentName: row.documentName,
                           chunkIndex: row.chunkIndex, text: row.text, similarity: sim,
                           page: row.page, section: row.section)
        }
        return Array(scored.sorted { $0.similarity > $1.similarity }.prefix(limit))
    }

    func list() -> [DocumentRef] { documents }

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
        NSLog("[DocumentStore] Cleared all documents")
    }

    // MARK: - SQLite setup

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            NSLog("[DocumentStore] Failed to open database at %@", dbURL.path)
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
                             page: Int?, section: String?, createdAt: Double) {
        let sql = "INSERT INTO doc_chunks (id, document_id, chunk_index, text, embedding, page, section, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
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
        _ = sqlite3_step(stmt)
    }

    // MARK: - Fetches

    private struct ChunkRow {
        let documentId: String
        let documentName: String
        let chunkIndex: Int
        let text: String
        let embedding: [Float]?
        let page: Int?
        let section: String?
    }

    private func fetchChunks(namespace: String?, documentIds: [String]?) -> [ChunkRow] {
        var sql = """
        SELECT c.document_id, d.name, c.chunk_index, c.text, c.embedding, c.page, c.section
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
            let docId = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let idx = Int(sqlite3_column_int(stmt, 2))
            let text = String(cString: sqlite3_column_text(stmt, 3))
            var emb: [Float]? = nil
            if sqlite3_column_type(stmt, 4) != SQLITE_NULL, let ptr = sqlite3_column_blob(stmt, 4) {
                let len = sqlite3_column_bytes(stmt, 4)
                emb = dataToVec(Data(bytes: ptr, count: Int(len)))
            }
            let page = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 5)) : nil
            let section = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            rows.append(ChunkRow(documentId: docId, documentName: name, chunkIndex: idx, text: text,
                                 embedding: emb, page: page, section: section))
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
