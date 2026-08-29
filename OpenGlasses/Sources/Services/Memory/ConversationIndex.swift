import Foundation
import SQLite3

/// On-device full-text index over conversation turns (SQLite **FTS5**) — the substrate for
/// cross-session recall. Same `SQLite3` approach as `RAG/DocumentStore`; the DB path is
/// injectable so tests run against a temp file. Timestamps are stored ISO-8601 (fixed-width,
/// lexically sortable) so date-window filtering works with plain string comparisons.
///
/// Pure data layer — no model, no UI, no `Wearables` — so it's fully headless-testable.
final class ConversationIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `text` is the only indexed column → FTS5 column index 3 for `snippet()`.
    private static let textColumnIndex: Int32 = 3

    private init(sqlitePath: String, useWAL: Bool) {
        if sqlite3_open(sqlitePath, &db) != SQLITE_OK {
            NSLog("[ConversationIndex] Failed to open database")
        }
        if useWAL { exec("PRAGMA journal_mode=WAL") }
        exec("PRAGMA synchronous=NORMAL")
        createTable()
    }

    /// Production factory. The decrypted search projection exists only for this process and can be
    /// destroyed immediately when the conversation store locks.
    static func inMemory() -> ConversationIndex {
        ConversationIndex(sqlitePath: ":memory:", useWAL: false)
    }

    /// File-backed initializer for SQLite integration tests only. Production composition must use
    /// `inMemory()` so conversation text never becomes a second durable plaintext store.
    convenience init(dbURL: URL) {
        self.init(sqlitePath: dbURL.path, useWAL: true)
    }

    deinit { sqlite3_close(db) }

    private func createTable() {
        exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS turns USING fts5(
            turn_id UNINDEXED, thread_id UNINDEXED, role UNINDEXED, text, ts UNINDEXED
        )
        """)
    }

    // MARK: - Writes

    /// Index a turn, replacing any existing row with the same `id` (idempotent re-index).
    func index(_ turn: IndexedTurn) {
        delete(id: turn.id)
        let sql = "INSERT INTO turns (turn_id, thread_id, role, text, ts) VALUES (?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, turn.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, turn.threadID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, turn.role, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, turn.text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, RecallTimestamp.string(from: turn.timestamp), -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    /// Bulk index (unlock-time rebuild), wrapped in one transaction. The cancellation check lets a
    /// lock tear down a large rebuild without carrying on through the remaining decrypted turns.
    @discardableResult
    func indexAll(_ turns: [IndexedTurn], shouldCancel: () -> Bool = { false }) -> Bool {
        exec("BEGIN TRANSACTION")
        for turn in turns {
            if shouldCancel() {
                exec("ROLLBACK")
                return false
            }
            index(turn)
        }
        exec("COMMIT")
        return true
    }

    func delete(id: String) {
        let sql = "DELETE FROM turns WHERE turn_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    func delete(messageIDs: [String]) {
        guard !messageIDs.isEmpty else { return }
        exec("BEGIN TRANSACTION")
        for id in messageIDs { delete(id: id) }
        exec("COMMIT")
    }

    func delete(threadID: String) {
        let sql = "DELETE FROM turns WHERE thread_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, threadID, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    func clear() { exec("DELETE FROM turns") }

    func count() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM turns", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - Search

    /// Search the index. With a text match, rows are ranked by FTS5 bm25 (best first) and
    /// carry a highlighted snippet; without one (date-only / empty query) the most recent
    /// turns in the window are returned.
    func search(_ query: ParsedQuery, limit: Int = 12) -> [RecallHit] {
        guard limit > 0 else { return [] }
        var hits: [RecallHit] = []

        let dateClause = [
            query.since != nil ? "ts >= ?" : nil,
            query.until != nil ? "ts < ?" : nil,
        ].compactMap { $0 }

        let sql: String
        if query.match != nil {
            let clauses = (["turns MATCH ?"] + dateClause).joined(separator: " AND ")
            sql = """
            SELECT turn_id, thread_id, role, text, ts,
                   snippet(turns, \(Self.textColumnIndex), '[', ']', '…', 12), bm25(turns)
            FROM turns WHERE \(clauses)
            ORDER BY bm25(turns) LIMIT ?
            """
        } else {
            let whereSQL = dateClause.isEmpty ? "" : "WHERE \(dateClause.joined(separator: " AND "))"
            sql = """
            SELECT turn_id, thread_id, role, text, ts, '', 0.0
            FROM turns \(whereSQL) ORDER BY ts DESC LIMIT ?
            """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        if let match = query.match {
            sqlite3_bind_text(stmt, bindIndex, match, -1, SQLITE_TRANSIENT); bindIndex += 1
        }
        if let since = query.since {
            sqlite3_bind_text(stmt, bindIndex, RecallTimestamp.string(from: since), -1, SQLITE_TRANSIENT); bindIndex += 1
        }
        if let until = query.until {
            sqlite3_bind_text(stmt, bindIndex, RecallTimestamp.string(from: until), -1, SQLITE_TRANSIENT); bindIndex += 1
        }
        sqlite3_bind_int(stmt, bindIndex, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let threadID = String(cString: sqlite3_column_text(stmt, 1))
            let role = String(cString: sqlite3_column_text(stmt, 2))
            let text = String(cString: sqlite3_column_text(stmt, 3))
            let tsString = String(cString: sqlite3_column_text(stmt, 4))
            let snippetRaw = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let rank = sqlite3_column_double(stmt, 6)
            let snippet = snippetRaw.isEmpty ? String(text.prefix(140)) : snippetRaw
            hits.append(RecallHit(
                id: id, threadID: threadID, role: role, text: text,
                timestamp: RecallTimestamp.date(from: tsString) ?? Date(timeIntervalSinceReferenceDate: 0),
                snippet: snippet, rank: rank
            ))
        }
        return hits
    }

    /// Convenience: parse a natural phrase then search.
    func search(phrase: String, now: Date = Date(), limit: Int = 12) -> [RecallHit] {
        search(FTSQueryBuilder.build(phrase, now: now), limit: limit)
    }

    // MARK: - SQLite helper

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}
