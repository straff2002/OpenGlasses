import XCTest
@testable import OpenGlasses

/// Plan KK P3 — the timeline as a request carries it, end to end: through the real
/// `sendOpenAICompatible` over a fake transport (no network, no keys), on a resumed thread
/// (`replayMessages`), after a clear, and as the Prompt Inspector words it. Invented values only.
@MainActor
final class TimelineInRequestTests: XCTestCase {

    private typealias F = TimelineFixtures

    private var directory: URL!
    private var store: ConversationStore!
    private var usagePath: URL!
    private var services: [LLMService] = []
    private var trackers: [WeakTracker] = []
    private struct WeakTracker { weak var tracker: UsageTracker? }
    private var savedBudget: Any?
    private var savedEnabled = true
    private var savedHipaa = false

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kk-request-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        store = ConversationStore(directory: directory)
        usagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kk-request-usage-\(UUID().uuidString).sqlite")
        RecordingQueueProtocol.reset()
        LLMService.resetLearnedRouteStateForTesting()
        savedBudget = UserDefaults.standard.object(forKey: "apiHistoryTokenBudget")
        savedEnabled = Config.conversationTimelineEnabled
        savedHipaa = Config.hipaaMode
        Config.conversationTimelineEnabled = true
        Config.hipaaMode = false
        Config.apiHistoryTokenBudget = 900
    }

    override func tearDown() async throws {
        if let savedBudget {
            UserDefaults.standard.set(savedBudget, forKey: "apiHistoryTokenBudget")
        } else {
            UserDefaults.standard.removeObject(forKey: "apiHistoryTokenBudget")
        }
        Config.conversationTimelineEnabled = savedEnabled
        Config.hipaaMode = savedHipaa
        RecordingQueueProtocol.reset()
        LLMService.resetLearnedRouteStateForTesting()
        services.forEach { $0.usageTrackerOverride = nil }
        services = []
        var spins = 0
        while trackers.contains(where: { $0.tracker != nil }), spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        trackers = []
        try? FileManager.default.removeItem(at: usagePath)
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func service() -> LLMService {
        let llm = LLMService()
        llm.processingConsent = CloudConsentFixture.conversation()
        let session = RecordingQueueProtocol.session()
        llm.dataSession = session
        llm.streamingSession = session
        let tracker = UsageTracker(store: UsageStore(path: usagePath))
        llm.usageTrackerOverride = tracker
        services.append(llm)
        trackers.append(WeakTracker(tracker: tracker))
        return llm
    }

    private let config = ModelConfig(id: "kk", name: "kk", provider: LLMProvider.openai.rawValue,
                                     apiKey: "test", model: "gpt-test-notes",
                                     baseURL: "https://selected.example.test/v1")

    private let reply = #"{"choices":[{"message":{"role":"assistant","content":"Noted."}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#

    /// Eight earlier exchanges of about 100 tokens a message, in the model's history and (as
    /// `TimelineMessage`s) in the thread, plus the question about to be asked, `u8`.
    private func history() -> [(role: String, content: String)] {
        var turns: [(role: String, content: String)] = []
        for turn in 0..<8 {
            turns.append((role: "user", content: "question \(turn) " + String(repeating: "q", count: 380)))
            turns.append((role: "assistant", content: "answer \(turn) " + String(repeating: "a", count: 380)))
        }
        return turns
    }

    private func thread(covering span: ClosedRange<Int>?) -> TimelineRequestBlock.Thread {
        var messages = F.conversation(8, tokens: 100)
        messages.append(TimelineMessage(id: "u8", role: "user", timestamp: F.minutes(16), estimatedTokens: 10))
        let entries = span.map { [F.entry("e1", messages, $0, text: "Suction read 52 psi on the first visit.")] } ?? []
        return TimelineRequestBlock.Thread(messages: messages, entries: entries, answeringMessageID: "u8")
    }

    /// The trailing system message the request carried: the volatile tail, the note, the block.
    private func tail() throws -> String {
        let body = try XCTUnwrap(RecordingQueueProtocol.requests.last?.json)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        return try XCTUnwrap(messages.last { $0["role"] as? String == "system" }?["content"] as? String)
    }

    private func send(_ llm: LLMService) async throws {
        RecordingQueueProtocol.queue = [(200, reply)]
        _ = try await llm.sendOpenAICompatibleForTesting("what was the suction?", volatileTail: "[the time]",
                                                         config: config, includeTools: false)
    }

    // MARK: - API routes through `requestSystemParts`

    func testCompleteCoverageReplacesTheNoteInTheVolatileTail() async throws {
        let llm = service()
        llm.resetConversationHistoryForTesting(history())
        let covered = thread(covering: 0...13)
        llm.timelineThreadSource = { covered }
        let lines = try await capturingLog { try await send(llm) }

        let tail = try tail()
        XCTAssertTrue(tail.hasPrefix("[the time]\n\n"), tail)
        XCTAssertTrue(tail.contains("Earlier in this conversation:"))
        XCTAssertTrue(tail.contains("Suction read 52 psi on the first visit."))
        XCTAssertFalse(tail.contains("[Working context"), "the block replaced the note")
        XCTAssertFalse(tail.contains("brain"), "no tools were declared, so recall is not named")
        let decision = try XCTUnwrap(llm.lastTimelineDecision)
        XCTAssertTrue(decision.replacesNote)
        XCTAssertGreaterThan(llm.lastTimelineReading?.omittedUserTurns ?? 0, 0)

        XCTAssertTrue(lines.contains { $0.contains("timelineInRequest") && $0.contains("replacedNote") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("52 psi") || $0.contains("Suction") }, "no block text in any log")
    }

    func testAGapKeepsTheNoteSaysSoAndTheBlockFollows() async throws {
        let llm = service()
        llm.resetConversationHistoryForTesting(history())
        let partial = thread(covering: 0...1)
        llm.timelineThreadSource = { partial }
        try await send(llm)

        let tail = try tail()
        let note = try XCTUnwrap(tail.range(of: "[Working context"))
        let block = try XCTUnwrap(tail.range(of: "Earlier in this conversation:"))
        XCTAssertLessThan(note.lowerBound, block.lowerBound, "the note first, then the notes")
        XCTAssertTrue(tail.contains(APIHistoryBudget.partialNotesSentence))
        XCTAssertEqual(llm.lastTimelineDecision?.notesArePartial, true)
    }

    func testTheSettingOffSendsThePlainNote() async throws {
        Config.conversationTimelineEnabled = false
        let llm = service()
        llm.resetConversationHistoryForTesting(history())
        let covered = thread(covering: 0...13)
        llm.timelineThreadSource = { covered }
        try await send(llm)

        let tail = try tail()
        XCTAssertTrue(tail.contains("[Working context"))
        XCTAssertFalse(tail.contains("Earlier in this conversation"))
        XCTAssertFalse(tail.contains(APIHistoryBudget.partialNotesSentence))
        XCTAssertEqual(llm.lastTimelineDecision?.skip, .settingOff)
    }

    /// The block's room comes off the history allowance: with notes to show, the same history
    /// keeps fewer messages than without.
    func testTheBlockIsPaidForFromTheHistoryAllowance() async throws {
        let without = service()
        without.resetConversationHistoryForTesting(history())
        try await send(without)
        let keptWithout = try XCTUnwrap(without.lastTimelineReading?.keptUserTurns)

        RecordingQueueProtocol.reset()
        let with = service()
        with.resetConversationHistoryForTesting(history())
        let covered = thread(covering: 0...13)
        with.timelineThreadSource = { covered }
        try await send(with)
        let keptWith = try XCTUnwrap(with.lastTimelineReading?.keptUserTurns)
        XCTAssertLessThan(keptWith, keptWithout)
    }

    /// A new topic with the thread left open (or a model switch): nothing saved before the clear
    /// is shown, and the note owns up to what the budget left out.
    func testNothingBeforeAClearIsShown() async throws {
        let llm = service()
        llm.clearHistory()
        llm.resetConversationHistoryForTesting(history())
        let covered = thread(covering: 0...13)   // saved on 3 November, before the clear
        llm.timelineThreadSource = { covered }
        try await send(llm)

        XCTAssertNotNil(llm.lastTimelineReading?.clearedAt)
        XCTAssertEqual(llm.lastTimelineDecision?.skip, .nothingCovered)
        let tail = try tail()
        XCTAssertTrue(tail.contains("[Working context"))
        XCTAssertFalse(tail.contains("Earlier in this conversation"))
    }

    // MARK: - Resume: the legacy summary and the timeline never describe a span twice

    /// A thread saved with eight exchanges, a legacy summary, and (when `notes`) a timeline entry
    /// over its first five exchanges.
    private func seedResumableThread(notes: Bool) throws -> String {
        let id = store.startThread(mode: "direct").id
        for turn in 0..<8 {
            store.appendMessage(role: "user", content: "question \(turn) " + String(repeating: "q", count: 380))
            store.appendMessage(role: "assistant", content: "answer \(turn) " + String(repeating: "a", count: 380))
        }
        let index = try XCTUnwrap(store.threads.firstIndex { $0.id == id })
        store.threads[index].compressedSummary = "An older summary of the same messages."
        if notes {
            let messages = TimelineMessage.reduce(store.threads[index].messages)
            store.threads[index].timeline = [F.entry("e1", messages, 0...9, text: "The first five exchanges.")]
        }
        return id
    }

    func testTheLegacySummaryIsReplayedOnlyWithoutATimeline() throws {
        let legacy = try seedResumableThread(notes: false)
        XCTAssertEqual(store.replayMessages(for: legacy).first?.content.hasPrefix("[Prior conversation context]"), true)
        let withNotes = try seedResumableThread(notes: true)
        let replay = store.replayMessages(for: withNotes)
        XCTAssertFalse(replay.contains { $0.content.contains("older summary") })
        XCTAssertEqual(replay.count, 16, "every saved message, word for word, and nothing else")
    }

    /// Replay, then the request budget, then the block: each span appears once. What the budget
    /// keeps is in the request word for word; the block covers only what it left out; the legacy
    /// summary is not there at all.
    func testReplayBudgetAndBlockShowEachSpanOnce() throws {
        let id = try seedResumableThread(notes: true)
        let history: [[String: Any]] = store.replayMessages(for: id).map { ["role": $0.role, "content": $0.content] }
        let selection = APIHistoryBudget.select(history: history, protectedStart: history.count - 2, allowance: 1_100)
        XCTAssertGreaterThan(selection.omittedMessages, 0)
        XCTAssertFalse(selection.history.contains { ($0["content"] as? String)?.contains("older summary") == true })

        let saved = try XCTUnwrap(store.threads.first { $0.id == id })
        let messages = TimelineMessage.reduce(saved.messages)
        let reading = TimelineRequestReading(
            keptUserTurns: TimelineRequestReading.realUserTurns(in: selection.history),
            historyUserTurns: TimelineRequestReading.realUserTurns(in: history), floorDate: nil,
            omittedUserTurns: TimelineRequestReading.omittedUserTurns(in: history, omitted: selection.omittedMessages,
                                                                      floor: 0))
        let decision = TimelineRequestBlock.decide(
            .init(thread: .init(messages: messages, entries: saved.timeline ?? []), reading: reading,
                  omittedMessages: selection.omittedMessages, tokenCap: TimelineRenderer.defaultTokenCap),
            recallOffered: false, timeZone: F.utc)
        let block = try XCTUnwrap(decision.text)
        XCTAssertTrue(block.contains("The first five exchanges."))
        // The entry covers the first ten messages; the budget left out fewer, so the entry runs
        // into the request: an overlap of a few lines, never the same span from two summaries.
        XCTAssertFalse(block.contains("older summary"))
        let keptTexts = Set(selection.history.compactMap { $0["content"] as? String })
        XCTAssertTrue(keptTexts.allSatisfy { !block.contains($0) }, "no kept message is quoted in the block")
    }

    // MARK: - The Prompt Inspector

    func testTheInspectorNamesEveryState() {
        typealias B = TimelineRequestBlock
        var decisions: [B.Decision?] = [nil]
        decisions.append(B.Decision(text: "x", replacesNote: true, renderedCount: 1, estimatedTokens: 9, skip: nil))
        decisions.append(B.Decision(text: "x", replacesNote: false, renderedCount: 1, estimatedTokens: 9, skip: nil))
        let skips: [B.Skip] = [.settingOff, .hipaaMode, .onDeviceModel, .routeCarriesNoBlock, .noThread,
                               .noEntries, .nothingOmitted, .nothingCovered, .noRoom]
        decisions.append(contentsOf: skips.map { B.Decision.skipped($0) })
        let statuses = decisions.map(PromptInspectorView.timelineStatus)
        XCTAssertEqual(Set(statuses).count, statuses.count, "each state has its own words")
        XCTAssertTrue(statuses.allSatisfy { !$0.isEmpty })
    }

    // MARK: - Helpers

    private func capturingLog(_ body: () async throws -> Void) async rethrows -> [String] {
        let sink = LineSink()
        let token = PrivacyLog.addTap { _, line in sink.record(line) }
        defer { PrivacyLog.removeTap(token) }
        try await body()
        return sink.lines
    }

    private final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func record(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
