import Foundation
import SQLite3

/// Durable, append-only FIFO of `QueuedOp`, backed by SQLite (Plan T) — the same storage family
/// as `SemanticMemoryStore`. Survives app kills: everything a technician does offline is written
/// here synchronously, so a dropped connection mid-procedure never loses work. Ops are inserted
/// once and only their `state`/`attempts` mutate; `done` rows are tombstones until `purgeDone`.
@MainActor
final class OfflineQueue {
    private var db: OpaquePointer?

    /// `path` is injectable so tests can use a throwaway file (and reopen it to prove survival).
    init(path: URL? = nil) {
        let url = path ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("offline_queue.sqlite")
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            NSLog("[OfflineQueue] Failed to open database at %@", url.path)
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS ops (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            session_id TEXT NOT NULL,
            payload BLOB,
            created_at REAL NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL DEFAULT 'pending',
            seq INTEGER
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_ops_state ON ops(state)")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Mutations

    /// Append an op. Stable, monotonic `seq` (rowid) gives a deterministic FIFO tie-break when two
    /// ops share a `created_at`.
    func enqueue(_ op: QueuedOp) {
        let sql = "INSERT OR REPLACE INTO ops (id, kind, session_id, payload, created_at, attempts, state, seq) " +
                  "VALUES (?, ?, ?, ?, ?, ?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM ops))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, op.id)
        bindText(stmt, 2, op.kind.rawValue)
        bindText(stmt, 3, op.sessionId)
        op.payload.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 4, raw.baseAddress, Int32(op.payload.count), Self.transient)
        }
        sqlite3_bind_double(stmt, 5, op.createdAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 6, Int32(op.attempts))
        bindText(stmt, 7, op.state.rawValue)
        _ = sqlite3_step(stmt)
    }

    /// Update an op's state (and optionally its attempt count).
    func mark(_ id: String, state: OpState, attempts: Int? = nil) {
        let sql = attempts == nil
            ? "UPDATE ops SET state = ? WHERE id = ?"
            : "UPDATE ops SET state = ?, attempts = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, state.rawValue)
        if let attempts {
            sqlite3_bind_int(stmt, 2, Int32(attempts))
            bindText(stmt, 3, id)
        } else {
            bindText(stmt, 2, id)
        }
        _ = sqlite3_step(stmt)
    }

    /// Delete delivered (tombstone) ops to reclaim space.
    func purgeDone() {
        exec("DELETE FROM ops WHERE state = 'done'")
    }

    /// Test helper: wipe everything.
    func deleteAll() {
        exec("DELETE FROM ops")
    }

    // MARK: - Queries

    /// Pending ops in strict FIFO order (by `created_at`, then insert order).
    func pending(limit: Int = 500) -> [QueuedOp] {
        query("SELECT id, kind, session_id, payload, created_at, attempts, state FROM ops " +
              "WHERE state = 'pending' ORDER BY created_at ASC, seq ASC LIMIT \(limit)")
    }

    /// Every op, newest first — for the status UI.
    func all(limit: Int = 500) -> [QueuedOp] {
        query("SELECT id, kind, session_id, payload, created_at, attempts, state FROM ops " +
              "ORDER BY created_at DESC, seq DESC LIMIT \(limit)")
    }

    var pendingCount: Int { count(where: "state = 'pending'") }
    var conflictCount: Int { count(where: "state = 'conflict'") }

    // MARK: - SQLite plumbing

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT

    private func query(_ sql: String) -> [QueuedOp] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var ops: [QueuedOp] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let kind = OpKind(rawValue: String(cString: sqlite3_column_text(stmt, 1))) ?? .logEntry
            let sessionId = String(cString: sqlite3_column_text(stmt, 2))
            var payload = Data()
            if let blob = sqlite3_column_blob(stmt, 3) {
                payload = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 3)))
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            let attempts = Int(sqlite3_column_int(stmt, 5))
            let state = OpState(rawValue: String(cString: sqlite3_column_text(stmt, 6))) ?? .pending
            ops.append(QueuedOp(id: id, kind: kind, sessionId: sessionId, payload: payload,
                                createdAt: createdAt, attempts: attempts, state: state))
        }
        return ops
    }

    private func count(where clause: String) -> Int {
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM ops WHERE \(clause)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }
}
