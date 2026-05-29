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
