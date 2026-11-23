import XCTest
@testable import OpenGlasses

/// A `completeStateless` call (the lecture assistant's talk note, the planner, the complexity
/// classifier, a summary) runs in a history of its own and never touches the conversation. It used
/// to empty the shared history and put a snapshot back when it ended, so a wearer's turn that
/// overlapped it ran over no history, and lost its exchange to the snapshot put back over it.
///
/// Each case holds one request on the fake transport while the other side runs, the overlap a
/// slow model makes on the device.
@MainActor
final class StatelessCallHistoryTests: XCTestCase {
    private var savedModels: [ModelConfig] = []
    private var activeID = ""
    private var cascade = false
    private var hipaa = false
    private var localOnly = false
    private var agent = false

    private let statelessPrompt = "STATELESS NOTE: say what the lecturer just covered."
    private let scheduledPrompt = "SCHEDULED PROMPT: check the calendar, or say [NOTHING]."
    private let earlier: [(role: String, content: String)] = [
        ("user", "What's on today?"), ("assistant", "Two jobs, both in town.")
    ]
    private var conversation: [String] {
        ["user: What's on today?", "assistant: Two jobs, both in town.",
         "user: Can you hear me", "assistant: I can hear you."]
    }

    override func setUp() {
        super.setUp()
        savedModels = Config.savedModels
        activeID = Config.activeModelId
        cascade = Config.modelCascadeEnabled
        hipaa = Config.hipaaMode
        localOnly = Config.hipaaLocalOnly
        agent = Config.agentModeEnabled
        Config.modelCascadeEnabled = false
        Config.hipaaMode = false
        Config.hipaaLocalOnly = false
        Config.setAgentModeEnabled(false)
        useModel(smallContext: true)
        StatelessHoldingProtocol.reset()
    }

    override func tearDown() {
        StatelessHoldingProtocol.reset()
        Config.setSavedModels(savedModels)
        Config.setActiveModelId(activeID)
        Config.modelCascadeEnabled = cascade
        Config.hipaaMode = hipaa
        Config.hipaaLocalOnly = localOnly
        Config.setAgentModeEnabled(agent)
        super.tearDown()
    }

    private func useModel(smallContext: Bool) {
        Config.setSavedModels([
            ModelConfig(id: "assistant", name: "Assistant", provider: LLMProvider.openai.rawValue,
                        apiKey: "test", model: "assistant-model",
                        // An origin `CloudConsentFixture.conversation()` approves.
                        baseURL: "https://selected.example.test/v1", supportsVision: false,
                        smallContext: smallContext)
        ])
        Config.setActiveModelId("assistant")
    }

    private func service() -> LLMService {
        let service = LLMService()
        service.processingConsent = CloudConsentFixture.conversation()
        let session = StatelessHoldingProtocol.session()
        service.dataSession = session
        service.streamingSession = session
        service.resetConversationHistoryForTesting(earlier)
        return service
    }

    private func answer(_ text: String) -> String {
        #"{"choices":[{"message":{"role":"assistant","content":"\#(text)"}}]}"#
    }

    private func history(_ service: LLMService) -> [String] {
        service.conversationHistoryForTesting().map { "\($0.role): \($0.content)" }
    }

    private func request(containing marker: String) throws -> String {
        try XCTUnwrap(StatelessHoldingProtocol.requests.last { $0.contains(marker) },
                      "no request carried \(marker)")
    }

    private func waitForHeld(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<250 where StatelessHoldingProtocol.heldCount < count {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(StatelessHoldingProtocol.heldCount, count, "requests held in flight",
                       file: file, line: line)
    }

    // MARK: - A wearer's turn beside a stateless call

    func testATurnDuringAStatelessCallReadsTheConversationAndKeepsItsExchange() async throws {
        StatelessHoldingProtocol.holdMarkers = ["STATELESS NOTE"]
        StatelessHoldingProtocol.queue = [(200, answer("I can hear you."))]
        let service = service()
        let note = Task { @MainActor in
            try await service.completeStateless(self.statelessPrompt, system: "Write a short note.")
        }
        await waitForHeld(1)

        let reply = try await service.sendMessageCascading("Can you hear me")
        XCTAssertEqual(reply, "I can hear you.")
        let turn = try request(containing: "Can you hear me")
        XCTAssertTrue(turn.contains("What's on today?"), "the turn runs over the conversation, not an emptied one")
        XCTAssertTrue(turn.contains("Two jobs, both in town."))

        StatelessHoldingProtocol.release("STATELESS NOTE", body: answer("They covered the refrigerant cycle."))
        let written = try await note.value
        XCTAssertEqual(written, "They covered the refrigerant cycle.")
        XCTAssertEqual(history(service), conversation, "the call ending puts nothing back over the turn")
    }

    func testAStatelessCallThatOutlastsATurnStartedBeforeItLosesNothing() async throws {
        StatelessHoldingProtocol.holdMarkers = ["Can you hear me", "STATELESS NOTE"]
        let service = service()
        let turn = Task { @MainActor in try await service.sendMessageCascading("Can you hear me") }
        await waitForHeld(1)
        let note = Task { @MainActor in
            try await service.completeStateless(self.statelessPrompt, system: "Write a short note.")
        }
        await waitForHeld(2)

        StatelessHoldingProtocol.release("Can you hear me", body: answer("I can hear you."))
        let reply = try await turn.value
        XCTAssertEqual(reply, "I can hear you.")
        XCTAssertEqual(history(service), conversation, "the turn's reply lands in the conversation")

        StatelessHoldingProtocol.release("STATELESS NOTE", body: answer("They covered the refrigerant cycle."))
        _ = try await note.value
        XCTAssertEqual(history(service), conversation, "a snapshot from before the reply never comes back")

        let sent = try request(containing: "STATELESS NOTE")
        XCTAssertFalse(sent.contains("What's on today?"), "the call never reads the conversation")
        XCTAssertFalse(sent.contains("Can you hear me"))
    }

    func testAStatelessCallLeavesTheConversationAsItFoundIt() async throws {
        StatelessHoldingProtocol.queue = [(200, answer("A note.")), (200, answer("I can hear you."))]
        let service = service()
        let note = try await service.completeStateless(statelessPrompt, system: "Write a short note.")
        XCTAssertEqual(note, "A note.")
        XCTAssertEqual(history(service), ["user: What's on today?", "assistant: Two jobs, both in town."])

        _ = try await service.sendMessageCascading("Can you hear me")
        let turn = try request(containing: "Can you hear me")
        XCTAssertFalse(turn.contains("STATELESS NOTE"), "the next turn never carries the call's prompt")
        XCTAssertFalse(turn.contains("A note."))
        XCTAssertEqual(history(service), conversation)
    }

    func testAFailedStatelessCallLeavesTheConversationAsItFoundIt() async throws {
        StatelessHoldingProtocol.queue = [(400, #"{"error":{"message":"API key not valid."}}"#)]
        let service = service()
        do {
            _ = try await service.completeStateless(statelessPrompt, system: "Write a short note.")
            XCTFail("a refused key fails the call")
        } catch {}
        XCTAssertEqual(history(service), ["user: What's on today?", "assistant: Two jobs, both in town."])
    }

    // MARK: - Writers beside a stateless call

    func testClearingTheConversationDuringAStatelessCallStaysCleared() async throws {
        StatelessHoldingProtocol.holdMarkers = ["STATELESS NOTE"]
        let service = service()
        let note = Task { @MainActor in
            try await service.completeStateless(self.statelessPrompt, system: "Write a short note.")
        }
        await waitForHeld(1)

        service.clearHistory()
        StatelessHoldingProtocol.release("STATELESS NOTE", body: answer("A note."))
        _ = try await note.value
        XCTAssertEqual(history(service), [], "the call ending never brings the cleared history back")
    }

    func testAStatelessCallNoLongerStopsAScheduledRun() async throws {
        StatelessHoldingProtocol.holdMarkers = ["SCHEDULED PROMPT"]
        StatelessHoldingProtocol.queue = [(200, answer("A note."))]
        let service = service()
        let run = Task { @MainActor in
            try await service.sendOffConversation(self.scheduledPrompt, locationContext: nil,
                                                  memoryContext: nil, agentContext: nil)
        }
        await waitForHeld(1)

        let note = try await service.completeStateless(statelessPrompt, system: "Write a short note.")
        XCTAssertEqual(note, "A note.")

        StatelessHoldingProtocol.release("SCHEDULED PROMPT", body: answer("Nothing coming up."))
        let reply = try await run.value
        XCTAssertEqual(reply, "Nothing coming up.", "the call does not write the conversation, so the run goes on")
        XCTAssertEqual(history(service), ["user: What's on today?", "assistant: Two jobs, both in town."])
    }

    // MARK: - The timeline reading

    func testAStatelessCallNeverSetsTheTimelineReading() async throws {
        useModel(smallContext: false)
        StatelessHoldingProtocol.queue = [(200, answer("A note."))]
        let service = service()
        _ = try await service.completeStateless(statelessPrompt, system: "Write a short note.")
        XCTAssertNil(service.lastTimelineReading, "a stateless request says nothing about the conversation")
        XCTAssertNil(service.lastTimelineDecision)
    }

    func testATurnDuringAStatelessCallStillTakesItsTimelineReading() async throws {
        useModel(smallContext: false)
        StatelessHoldingProtocol.holdMarkers = ["STATELESS NOTE"]
        StatelessHoldingProtocol.queue = [(200, answer("I can hear you."))]
        let service = service()
        let note = Task { @MainActor in
            try await service.completeStateless(self.statelessPrompt, system: "Write a short note.")
        }
        await waitForHeld(1)

        _ = try await service.sendMessageCascading("Can you hear me")
        let reading = try XCTUnwrap(service.lastTimelineReading,
                                    "a call in flight elsewhere does not silence the turn's reading")
        XCTAssertEqual(reading.historyUserTurns, 2, "read from the conversation, not the call's history")

        StatelessHoldingProtocol.release("STATELESS NOTE", body: answer("A note."))
        _ = try await note.value
        XCTAssertEqual(service.lastTimelineReading?.historyUserTurns, 2, "the call ending leaves the reading alone")
    }
}

/// Answers from a queue, except that a request whose body holds one of `holdMarkers` waits until
/// `release` answers it: a model still thinking while something else runs.
private final class StatelessHoldingProtocol: URLProtocol {
    nonisolated(unsafe) static var queue: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var holdMarkers: [String] = []
    nonisolated(unsafe) private static var recorded: [String] = []
    nonisolated(unsafe) private static var held: [(body: String, request: StatelessHoldingProtocol)] = []
    private static let lock = NSLock()

    static var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static var heldCount: Int {
        lock.lock(); defer { lock.unlock() }
        return held.count
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue = []
        holdMarkers = []
        recorded = []
        held = []
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StatelessHoldingProtocol.self]
        return URLSession(configuration: config)
    }

    /// Answer the held request whose body holds `marker`.
    static func release(_ marker: String, status: Int = 200, body: String) {
        lock.lock()
        guard let index = held.firstIndex(where: { $0.body.contains(marker) }) else {
            lock.unlock()
            XCTFail("no held request carries \(marker)")
            return
        }
        let request = held.remove(at: index).request
        lock.unlock()
        request.respond(status: status, body: body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = String(decoding: request.httpBody ?? Self.drain(request.httpBodyStream), as: UTF8.self)
        Self.lock.lock()
        Self.recorded.append(body)
        if Self.holdMarkers.contains(where: { body.contains($0) }) {
            Self.held.append((body, self))
            Self.lock.unlock()
            return
        }
        let next = Self.queue.isEmpty ? (status: 200, body: "") : Self.queue.removeFirst()
        Self.lock.unlock()
        respond(status: next.status, body: next.body)
    }

    override func stopLoading() {}

    private func respond(status: Int, body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
