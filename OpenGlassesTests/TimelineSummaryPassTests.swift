import XCTest
@testable import OpenGlasses

/// Plan KK P2 — the summary pass against a real store in a temp directory and a fake model. The
/// conversation is invented; message sizes are set by length (the estimate is a quarter of the
/// characters), so the chunk arithmetic is the same as on the phone.
@MainActor
final class TimelineSummaryPassTests: XCTestCase {

    private var directory: URL!
    private var store: ConversationStore!
    private var calls: [TimelineSummaryPrompt.Request] = []
    /// What the fake model answers next; the default writes a short plain note.
    private var answer: (TimelineSummaryPrompt.Request) throws -> TimelineSummaryCompletion = { _ in
        TimelineSummaryCompletion(text: "- Notes about this part.", finishedNormally: true)
    }
    /// Runs inside the model call, while the pass is waiting on it.
    private var beforeAnswering: (() async -> Void)?

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kk-pass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        store = ConversationStore(directory: directory)
        calls = []
        beforeAnswering = nil
    }

    override func tearDown() async throws {
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        try await super.tearDown()
    }

    private func makePass() -> TimelineSummaryPass {
        TimelineSummaryPass(store: store, summarise: { [unowned self] request in
            self.calls.append(request)
            await self.beforeAnswering?()
            return try self.answer(request)
        }, timeZone: { TimelineFixtures.utc })
    }

    private let settings = TimelineSummaryPass.Settings(enabled: true, hipaaMode: false,
                                                        provider: .anthropic, atSpendCap: false)

    /// A message of about `tokens` estimated tokens.
    private func text(_ label: String, tokens: Int) -> String {
        label + " " + String(repeating: "x", count: max(0, tokens * 4 - label.count - 1))
    }

    /// `exchanges` saved user/assistant pairs; returns the user message ids, oldest first.
    @discardableResult
    private func seed(_ exchanges: Int, tokens: Int = 200) throws -> (thread: String, users: [String]) {
        let thread = store.startThread(mode: "direct")
        var users: [String] = []
        for turn in 0..<exchanges {
            users.append(try XCTUnwrap(store.appendMessage(role: "user", content: text("question \(turn)", tokens: tokens))))
            store.appendMessage(role: "assistant", content: text("answer \(turn)", tokens: tokens))
        }
        return (thread.id, users)
    }

    private func turn(_ thread: String, answering: String?, kept: Int, history: Int,
                      floor: Date? = nil) -> TimelineSummaryPass.Turn {
        .init(threadID: thread, answeringMessageID: answering,
              reading: TimelineRequestReading(keptUserTurns: kept, historyUserTurns: history, floorDate: floor))
    }

    private func timeline(_ thread: String) -> [TimelineEntry] {
        store.threads.first { $0.id == thread }?.timeline ?? []
    }

    private func ids(_ thread: String) -> [String] {
        store.threads.first { $0.id == thread }?.messages.map(\.id) ?? []
    }

    // MARK: - Coverage

    /// P0's main finding: the newest omitted run is covered after the reply, however small.
    func testTheOpenRunIsCoveredAtOnceWhateverItsSize() async throws {
        let (thread, users) = try seed(5)
        let report = await makePass().run(turn(thread, answering: users[4], kept: 2, history: 5),
                                          settings: settings)
        XCTAssertEqual(report, .ran(summarised: 1, merged: 0, stopped: nil))
        let entries = timeline(thread)
        XCTAssertEqual(entries.count, 1)
        let messages = ids(thread)
        XCTAssertEqual(entries.first?.firstMessageID, messages[0])
        XCTAssertEqual(entries.first?.lastMessageID, messages[5], "up to the kept turns, about 1,200 tokens")
        XCTAssertEqual(entries.first?.tier, .chunk)

        let again = await makePass().run(turn(thread, answering: users[4], kept: 2, history: 5),
                                         settings: settings)
        XCTAssertEqual(again, .skipped(.nothingEligible))
        XCTAssertEqual(calls.count, 1, "covered is covered")
    }

    func testTheTurnBeingAnsweredIsNeverSummarised() async throws {
        let (thread, users) = try seed(3)
        // The request says it kept nothing (a count can be wrong), but the answered turn was in it.
        await makePass().run(turn(thread, answering: users[2], kept: 0, history: 3), settings: settings)
        XCTAssertEqual(timeline(thread).first?.lastMessageID, ids(thread)[3])
    }

    func testAtMostThreeChunksPerPassAndTheRestOnTheNext() async throws {
        // 20 exchanges of 2,000-token messages: about 4 messages per 8k chunk.
        let (thread, users) = try seed(20, tokens: 2_000)
        let pass = makePass()
        let first = await pass.run(turn(thread, answering: users[19], kept: 1, history: 20), settings: settings)
        XCTAssertEqual(first, .ran(summarised: 3, merged: 0, stopped: nil))
        XCTAssertEqual(timeline(thread).count, 3)
        XCTAssertTrue(calls.allSatisfy { $0.tier == .chunk })

        // Six chunks now wait, so the same pass merges the oldest four.
        let second = await pass.run(turn(thread, answering: users[19], kept: 1, history: 20), settings: settings)
        XCTAssertEqual(second, .ran(summarised: 3, merged: 1, stopped: nil))
        let messages = ids(thread)
        let entries = timeline(thread)
        XCTAssertEqual(entries.map(\.tier), [.merged, .chunk, .chunk])
        XCTAssertEqual(entries.map(\.firstMessageID), [0, 16, 20].map { messages[$0] },
                       "in order, each running on from the last")
        XCTAssertEqual(entries.first?.lastMessageID, messages[15])
    }

    func testMessagesBeforeTheJobFloorAreLeftOut() async throws {
        let (thread, users) = try seed(6)
        let saved = try XCTUnwrap(store.threads.first { $0.id == thread }).messages
        // The job opened with question 2. (Moving a later turn-start back to that question is
        // `effectiveFloor`'s, tested on fixed times; these messages are microseconds apart.)
        let floor = saved[4].timestamp
        await makePass().run(turn(thread, answering: users[5], kept: 1, history: 4, floor: floor),
                             settings: settings)
        XCTAssertEqual(timeline(thread).first?.firstMessageID, saved[4].id,
                       "the job's first question is in, everything before it is out")
    }

    // MARK: - What the model is shown, and what is kept

    func testTheModelSeesOnlyTheChunksWordsAndLostFiguresComeBack() async throws {
        let thread = store.startThread(mode: "direct").id
        store.appendMessage(role: "user", content: "Suction is 52 psi on the LX-4410B.")
        store.appendMessage(role: "system", content: "app line the model never sees")
        store.appendMessage(role: "assistant", content: "Noted.")
        let live = try XCTUnwrap(store.appendMessage(role: "user", content: "what next?"))
        answer = { _ in TimelineSummaryCompletion(text: "- Suction reading taken.", finishedNormally: true) }

        await makePass().run(turn(thread, answering: live, kept: 1, history: 2), settings: settings)

        let request = try XCTUnwrap(calls.first)
        XCTAssertTrue(request.user.contains("Person: Suction is 52 psi on the LX-4410B."))
        XCTAssertFalse(request.user.contains("app line"))
        XCTAssertFalse(request.user.contains("what next?"), "the live turn is not in the chunk")
        let note = try XCTUnwrap(timeline(thread).first?.text)
        XCTAssertTrue(note.hasPrefix("- Suction reading taken."))
        XCTAssertTrue(note.contains(TimelineDetailCheck.heading))
        XCTAssertTrue(note.contains("\"Suction is 52 psi on the LX-4410B.\""), note)
    }

    func testARejectedSummaryLeavesTheRangeUncoveredAndBacksOff() async throws {
        let (thread, users) = try seed(4)
        let pass = makePass()
        answer = { _ in TimelineSummaryCompletion(text: "- Half a no", finishedNormally: false) }
        let report = await pass.run(turn(thread, answering: users[3], kept: 1, history: 4), settings: settings)
        XCTAssertEqual(report, .ran(summarised: 0, merged: 0, stopped: .summaryFailed("cutOff")))
        XCTAssertTrue(timeline(thread).isEmpty)

        answer = { _ in TimelineSummaryCompletion(text: "- Fine now.", finishedNormally: true) }
        let skipped = await pass.run(turn(thread, answering: users[3], kept: 1, history: 4), settings: settings)
        XCTAssertEqual(skipped, .skipped(.backingOff))
        XCTAssertEqual(calls.count, 1, "the skipped pass asks nothing")

        let retried = await pass.run(turn(thread, answering: users[3], kept: 1, history: 4), settings: settings)
        XCTAssertEqual(retried, .ran(summarised: 1, merged: 0, stopped: nil))
    }

    func testAFailedCallBacksOffAndTwoFailuresBackOffLonger() async throws {
        let (thread, users) = try seed(4)
        let pass = makePass()
        answer = { _ in throw TimelineSummaryError.rejected }
        let failed = await pass.run(turn(thread, answering: users[3], kept: 1, history: 4), settings: settings)
        XCTAssertEqual(failed, .ran(summarised: 0, merged: 0, stopped: .summaryFailed("rejected")))
        let result1 = await pass.run(turn(thread, answering: users[3], kept: 1, history: 4), settings: settings)
        XCTAssertEqual(result1, .skipped(.backingOff))
        // Second failure in a row: two passes skipped.
        _ = await pass.run(turn(thread, answering: users[3], kept: 1, history: 4), settings: settings)
        let result2 = await pass.run(turn(thread, answering: users[3], kept: 1, history: 4), settings: settings)
        XCTAssertEqual(result2, .skipped(.backingOff))
        let result3 = await pass.run(turn(thread, answering: users[3], kept: 1, history: 4), settings: settings)
        XCTAssertEqual(result3, .skipped(.backingOff))
        XCTAssertEqual(calls.count, 2)
    }

    // MARK: - The gate, live

    func testTheGateStopsThePassBeforeTheModelIsAsked() async throws {
        let (thread, users) = try seed(4)
        let pass = makePass()
        let base = turn(thread, answering: users[3], kept: 1, history: 4)
        var off = settings
        off.enabled = false
        let result4 = await pass.run(base, settings: off)
        XCTAssertEqual(result4, .skipped(.settingOff))
        var hipaa = settings
        hipaa.hipaaMode = true
        let result5 = await pass.run(base, settings: hipaa)
        XCTAssertEqual(result5, .skipped(.hipaaMode))
        var local = settings
        local.provider = .local
        let result6 = await pass.run(base, settings: local)
        XCTAssertEqual(result6, .skipped(.onDeviceModel))
        var capped = settings
        capped.atSpendCap = true
        let result7 = await pass.run(base, settings: capped)
        XCTAssertEqual(result7, .skipped(.spendCap))
        let unread = TimelineSummaryPass.Turn(threadID: thread, answeringMessageID: users[3], reading: nil)
        let result8 = await pass.run(unread, settings: settings)
        XCTAssertEqual(result8, .skipped(.noRequestReading))

        store.isLocked = true
        let result9 = await pass.run(base, settings: settings)
        XCTAssertEqual(result9, .skipped(.storeUnavailable))
        store.isLocked = false

        store.startThread(mode: "direct")
        let result10 = await pass.run(base, settings: settings)
        XCTAssertEqual(result10, .skipped(.threadNotActive),
                       "the in-memory history is the active thread's, not this one's")
        XCTAssertTrue(calls.isEmpty)
    }

    func testOnePassPerThreadAtATime() async throws {
        let (thread, users) = try seed(4)
        let pass = makePass()
        let base = turn(thread, answering: users[3], kept: 1, history: 4)
        var overlapping: TimelineSummaryPass.Report?
        beforeAnswering = { [unowned self] in
            self.beforeAnswering = nil
            XCTAssertTrue(pass.isRunning(thread))
            // A second reply lands while the first pass waits on the model.
            overlapping = await pass.run(base, settings: self.settings)
        }
        let first = await pass.run(base, settings: settings)
        XCTAssertEqual(first, .ran(summarised: 1, merged: 0, stopped: nil))
        XCTAssertEqual(overlapping, .skipped(.passRunning))
        XCTAssertFalse(pass.isRunning(thread))
    }

    // MARK: - Re-checked at save time

    func testATruncateWhileTheModelAnswersRefusesTheWrite() async throws {
        let (thread, users) = try seed(4)
        beforeAnswering = { [unowned self] in self.store.truncate(from: users[1], in: thread) }
        let report = await makePass().run(turn(thread, answering: users[3], kept: 1, history: 4),
                                          settings: settings)
        XCTAssertEqual(report, .ran(summarised: 0, merged: 0, stopped: .saveRefused(.spanChanged)))
        XCTAssertTrue(timeline(thread).isEmpty)
    }

    func testADeleteWhileTheModelAnswersRefusesTheWrite() async throws {
        let (thread, users) = try seed(4)
        beforeAnswering = { [unowned self] in self.store.deleteThread(thread) }
        let report = await makePass().run(turn(thread, answering: users[3], kept: 1, history: 4),
                                          settings: settings)
        XCTAssertEqual(report, .ran(summarised: 0, merged: 0, stopped: .saveRefused(.threadGone)))
    }

    func testALockWhileTheModelAnswersRefusesTheWriteWithoutBackingOff() async throws {
        let (thread, users) = try seed(4)
        let pass = makePass()
        beforeAnswering = { [unowned self] in self.store.isLocked = true }
        let report = await pass.run(turn(thread, answering: users[3], kept: 1, history: 4), settings: settings)
        XCTAssertEqual(report, .ran(summarised: 0, merged: 0, stopped: .saveRefused(.storeUnavailable)))
        store.isLocked = false
        beforeAnswering = nil
        let next = await pass.run(turn(thread, answering: users[3], kept: 1, history: 4), settings: settings)
        XCTAssertEqual(next, .ran(summarised: 1, merged: 0, stopped: nil), "the model did nothing wrong")
    }

    func testTheStoreRefusesAChunkSomethingAlreadyCovers() throws {
        let (thread, _) = try seed(3)
        let messages = try XCTUnwrap(store.threads.first { $0.id == thread }).messages
        func entry(_ id: String, _ first: Int, _ last: Int) -> TimelineEntry {
            TimelineEntry(id: id, firstMessageID: messages[first].id, lastMessageID: messages[last].id,
                          startedAt: messages[first].timestamp, endedAt: messages[last].timestamp,
                          tier: .chunk, text: "notes")
        }
        XCTAssertEqual(store.saveTimelineChunk(entry("later", 2, 3), in: thread), .saved)
        XCTAssertEqual(store.saveTimelineChunk(entry("earlier", 0, 1), in: thread), .saved)
        XCTAssertEqual(timeline(thread).map(\.id), ["earlier", "later"], "kept in span order")
        XCTAssertEqual(store.saveTimelineChunk(entry("overlap", 1, 2), in: thread), .alreadyCovered)
        XCTAssertEqual(store.saveTimelineChunk(entry("backwards", 3, 1), in: thread), .spanChanged)
        XCTAssertEqual(store.saveTimelineChunk(entry("x", 4, 5), in: "no-such-thread"), .threadGone)

        let reopened = ConversationStore(directory: directory)
        XCTAssertEqual(reopened.threads.first { $0.id == thread }?.timeline?.map(\.id), ["earlier", "later"])
    }

    // MARK: - Merges

    func testSixChunksBecomeOneMergedEntryAndTwoBuffered() async throws {
        let (thread, users) = try seed(8)
        let messages = try XCTUnwrap(store.threads.first { $0.id == thread }).messages
        for chunk in 0..<6 {
            let first = messages[chunk * 2]
            let last = messages[chunk * 2 + 1]
            let entry = TimelineEntry(id: "c\(chunk)", firstMessageID: first.id, lastMessageID: last.id,
                                      startedAt: first.timestamp, endedAt: last.timestamp, tier: .chunk,
                                      text: "- Chunk \(chunk).")
            XCTAssertEqual(store.saveTimelineChunk(entry, in: thread), .saved)
        }
        let report = await makePass().run(turn(thread, answering: users[7], kept: 2, history: 8),
                                          settings: settings)
        XCTAssertEqual(report, .ran(summarised: 0, merged: 1, stopped: nil))
        XCTAssertEqual(calls.map(\.tier), [.merged])
        let entries = timeline(thread)
        XCTAssertEqual(entries.map(\.tier), [.merged, .chunk, .chunk])
        XCTAssertEqual(entries.first?.firstMessageID, messages[0].id)
        XCTAssertEqual(entries.first?.lastMessageID, messages[7].id)
        XCTAssertEqual(entries.dropFirst().map(\.id), ["c4", "c5"])
    }

    func testAMergeWhoseSourcesChangedIsRefused() throws {
        let (thread, _) = try seed(8)
        let messages = try XCTUnwrap(store.threads.first { $0.id == thread }).messages
        var entries: [TimelineEntry] = []
        for chunk in 0..<6 {
            let first = messages[chunk * 2]
            let last = messages[chunk * 2 + 1]
            entries.append(TimelineEntry(id: "c\(chunk)", firstMessageID: first.id, lastMessageID: last.id,
                                         startedAt: first.timestamp, endedAt: last.timestamp, tier: .chunk,
                                         text: "- Chunk \(chunk)."))
        }
        let index = try XCTUnwrap(store.threads.firstIndex { $0.id == thread })
        store.threads[index].timeline = entries
        let plan = try XCTUnwrap(TimelineMergePlanner.nextMerge(entries: entries, messageIDs: messages.map(\.id)))
        let sources = Array(entries.prefix(4))
        store.threads[index].timeline?[1] = entries[1].redacting()
        XCTAssertEqual(store.applyTimelineMerge(plan, merged: plan.entry(id: "m", text: "- Merged."),
                                                in: thread, sources: sources), .sourcesChanged)
        XCTAssertEqual(timeline(thread).count, 6)
    }

    // MARK: - Redacted entries

    func testARedactedEntryIsNeverRenderedOrMerged() throws {
        let messages = TimelineFixtures.conversation(8)
        var entries: [TimelineEntry] = []
        for chunk in 0..<7 {
            entries.append(TimelineFixtures.entry("c\(chunk)", messages, (chunk * 2)...(chunk * 2 + 1),
                                                  text: "- Chunk \(chunk)."))
        }
        entries[2] = entries[2].redacting()
        let rendered = TimelineRenderer.render(entries: entries, coverageHasGaps: false,
                                               timeZone: TimelineFixtures.utc)
        XCTAssertEqual(rendered.renderedCount, 6)
        XCTAssertFalse(rendered.text?.contains("Chunk 2") ?? true)

        let plan = TimelineMergePlanner.nextMerge(entries: entries, messageIDs: messages.map(\.id))
        XCTAssertEqual(plan?.sourceIDs, ["c3", "c4", "c5", "c6"],
                       "c0 and c1 cannot run across the cleared entry, and it is never a source")
    }
}
