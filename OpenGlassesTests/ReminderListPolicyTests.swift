import XCTest
@testable import OpenGlasses

/// The reminder list reaches the model as text, so a title left out of it cannot be read back or
/// completed by name: every reminder has to be reachable.
final class ReminderListPolicyTests: XCTestCase {

    private func titles(_ count: Int) -> [String] {
        (1...count).map { "Item \($0)" }
    }

    func testNoRemindersSaysSo() {
        XCTAssertEqual(ReminderListPolicy.reply([], offset: 0), "No incomplete reminders.")
    }

    func testOneReminderReadsAsSingular() {
        XCTAssertEqual(ReminderListPolicy.reply(["Bagels"], offset: 0), "1 reminder: Bagels.")
    }

    func testAnEleventhReminderIsListedNotCounted() {
        let reply = ReminderListPolicy.reply(titles(11), offset: 0)
        XCTAssertTrue(reply.contains("Item 11"), reply)
        XCTAssertFalse(reply.contains("Plus"), reply)
    }

    func testAFullPageSaysNothingIsLeft() {
        XCTAssertFalse(ReminderListPolicy.reply(titles(ReminderListPolicy.pageSize), offset: 0).contains("Plus"))
    }

    func testPastAPageTheReplyNamesTheNextOffset() {
        let size = ReminderListPolicy.pageSize
        let reply = ReminderListPolicy.reply(titles(size + 3), offset: 0)
        XCTAssertTrue(reply.contains("Item \(size)."), reply)
        XCTAssertFalse(reply.contains("Item \(size + 1)"), reply)
        XCTAssertTrue(reply.hasSuffix("Plus 3 more: list again with offset \(size)."), reply)
    }

    func testTheNextPageReachesTheLastReminder() {
        let size = ReminderListPolicy.pageSize
        let reply = ReminderListPolicy.reply(titles(size + 3), offset: size)
        XCTAssertTrue(reply.hasPrefix("Reminders \(size + 1) to \(size + 3) of \(size + 3): "), reply)
        XCTAssertTrue(reply.hasSuffix("Item \(size + 3)."), reply)
    }

    func testAnOffsetPastTheEndIsAnsweredNotEmpty() {
        XCTAssertEqual(ReminderListPolicy.reply(titles(3), offset: 3), "There are only 3 incomplete reminders.")
    }

    func testANegativeOffsetStartsAtTheTop() {
        XCTAssertEqual(ReminderListPolicy.reply(titles(2), offset: -1), ReminderListPolicy.reply(titles(2), offset: 0))
    }
}
