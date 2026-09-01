import Foundation
import SQLite3

/// Persists self-proposed skills through their review lifecycle — **pending** (awaiting the user),
/// **approved** (the user accepted; ready to inject like any skill), **dismissed** (rejected; never
/// re-proposed). Strictly on-device (`evolved_skills.sqlite`), never synced. The store is the only
/// stateful piece of the evolution loop; the decisions feeding it are pure ([[EvolutionTrigger]],
/// [[SkillDeduplicator]], [[SkillProposal]]).
@MainActor
final class EvolvedSkillStore: ObservableObject {

    static let shared = EvolvedSkillStore()

    enum Status: String { case pending, approved, dismissed }

    struct EvolvedSkill: Identifiable, Equatable {
        let id: String
        let draft: SkillDraft
        let status: Status
        let createdAt: Date
        let resolvedAt: Date?
    }

    private var db: OpaquePointer?
    private let dbURL: URL
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `directory` is injectable so tests can point at a temp folder.
    init(directory: URL? = nil) {
        let docs = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        dbURL = docs.appendingPathComponent("evolved_skills.sqlite")
        openDatabase()
        createTable()
    }

    deinit { sqlite3_close(db) }

    // MARK: - Write

    /// Enqueue a proposed draft as `pending`. No-ops (returns false) if a skill with the same name
    /// already exists in any status — once dismissed, it's never re-proposed. Returns true if inserted.
    @discardableResult
    func enqueue(_ draft: SkillDraft) -> Bool {
        guard !knownNames().contains(draft.name) else { return false }
        let sql = """
        INSERT INTO evolved_skills (id, name, trigger_text, instruction, status, created_at, resolved_at)
        VALUES (?, ?, ?, ?, 'pending', ?, NULL)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, draft.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, draft.trigger, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, draft.instruction, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func approve(id: String) { resolve(id: id, to: .approved) }
    func dismiss(id: String) { resolve(id: id, to: .dismissed) }

    private func resolve(id: String, to status: Status) {
        let sql = "UPDATE evolved_skills SET status = ?, resolved_at = ? WHERE id = ? AND status = 'pending'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    // MARK: - Read

    func pending() -> [EvolvedSkill] { fetch(status: .pending) }
    func approved() -> [EvolvedSkill] { fetch(status: .approved) }
    func all() -> [EvolvedSkill] { fetch(status: nil) }

    /// Every skill name on record (any status) — drives auto-naming collisions and "never re-propose".
    func knownNames() -> Set<String> {
        var names = Set<String>()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM evolved_skills", -1, &stmt, nil) == SQLITE_OK else { return names }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { names.insert(String(cString: sqlite3_column_text(stmt, 0))) }
        return names
    }

    /// Drafts to dedup a new proposal against — pending + approved (dismissed ones are blocked by name).
    func activeDrafts() -> [SkillDraft] {
        (pending() + approved()).map(\.draft)
    }

    private func fetch(status: Status?) -> [EvolvedSkill] {
        var sql = "SELECT id, name, trigger_text, instruction, status, created_at, resolved_at FROM evolved_skills"
        if let status { sql += " WHERE status = '\(status.rawValue)'" }
        sql += " ORDER BY created_at DESC"
        var rows: [EvolvedSkill] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(EvolvedSkill(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                draft: SkillDraft(name: String(cString: sqlite3_column_text(stmt, 1)),
                                  trigger: String(cString: sqlite3_column_text(stmt, 2)),
                                  instruction: String(cString: sqlite3_column_text(stmt, 3))),
                status: Status(rawValue: String(cString: sqlite3_column_text(stmt, 4))) ?? .pending,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                resolvedAt: sqlite3_column_type(stmt, 6) != SQLITE_NULL
                    ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)) : nil
            ))
        }
        return rows
    }

    // MARK: - SQLite setup

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            PrivacyLog.store(.evolvedSkills, .openFailed,
                             error: .sqlite(code: sqlite3_errcode(db),
                                            extended: sqlite3_extended_errcode(db)))
        }
        exec("PRAGMA journal_mode=WAL")
    }

    private func createTable() {
        exec("""
        CREATE TABLE IF NOT EXISTS evolved_skills (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            trigger_text TEXT NOT NULL,
            instruction TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            created_at REAL NOT NULL,
            resolved_at REAL
        )
        """)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }
}
