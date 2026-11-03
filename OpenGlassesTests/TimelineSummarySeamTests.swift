import XCTest
@testable import OpenGlasses

/// Plan KK P2 — the summary seam over a stubbed transport: tools off, sent to the active model,
/// counted in Usage, read with how it ended, and never touching the live conversation history.
/// Also that the pass's log lines carry no text. Values are invented.
@MainActor
final class TimelineSummarySeamTests: XCTestCase {

    private var savedModels: [ModelConfig] = []
    private var activeID = ""
    private var hipaa = false
    private var localOnly = false
    private var usagePath: URL!
    private var services: [LLMService] = []
    private var trackers: [WeakTracker] = []
    private struct WeakTracker { weak var tracker: UsageTracker? }

    override func setUp() {
        super.setUp()
        savedModels = Config.savedModels
        activeID = Config.activeModelId
        hipaa = Config.hipaaMode
        localOnly = Config.hipaaLocalOnly
        Config.hipaaMode = false
        Config.hipaaLocalOnly = false
        Config.setSavedModels([
            ModelConfig(id: "summary", name: "Summary", provider: LLMProvider.openai.rawValue,
                        apiKey: "test", model: "gpt-test-notes", baseURL: "https://selected.example.test/v1"),
            ModelConfig(id: "phone", name: "Phone", provider: LLMProvider.local.rawValue,
                        apiKey: "", model: "mlx-community/test-model", baseURL: ""),
        ])
        Config.setActiveModelId("summary")
        RecordingQueueProtocol.reset()
        usagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kk-seam-usage-\(UUID().uuidString).sqlite")
    }

    override func tearDown() async throws {
        Config.setSavedModels(savedModels)
        Config.setActiveModelId(activeID)
        Config.hipaaMode = hipaa
        Config.hipaaLocalOnly = localOnly
        RecordingQueueProtocol.reset()
        services.forEach { $0.usageTrackerOverride = nil }
        services = []
        var spins = 0
        while trackers.contains(where: { $0.tracker != nil }), spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        trackers = []
        try? FileManager.default.removeItem(at: usagePath)
        try await super.tearDown()
    }

    private func service() -> (LLMService, UsageTracker) {
        let llm = LLMService()
        llm.processingConsent = CloudConsentFixture.conversation()
        let session = RecordingQueueProtocol.session()
        llm.dataSession = session
        llm.streamingSession = session
        let tracker = UsageTracker(store: UsageStore(path: usagePath))
        llm.usageTrackerOverride = tracker
        services.append(llm)
        trackers.append(WeakTracker(tracker: tracker))
        return (llm, tracker)
    }

    private func records(_ tracker: UsageTracker, atLeast count: Int) async -> [UsageRecord] {
        for _ in 0..<200 {
            let found = tracker.store.records(since: .distantPast)
            if found.count >= count { return found }
            await Task.yield()
        }
        return tracker.store.records(since: .distantPast)
    }

    private func reply(_ finish: String) -> String {
        #"{"choices":[{"message":{"role":"assistant","content":"- 09:00 Suction 52 psi."},"finish_reason":""#
            + finish + #""}],"usage":{"prompt_tokens":40,"completion_tokens":9}}"#
    }

    private var request: TimelineSummaryPrompt.Request {
        var lines: [TimelineSummaryPrompt.Line] = []
        lines.append(.init(role: "user", text: "Suction is 52 psi.", timestamp: TimelineFixtures.minutes(0)))
        lines.append(.init(role: "assistant", text: "Noted.", timestamp: TimelineFixtures.minutes(1)))
        return TimelineSummaryPrompt.chunk(lines, timeZone: TimelineFixtures.utc)
    }

    // MARK: - The call

    func testOneToolFreeCallToTheActiveModelCountedInUsage() async throws {
        let (llm, tracker) = service()
        llm.injectSystemMessage("[a note already in the live history]")
        let before = llm.rawConversationHistoryForTesting().count
        RecordingQueueProtocol.queue = [(200, reply("stop"))]

        let completion = try await llm.completeTimelineSummary(request)

        XCTAssertEqual(completion, TimelineSummaryCompletion(text: "- 09:00 Suction 52 psi.", finishedNormally: true))
        let sent = try XCTUnwrap(RecordingQueueProtocol.requests.first)
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
        XCTAssertEqual(sent.url, "https://selected.example.test/v1/chat/completions")
        let body = try XCTUnwrap(sent.json)
        XCTAssertNil(body["tools"], "tools off")
        XCTAssertEqual(body["model"] as? String, "gpt-test-notes", "the conversation's own model")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["system", "user"],
                       "no conversation history rides along")
        XCTAssertEqual(llm.rawConversationHistoryForTesting().count, before, "the live history is untouched")
        XCTAssertNil(llm.lastTimelineReading, "a summary call is not a conversation request")

        let usage = await records(tracker, atLeast: 1)
        XCTAssertEqual(usage.first?.tokensIn, 40)
        XCTAssertEqual(usage.first?.tokensOut, 9)
        XCTAssertEqual(usage.first?.model, "gpt-test-notes")
    }

    func testAReplyCutOffAtTheAllowanceIsSaidToBe() async throws {
        let (llm, _) = service()
        RecordingQueueProtocol.queue = [(200, reply("length"))]
        let completion = try await llm.completeTimelineSummary(request)
        XCTAssertFalse(completion.finishedNormally)
        XCTAssertEqual(TimelineSummaryAcceptance.evaluate(completion.text, tier: .chunk,
                                                          finishedNormally: completion.finishedNormally),
                       .rejected(.cutOff))
    }

    func testAProviderErrorThrowsAndCountsNothing() async throws {
        let (llm, tracker) = service()
        RecordingQueueProtocol.queue = [(500, #"{"error":{"message":"overloaded"}}"#)]
        do {
            _ = try await llm.completeTimelineSummary(request)
            XCTFail("a failed call must not come back as a note")
        } catch {
            XCTAssertEqual(error as? TimelineSummaryError, .rejected)
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(tracker.store.records(since: .distantPast).isEmpty)
    }

    func testAPhoneModelIsNeverAsked() async throws {
        let (llm, _) = service()
        Config.setActiveModelId("phone")
        do {
            _ = try await llm.completeTimelineSummary(request)
            XCTFail("on-device inference cannot run in the background")
        } catch {
            XCTAssertEqual(error as? TimelineSummaryError, .unavailable)
        }
        XCTAssertTrue(RecordingQueueProtocol.requests.isEmpty)
    }

    // MARK: - The log

    /// Counts, sizes, durations and named reasons only: nothing the wearer said, nothing the
    /// model wrote.
    func testThePassLogsNoText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kk-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId")
        defer { UserDefaults.standard.removeObject(forKey: "conversationStore_activeThreadId") }
        let store = ConversationStore(directory: directory)
        let thread = store.startThread(mode: "direct").id
        store.appendMessage(role: "user", content: "Quillon reads 52 psi on unit ZX-7781.")
        store.appendMessage(role: "assistant", content: "Noted the Quillon reading.")
        let live = try XCTUnwrap(store.appendMessage(role: "user", content: "and now?"))

        let sink = Sink()
        let token = PrivacyLog.addTap { _, line in sink.record(line) }
        defer { PrivacyLog.removeTap(token) }
        var attempt = 0
        let pass = TimelineSummaryPass(store: store, summarise: { _ in
            attempt += 1
            if attempt == 1 { return TimelineSummaryCompletion(text: "Marrowind cut", finishedNormally: false) }
            return TimelineSummaryCompletion(text: "- Marrowind reading noted.", finishedNormally: true)
        })
        let turn = TimelineSummaryPass.Turn(
            threadID: thread, answeringMessageID: live,
            reading: TimelineRequestReading(keptUserTurns: 1, historyUserTurns: 2, floorDate: nil))
        let settings = TimelineSummaryPass.Settings(enabled: true, hipaaMode: false, provider: .openai,
                                                    atSpendCap: false)
        _ = await pass.run(turn, settings: settings)   // refused: cut off
        _ = await pass.run(turn, settings: settings)   // backing off
        let last = await pass.run(turn, settings: settings)
        XCTAssertEqual(last, .ran(summarised: 1, merged: 0, stopped: nil))

        let lines = sink.lines
        XCTAssertTrue(lines.contains { $0.contains("timelineSummarised") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("timelineSummaryFailed") && $0.contains("cutOff") })
        XCTAssertTrue(lines.contains { $0.contains("timelinePassSkipped") && $0.contains("backingOff") })
        for word in ["Quillon", "Marrowind", "ZX-7781", "52 psi", "and now"] {
            XCTAssertFalse(lines.contains { $0.contains(word) }, "\(word) reached the log")
        }
    }
}

private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ line: String) {
        lock.lock(); stored.append(line); lock.unlock()
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
