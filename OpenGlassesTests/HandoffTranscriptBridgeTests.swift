import XCTest
@testable import OpenGlasses

/// Plan GE P0 — the conversation across the handoff, both ways.
final class HandoffTranscriptBridgeTests: XCTestCase {

    /// One token per character keeps the arithmetic readable.
    private let perCharacter: (String) -> Int = { $0.count }

    private func turns(_ pairs: [(String, String)]) -> [HandoffTranscriptBridge.Turn] {
        pairs.map { (role: $0.0, content: $0.1) }
    }

    // MARK: - Outbound

    func testEverythingFitsAndOrderIsKept() {
        let history = turns([("user", "aa"), ("assistant", "bb"), ("user", "cc"), ("assistant", "dd")])
        let window = HandoffTranscriptBridge.outboundWindow(history: history, budgetTokens: 100,
                                                            estimate: perCharacter)
        XCTAssertEqual(window.map(\.content), ["aa", "bb", "cc", "dd"])
    }

    func testTheOldestTurnsAreDroppedFirstToFitTheWindow() {
        let history = turns([("user", "1111"), ("assistant", "2222"), ("user", "3333"), ("assistant", "4444")])
        let window = HandoffTranscriptBridge.outboundWindow(history: history, budgetTokens: 9,
                                                            estimate: perCharacter)
        XCTAssertEqual(window.map(\.content), ["3333", "4444"])
    }

    func testTheWindowOpensOnAUserTurn() {
        let history = turns([("user", "111"), ("assistant", "222"), ("user", "333"), ("assistant", "444")])
        // 9 tokens fit the last three turns, but the oldest of them is the assistant's half.
        let window = HandoffTranscriptBridge.outboundWindow(history: history, budgetTokens: 9,
                                                            estimate: perCharacter)
        XCTAssertEqual(window.first?.role, "user")
        XCTAssertEqual(window.map(\.content), ["333", "444"])
    }

    func testAnExistingSummaryRidesInFrontWhenTurnsWereDropped() {
        let summary = "[Earlier conversation context — 8 messages compressed]\nUser said: hi"
        let old = String(repeating: "o", count: 100)
        let history = turns([("user", summary), ("user", old), ("assistant", old),
                             ("user", "new q"), ("assistant", "new a")])
        // Too small for everything; the summary takes at most half, the newest exchange the rest.
        let budget = 2 * summary.count + 10
        let window = HandoffTranscriptBridge.outboundWindow(history: history, budgetTokens: budget,
                                                            estimate: perCharacter)
        XCTAssertEqual(window.map(\.content), [summary, "new q", "new a"],
                       "no model call writes a summary; the existing one is reused")
    }

    func testNoSummaryWhenNothingWasDropped() {
        let summary = "[Conversation summary — 4 earlier messages]\nstuff"
        let history = turns([("user", summary), ("user", "q"), ("assistant", "a")])
        let window = HandoffTranscriptBridge.outboundWindow(history: history, budgetTokens: 1_000,
                                                            estimate: perCharacter)
        XCTAssertEqual(window.map(\.content), ["q", "a"])
    }

    func testTheTurnCapHoldsWhateverTheBudget() {
        let history = (0..<40).map { (role: $0 % 2 == 0 ? "user" : "assistant", content: "t\($0)") }
        let window = HandoffTranscriptBridge.outboundWindow(history: history, budgetTokens: 1_000_000,
                                                            estimate: perCharacter)
        XCTAssertEqual(window.count, HandoffTranscriptBridge.maxOutboundTurns)
        XCTAssertEqual(window.last?.content, "t39")
    }

    func testANonPositiveBudgetCarriesNothing() {
        let history = turns([("user", "q")])
        XCTAssertTrue(HandoffTranscriptBridge.outboundWindow(history: history, budgetTokens: 0).isEmpty)
    }

    // MARK: - Inbound

    func testNoNoteWhenNothingWasAnsweredOnThePhone() {
        XCTAssertNil(HandoffTranscriptBridge.inboundNote([]))
    }

    func testTheNoteIsOneLineNamingTheMarkedAnswers() throws {
        let note = try XCTUnwrap(HandoffTranscriptBridge.inboundNote([
            .init(question: "what's 15% of 80", answer: "12"),
            .init(question: "when does the ferry leave", answer: "at 3"),
        ]))
        XCTAssertFalse(note.contains("\n"), "one line")
        XCTAssertTrue(note.contains("2 answers"))
        XCTAssertTrue(note.contains("smaller on-device model"))
        XCTAssertTrue(note.contains("\u{201C}what's 15% of 80\u{201D}"))
        XCTAssertTrue(note.contains("\u{201C}when does the ferry leave\u{201D}"))
    }

    func testTheNoteQuotesTheLastThreeAndCountsTheRest() throws {
        let answers = (1...5).map { HandoffTranscriptBridge.OnDeviceAnswer(question: "q\($0)", answer: "a") }
        let note = try XCTUnwrap(HandoffTranscriptBridge.inboundNote(answers))
        XCTAssertTrue(note.contains("5 answers"))
        XCTAssertFalse(note.contains("\u{201C}q2\u{201D}"))
        XCTAssertTrue(note.contains("\u{201C}q5\u{201D}"))
        XCTAssertTrue(note.contains("and 2 more"))
    }

    func testLongQuestionsAreClipped() throws {
        let long = String(repeating: "word ", count: 40)
        let note = try XCTUnwrap(HandoffTranscriptBridge.inboundNote([.init(question: long, answer: "x")]))
        XCTAssertTrue(note.contains("\u{2026}"))
        XCTAssertLessThan(note.count, 400)
    }

    // MARK: - Marking in the conversation store

    func testAnsweredOnDeviceMarkingRoundTripsAndOldFilesStillDecode() throws {
        let marked = ConversationMessage(role: "assistant", content: "12", answeredOnDevice: true)
        let plain = ConversationMessage(role: "assistant", content: "12")
        XCTAssertTrue(marked.isAnsweredOnDevice)
        XCTAssertFalse(plain.isAnsweredOnDevice)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ConversationMessage.self, from: encoder.encode(marked))
        XCTAssertTrue(decoded.isAnsweredOnDevice)
        // An ordinary reply stores nothing extra.
        let plainJSON = String(decoding: try encoder.encode(plain), as: UTF8.self)
        XCTAssertFalse(plainJSON.contains("answeredOnDevice"))

        // A message saved before the field existed.
        let legacy = #"{"id":"x","role":"assistant","content":"hi","imageAttached":false,"timestamp":0}"#
        let old = try decoder.decode(ConversationMessage.self, from: Data(legacy.utf8))
        XCTAssertFalse(old.isAnsweredOnDevice)
    }
}
