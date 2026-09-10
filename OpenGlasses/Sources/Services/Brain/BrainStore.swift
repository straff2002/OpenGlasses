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
        /// Always a member of [[RelationOntology]]`.allowed` — `addEdge` drops anything else.
        let relation: String
        let dstName: String
        let dstKind: String
        let sourceRef: String?
        let createdAt: Date

        // The distillation tier. Defaulted so every reader written before it existed still
        // compiles, and so a row carried over by the schema migration reads exactly as it did.
        var state: BrainDistiller.State = .permanent
        var confidence: Double = 1.0
        var observations: Int = 1
        var distinctSessions: Int = 1
        /// When this claim became current; `nil` only for a row no migration has touched.
        var validFrom: Date?
        /// The last time it was observed — repetition moves this, `validFrom` stays put.
        var lastSeen: Date?
        /// Set when a newer claim retired this one. Nothing is deleted; history is stamped.
        var supersededAt: Date?

        /// How the edge reads to the model. The failure mode that matters is a guess or a
        /// retired fact being read as a present-tense truth, so both say so in words.
        var sentence: String {
            let cite = sourceRef.map { " (from \($0))" } ?? ""
            if supersededAt != nil || state == .superseded {
                return "\(srcName) \(RelationOntology.pastPhrase(for: relation)) \(dstName)\(cite)"
            }
            let verb = RelationOntology.phrase(for: relation)
            let marker = state == .provisional ? " (unconfirmed)" : ""
            return "\(srcName) \(verb) \(dstName)\(cite)\(marker)"
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

    /// A follow-up: what a person wants / is looking for / you owe them. A lightweight CRM "need",
    /// distinct from a fact (an edge) or a sighting (an encounter) — it has an open/resolved lifecycle.
    struct Need: Identifiable, Equatable {
        let id: String
        let person: String
        let text: String
        let createdAt: Date
        let resolvedAt: Date?

        var isOpen: Bool { resolvedAt == nil }
    }

    struct Stats {
        let entities: Int
        let edges: Int
        let encounters: Int
        let openNeeds: Int
    }

    // MARK: - Private

    private var db: OpaquePointer?
    private let dbURL: URL
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// The dials the distillation pass turns on. Injectable so a test can compress a fortnight
    /// into a millisecond, or a twenty-ingest budget into two.
    let policy: BrainDistiller.Policy

    /// Ingests since the last distillation pass. A long session distils on the way rather than
    /// waiting for an end that may never come.
    private var ingestsSinceDistillation = 0

    /// `PRAGMA user_version` of the schema this build writes.
    private static let schemaVersion: Int32 = 1

    // MARK: - Init

    /// `directory` is injectable so tests can point at a temp folder.
    init(directory: URL? = nil, policy: BrainDistiller.Policy = .default) {
        let docs = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.policy = policy
        dbURL = docs.appendingPathComponent("brain.sqlite")
        openDatabase()
        // A database that already has an `edges` table predates the tiered schema; a fresh one is
        // created with it. Telling them apart is what keeps a first launch from logging a
        // migration that carried nothing.
        let inherited = tableExists("edges")
        createTables()
        if inherited {
            migrateSchemaIfNeeded()
        } else {
            exec("PRAGMA user_version = \(Self.schemaVersion)")
        }
        StoreProtection.applyDatabase(at: dbURL)
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

    /// Remove an entity (by name, any kind) plus all its edges, encounters, and needs.
    func forget(entityName: String) {
        let norm = escapedSQL(entityName.lowercased())
        exec("""
        DELETE FROM edges WHERE src_id IN (SELECT id FROM entities WHERE normalized = '\(norm)')
            OR dst_id IN (SELECT id FROM entities WHERE normalized = '\(norm)')
        """)
        exec("DELETE FROM encounters WHERE lower(person) = '\(norm)'")
        exec("DELETE FROM needs WHERE lower(person) = '\(norm)'")
        exec("DELETE FROM entities WHERE normalized = '\(norm)'")
    }

    // MARK: - Edges

    /// Add a typed edge, upserting both endpoints.
    ///
    /// A repeat is no longer thrown away: re-observing the same `(src, relation, dst)` bumps the
    /// observation count, moves the last-seen stamp, and counts the session if it is a new one —
    /// still one row, but a row that now carries how often and how widely it has been heard. A
    /// relation outside [[RelationOntology]] is dropped and counted rather than stored.
    ///
    /// The tier defaults reproduce what every caller meant before the tier existed: a directly
    /// stated claim, permanent, full confidence.
    ///
    /// A retired claim can also come back. Nothing here is deleted, so "Maria lives in Wellington"
    /// after a move to Auckland lands on the row that supersession stamped; a *direct* restatement
    /// revives it — current again, valid from now, so the next pass retires Auckland by the same
    /// recency rule that retired Wellington. A provisional repeat does not: a guess cannot overturn
    /// what a distillation already decided.
    func addEdge(srcKind: String, srcName: String, relation: String,
                 dstKind: String, dstName: String, sourceRef: String? = nil,
                 sessionID: String? = nil,
                 confidence: Double = 1.0,
                 state: BrainDistiller.State = .permanent,
                 now: Date = Date()) {
        let canonical = RelationOntology.canonical(relation)
        guard RelationOntology.isAllowed(canonical) else {
            RelationOntology.recordDrop(canonical)
            return
        }
        let srcId = upsertEntity(kind: srcKind, name: srcName)
        let dstId = upsertEntity(kind: dstKind, name: dstName)
        let sql = """
        INSERT INTO edges (id, src_id, relation, dst_id, source_ref, created_at,
                           session_id, confidence, state, observations, distinct_sessions,
                           valid_from, last_seen, superseded_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 1, ?, ?, NULL)
        ON CONFLICT(src_id, relation, dst_id) DO UPDATE SET
            observations = observations + 1,
            last_seen = excluded.last_seen,
            distinct_sessions = distinct_sessions + (
                CASE WHEN excluded.session_id IS NOT NULL
                      AND (session_id IS NULL OR session_id <> excluded.session_id)
                     THEN 1 ELSE 0 END),
            session_id = COALESCE(excluded.session_id, session_id),
            confidence = MAX(confidence, excluded.confidence),
            state = CASE WHEN state = 'superseded' AND excluded.state <> 'permanent' THEN 'superseded'
                         WHEN excluded.state = 'permanent' THEN 'permanent'
                         ELSE state END,
            superseded_at = CASE WHEN state = 'superseded' AND excluded.state = 'permanent'
                                 THEN NULL ELSE superseded_at END,
            valid_from = CASE WHEN state = 'superseded' AND excluded.state = 'permanent'
                              THEN excluded.valid_from ELSE valid_from END,
            source_ref = COALESCE(source_ref, excluded.source_ref)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let stamp = now.timeIntervalSince1970
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, srcId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, canonical, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, dstId, -1, SQLITE_TRANSIENT)
        if let ref = sourceRef {
            sqlite3_bind_text(stmt, 5, ref, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_double(stmt, 6, stamp)
        if let sessionID, !sessionID.isEmpty {
            sqlite3_bind_text(stmt, 7, sessionID, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_double(stmt, 8, confidence)
        sqlite3_bind_text(stmt, 9, state.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 10, stamp)
        sqlite3_bind_double(stmt, 11, stamp)
        _ = sqlite3_step(stmt)
    }

    /// Edges touching the named entity, in either direction, newest first.
    ///
    /// Retired edges are excluded by default: the callers spend a five- or eight-row budget on
    /// this, and history should not eat a slot the present tense needed. Ask for it and it comes
    /// back — behind the current facts, and rendered in the past tense.
    func neighbors(of name: String, limit: Int = 12, includeSuperseded: Bool = false) -> [Edge] {
        let norm = escapedSQL(name.lowercased())
        let sql = """
        SELECT \(Self.edgeColumns)
        FROM edges e JOIN entities s ON e.src_id = s.id JOIN entities d ON e.dst_id = d.id
        WHERE (s.normalized = '\(norm)' OR d.normalized = '\(norm)')\(Self.currencyClause(includeSuperseded))
        ORDER BY (e.superseded_at IS NULL) DESC, e.created_at DESC LIMIT \(limit)
        """
        return fetchEdges(sql)
    }

    /// Everyone/everything with the given relation to the named entity
    /// ("who works_at Acme?" → people with works_at edges into Acme).
    func sources(relation: String, dstName: String, limit: Int = 12,
                 includeSuperseded: Bool = false) -> [Edge] {
        let sql = """
        SELECT \(Self.edgeColumns)
        FROM edges e JOIN entities s ON e.src_id = s.id JOIN entities d ON e.dst_id = d.id
        WHERE e.relation = '\(escapedSQL(RelationOntology.canonical(relation)))'
          AND d.normalized = '\(escapedSQL(dstName.lowercased()))'\(Self.currencyClause(includeSuperseded))
        ORDER BY (e.superseded_at IS NULL) DESC, e.created_at DESC LIMIT \(limit)
        """
        return fetchEdges(sql)
    }

    // MARK: - Distillation

    /// Revise the graph: promote what has been corroborated, retire what a newer claim replaced,
    /// drop what was said once and never again. Pure decisions ([[BrainDistiller]]), applied here
    /// in one transaction so a half-distilled graph is never readable.
    ///
    /// `sessionID` names the conversation that just ended; it is carried for the record only —
    /// the pass itself looks at the whole graph, because an expiry window and a supersession both
    /// concern edges no session touched.
    @discardableResult
    func distill(sessionID: String? = nil, now: Date = Date()) -> BrainDistiller.Summary {
        let candidates = distillationCandidates()
        let decisions = BrainDistiller.decide(candidates: candidates, now: now, policy: policy)
        let summary = BrainDistiller.Summary(decisions)
        ingestsSinceDistillation = 0
        guard summary.changed > 0 else { return summary }

        // All of it or none of it: a pass that promoted an edge but failed to retire the one it
        // replaced would leave two present-tense answers to the same question, which is the exact
        // state this whole change exists to end.
        exec("BEGIN IMMEDIATE")
        var applied = true
        for decision in decisions where applied {
            let id = escapedSQL(decision.id)
            switch decision {
            case .promote(_, let confidence):
                applied = exec("""
                UPDATE edges SET state = 'permanent', confidence = \(Self.number(confidence)),
                                 valid_from = COALESCE(valid_from, created_at)
                WHERE id = '\(id)'
                """)
            case .reinforce(_, let confidence):
                applied = exec("UPDATE edges SET confidence = \(Self.number(confidence)) WHERE id = '\(id)'")
            case .supersede(_, let at):
                applied = exec("""
                UPDATE edges SET state = 'superseded',
                                 superseded_at = \(Self.number(at.timeIntervalSince1970))
                WHERE id = '\(id)'
                """)
            case .expire:
                applied = exec("DELETE FROM edges WHERE id = '\(id)'")
            case .keep:
                break
            }
        }
        guard applied else {
            exec("ROLLBACK")
            PrivacyLog.store(.brain, .writeFailed, count: summary.changed, total: summary.considered)
            return BrainDistiller.Summary()
        }
        exec("COMMIT")

        PrivacyLog.store(.brain, .distilled, count: summary.changed, total: summary.considered)
        return summary
    }

    /// Every edge, flattened to the values the rules read. `valid_from` / `last_seen` fall back to
    /// `created_at` so a row a migration has not stamped still reasons correctly.
    private func distillationCandidates() -> [BrainDistiller.Candidate] {
        let sql = """
        SELECT e.id, s.name, e.relation, d.name, e.state, e.confidence, e.observations,
               e.distinct_sessions, COALESCE(e.valid_from, e.created_at),
               COALESCE(e.last_seen, e.created_at), e.superseded_at
        FROM edges e JOIN entities s ON e.src_id = s.id JOIN entities d ON e.dst_id = d.id
        """
        var rows: [BrainDistiller.Candidate] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(BrainDistiller.Candidate(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                srcName: String(cString: sqlite3_column_text(stmt, 1)),
                relation: String(cString: sqlite3_column_text(stmt, 2)),
                dstName: String(cString: sqlite3_column_text(stmt, 3)),
                state: BrainDistiller.State(rawValue: String(cString: sqlite3_column_text(stmt, 4))) ?? .permanent,
                confidence: sqlite3_column_double(stmt, 5),
                observations: Int(sqlite3_column_int(stmt, 6)),
                distinctSessions: Int(sqlite3_column_int(stmt, 7)),
                validFrom: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
                lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)),
                supersededAt: sqlite3_column_type(stmt, 10) != SQLITE_NULL
                    ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10)) : nil))
        }
        return rows
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

    // MARK: - Needs / follow-ups

    /// Record a follow-up for `person` (what they want / you owe them). Upserts the person entity so
    /// the dossier links up. Returns the new need's id.
    @discardableResult
    func addNeed(person: String, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID().uuidString
        guard !trimmed.isEmpty, !person.trimmingCharacters(in: .whitespaces).isEmpty else { return id }
        upsertEntity(kind: "person", name: person)
        let sql = "INSERT INTO needs (id, person, text, created_at, resolved_at) VALUES (?, ?, ?, ?, NULL)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return id }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, person, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, trimmed, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        _ = sqlite3_step(stmt)
        return id
    }

    /// Needs, newest first. Pass a person to filter; `openOnly` hides resolved ones.
    func needs(for person: String? = nil, openOnly: Bool = false, limit: Int = 20) -> [Need] {
        var clauses: [String] = []
        if let p = person { clauses.append("lower(person) = '\(escapedSQL(p.lowercased()))'") }
        if openOnly { clauses.append("resolved_at IS NULL") }
        var sql = "SELECT id, person, text, created_at, resolved_at FROM needs"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY created_at DESC LIMIT \(limit)"

        var rows: [Need] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Need(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                person: String(cString: sqlite3_column_text(stmt, 1)),
                text: String(cString: sqlite3_column_text(stmt, 2)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                resolvedAt: sqlite3_column_type(stmt, 4) != SQLITE_NULL
                    ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)) : nil
            ))
        }
        return rows
    }

    /// Mark a specific need resolved. No-op if already resolved or unknown.
    func resolveNeed(id: String) {
        let sql = "UPDATE needs SET resolved_at = ? WHERE id = ? AND resolved_at IS NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    /// Resolve open needs for a person, optionally only those whose text contains `matching`.
    /// Returns how many were resolved.
    @discardableResult
    func resolveNeeds(for person: String, matching: String? = nil) -> Int {
        let open = needs(for: person, openOnly: true, limit: 100)
        let targets = matching.map { needle in
            open.filter { $0.text.lowercased().contains(needle.lowercased()) }
        } ?? open
        for need in targets { resolveNeed(id: need.id) }
        return targets.count
    }

    // MARK: - Project memory

    /// Record a note scoped to an active project/job (`projectTag` is the `FieldSession.id`). Returns
    /// the new record's id. Transient by intent — it surfaces only while its project is active.
    @discardableResult
    func addProjectMemory(projectTag: String, text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTag = projectTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID().uuidString
        guard !trimmedText.isEmpty, !trimmedTag.isEmpty else { return id }
        let sql = "INSERT INTO project_memory (id, project_tag, text, created_at) VALUES (?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return id }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, trimmedTag, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, trimmedText, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        _ = sqlite3_step(stmt)
        return id
    }

    /// Project memories for a given project, oldest first (reads as a running log). Empty for an
    /// unknown tag.
    func projectMemories(for projectTag: String, limit: Int = 50) -> [ProjectMemory] {
        let sql = """
        SELECT id, project_tag, text, created_at FROM project_memory
        WHERE project_tag = '\(escapedSQL(projectTag))'
        ORDER BY created_at ASC LIMIT \(limit)
        """
        var rows: [ProjectMemory] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(ProjectMemory(
                id: UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID(),
                projectTag: String(cString: sqlite3_column_text(stmt, 1)),
                text: String(cString: sqlite3_column_text(stmt, 2)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            ))
        }
        return rows
    }

    /// Drop all project memories for a project (e.g. when the job is closed and you don't want to
    /// retain its notes). No-op for an unknown tag.
    func clearProjectMemories(for projectTag: String) {
        exec("DELETE FROM project_memory WHERE project_tag = '\(escapedSQL(projectTag))'")
    }

    // MARK: - Ingestion

    /// Extract typed edges from free text (zero LLM calls) and store them. If `subject` is given
    /// and the text matches no subject-led pattern on its own (e.g. the fact is just
    /// "works at Stripe"), retries with the subject prepended. Known people mentioned in the text
    /// gain a `mentioned_in` edge to the source when `sourceRef` and `sourceKind` are provided.
    /// `sessionID` is the conversation the text came from, when the caller knows it. It is what
    /// lets corroboration mean "heard in two different conversations" rather than "said twice in
    /// one breath"; callers that have no conversation to name pass nothing and lose nothing.
    func ingest(text: String, subject: String? = nil, sourceRef: String? = nil,
                sourceKind: String? = nil, sessionID: String? = nil) {
        var relations = BrainRelationExtractor.extract(from: text)
        if relations.isEmpty, let subject, !subject.isEmpty {
            relations = BrainRelationExtractor.extract(from: "\(subject) \(text)")
        }
        for r in relations {
            addEdge(srcKind: r.srcKind, srcName: r.src, relation: r.relation,
                    dstKind: r.dstKind, dstName: r.dst, sourceRef: sourceRef, sessionID: sessionID)
        }
        if let ref = sourceRef, let kind = sourceKind {
            for person in entityNames(mentionedIn: text, kind: "person") where person.lowercased() != ref.lowercased() {
                addEdge(srcKind: "person", srcName: person, relation: "mentioned_in",
                        dstKind: kind, dstName: ref, sourceRef: nil, sessionID: sessionID)
            }
        }
        noteIngestAgainstBudget(sessionID: sessionID)
    }

    /// A long session should not have to end before the graph tidies itself, so every so many
    /// ingests the pass runs anyway.
    private func noteIngestAgainstBudget(sessionID: String?) {
        ingestsSinceDistillation += 1
        guard ingestsSinceDistillation >= policy.ingestsBetweenPasses else { return }
        distill(sessionID: sessionID)   // resets the counter
    }

    // MARK: - Stats

    var stats: Stats {
        Stats(entities: count("entities"), edges: count("edges"), encounters: count("encounters"),
              openNeeds: needs(openOnly: true, limit: 1000).count)
    }

    // MARK: - SQLite setup

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            PrivacyLog.store(.brain, .openFailed,
                             error: .sqlite(code: sqlite3_errcode(db),
                                            extended: sqlite3_extended_errcode(db)))
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
        // The eight columns after `created_at` are the distillation tier. `UNIQUE(src_id,
        // relation, dst_id)` is retained deliberately: supersession is about *different*
        // destinations, and the constraint is what turns a repeat into an update rather than a
        // second row. A database that predates them gets them by `migrateSchemaIfNeeded`.
        exec("""
        CREATE TABLE IF NOT EXISTS edges (
            id TEXT PRIMARY KEY,
            src_id TEXT NOT NULL,
            relation TEXT NOT NULL,
            dst_id TEXT NOT NULL,
            source_ref TEXT,
            created_at REAL NOT NULL,
            session_id TEXT,
            confidence REAL NOT NULL DEFAULT 1.0,
            state TEXT NOT NULL DEFAULT 'permanent',
            observations INTEGER NOT NULL DEFAULT 1,
            distinct_sessions INTEGER NOT NULL DEFAULT 1,
            valid_from REAL,
            last_seen REAL,
            superseded_at REAL,
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
        exec("""
        CREATE TABLE IF NOT EXISTS needs (
            id TEXT PRIMARY KEY,
            person TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at REAL NOT NULL,
            resolved_at REAL
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS project_memory (
            id TEXT PRIMARY KEY,
            project_tag TEXT NOT NULL,
            text TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_entities_norm ON entities(normalized)")
        exec("CREATE INDEX IF NOT EXISTS idx_project_memory_tag ON project_memory(project_tag)")
        exec("CREATE INDEX IF NOT EXISTS idx_edges_src ON edges(src_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_edges_dst ON edges(dst_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_encounters_person ON encounters(person)")
        exec("CREATE INDEX IF NOT EXISTS idx_needs_person ON needs(person)")
    }

    // MARK: - Schema migration

    /// Bring a pre-tier `edges` table up to the current schema, additively.
    ///
    /// The whole risk of this change is one `ALTER TABLE` sequence running against a database
    /// nobody can inspect, so: no table is rewritten, no row is deleted, no constraint changes,
    /// and every new column has a default that reproduces exactly what the row already meant —
    /// permanent, full confidence, one observation, one session. If any statement fails,
    /// `user_version` stays 0 and the store reads as it did before; the next launch tries again,
    /// and only adds the columns still missing.
    ///
    /// Eight columns, not the six the plan first named. `last_seen` because expiry needs the time
    /// of the *last* sighting and `created_at` is the first; `distinct_sessions` because "heard in
    /// two different conversations" cannot be told from a single `session_id`.
    private func migrateSchemaIfNeeded() {
        guard userVersion() < Self.schemaVersion else { return }
        let present = Set(columnNames(of: "edges"))
        let additions: [(column: String, sql: String)] = [
            ("session_id", "ALTER TABLE edges ADD COLUMN session_id TEXT"),
            ("confidence", "ALTER TABLE edges ADD COLUMN confidence REAL NOT NULL DEFAULT 1.0"),
            ("state", "ALTER TABLE edges ADD COLUMN state TEXT NOT NULL DEFAULT 'permanent'"),
            ("observations", "ALTER TABLE edges ADD COLUMN observations INTEGER NOT NULL DEFAULT 1"),
            ("distinct_sessions", "ALTER TABLE edges ADD COLUMN distinct_sessions INTEGER NOT NULL DEFAULT 1"),
            ("valid_from", "ALTER TABLE edges ADD COLUMN valid_from REAL"),
            ("last_seen", "ALTER TABLE edges ADD COLUMN last_seen REAL"),
            ("superseded_at", "ALTER TABLE edges ADD COLUMN superseded_at REAL"),
        ]
        for addition in additions where !present.contains(addition.column) {
            guard exec(addition.sql) else { return }
        }
        // `valid_from` and `last_seen` cannot be added with a non-constant default, so they are
        // backfilled: an edge that was already here has been valid, and last seen, since it was
        // written.
        guard exec("UPDATE edges SET valid_from = created_at WHERE valid_from IS NULL"),
              exec("UPDATE edges SET last_seen = created_at WHERE last_seen IS NULL") else { return }
        let carried = count("edges")
        guard exec("PRAGMA user_version = \(Self.schemaVersion)") else { return }
        PrivacyLog.store(.brain, .migrated, count: carried)
    }

    private func userVersion() -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    private func tableExists(_ table: String) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(escapedSQL(table))'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func columnNames(of table: String) -> [String] {
        var names: [String] = []
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return names }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let raw = sqlite3_column_text(stmt, 1) { names.append(String(cString: raw)) }
        }
        return names
    }

    // MARK: - Helpers

    /// The edge projection every read shares, so a new column is added in one place.
    private static let edgeColumns = """
    s.name, s.kind, e.relation, d.name, d.kind, e.source_ref, e.created_at, e.state, \
    e.confidence, e.observations, e.distinct_sessions, e.valid_from, e.last_seen, e.superseded_at
    """

    private static func currencyClause(_ includeSuperseded: Bool) -> String {
        includeSuperseded ? "" : "\n  AND e.superseded_at IS NULL"
    }

    /// A `Double` as SQL. Locale-independent, because a comma decimal separator would be a
    /// syntax error rather than a wrong number.
    private static func number(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

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
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                state: BrainDistiller.State(rawValue: String(cString: sqlite3_column_text(stmt, 7))) ?? .permanent,
                confidence: sqlite3_column_double(stmt, 8),
                observations: Int(sqlite3_column_int(stmt, 9)),
                distinctSessions: Int(sqlite3_column_int(stmt, 10)),
                validFrom: sqlite3_column_type(stmt, 11) != SQLITE_NULL
                    ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11)) : nil,
                lastSeen: sqlite3_column_type(stmt, 12) != SQLITE_NULL
                    ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)) : nil,
                supersededAt: sqlite3_column_type(stmt, 13) != SQLITE_NULL
                    ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13)) : nil
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
/// semantic search — but a wrong edge pollutes graph answers. Every relation it produces is
/// checked against [[RelationOntology]] on the way out, so the patterns cannot quietly widen the
/// vocabulary the rest of the graph reasons over.
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
                // The patterns and the ontology are two statements of the same vocabulary; this
                // is where they are held to it, so neither can drift on its own.
                guard RelationOntology.isAllowed(relation) else { return }
                let rel = Relation(srcKind: "person", src: src, relation: relation, dstKind: dstKind, dst: dst)
                if !results.contains(rel) { results.append(rel) }
            }
        }
        return results
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
    }

    /// Whether a captured span is plausibly a name: non-empty, at most 60 characters, and not
    /// beginning with a stopword. Internal rather than private because the enrichment parser has
    /// to hold a model's proposed names to exactly the bound the patterns hold their own to —
    /// duplicating the rule there would be two rules that agree until one of them is edited.
    static func isUsableName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 60 else { return false }
        let first = s.components(separatedBy: " ").first?.lowercased() ?? ""
        return !stopwords.contains(first)
    }
}
