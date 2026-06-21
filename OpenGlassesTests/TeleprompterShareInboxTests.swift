import XCTest
@testable import OpenGlasses

/// Headless tests for the Share Extension hand-off (Teleprompter PR B): the app-group
/// inbox round-trip and the store draining it into saved scripts. Uses the inbox's
/// `testContainerURL` seam so no real app-group container is touched.
@MainActor
final class TeleprompterShareInboxTests: XCTestCase {

    private var container: URL!

    override func setUp() {
        super.setUp()
        container = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        SharedTeleprompterInbox.testContainerURL = container
    }

    override func tearDown() {
        SharedTeleprompterInbox.testContainerURL = nil
        try? FileManager.default.removeItem(at: container)
        super.tearDown()
    }

    func testInboxAppendAndDrainRoundTrips() {
        SharedTeleprompterInbox.append(title: "Keynote", text: "the opening line")
        SharedTeleprompterInbox.append(title: "", text: "second script")

        let drained = SharedTeleprompterInbox.drain()
        XCTAssertEqual(drained.map(\.title), ["Keynote", ""])
        XCTAssertEqual(drained.map(\.text), ["the opening line", "second script"])

        // Draining clears the inbox.
        XCTAssertTrue(SharedTeleprompterInbox.drain().isEmpty)
    }

    func testInboxIgnoresEmptyText() {
        SharedTeleprompterInbox.append(title: "x", text: "   \n  ")
        XCTAssertTrue(SharedTeleprompterInbox.drain().isEmpty)
    }

    func testStoreImportsPendingSharesNewestFirst() {
        // A store over a separate temp directory (its own JSON file, not the inbox).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = TeleprompterScriptStore(directory: dir)
        XCTAssertTrue(store.scripts.isEmpty)

        SharedTeleprompterInbox.append(title: "First", text: "one")
        SharedTeleprompterInbox.append(title: "", text: "Derived title\nbody")

        let count = store.importPendingShares()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.scripts.map(\.title), ["Derived title", "First"])  // newest first; empty title derived
        XCTAssertTrue(SharedTeleprompterInbox.drain().isEmpty)                   // inbox consumed
    }
}
