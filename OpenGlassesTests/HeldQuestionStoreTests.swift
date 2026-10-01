import XCTest
@testable import OpenGlasses

/// Plan GE P2 — the question held while nothing on the phone can think.
final class HeldQuestionStoreTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 3_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testOneSlotPerConversationAndTheNewestWins() {
        var store = HeldQuestionStore()
        XCTAssertEqual(store.hold("first", conversationId: "a", now: at(0)), .held)
        XCTAssertEqual(store.hold("second", conversationId: "a", now: at(10)), .replaced)
        XCTAssertEqual(store.take(conversationId: "a", now: at(20)), .fresh("second"))
        XCTAssertEqual(store.take(conversationId: "a", now: at(21)), .none, "taking empties the slot")
    }

    func testConversationsDoNotShareASlot() {
        var store = HeldQuestionStore()
        store.hold("in a", conversationId: "a", now: at(0))
        store.hold("in b", conversationId: "b", now: at(0))
        XCTAssertEqual(store.take(conversationId: "b", now: at(1)), .fresh("in b"))
        XCTAssertTrue(store.isHolding(conversationId: "a"))
    }

    func testThirtyMinuteTimeToLive() {
        XCTAssertEqual(HeldQuestionStore().ttl, 30 * 60)
        var store = HeldQuestionStore()
        store.hold("q", conversationId: "a", now: at(0))
        XCTAssertEqual(store.take(conversationId: "a", now: at(30 * 60 - 1)), .fresh("q"))
        store.hold("q", conversationId: "a", now: at(0))
        XCTAssertEqual(store.take(conversationId: "a", now: at(30 * 60)), .expired)
    }

    func testExpiryCountsWhatWentAndKeepsTheRest() {
        var store = HeldQuestionStore()
        store.hold("old", conversationId: "a", now: at(0))
        store.hold("new", conversationId: "b", now: at(1500))
        XCTAssertEqual(store.expire(now: at(1900)), 1)
        XCTAssertFalse(store.isHolding(conversationId: "a"))
        XCTAssertTrue(store.isHolding(conversationId: "b"))
    }

    /// Never persisted: the store is a plain value with no storage, so a relaunch forgets it.
    func testNeverPersisted() {
        let mirror = Mirror(reflecting: HeldQuestionStore())
        let labels = mirror.children.compactMap(\.label)
        XCTAssertEqual(Set(labels), ["ttl", "slots"], "no file, defaults or keychain handle")
        XCTAssertFalse(UserDefaults.standard.dictionaryRepresentation().keys.contains { $0.lowercased().contains("heldquestion") })
    }

    func testRemoveAllForgetsEverything() {
        var store = HeldQuestionStore()
        store.hold("q", conversationId: "a", now: at(0))
        store.removeAll()
        XCTAssertTrue(store.isEmpty)
    }
}
