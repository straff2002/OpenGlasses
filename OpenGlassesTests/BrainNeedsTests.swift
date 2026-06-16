import XCTest
@testable import OpenGlasses

/// Tests for the BrainStore needs/follow-ups feature — recording what a person wants / you owe them,
/// listing open follow-ups, resolving them, and their lifecycle through persistence + forget.
@MainActor
final class BrainNeedsTests: XCTestCase {

    private var tempRoot: URL!
    private var store: BrainStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainNeedsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = BrainStore(directory: tempRoot)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testAddNeedAndList() {
        store.addNeed(person: "Bob", text: "wants a copy of the deck")
        let needs = store.needs(for: "Bob")
        XCTAssertEqual(needs.count, 1)
        XCTAssertEqual(needs.first?.text, "wants a copy of the deck")
        XCTAssertTrue(needs.first?.isOpen ?? false)
    }

    func testAddNeedUpsertsPersonEntity() {
        store.addNeed(person: "Dana", text: "intro to a designer")
        // The person becomes a brain entity so the dossier links up.
        XCTAssertTrue(store.entityNames(mentionedIn: "met Dana today", kind: "person").contains("Dana"))
    }

    func testAddNeedRejectsEmptyText() {
        store.addNeed(person: "Bob", text: "   ")
        XCTAssertTrue(store.needs(for: "Bob").isEmpty)
    }

    func testOpenOnlyHidesResolved() {
        let id = store.addNeed(person: "Bob", text: "send invoice")
        store.addNeed(person: "Bob", text: "book lunch")
        store.resolveNeed(id: id)
        XCTAssertEqual(store.needs(for: "Bob").count, 2)                 // all
        let open = store.needs(for: "Bob", openOnly: true)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.text, "book lunch")
    }

    func testResolveNeedById() {
        let id = store.addNeed(person: "Bob", text: "x")
        store.resolveNeed(id: id)
        XCTAssertFalse(store.needs(for: "Bob").first?.isOpen ?? true)
    }

    func testResolveNeedsForPersonMatching() {
        store.addNeed(person: "Bob", text: "wants the deck")
        store.addNeed(person: "Bob", text: "wants an intro")
        let closed = store.resolveNeeds(for: "Bob", matching: "deck")
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(store.needs(for: "Bob", openOnly: true).first?.text, "wants an intro")
    }

    func testResolveNeedsForPersonAll() {
        store.addNeed(person: "Bob", text: "a")
        store.addNeed(person: "Bob", text: "b")
        XCTAssertEqual(store.resolveNeeds(for: "Bob"), 2)               // matching nil → all open
        XCTAssertTrue(store.needs(for: "Bob", openOnly: true).isEmpty)
    }

    func testNeedsFilterByPersonCaseInsensitive() {
        store.addNeed(person: "Bob", text: "for bob")
        store.addNeed(person: "Alice", text: "for alice")
        XCTAssertEqual(store.needs(for: "bob").count, 1)
        XCTAssertEqual(store.needs(for: "BOB").first?.text, "for bob")
        XCTAssertEqual(store.needs().count, 2)                          // all people
    }

    func testForgetDeletesNeeds() {
        store.addNeed(person: "Bob", text: "x")
        store.forget(entityName: "Bob")
        XCTAssertTrue(store.needs(for: "Bob").isEmpty)
    }

    func testStatsCountsOpenNeedsOnly() {
        let id = store.addNeed(person: "Bob", text: "a")
        store.addNeed(person: "Alice", text: "b")
        store.resolveNeed(id: id)
        XCTAssertEqual(store.stats.openNeeds, 1)
    }

    func testNeedsPersistAcrossReopen() {
        store.addNeed(person: "Bob", text: "persisted follow-up")
        // Reopen the same database file.
        let reopened = BrainStore(directory: tempRoot)
        XCTAssertEqual(reopened.needs(for: "Bob").first?.text, "persisted follow-up")
    }
}
