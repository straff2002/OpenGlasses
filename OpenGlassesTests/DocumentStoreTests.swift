import SQLite3
import XCTest
@testable import OpenGlasses

@MainActor
final class DocumentStoreTests: XCTestCase {

    private func makeStore() -> DocumentStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DocumentStore(directory: dir)
    }

    private let manual = """
    To reset the thermostat, hold the power button for ten seconds until the screen blinks.
    The unit will then restart and return to factory defaults.
    For Wi-Fi setup, open the companion app and select Add Device from the main menu.
    Battery replacement requires a Phillips screwdriver and two AA cells.
    The warranty covers parts and labour for two years from the date of purchase.
    """

    func testEmptyIngestReturnsNil() async {
        let store = makeStore()
        let ref = await store.ingest(name: "Empty", text: "   \n  ")
        XCTAssertNil(ref)
        XCTAssertTrue(store.list().isEmpty)
    }

    func testIngestStoresDocumentMetadata() async {
        let store = makeStore()
        let ref = await store.ingest(name: "Manual", text: manual, sourceType: "scan")
        XCTAssertNotNil(ref)
        XCTAssertEqual(store.list().count, 1)
        let doc = try? XCTUnwrap(store.list().first)
        XCTAssertEqual(doc?.name, "Manual")
        XCTAssertEqual(doc?.sourceType, "scan")
        XCTAssertGreaterThan(doc?.chunkCount ?? 0, 0)
        XCTAssertEqual(doc?.charCount, manual.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    func testQueryRetrievesRelevantPassage() async throws {
        try XCTSkipUnless(Embedder().isAvailable, "No NLEmbedding model available in this environment")
        let store = makeStore()
        _ = await store.ingest(name: "Manual", text: manual)

        let results = store.query("how do I reset the device", limit: 2)
        XCTAssertFalse(results.isEmpty)
        // The top passage should be the reset instructions, not the warranty line.
        XCTAssertTrue(results[0].text.lowercased().contains("reset"),
                      "Top passage was: \(results[0].text)")
    }

    func testQueryCanScopeToDocumentIds() async throws {
        try XCTSkipUnless(Embedder().isAvailable, "No NLEmbedding model available in this environment")
        let store = makeStore()
        let a = await store.ingest(name: "A", text: manual)
        _ = await store.ingest(name: "B", text: "Completely unrelated cooking recipe about pasta and tomato sauce.")
        let aId = try XCTUnwrap(a?.id)

        let scoped = store.query("reset the device", documentIds: [aId])
        XCTAssertFalse(scoped.isEmpty)
        XCTAssertTrue(scoped.allSatisfy { $0.documentId == aId })
    }

    func testForgetRemovesDocumentAndChunks() async throws {
        try XCTSkipUnless(Embedder().isAvailable, "No NLEmbedding model available in this environment")
        let store = makeStore()
        let ref = await store.ingest(name: "Manual", text: manual)
        let id = try XCTUnwrap(ref?.id)

        store.forget(documentId: id)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertTrue(store.query("reset the device").isEmpty)
    }

    func testClearAll() async {
        let store = makeStore()
        _ = await store.ingest(name: "One", text: manual)
        _ = await store.ingest(name: "Two", text: manual)
        XCTAssertEqual(store.list().count, 2)
        store.clearAll()
        XCTAssertTrue(store.list().isEmpty)
    }

    // MARK: - Kind and figure (Plan EK)

    /// A manual page in the structured grammar: prose under a heading, then a drawing.
    private let structured = """
    Page 7

    ## Priming Condensate Trap

    Pour ten fluid ounces of water into the trap before starting the unit.
    The trap must be primed after any service that empties it.

    Page 8

    <!-- page: diagram -->
    ### Figure 58 — Integrated Control

    W1 LOW STAGE HEAT
    C 24VAXC COMMON
    LGWP1 LOW GWP SENSOR INTERFACE
    """

    func testKindAndFigureRoundTripThroughTheStore() async throws {
        let store = makeStore()
        _ = await store.ingest(name: "Manual", text: structured)

        let drawing = store.passages(containingToken: "24VAXC")
        XCTAssertFalse(drawing.isEmpty)
        XCTAssertTrue(drawing.allSatisfy { $0.kind == .diagram && $0.figure == "Figure 58" && $0.page == 8 },
                      "\(drawing)")

        let prose = store.passages(containingToken: "ounces")
        XCTAssertFalse(prose.isEmpty)
        XCTAssertTrue(prose.allSatisfy { $0.kind == .prose && $0.figure == nil && $0.section == "Priming Condensate Trap" },
                      "\(prose)")
    }

    func testTokenSearchReachesDrawingsAndSemanticSearchDoesNot() async throws {
        try XCTSkipUnless(Embedder().isAvailable, "No NLEmbedding model available in this environment")
        let store = makeStore()
        _ = await store.ingest(name: "Manual", text: structured)

        // A bag of terminal labels embeds to noise; it is reached by the token search instead.
        XCTAssertTrue(store.query("low gwp sensor interface", limit: 8).allSatisfy { $0.kind == .prose })
        XCTAssertFalse(store.query("low gwp sensor interface", limit: 8, kinds: [.prose, .diagram])
            .filter { $0.kind == .diagram }.isEmpty, "the filter is what excludes them, not the corpus")
        XCTAssertTrue(store.passages(containingToken: "LGWP1").contains { $0.kind == .diagram })
        XCTAssertTrue(store.passages(containingToken: "LGWP1", kinds: [.prose]).isEmpty)
    }

    func testAStoreCreatedBeforeTheColumnsExistedStillOpensAndReadsAsProse() throws {
        // A database written by a build from before Plan EK — `doc_chunks` without `kind` or
        // `figure`. Opening it must add the columns and read its rows back as prose with no figure,
        // which is exactly how they were already being treated. No re-index, no data loss.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("documents.sqlite").path

        var legacy: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &legacy), SQLITE_OK)
        for sql in [
            """
            CREATE TABLE documents (id TEXT PRIMARY KEY, name TEXT NOT NULL,
                source_type TEXT NOT NULL DEFAULT 'text', namespace TEXT NOT NULL DEFAULT 'global',
                created_at REAL NOT NULL, chunk_count INTEGER NOT NULL DEFAULT 0,
                char_count INTEGER NOT NULL DEFAULT 0)
            """,
            """
            CREATE TABLE doc_chunks (id TEXT PRIMARY KEY, document_id TEXT NOT NULL,
                chunk_index INTEGER NOT NULL, text TEXT NOT NULL, embedding BLOB,
                page INTEGER, section TEXT, created_at REAL NOT NULL)
            """,
            "INSERT INTO documents VALUES ('d1', 'Old Manual', 'text', 'global', 0, 1, 80)",
            """
            INSERT INTO doc_chunks VALUES ('c1', 'd1', 0,
                'To reset the thermostat, hold the power button for ten seconds.', NULL, 3, 'Resetting', 0)
            """
        ] {
            XCTAssertEqual(sqlite3_exec(legacy, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        sqlite3_close(legacy)

        let store = DocumentStore(directory: dir)
        XCTAssertEqual(store.list().map(\.name), ["Old Manual"])
        let rows = store.passages(containingToken: "thermostat")
        XCTAssertEqual(rows.count, 1, "an old row still reads back")
        XCTAssertEqual(rows.first?.kind, .prose)
        XCTAssertNil(rows.first?.figure)
        XCTAssertEqual(rows.first?.page, 3)
        XCTAssertEqual(rows.first?.section, "Resetting")
    }

    func testPersistenceAcrossReopen() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store1 = DocumentStore(directory: dir)
        _ = await store1.ingest(name: "Manual", text: manual)
        XCTAssertEqual(store1.list().count, 1)

        let store2 = DocumentStore(directory: dir)
        XCTAssertEqual(store2.list().count, 1)
        XCTAssertEqual(store2.list().first?.name, "Manual")
    }
}
