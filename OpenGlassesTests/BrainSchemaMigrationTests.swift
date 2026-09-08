import XCTest
import SQLite3
@testable import OpenGlasses

/// The one genuinely risky part of teaching the graph to revise itself: an `ALTER TABLE` sequence
/// running against a database on a wearer's phone that nobody can inspect.
///
/// So the v0 schema is written here explicitly — the six columns `edges` had before the tier
/// existed — and the assertions are about what survives: every row, reading exactly as it did,
/// with `user_version` as the marker that says the work is done and must not be repeated.
@MainActor
final class BrainSchemaMigrationTests: XCTestCase {

    private var tempRoot: URL!
    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        dbURL = tempRoot.appendingPathComponent("brain.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - A v0 database, written the way the old build wrote one

    private static let firstSeen = Date(timeIntervalSince1970: 1_700_000_000)

    private func writeVersionZeroDatabase() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let stamp = Self.firstSeen.timeIntervalSince1970
        for sql in [
            """
            CREATE TABLE entities (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL,
                normalized TEXT NOT NULL, created_at REAL NOT NULL, UNIQUE(kind, normalized))
            """,
            """
            CREATE TABLE edges (
                id TEXT PRIMARY KEY, src_id TEXT NOT NULL, relation TEXT NOT NULL,
                dst_id TEXT NOT NULL, source_ref TEXT, created_at REAL NOT NULL,
                UNIQUE(src_id, relation, dst_id))
            """,
            "INSERT INTO entities VALUES ('p1', 'person', 'Maria', 'maria', \(stamp))",
            "INSERT INTO entities VALUES ('l1', 'place', 'Wellington', 'wellington', \(stamp))",
            "INSERT INTO entities VALUES ('o1', 'org', 'Acme', 'acme', \(stamp))",
            "INSERT INTO edges VALUES ('e1', 'p1', 'lives_in', 'l1', 'old notes', \(stamp))",
            "INSERT INTO edges VALUES ('e2', 'p1', 'works_at', 'o1', NULL, \(stamp))",
        ] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "failed: \(sql)")
        }
        XCTAssertEqual(userVersion(), 0, "A database written by the old build is at version 0")
    }

    private func userVersion() -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int(stmt, 0)
    }

    private func columnNames() -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(edges)", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let raw = sqlite3_column_text(stmt, 1) { names.insert(String(cString: raw)) }
        }
        return names
    }

    /// Lines the log emitted while `body` ran.
    private func capturingLog(_ body: () -> Void) -> [String] {
        let lock = NSLock()
        var lines: [String] = []
        let token = PrivacyLog.addTap { _, line in
            lock.lock(); lines.append(line); lock.unlock()
        }
        defer { PrivacyLog.removeTap(token) }
        body()
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    // MARK: - Tests

    /// Additive only: the eight columns arrive and not one edge is lost on the way.
    func testMigrationAddsTheColumnsAndKeepsEveryEdge() {
        writeVersionZeroDatabase()
        var store: BrainStore? = BrainStore(directory: tempRoot)
        XCTAssertEqual(store?.stats.edges, 2, "Every pre-existing edge survives the upgrade")
        store = nil

        XCTAssertTrue(columnNames().isSuperset(of: [
            "session_id", "confidence", "state", "observations",
            "distinct_sessions", "valid_from", "last_seen", "superseded_at",
        ]))
        XCTAssertEqual(userVersion(), 1)
    }

    /// Every new column's default reproduces what the row already meant, so a migrated edge reads
    /// exactly as it did before: a permanent fact, fully believed, valid since it was written.
    func testMigratedRowsReadBackPermanentAndFullyConfident() throws {
        writeVersionZeroDatabase()
        let store = BrainStore(directory: tempRoot)
        let edges = store.neighbors(of: "Maria")
        XCTAssertEqual(edges.count, 2)
        for edge in edges {
            XCTAssertEqual(edge.state, .permanent)
            XCTAssertEqual(edge.confidence, 1.0, accuracy: 0.0001)
            XCTAssertEqual(edge.observations, 1)
            XCTAssertEqual(edge.distinctSessions, 1)
            XCTAssertNil(edge.supersededAt)
            let validFrom = try XCTUnwrap(edge.validFrom)
            let lastSeen = try XCTUnwrap(edge.lastSeen)
            XCTAssertEqual(validFrom.timeIntervalSince1970,
                           edge.createdAt.timeIntervalSince1970, accuracy: 0.0001,
                           "valid_from is backfilled from created_at")
            XCTAssertEqual(lastSeen.timeIntervalSince1970,
                           edge.createdAt.timeIntervalSince1970, accuracy: 0.0001)
        }
        XCTAssertEqual(edges.first(where: { $0.relation == "lives_in" })?.sentence,
                       "Maria lives in Wellington (from old notes)",
                       "A carried-over edge still reads as a present-tense fact")
    }

    /// The version marker is what stops the work repeating. A second open finds version 1 and does
    /// nothing at all — no statements, no log line.
    func testReopeningRunsNoSecondMigration() {
        writeVersionZeroDatabase()
        var store: BrainStore? = BrainStore(directory: tempRoot)
        store = nil
        XCTAssertEqual(userVersion(), 1)

        let lines = capturingLog {
            var reopened: BrainStore? = BrainStore(directory: tempRoot)
            XCTAssertEqual(reopened?.stats.edges, 2)
            reopened = nil
        }
        XCTAssertFalse(lines.contains { $0.contains("event=migrated") },
                       "A migrated database must not migrate again: \(lines)")
        XCTAssertEqual(userVersion(), 1, "user_version stays 1")
    }

    /// The migration says how many rows it carried — a count, which is all a diagnostic needs.
    func testMigrationIsLogged() {
        writeVersionZeroDatabase()
        let lines = capturingLog {
            var store: BrainStore? = BrainStore(directory: tempRoot)
            _ = store?.stats
            store = nil
        }
        let migrated = lines.filter { $0.contains("store=brain") && $0.contains("event=migrated") }
        XCTAssertEqual(migrated.count, 1, "one migration, logged once: \(lines)")
        XCTAssertTrue(migrated.first?.contains("count=2") == true,
                      "the count is the rows carried: \(migrated)")
    }

    /// A first launch is not a migration. A fresh database is created at the current version, and
    /// says nothing about carrying rows it never had.
    func testFreshDatabaseIsCurrentWithoutAMigrationLine() {
        let lines = capturingLog {
            var store: BrainStore? = BrainStore(directory: tempRoot)
            store?.addEdge(srcKind: "person", srcName: "Alice", relation: "works_at",
                           dstKind: "org", dstName: "Acme")
            store = nil
        }
        XCTAssertEqual(userVersion(), 1)
        XCTAssertFalse(lines.contains { $0.contains("event=migrated") },
                       "Nothing was migrated on a first launch: \(lines)")
    }
}
