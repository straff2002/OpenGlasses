import Foundation
import SQLite3

/// On-device knowledge graph: typed entities, typed edges between them, and an encounter log.
///
/// The "brain" layer that links what the other memory stores already hold. Where
/// `SemanticMemoryStore` answers "what facts resemble this query?" and `DocumentStore` answers
/// "which passages resemble it?", the brain answers relational questions vector search can't reach:
/// "who works at Acme?", "when did I last run into Alice, and where?".
///
/// Edges are extracted from ingested text with zero LLM calls ([[BrainRelationExtractor]]) —
/// pattern-based, high precision over recall. Lives in its own `brain.sqlite`; strictly on-device,
/// never synced to the gateway.
@MainActor
final class BrainStore: ObservableObject {

    static let shared = BrainStore()

    // MARK: - Types

    struct Entity: Identifiable, Equatable {
        let id: String
        let kind: String      // "person", "org", "place", "event", "source"
        let name: String
        let createdAt: Date
    }

    struct Edge: Equatable {
        let srcName: String
        let srcKind: String
        let relation: String  // "works_at", "lives_in", "founded", "leads", "married_to", "studied_at", "invested_in", "mentioned_in"
        let dstName: String
        let dstKind: String
        let sourceRef: String?
        let createdAt: Date

        var sentence: String {
            let verb = relation.replacingOccurrences(of: "_", with: " ")
            let cite = sourceRef.map { " (from \($0))" } ?? ""
            return "\(srcName) \(verb) \(dstName)\(cite)"
        }
    }

    struct Encounter: Equatable {
        let person: String
        let locationName: String?
        let latitude: Double?
        let longitude: Double?
        let context: String?
        let occurredAt: Date
    }

    struct Stats {
        let entities: Int
        let edges: Int
        let encounters: Int
    }

    // MARK: - Private

    private var db: OpaquePointer?
    private let dbURL: URL
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Init

    /// `directory` is injectable so tests can point at a temp folder.
    init(directory: URL? = nil) {
        let docs = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        dbURL = docs.appendingPathComponent("brain.sqlite")
        openDatabase()
        createTables()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Entities

    /// Insert the entity if it doesn't exist (case-insensitive on name within a kind); returns its id.
    @discardableResult
    func upsertEntity(kind: String, name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = entityId(kind: kind, name: trimmed) { return existing }
        let id = UUID().uuidString
        let sql = "INSERT INTO entities (id, kind, name, normalized, created_at) VALUES (?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return id }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, kind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, trimmed, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, trimmed.lowercased(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        _ = sqlite3_step(stmt)
        return id
    }

    /// Entity names that appear as substrings of the given text. Drives graph lookup from a
    /// free-form query ("what do I know about Alice's company?" → matches "Alice").
    /// Pass a kind to restrict (e.g. "person" when building mention edges).
    func entityNames(mentionedIn text: String, kind: String? = nil) -> [String] {
        let lowered = text.lowercased()
        var names: [String] = []
        var sql = "SELECT DISTINCT name, normalized FROM entities"
        if let kind { sql += " WHERE kind = '\(escapedSQL(kind))'" }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let normalized = String(cString: sqlite3_column_text(stmt, 1))
            if lowered.contains(normalized), !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// Remove an entity (by name, any kind) plus all its edges and encounters.
    func forget(entityName: String) {
        let norm = escapedSQL(entityName.lowercased())
        exec("""
        DELETE FROM edges WHERE src_id IN (SELECT id FROM entities WHERE normalized = '\(norm)')
            OR dst_id IN (SELECT id FROM entities WHERE normalized = '\(norm)')
        """)
        exec("DELETE FROM encounters WHERE lower(person) = '\(norm)'")
        exec("DELETE FROM entities WHERE normalized = '\(norm)'")
    }

    // MARK: - Edges

    /// Add a typed edge, upserting both endpoints. Duplicate (src, relation, dst) edges are ignored.
    func addEdge(srcKind: String, srcName: String, relation: String,
                 dstKind: String, dstName: String, sourceRef: String? = nil) {
        let srcId = upsertEntity(kind: srcKind, name: srcName)
        let dstId = upsertEntity(kind: dstKind, name: dstName)
        let sql = """
        INSERT OR IGNORE INTO edges (id, src_id, relation, dst_id, source_ref, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, srcId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, relation, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, dstId, -1, SQLITE_TRANSIENT)
        if let ref = sourceRef {
            sqlite3_bind_text(stmt, 5, ref, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        _ = sqlite3_step(stmt)
    }

    /// Edges touching the named entity, in either direction, newest first.
    func neighbors(of name: String, limit: Int = 12) -> [Edge] {
        let norm = escapedSQL(name.lowercased())
        let sql = """
        SELECT s.name, s.kind, e.relation, d.name, d.kind, e.source_ref, e.created_at
        FROM edges e JOIN entities s ON e.src_id = s.id JOIN entities d ON e.dst_id = d.id
        WHERE s.normalized = '\(norm)' OR d.normalized = '\(norm)'
        ORDER BY e.created_at DESC LIMIT \(limit)
        """
        return fetchEdges(sql)
    }

    /// Everyone/everything with the given relation to the named entity
    /// ("who works_at Acme?" → people with works_at edges into Acme).
    func sources(relation: String, dstName: String, limit: Int = 12) -> [Edge] {
        let sql = """
        SELECT s.name, s.kind, e.relation, d.name, d.kind, e.source_ref, e.created_at
        FROM edges e JOIN entities s ON e.src_id = s.id JOIN entities d ON e.dst_id = d.id
        WHERE e.relation = '\(escapedSQL(relation))' AND d.normalized = '\(escapedSQL(dstName.lowercased()))'
        ORDER BY e.created_at DESC LIMIT \(limit)
        """
        return fetchEdges(sql)
    }

    // MARK: - Encounters

    /// Log that a person was encountered (face recognition, or explicitly via the tool).
    func logEncounter(person: String, locationName: String? = nil,
                      latitude: Double? = nil, longitude: Double? = nil, context: String? = nil) {
        upsertEntity(kind: "person", name: person)
        let sql = """
        INSERT INTO encounters (id, person, location_name, latitude, longitude, context, occurred_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, person, -1, SQLITE_TRANSIENT)
        if let loc = locationName { sqlite3_bind_text(stmt, 3, loc, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
        if let lat = latitude { sqlite3_bind_double(stmt, 4, lat) } else { sqlite3_bind_null(stmt, 4) }
        if let lon = longitude { sqlite3_bind_double(stmt, 5, lon) } else { sqlite3_bind_null(stmt, 5) }
        if let ctx = context { sqlite3_bind_text(stmt, 6, ctx, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
        _ = sqlite3_step(stmt)
    }

    /// Encounters, newest first. Pass a person to filter; nil for all.
    func encounters(for person: String? = nil, limit: Int = 10) -> [Encounter] {
        var sql = "SELECT person, location_name, latitude, longitude, context, occurred_at FROM encounters"
        if let p = person { sql += " WHERE lower(person) = '\(escapedSQL(p.lowercased()))'" }
        sql += " ORDER BY occurred_at DESC LIMIT \(limit)"

        var rows: [Encounter] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Encounter(
                person: String(cString: sqlite3_column_text(stmt, 0)),
                locationName: sqlite3_column_type(stmt, 1) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 1)) : nil,
                latitude: sqlite3_column_type(stmt, 2) != SQLITE_NULL ? sqlite3_column_double(stmt, 2) : nil,
                longitude: sqlite3_column_type(stmt, 3) != SQLITE_NULL ? sqlite3_column_double(stmt, 3) : nil,
                context: sqlite3_column_type(stmt, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 4)) : nil,
                occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            ))
        }
        return rows
    }

    // MARK: - Ingestion

    /// Extract typed edges from free text (zero LLM calls) and store them. If `subject` is given
    /// and the text matches no subject-led pattern on its own (e.g. the fact is just
    /// "works at Stripe"), retries with the subject prepended. Known people mentioned in the text
    /// gain a `mentioned_in` edge to the source when `sourceRef` and `sourceKind` are provided.
    func ingest(text: String, subject: String? = nil, sourceRef: String? = nil, sourceKind: String? = nil) {
        var relations = BrainRelationExtractor.extract(from: text)
        if relations.isEmpty, let subject, !subject.isEmpty {
            relations = BrainRelationExtractor.extract(from: "\(subject) \(text)")
        }
        for r in relations {
            addEdge(srcKind: r.srcKind, srcName: r.src, relation: r.relation,
                    dstKind: r.dstKind, dstName: r.dst, sourceRef: sourceRef)
        }
        if let ref = sourceRef, let kind = sourceKind {
            for person in entityNames(mentionedIn: text, kind: "person") where person.lowercased() != ref.lowercased() {
                addEdge(srcKind: "person", srcName: person, relation: "mentioned_in",
                        dstKind: kind, dstName: ref, sourceRef: nil)
            }
        }
    }

    // MARK: - Stats

    var stats: Stats {
        Stats(entities: count("entities"), edges: count("edges"), encounters: count("encounters"))
    }

    // MARK: - SQLite setup

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            NSLog("[BrainStore] Failed to open database at %@", dbURL.path)
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
    }

    private func createTables() {
        exec("""
        CREATE TABLE IF NOT EXISTS entities (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            name TEXT NOT NULL,
            normalized TEXT NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE(kind, normalized)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS edges (
            id TEXT PRIMARY KEY,
            src_id TEXT NOT NULL,
            relation TEXT NOT NULL,
            dst_id TEXT NOT NULL,
            source_ref TEXT,
            created_at REAL NOT NULL,
            UNIQUE(src_id, relation, dst_id)
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS encounters (
            id TEXT PRIMARY KEY,
            person TEXT NOT NULL,
            location_name TEXT,
            latitude REAL,
            longitude REAL,
            context TEXT,
            occurred_at REAL NOT NULL
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_entities_norm ON entities(normalized)")
        exec("CREATE INDEX IF NOT EXISTS idx_edges_src ON edges(src_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_edges_dst ON edges(dst_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_encounters_person ON encounters(person)")
    }

    // MARK: - Helpers

    private func entityId(kind: String, name: String) -> String? {
        let sql = "SELECT id FROM entities WHERE kind = ? AND normalized = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, kind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, name.lowercased(), -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    private func fetchEdges(_ sql: String) -> [Edge] {
        var rows: [Edge] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Edge(
                srcName: String(cString: sqlite3_column_text(stmt, 0)),
                srcKind: String(cString: sqlite3_column_text(stmt, 1)),
                relation: String(cString: sqlite3_column_text(stmt, 2)),
                dstName: String(cString: sqlite3_column_text(stmt, 3)),
                dstKind: String(cString: sqlite3_column_text(stmt, 4)),
                sourceRef: sqlite3_column_type(stmt, 5) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 5)) : nil,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            ))
        }
        return rows
    }

    private func count(_ table: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func escapedSQL(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }
}

// MARK: - Relation extraction

/// Pattern-based (zero LLM calls) extraction of typed relations from prose.
/// Tuned for precision over recall: a missed edge costs nothing — the text is still findable via
/// semantic search — but a wrong edge pollutes graph answers.
enum BrainRelationExtractor {

    struct Relation: Equatable {
        let srcKind: String
        let src: String
        let relation: String
        let dstKind: String
        let dst: String
    }

    /// A proper-noun phrase: one or more capitalized words, allowing internal '&', "of", "the".
    private static let name = "([A-Z][\\w'’-]*(?:\\s+(?:[A-Z][\\w'’-]*|of|the|&))*)"

    /// (pattern, relation, dstKind). Subject is always captured first and treated as a person.
    private static let patterns: [(regex: NSRegularExpression, relation: String, dstKind: String)] = {
        let table: [(String, String, String)] = [
            ("\(name)\\s+(?:works|working)\\s+(?:at|for)\\s+\(name)", "works_at", "org"),
            ("\(name)\\s+(?:joined|joins)\\s+\(name)", "works_at", "org"),
            ("\(name)\\s+(?:is|was)\\s+(?:the\\s+)?(?:CEO|CTO|COO|CFO|founder|co-founder|president|head|director|VP)\\s+(?:of|at)\\s+\(name)", "leads", "org"),
            ("\(name)\\s+(?:founded|co-founded|started)\\s+\(name)", "founded", "org"),
            ("\(name)\\s+invested\\s+in\\s+\(name)", "invested_in", "org"),
            ("\(name)\\s+(?:lives|lived|living)\\s+in\\s+\(name)", "lives_in", "place"),
            ("\(name)\\s+(?:moved|moving)\\s+to\\s+\(name)", "lives_in", "place"),
            ("\(name)\\s+(?:is\\s+)?married\\s+to\\s+\(name)", "married_to", "person"),
            ("\(name)\\s+(?:studied|studies)\\s+at\\s+\(name)", "studied_at", "org"),
            ("\(name)\\s+(?:attended|is\\s+attending)\\s+\(name)", "attended", "event"),
        ]
        return table.compactMap { pattern, relation, dstKind in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, relation, dstKind)
        }
    }()

    /// Words that pass the capitalized-phrase test only because they start a sentence.
    private static let stopwords: Set<String> = [
        "i", "the", "he", "she", "they", "we", "it", "this", "that", "a", "an",
        "my", "his", "her", "their", "our", "and", "but", "so", "then", "when",
    ]

    static func extract(from text: String) -> [Relation] {
        var results: [Relation] = []
        let range = NSRange(text.startIndex..., in: text)
        for (regex, relation, dstKind) in patterns {
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match,
                      let srcRange = Range(match.range(at: 1), in: text),
                      let dstRange = Range(match.range(at: 2), in: text) else { return }
                let src = clean(String(text[srcRange]))
                let dst = clean(String(text[dstRange]))
                guard isUsableName(src), isUsableName(dst), src.lowercased() != dst.lowercased() else { return }
                let rel = Relation(srcKind: "person", src: src, relation: relation, dstKind: dstKind, dst: dst)
                if !results.contains(rel) { results.append(rel) }
            }
        }
        return results
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
    }

    private static func isUsableName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 60 else { return false }
        let first = s.components(separatedBy: " ").first?.lowercased() ?? ""
        return !stopwords.contains(first)
    }
}
