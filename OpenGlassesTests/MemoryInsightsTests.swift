import XCTest
@testable import OpenGlasses

/// Headless tests for Memory & Recall Phase 4 — `InsightsService` event-mapping and recap
/// formatting. The aggregation itself is covered by `MemoryRecallCoreTests`; here we check the
/// conversation-history → events mapping (pure) and the spoken recap text.
@MainActor
final class MemoryInsightsTests: XCTestCase {

    private func thread(_ messages: [(String, String)]) -> ConversationThread {
        var t = ConversationThread(mode: "direct", title: "T")
        t.messages = messages.map { ConversationMessage(role: $0.0, content: $0.1) }
        return t
    }

    private func thread(withTools messages: [(String, String, [String])]) -> ConversationThread {
        var t = ConversationThread(mode: "direct", title: "T")
        t.messages = messages.map { ConversationMessage(role: $0.0, content: $0.1, toolNames: $0.2) }
        return t
    }

    func testBuildEventsCarriesThePersistedTools() {
        let events = InsightsService.buildEvents(from: [thread(withTools: [
            ("user", "what is on today", []),
            ("assistant", "Two events", ["calendar"]),
        ])])
        XCTAssertEqual(events.map(\.toolNames), [[], ["calendar"]])
    }

    func testReportFromBuiltEventsSurfacesPersistedTools() {
        let threads = [thread(withTools: [
            ("user", "what is on today", []),
            ("assistant", "Two events", ["calendar"]),
            ("user", "and tomorrow", []),
            ("assistant", "One event", ["calendar", "get_weather"]),
        ])]
        let events = InsightsService.buildEvents(from: threads)
        let report = InsightsAggregator.aggregate(events, since: Date().addingTimeInterval(-3600), now: Date())
        XCTAssertEqual(report.topTools.first?.name, "calendar")
        XCTAssertEqual(report.topTools.first?.count, 2)
    }

    func testLegacyMessageWithoutToolNamesStillDecodes() throws {
        let data = Data(#"{"id":"legacy","role":"assistant","content":"ok","imageAttached":false,"timestamp":0}"#.utf8)
        let message = try JSONDecoder().decode(ConversationMessage.self, from: data)
        XCTAssertNil(message.toolNames)
        XCTAssertEqual(message.content, "ok")
    }

    func testToolFreeReplyStoresNoToolList() throws {
        let message = ConversationMessage(role: "assistant", content: "ok")
        XCTAssertNil(message.toolNames, "nil, not [], so the saved file only grows for turns that used tools")
        let json = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        XCTAssertFalse(json.contains("toolNames"))
    }

    func testBuildEventsMapsEveryMessage() {
        let threads = [
            thread([("user", "tell me about the museum app"), ("assistant", "sure")]),
            thread([("user", "remind me about the museum launch")]),
        ]
        let events = InsightsService.buildEvents(from: threads)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.filter { $0.role == "user" }.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.toolNames.isEmpty })
        XCTAssertEqual(events.first?.text, "tell me about the museum app")
    }

    func testReportFromBuiltEventsSurfacesTopics() {
        let threads = [thread([("user", "the museum proposal"), ("user", "museum budget")])]
        let events = InsightsService.buildEvents(from: threads)
        let report = InsightsAggregator.aggregate(events, since: Date().addingTimeInterval(-3600), now: Date())
        XCTAssertEqual(report.userTurns, 2)
        XCTAssertEqual(report.topTopics.first?.name, "museum")
    }

    func testRecapTextReadsNaturally() {
        let report = InsightsReport(
            windowStart: Date(), windowEnd: Date(), totalTurns: 8, userTurns: 4,
            topTools: [.init(name: "reminder", count: 3)],
            topTopics: [.init(name: "museum", count: 4), .init(name: "budget", count: 2)],
            summary: "x"
        )
        let recap = InsightsService.shared.recapText(report, days: 7)
        XCTAssertTrue(recap.contains("4 exchanges"))
        XCTAssertTrue(recap.contains("museum"))
        XCTAssertTrue(recap.contains("reminder"))
    }

    func testRecapTextEmpty() {
        let empty = InsightsReport(windowStart: Date(), windowEnd: Date(), totalTurns: 0,
                                   userTurns: 0, topTools: [], topTopics: [], summary: "")
        XCTAssertTrue(InsightsService.shared.recapText(empty, days: 7).lowercased().contains("nothing to report"))
    }
}
