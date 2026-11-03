import XCTest
@testable import OpenGlasses

/// Plan KK P1 — which saved messages have left the request, what covers them, and the next chunk.
/// The rule every case comes back to: a gap is the defect, an overlap only wastes tokens.
final class TimelineCoverageTests: XCTestCase {

    private typealias F = TimelineFixtures

    // MARK: - The eligible range

    func testMessagesBeforeTheKeptUserTurnsAreEligible() {
        let messages = F.conversation(10)
        let result = TimelineCoverage.compute(messages: messages, keptUserTurns: 3, entries: [])
        XCTAssertEqual(result.eligible, 0..<14, "u7 is the third user turn from the end")
        XCTAssertEqual(result.gaps, [0..<14])
        XCTAssertEqual(result.uncoveredTokens, 14_000)
        XCTAssertTrue(result.hasGaps)
    }

    func testNothingIsEligibleWhenTheRequestKeptMoreTurnsThanTheThreadHolds() {
        let result = TimelineCoverage.compute(messages: F.conversation(3), keptUserTurns: 4, entries: [])
        XCTAssertTrue(result.eligible.isEmpty)
        XCTAssertTrue(result.gaps.isEmpty)
        XCTAssertNil(result.nextChunk)
    }

    func testTheTurnBeingAnsweredIsNeverEligible() {
        // A history count far larger than the thread's would otherwise make the whole thread
        // eligible, the live turn included.
        let result = TimelineCoverage.compute(messages: F.conversation(5), keptUserTurns: 1,
                                              historyUserTurns: 100, answeringMessageID: "u4", entries: [])
        XCTAssertEqual(result.eligible, 0..<8, "u4, the turn being answered, stays out")
    }

    /// Three turns never reached the thread, and the request kept only those: every saved message
    /// has left. The last saved user message is not the turn being answered, so it is not held
    /// back — holding it back would leave a9 uncovered while `hasGaps` said nothing was missing.
    func testUnsavedTurnsDoNotProtectTheLastSavedOne() {
        let result = TimelineCoverage.compute(messages: F.conversation(10), keptUserTurns: 3,
                                              historyUserTurns: 13, entries: [])
        XCTAssertEqual(result.eligible, 0..<20)
    }

    /// The request kept more user turns than the thread holds, yet the history holds more still:
    /// the head reading finds the first four saved exchanges gone.
    func testKeepingMoreThanTheThreadHoldsStillReadsFromTheHead() {
        let result = TimelineCoverage.compute(messages: F.conversation(5), keptUserTurns: 6,
                                              historyUserTurns: 10, entries: [])
        XCTAssertEqual(result.eligible, 0..<8)
        XCTAssertTrue(result.hasGaps)
    }

    func testOnlyUserAndAssistantMessagesCount() {
        var messages = F.conversation(4)
        messages.insert(TimelineMessage(id: "s0", role: "system", timestamp: F.minutes(0.5),
                                        estimatedTokens: 9_999), at: 1)
        let result = TimelineCoverage.compute(messages: messages, keptUserTurns: 1, entries: [])
        XCTAssertEqual(result.eligible, 0..<6, "the system line is not a position at all")
        XCTAssertEqual(result.uncoveredTokens, 6_000, "nor does it weigh anything")
    }

    func testReduceKeepsTheConversationAndSizesItLikeTheRequestBudget() {
        let messages = [ConversationMessage(role: "user", content: String(repeating: "x", count: 400)),
                        ConversationMessage(role: "system", content: "[Prior conversation context]"),
                        ConversationMessage(role: "assistant", content: "ok")]
        let reduced = TimelineMessage.reduce(messages)
        XCTAssertEqual(reduced.map(\.role), ["user", "assistant"])
        XCTAssertEqual(reduced.map(\.estimatedTokens), [100, 50], "text/4 with the 50-token floor")
        XCTAssertEqual(reduced.map(\.id), [messages[0].id, messages[2].id])
    }

    // MARK: - Counting from the tail when it is wrong

    /// A resumed thread whose history leads with the injected `[Prior conversation context]`
    /// message holds one more user turn than the thread. The head reading then says one exchange
    /// more has left than really has: an overlap, which is allowed.
    func testReplayWithAnInjectedSummaryOverlapsRatherThanGaps() {
        let messages = F.conversation(10)
        let result = TimelineCoverage.compute(messages: messages, keptUserTurns: 3,
                                              historyUserTurns: 11, entries: [])
        XCTAssertGreaterThanOrEqual(result.eligible.upperBound, 14, "everything that left is eligible")
        XCTAssertEqual(result.eligible, 0..<16, "u7/a7 is in the request and eligible too: overlap")
    }

    /// The history's newest turn never reached the saved thread. Counting K from the thread's
    /// tail then calls one saved exchange live that the request has dropped — a gap. Reading from
    /// the head as well closes it.
    func testATurnThatNeverSavedDoesNotOpenAGap() {
        let messages = F.conversation(10)
        let tailOnly = TimelineCoverage.compute(messages: messages, keptUserTurns: 3, entries: [])
        XCTAssertEqual(tailOnly.eligible, 0..<14, "the tail alone leaves u8 out")
        let withHistory = TimelineCoverage.compute(messages: messages, keptUserTurns: 3,
                                                   historyUserTurns: 11, entries: [])
        XCTAssertEqual(withHistory.eligible, 0..<16,
                       "the request kept u8, u9 and the unsaved turn: u7 and a7 have left")
    }

    /// A legacy compaction shortened the history's head, so it holds fewer user turns than the
    /// thread. The head reading would cover less; the tail reading wins.
    func testACompactedHistoryFallsBackToTheTail() {
        let result = TimelineCoverage.compute(messages: F.conversation(10), keptUserTurns: 3,
                                              historyUserTurns: 5, entries: [])
        XCTAssertEqual(result.eligible, 0..<14)
    }

    // MARK: - Floors

    func testNothingBeforeTheFloorIsEligible() throws {
        let messages = F.conversation(10)
        let result = TimelineCoverage.compute(messages: messages, keptUserTurns: 2,
                                              floor: messages[8].timestamp, entries: [])
        XCTAssertEqual(result.eligible, 8..<16)
        XCTAssertEqual(result.nextChunk?.range.lowerBound, 8, "a chunk never starts before the floor")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.nextChunk).startedAt, messages[8].timestamp)
    }

    func testAnEntryThatStartsBeforeTheFloorCoversNothing() {
        let messages = F.conversation(10)
        // Written before the job began, it mixes both sides of the floor and is never rendered.
        let spanning = F.entry("e1", messages, 0...11)
        let result = TimelineCoverage.compute(messages: messages, keptUserTurns: 2,
                                              floor: messages[8].timestamp, entries: [spanning])
        XCTAssertTrue(result.covered.isEmpty)
        XCTAssertEqual(result.gaps, [8..<16])
    }

    func testAFloorAfterEveryMessageLeavesNothingEligible() {
        let result = TimelineCoverage.compute(messages: F.conversation(4), keptUserTurns: 1,
                                              floor: F.minutes(999), entries: [])
        XCTAssertTrue(result.eligible.isEmpty)
        XCTAssertNil(result.nextChunk)
    }

    // MARK: - Entries

    func testCoveredMessagesAreSkippedAndTheNextChunkStartsAfterThem() {
        let messages = F.conversation(12)
        let result = TimelineCoverage.compute(messages: messages, keptUserTurns: 3,
                                              entries: [F.entry("e1", messages, 0...7)])
        XCTAssertEqual(result.covered, [0..<8])
        XCTAssertEqual(result.gaps, [8..<18])
        XCTAssertEqual(result.uncoveredTokens, 10_000)
        XCTAssertEqual(result.nextChunk?.range, 8..<16)
        XCTAssertEqual(result.nextChunk?.firstMessageID, "u4")
        XCTAssertEqual(result.nextChunk?.lastMessageID, "a7")
    }

    func testOverlappingEntriesCoverTheirUnion() {
        let messages = F.conversation(8)
        let result = TimelineCoverage.compute(messages: messages, keptUserTurns: 1,
                                              entries: [F.entry("e1", messages, 0...5),
                                                        F.entry("e2", messages, 4...13)])
        XCTAssertEqual(result.covered, [0..<14])
        XCTAssertFalse(result.hasGaps)
        XCTAssertNil(result.nextChunk)
    }

    func testAnEntryWhoseMessagesAreGoneCoversNothing() {
        let messages = F.conversation(6)
        let stale = TimelineEntry(id: "e1", firstMessageID: "gone-1", lastMessageID: "gone-2",
                                  startedAt: F.start, endedAt: F.start, tier: .chunk, text: "notes")
        let backwards = TimelineEntry(id: "e2", firstMessageID: "a3", lastMessageID: "u1",
                                      startedAt: F.start, endedAt: F.start, tier: .chunk, text: "notes")
        let result = TimelineCoverage.compute(messages: messages, keptUserTurns: 1,
                                              entries: [stale, backwards])
        XCTAssertTrue(result.covered.isEmpty)
        XCTAssertEqual(result.gaps, [0..<10])
    }

    func testAnEntryReachingIntoTheLiveTurnsCoversOnlyWhatLeft() {
        let messages = F.conversation(6)
        let result = TimelineCoverage.compute(messages: messages, keptUserTurns: 2,
                                              entries: [F.entry("e1", messages, 0...11)])
        XCTAssertEqual(result.covered, [0..<8], "clipped to the eligible range")
        XCTAssertFalse(result.hasGaps)
    }

    // MARK: - The next chunk

    func testAnOpenRunBelowTheMinimumWaits() {
        let result = TimelineCoverage.compute(messages: F.conversation(4, tokens: 500),
                                              keptUserTurns: 1, entries: [])
        XCTAssertEqual(result.uncoveredTokens, 3_000)
        XCTAssertNil(result.nextChunk, "3k has left; a pass waits for about 5k")
        XCTAssertTrue(result.hasGaps, "waiting is still a gap the omission note owns up to")
    }

    func testTheChunkIsCutOnAMessageBoundaryAtTheMaximum() {
        let result = TimelineCoverage.compute(messages: F.conversation(10, tokens: 1_500),
                                              keptUserTurns: 1, entries: [])
        let chunk = result.nextChunk
        XCTAssertEqual(chunk?.range, 0..<5, "a sixth message would pass 8,000")
        XCTAssertEqual(chunk?.estimatedTokens, 7_500)
        XCTAssertEqual(chunk?.messageIDs, ["u0", "a0", "u1", "a1", "u2"])
        XCTAssertEqual(chunk?.startedAt, F.minutes(0))
        XCTAssertEqual(chunk?.endedAt, F.minutes(4))
    }

    func testASingleOversizedMessageIsAChunkOnItsOwn() {
        var messages = F.conversation(6)
        messages[0] = TimelineMessage(id: "u0", role: "user", timestamp: F.start, estimatedTokens: 9_000)
        let result = TimelineCoverage.compute(messages: messages, keptUserTurns: 1, entries: [])
        XCTAssertEqual(result.nextChunk?.range, 0..<1)
    }

    /// Two large messages that cannot share a chunk: the first goes alone, under the minimum,
    /// because waiting for the run to grow would never make it fit.
    func testAChunkCutShortByTheMaximumIsNotHeldBackByTheMinimum() {
        var messages = F.conversation(4)
        messages[0] = TimelineMessage(id: "u0", role: "user", timestamp: F.start, estimatedTokens: 3_000)
        messages[1] = TimelineMessage(id: "a0", role: "assistant", timestamp: F.minutes(1),
                                      estimatedTokens: 6_000)
        let result = TimelineCoverage.compute(messages: messages, keptUserTurns: 1, entries: [])
        XCTAssertEqual(result.nextChunk?.range, 0..<1)
        XCTAssertEqual(result.nextChunk?.estimatedTokens, 3_000)
    }

    /// An erasure or a refused summary can leave a hole between entries. It can never grow, so it
    /// is summarised whatever its size rather than blocking every chunk after it.
    func testAClosedHoleIsReturnedWhateverItsSize() {
        let messages = F.conversation(12)
        let result = TimelineCoverage.compute(messages: messages, keptUserTurns: 3,
                                              entries: [F.entry("e1", messages, 0...3),
                                                        F.entry("e2", messages, 6...13)])
        XCTAssertEqual(result.gaps, [4..<6, 14..<18])
        XCTAssertEqual(result.nextChunk?.range, 4..<6, "2k, under the minimum, and still next")
    }
}
