import XCTest
import SQLite3
@testable import OpenGlasses

/// Plan GG P0 — `memories` gains `origin` and `source_ref`. A row written before they existed reads
/// as `legacyUnknown`; nothing guesses that it was told. New writes carry their origin.
@MainActor
final class SemanticMemoryProvenanceMigrationTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemanticProvenance_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// The schema the previous build wrote: no provenance columns.
    private func writeLegacyDatabase() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("semantic_memory.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in [
            """
            CREATE TABLE memories (id TEXT PRIMARY KEY, key_name TEXT NOT NULL, value TEXT NOT NULL,
                topic TEXT NOT NULL DEFAULT 'general', namespace TEXT NOT NULL, created_at REAL NOT NULL,
                expires_at REAL, embedding BLOB, embedding_version TEXT,
                UNIQUE(key_name, namespace) ON CONFLICT REPLACE)
            """,
            "CREATE TABLE diary (id TEXT PRIMARY KEY, text TEXT NOT NULL, created_at REAL NOT NULL, embedding BLOB, embedding_version TEXT)",
            "INSERT INTO memories (id, key_name, value, topic, namespace, created_at) VALUES ('global:sister city', 'sister city', 'Wellington', 'people', 'global', 1700000000)",
        ] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
    }

    func testLegacyRowsReadAsLegacyUnknown() throws {
        writeLegacyDatabase()
        let store = SemanticMemoryStore(directory: dir)
        let entry = try XCTUnwrap(store.entry(id: "global:sister city"))
        XCTAssertEqual(entry.value, "Wellington", "the row survives the migration")
        XCTAssertEqual(entry.origin, .legacyUnknown)
        XCTAssertNil(entry.sourceRef)
        XCTAssertEqual(SemanticFactSource.fact(for: entry).origin, .legacyUnknown,
                       "the screen never upgrades an unknown origin")
    }

    func testMigrationIsIdempotentAcrossReopens() throws {
        writeLegacyDatabase()
        _ = SemanticMemoryStore(directory: dir)
        let reopened = SemanticMemoryStore(directory: dir)
        XCTAssertEqual(reopened.allEntries().count, 1)
        XCTAssertTrue(reopened.rememberGlobal("tea", value: "earl grey", origin: .toldMe))
    }

    func testNewWritesCarryOriginAndSource() throws {
        let store = SemanticMemoryStore(directory: dir)
        XCTAssertTrue(store.rememberGlobal("tea", value: "earl grey", origin: .toldMe, sourceRef: "thread-1"))
        XCTAssertTrue(store.rememberGlobal("mood", value: "tired on Mondays", origin: .inferred))

        let reopened = SemanticMemoryStore(directory: dir)
        let tea = try XCTUnwrap(reopened.entry(id: "global:tea"))
        XCTAssertEqual(tea.origin, .toldMe)
        XCTAssertEqual(tea.sourceRef, "thread-1")
        XCTAssertEqual(try XCTUnwrap(reopened.entry(id: "global:mood")).origin, .inferred)
    }

    func testReplyTagsTakeTheirOriginFromTheUtterance() throws {
        let store = SemanticMemoryStore(directory: dir)
        _ = store.parseAndExecuteCommands(in: "Noted. [REMEMBER: sister city = Wellington]",
                                          userUtterance: "Remember that my sister lives in Wellington",
                                          threadID: "t-42")
        _ = store.parseAndExecuteCommands(in: "Sounds busy. [REMEMBER: busy day = Tuesday]",
                                          userUtterance: "Tuesday is a busy one", threadID: "t-43")
        XCTAssertEqual(try XCTUnwrap(store.entry(id: "global:sister city")).origin, .toldMe)
        XCTAssertEqual(try XCTUnwrap(store.entry(id: "global:sister city")).sourceRef, "t-42")
        XCTAssertEqual(try XCTUnwrap(store.entry(id: "global:busy day")).origin, .inferred)
    }

    func testOriginStorageRoundTrips() {
        for origin: MemoryOrigin in [.toldMe, .inferred, .fromAddOn("pack.one"), .fromMeeting,
                                     .fromScan, .imported, .legacyUnknown] {
            XCTAssertEqual(MemoryOrigin(storageValue: origin.storageValue), origin)
        }
        XCTAssertEqual(MemoryOrigin(storageValue: "something-else"), .legacyUnknown)
    }
}
