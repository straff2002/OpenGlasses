import XCTest
@testable import OpenGlasses

/// Plan KK P3 — the timeline in a request: shown only where coverage says it belongs, in place of
/// the omission note only when nothing that left is missing from it, and never over a gap without
/// the note saying so. Invented conversations from `TimelineFixtures`.
final class TimelineRequestBlockTests: XCTestCase {

    private typealias F = TimelineFixtures
    private typealias B = TimelineRequestBlock

    // MARK: - Fixtures

    /// A reading that kept the last `kept` user turns of `history`, with `omitted` real turns left
    /// out after the floor.
    private func reading(kept: Int, history: Int, omitted: Int? = nil, floor: Date? = nil,
                         clearedAt: Date? = nil) -> TimelineRequestReading {
        TimelineRequestReading(keptUserTurns: kept, historyUserTurns: history, floorDate: floor,
                               omittedUserTurns: omitted ?? max(0, history - kept), clearedAt: clearedAt)
    }

    private func request(_ messages: [TimelineMessage], _ entries: [TimelineEntry],
                         reading: TimelineRequestReading, omittedMessages: Int = 6,
                         answering: String? = nil,
                         cap: Int = TimelineRenderer.defaultTokenCap) -> B.Request {
        let thread = B.Thread(messages: messages, entries: entries, answeringMessageID: answering)
        return B.Request(thread: thread, reading: reading, omittedMessages: omittedMessages, tokenCap: cap)
    }

    private func decide(_ request: B.Request, recall: Bool = false) -> B.Decision {
        B.decide(request, recallOffered: recall, timeZone: F.utc)
    }

    private func note(_ partial: Bool) -> String {
        "[note\(partial ? " partial" : "")]"
    }

    // MARK: - Complete coverage replaces the note

    func testCompleteCoverageReplacesTheNote() throws {
        let messages = F.conversation(6)
        // Kept the last three turns: u0…a2 (positions 0..<6) have left; one entry covers them.
        let entries = [F.entry("e1", messages, 0...5, text: "Arrived; suction read 52 psi.")]
        let decision = decide(request(messages, entries, reading: reading(kept: 3, history: 6)))
        XCTAssertTrue(decision.replacesNote)
        XCTAssertNil(decision.skip)
        XCTAssertEqual(decision.renderedCount, 1)
        let text = try XCTUnwrap(decision.text)
        XCTAssertTrue(text.hasPrefix(TimelineRenderer.label(recallOffered: false)))
        XCTAssertTrue(text.contains("suction read 52 psi"))
        XCTAssertEqual(B.workingContext(decision: decision, note: note), text, "the note is gone")
        XCTAssertEqual(decision.logToken, "replacedNote")
    }

    // MARK: - A gap keeps the note, says so, and the block follows

    /// The open run (a1, u2, a2) is not covered yet: the note stays, says the notes are partial,
    /// and comes first.
    func testAnUncoveredRunKeepsTheNoteAndSaysTheNotesArePartial() throws {
        let messages = F.conversation(6)
        let entries = [F.entry("e1", messages, 0...2)]
        let decision = decide(request(messages, entries, reading: reading(kept: 3, history: 6)))
        XCTAssertFalse(decision.replacesNote)
        XCTAssertTrue(decision.notesArePartial)
        let block = try XCTUnwrap(decision.text)
        XCTAssertEqual(B.workingContext(decision: decision, note: note), "[note partial]\n\n" + block)
        XCTAssertEqual(decision.logToken, "withNote")
    }

    /// P0's outdated answer: the "7 pm" note covered, the move to 7:45 in an uncovered run after
    /// it. The covered chunk must never be shown alone.
    func testACoveredChunkFollowedByAnUncoveredCorrectionIsNeverShownAlone() {
        let messages = F.conversation(8)
        let entries = [F.entry("early", messages, 0...3, text: "Visit booked for 7 pm.")]
        let decision = decide(request(messages, entries, reading: reading(kept: 2, history: 8)))
        XCTAssertNotNil(decision.text)
        XCTAssertFalse(decision.replacesNote)
        let context = B.workingContext(decision: decision, note: note) ?? ""
        XCTAssertTrue(context.hasPrefix("[note partial]"), context)
    }

    /// A hole between two covered runs is a gap as much as the open run is.
    func testAHoleBetweenCoveredRunsKeepsTheNote() {
        let messages = F.conversation(8)
        let entries = [F.entry("e1", messages, 0...3), F.entry("e2", messages, 8...11)]
        let decision = decide(request(messages, entries, reading: reading(kept: 2, history: 8)))
        XCTAssertEqual(decision.renderedCount, 2)
        XCTAssertFalse(decision.replacesNote)
    }

    func testAnEntryTheCapDroppedIsAGap() {
        let messages = F.conversation(6)
        let long = String(repeating: "a", count: 4_000)
        let entries = [F.entry("e1", messages, 0...2, text: long), F.entry("e2", messages, 3...5, text: "Later notes.")]
        let decision = decide(request(messages, entries, reading: reading(kept: 3, history: 6), cap: 400))
        XCTAssertEqual(decision.renderedCount, 1)
        XCTAssertFalse(decision.replacesNote, "the dropped oldest entry leaves its span uncovered")
        XCTAssertLessThanOrEqual(decision.estimatedTokens, 400)
    }

    // MARK: - Only what left the request

    func testAnEntryAboutMessagesStillInTheRequestIsNotShown() throws {
        let messages = F.conversation(6)
        let entries = [F.entry("left", messages, 0...5, text: "What left."),
                       F.entry("live", messages, 6...9, text: "Still in the request.")]
        let decision = decide(request(messages, entries, reading: reading(kept: 3, history: 6)))
        let text = try XCTUnwrap(decision.text)
        XCTAssertTrue(text.contains("What left."))
        XCTAssertFalse(text.contains("Still in the request."), "the same span is never shown twice")
        XCTAssertTrue(decision.replacesNote)
    }

    /// A merged entry that reaches into the request still covers what left: shown, an overlap.
    func testAnEntryStraddlingTheEdgeIsShown() {
        let messages = F.conversation(6)
        let entries = [F.entry("straddle", messages, 0...7)]
        let decision = decide(request(messages, entries, reading: reading(kept: 3, history: 6)))
        XCTAssertEqual(decision.renderedCount, 1)
        XCTAssertTrue(decision.replacesNote)
    }

    func testRedactedEntriesAreNeverShownAndTheirSpanIsNotAGap() throws {
        let messages = F.conversation(6)
        let entries = [F.entry("erased", messages, 0...1).redacting(),
                       F.entry("kept", messages, 2...5, text: "Fan motor swapped.")]
        let decision = decide(request(messages, entries, reading: reading(kept: 3, history: 6)))
        let text = try XCTUnwrap(decision.text)
        XCTAssertEqual(decision.renderedCount, 1)
        XCTAssertTrue(text.contains("Fan motor swapped."))
        XCTAssertTrue(decision.replacesNote, "a cleared span stays covered: the erasure leaves no hole")
    }

    func testOnlyARedactedEntryIsNoBlock() {
        let messages = F.conversation(6)
        let entries = [F.entry("erased", messages, 0...5).redacting()]
        XCTAssertEqual(decide(request(messages, entries, reading: reading(kept: 3, history: 6))).skip,
                       .nothingCovered)
        XCTAssertEqual(B.gate(enabled: true, hipaaMode: false, provider: .anthropic,
                              thread: B.Thread(messages: messages, entries: entries)), .noEntries)
    }

    func testEntriesBeforeTheJobFloorAreNeverShown() throws {
        let messages = F.conversation(8)
        // The job opened with u4 (position 8).
        let entries = [F.entry("previous", messages, 0...7, text: "The previous job."),
                       F.entry("this", messages, 8...11, text: "This job.")]
        let decision = decide(request(messages, entries,
                                      reading: reading(kept: 2, history: 8, omitted: 2, floor: messages[8].timestamp)))
        let text = try XCTUnwrap(decision.text)
        XCTAssertFalse(text.contains("The previous job."))
        XCTAssertTrue(text.contains("This job."))
        XCTAssertTrue(decision.replacesNote, "before the floor is another job, not a gap in this one")
    }

    /// A new topic (or a model switch) emptied the history at minute 8: nothing saved before it is
    /// this conversation, and the last question before the clear is not pulled back in.
    func testNothingBeforeAClearIsShown() throws {
        let messages = F.conversation(8)
        let entries = [F.entry("before", messages, 0...7, text: "Before the new topic."),
                       F.entry("after", messages, 8...11, text: "After it.")]
        let decision = decide(request(messages, entries,
                                      reading: reading(kept: 2, history: 4, clearedAt: F.minutes(7.5))))
        let text = try XCTUnwrap(decision.text)
        XCTAssertFalse(text.contains("Before the new topic."))
        XCTAssertTrue(text.contains("After it."))
        XCTAssertTrue(decision.replacesNote)
    }

    func testTheClearIsNotMovedBackToTheQuestionBeforeIt() {
        let messages = F.conversation(4)
        let reading = reading(kept: 1, history: 1, clearedAt: F.minutes(4.5))
        XCTAssertEqual(reading.timelineFloor(in: messages), F.minutes(4.5))
        let job = TimelineRequestReading(keptUserTurns: 1, historyUserTurns: 1, floorDate: F.minutes(4.5))
        XCTAssertEqual(job.timelineFloor(in: messages), F.minutes(4), "a job floor is moved back to u2")
        let both = TimelineRequestReading(keptUserTurns: 1, historyUserTurns: 1, floorDate: F.minutes(2.5),
                                          clearedAt: F.minutes(5.5))
        XCTAssertEqual(both.timelineFloor(in: messages), F.minutes(5.5), "the later of the two")
    }

    // MARK: - The count guard

    /// The history says four turns left after the floor, but the thread's eligible run holds only
    /// three: one turn that left never reached the thread, so it cannot be in the notes.
    func testMoreTurnsLeftThanTheThreadHoldsIsAGap() {
        let messages = F.conversation(6)
        let entries = [F.entry("e1", messages, 0...5)]
        let decision = decide(request(messages, entries, reading: reading(kept: 3, history: 6, omitted: 4)))
        XCTAssertNotNil(decision.text)
        XCTAssertFalse(decision.replacesNote)
    }

    /// A stale question id names an earlier message: coverage holds it and everything after it
    /// back, but the omitted count still says those turns left, so the note stays.
    func testAStaleQuestionIDCannotHideAGap() {
        let messages = F.conversation(6)
        let entries = [F.entry("e1", messages, 0...1)]
        let decision = decide(request(messages, entries, reading: reading(kept: 3, history: 6),
                                      answering: "u1"))
        XCTAssertFalse(decision.replacesNote)
    }

    func testTheQuestionBeingAnsweredIsHeldBack() {
        let messages = F.conversation(6)
        // The counts say everything left, but u5 is the question being answered.
        let entries = [F.entry("e1", messages, 0...9)]
        let decision = decide(request(messages, entries, reading: reading(kept: 0, history: 5),
                                      answering: "u5"))
        XCTAssertTrue(decision.replacesNote)
    }

    // MARK: - No block

    func testNothingOmittedIsNoBlockAndNoNote() {
        let messages = F.conversation(4)
        let decision = decide(request(messages, [F.entry("e1", messages, 0...3)],
                                      reading: reading(kept: 4, history: 4), omittedMessages: 0))
        XCTAssertEqual(decision.skip, .nothingOmitted)
        XCTAssertNil(B.workingContext(decision: decision, note: { _ in nil }))
    }

    func testNothingCoveredKeepsThePlainNote() {
        let messages = F.conversation(6)
        let decision = decide(request(messages, [], reading: reading(kept: 3, history: 6)))
        XCTAssertEqual(decision.skip, .nothingCovered)
        XCTAssertEqual(B.workingContext(decision: decision, note: note), "[note]")
        XCTAssertEqual(B.workingContext(decision: nil, note: note), "[note]")
    }

    func testTheGateNamesEachRefusalInOrder() {
        let thread = B.Thread(messages: F.conversation(2), entries: [F.entry("e", F.conversation(2), 0...1)])
        XCTAssertEqual(B.gate(enabled: false, hipaaMode: true, provider: .local, thread: nil), .settingOff)
        XCTAssertEqual(B.gate(enabled: true, hipaaMode: true, provider: .local, thread: nil), .hipaaMode)
        XCTAssertEqual(B.gate(enabled: true, hipaaMode: false, provider: .local, thread: thread), .onDeviceModel)
        XCTAssertEqual(B.gate(enabled: true, hipaaMode: false, provider: .appleOnDevice, thread: thread), .onDeviceModel)
        XCTAssertEqual(B.gate(enabled: true, hipaaMode: false, provider: .anthropic, thread: nil), .noThread)
        XCTAssertEqual(B.gate(enabled: true, hipaaMode: false, provider: .chatgpt,
                              thread: B.Thread(messages: F.conversation(2), entries: [])), .noEntries)
        XCTAssertNil(B.gate(enabled: true, hipaaMode: false, provider: .openai, thread: thread))
    }

    // MARK: - The label

    func testTheRecallClauseOnlyWhenBrainCanBeCalled() throws {
        let messages = F.conversation(6)
        let entries = [F.entry("e1", messages, 0...5)]
        let offered = try XCTUnwrap(decide(request(messages, entries, reading: reading(kept: 3, history: 6)),
                                           recall: true).text)
        let withheld = try XCTUnwrap(decide(request(messages, entries, reading: reading(kept: 3, history: 6)),
                                            recall: false).text)
        XCTAssertTrue(offered.contains(TimelineRenderer.recallClause))
        XCTAssertFalse(withheld.contains("brain"))
    }

    // MARK: - Reserving room

    func testTheAllowanceGivesUpTheReserveButNeverMoreThanHalf() {
        XCTAssertEqual(B.historyAllowance(14_000, reserve: 1_200).history, 12_800)
        XCTAssertEqual(B.historyAllowance(14_000, reserve: 1_200).blockCap, 1_200)
        XCTAssertEqual(B.historyAllowance(2_000, reserve: 1_500).history, 1_000)
        XCTAssertEqual(B.historyAllowance(2_000, reserve: 1_500).blockCap, 1_000)
        XCTAssertEqual(B.historyAllowance(14_000, reserve: 0).history, 14_000)
        XCTAssertEqual(B.historyAllowance(14_000, reserve: 0).blockCap, 0)
        XCTAssertEqual(B.historyAllowance(0, reserve: 1_200).history, 0, "trimming off: nothing reserved")
    }

    func testTheReserveIsTheWholeCandidateBlockUpToTheCap() {
        let messages = F.conversation(6)
        let small = [F.entry("e1", messages, 0...5, text: "Short notes.")]
        let reserve = B.reserve(B.Thread(messages: messages, entries: small), floor: nil, timeZone: F.utc)
        let whole = TimelineRenderer.render(entries: small, coverageHasGaps: false, timeZone: F.utc,
                                            recallOffered: true)
        XCTAssertEqual(reserve, whole.estimatedTokens)
        let huge = [F.entry("e1", messages, 0...5, text: String(repeating: "b", count: 20_000))]
        XCTAssertEqual(B.reserve(B.Thread(messages: messages, entries: huge), floor: nil, timeZone: F.utc),
                       TimelineRenderer.defaultTokenCap)
        XCTAssertEqual(B.reserve(B.Thread(messages: messages, entries: []), floor: nil, timeZone: F.utc), 0)
    }

    /// The block shown is a subset of what was reserved for, rendered to the reserve: when the
    /// request needs older entries the whole block's cap had dropped, it still never exceeds the
    /// reserve; it shows fewer, and keeps the note.
    func testTheBlockNeverExceedsWhatWasReserved() {
        let messages = F.conversation(12)
        var entries: [TimelineEntry] = []
        entries.append(F.entry("e1", messages, 0...3, text: String(repeating: "a", count: 2_400)))
        entries.append(F.entry("e2", messages, 4...7, text: String(repeating: "b", count: 2_400)))
        entries.append(F.entry("e3", messages, 8...11, text: String(repeating: "c", count: 1_600)))
        entries.append(F.entry("e4", messages, 12...15, text: String(repeating: "d", count: 1_600)))
        entries.append(F.entry("e5", messages, 16...19, text: String(repeating: "e", count: 1_600)))
        let thread = B.Thread(messages: messages, entries: entries)
        let reserve = B.reserve(thread, floor: nil, timeZone: F.utc)
        // Only e1 and e2 have left.
        let decision = decide(B.Request(thread: thread, reading: reading(kept: 8, history: 12),
                                        omittedMessages: 8, tokenCap: reserve))
        XCTAssertLessThanOrEqual(decision.estimatedTokens, reserve)
    }

    // MARK: - Privacy

    func testTheLogTokenNeverCarriesText() {
        let messages = F.conversation(6)
        let entries = [F.entry("e1", messages, 0...5, text: "Customer Avery Quinn at 12 Example Road.")]
        for kept in 0...6 {
            let decision = decide(request(messages, entries, reading: reading(kept: kept, history: 6)))
            XCTAssertFalse(decision.logToken.contains("Avery"))
            XCTAssertTrue(["replacedNote", "withNote"].contains(decision.logToken)
                          || B.Skip(rawValue: decision.logToken) != nil, decision.logToken)
        }
    }
}
