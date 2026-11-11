import XCTest
@testable import OpenGlasses

/// Plan KT P0 — the meeting summary's action items as a value, the same extraction the tool's text
/// reports, so a card never parses prose.
final class MeetingSummaryFactsTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testFactsCarryTheItemsAndTheSpanOfTheConversation() throws {
        let entries: [(text: String, timestamp: Date)] = [
            (text: "Morning everyone, thanks for coming in.", timestamp: start),
            (text: "Ana will send the revised plan by the end of the week.", timestamp: start.addingTimeInterval(600)),
            (text: "We agreed to keep the current supplier.", timestamp: start.addingTimeInterval(1200)),
            (text: "Lee needs to book the room for the next session.", timestamp: start.addingTimeInterval(1800)),
        ]
        let saved = start.addingTimeInterval(2400)
        let facts = try XCTUnwrap(MeetingSummaryTool.facts(from: entries, savedAt: saved))
        XCTAssertEqual(facts.actionItems, ["Ana will send the revised plan by the end of the week",
                                           "Lee needs to book the room for the next session"])
        XCTAssertEqual(facts.decisions, ["We agreed to keep the current supplier."])
        XCTAssertEqual(facts.startedAt, start)
        XCTAssertEqual(facts.endedAt, start.addingTimeInterval(1800))
        XCTAssertEqual(facts.savedAt, saved)
        XCTAssertTrue(facts.transcript.contains("current supplier"))
    }

    func testNoConversationNoFacts() {
        XCTAssertNil(MeetingSummaryTool.facts(from: [], savedAt: start))
    }

    func testTheValueMatchesTheToolsOwnExtraction() {
        let texts = ["Please check the figures before Friday.", "Nothing much else."]
        XCTAssertEqual(MeetingSummaryTool.extractActionItems(from: texts), ["Please check the figures before Friday"])
        let facts = MeetingSummaryTool.facts(from: texts.map { (text: $0, timestamp: start) }, savedAt: start)
        XCTAssertEqual(facts?.actionItems, MeetingSummaryTool.extractActionItems(from: texts))
    }
}
