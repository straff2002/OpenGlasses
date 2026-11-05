import XCTest
@testable import OpenGlasses

/// A scheduled task's run reads the conversation and leaves nothing in it, and a turn of the
/// wearer's that starts meanwhile stops it (`LLMService.sendOffConversation`). From a build-615
/// report: the calendar task's prompt, left unanswered in the history by a refused key, was what
/// the next voice turn's model answered, aloud, as "[NOTHING]".
@MainActor
final class ScheduledRunHistoryTests: XCTestCase {
    private var savedModels: [ModelConfig] = []
    private var activeID = ""
    private var cascade = false
    private var hipaa = false
    private var localOnly = false
    private var agent = false

    private let scheduledPrompt = "SCHEDULED PROMPT: check the calendar, or say [NOTHING]."
    private let earlier: [(role: String, content: String)] = [
        ("user", "What's on today?"), ("assistant", "Two jobs, both in town.")
    ]
    private let refusal = #"{"error":{"message":"API key not valid."}}"#

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
        Config.setSavedModels([
            ModelConfig(id: "assistant", name: "Assistant", provider: LLMProvider.openai.rawValue,
                        apiKey: "test", model: "assistant-model",
                        // An origin `CloudConsentFixture.conversation()` approves.
                        baseURL: "https://selected.example.test/v1", supportsVision: false,
                        smallContext: true)
        ])
        Config.setActiveModelId("assistant")
        HoldingProtocol.reset()
    }

    override func tearDown() {
        HoldingProtocol.reset()
        Config.setSavedModels(savedModels)
        Config.setActiveModelId(activeID)
        Config.modelCascadeEnabled = cascade
        Config.hipaaMode = hipaa
        Config.hipaaLocalOnly = localOnly
        Config.setAgentModeEnabled(agent)
        super.tearDown()
    }

    private func service() -> LLMService {
        let service = LLMService()
        service.processingConsent = CloudConsentFixture.conversation()
        let session = HoldingProtocol.session()
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

    private func waitForHeldRequest(file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where HoldingProtocol.heldCount == 0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(HoldingProtocol.heldCount, 1, "the scheduled request is in flight", file: file, line: line)
    }

    func testARunReadsTheConversationAndLeavesNothingInIt() async throws {
        HoldingProtocol.queue = [(200, answer("Nothing coming up."))]
        let service = service()
        let reply = try await service.sendOffConversation(scheduledPrompt, locationContext: nil,
                                                          memoryContext: nil, agentContext: nil)
        XCTAssertEqual(reply, "Nothing coming up.")
        let request = try XCTUnwrap(HoldingProtocol.requests.first)
        XCTAssertTrue(request.contains("What's on today?"), "the run sees the conversation")
        XCTAssertTrue(request.contains("SCHEDULED PROMPT"))
        XCTAssertEqual(history(service), ["user: What's on today?", "assistant: Two jobs, both in town."])
    }

    func testARefusedRunLeavesNoUnansweredPromptForTheNextTurn() async throws {
        HoldingProtocol.queue = [(400, refusal), (200, answer("I can hear you."))]
        let service = service()
        do {
            _ = try await service.sendOffConversation(scheduledPrompt, locationContext: nil,
                                                      memoryContext: nil, agentContext: nil)
            XCTFail("a refused key fails the run")
        } catch {}
        let reply = try await service.sendMessageCascading("Can you hear me")
        XCTAssertEqual(reply, "I can hear you.")
        let voice = try XCTUnwrap(HoldingProtocol.requests.last)
        XCTAssertFalse(voice.contains("SCHEDULED PROMPT"), "the voice turn never carries the task's prompt")
        XCTAssertFalse(history(service).contains { $0.contains("SCHEDULED PROMPT") })
    }

    func testAVoiceTurnStopsARunInFlightAndKeepsItsOwnExchange() async throws {
        HoldingProtocol.holdMarker = "SCHEDULED PROMPT"
        HoldingProtocol.queue = [(200, answer("I can hear you."))]
        let service = service()
        let run = Task { @MainActor in
            try await service.sendOffConversation(self.scheduledPrompt, locationContext: nil,
                                                  memoryContext: nil, agentContext: nil)
        }
        await waitForHeldRequest()

        let reply = try await service.sendMessageCascading("Can you hear me")
        XCTAssertEqual(reply, "I can hear you.")
        do {
            _ = try await run.value
            XCTFail("the run stops for the wearer's turn")
        } catch {
            XCTAssertTrue(error is LLMService.OffConversationRunYielded, "got \(error)")
        }
        let voice = try XCTUnwrap(HoldingProtocol.requests.last)
        XCTAssertFalse(voice.contains("SCHEDULED PROMPT"))
        XCTAssertTrue(voice.contains("What's on today?"))
        XCTAssertEqual(history(service), ["user: What's on today?", "assistant: Two jobs, both in town.",
                                          "user: Can you hear me", "assistant: I can hear you."])
    }

    func testClearingTheConversationDuringARunStaysCleared() async throws {
        HoldingProtocol.holdMarker = "SCHEDULED PROMPT"
        let service = service()
        let run = Task { @MainActor in
            try await service.sendOffConversation(self.scheduledPrompt, locationContext: nil,
                                                  memoryContext: nil, agentContext: nil)
        }
        await waitForHeldRequest()

        service.clearHistory()
        do {
            _ = try await run.value
            XCTFail("the run stops for the clear")
        } catch {
            XCTAssertTrue(error is LLMService.OffConversationRunYielded, "got \(error)")
        }
        XCTAssertEqual(history(service), [], "putting the run's history back never undoes the clear")
    }

    func testAFailedVoiceTurnLeavesNoUnansweredMessage() async throws {
        HoldingProtocol.queue = [(400, refusal), (200, answer("Yes, loud and clear."))]
        let service = service()
        do {
            _ = try await service.sendMessageCascading("First question")
            XCTFail("a refused key fails the turn")
        } catch {}
        XCTAssertEqual(history(service), ["user: What's on today?", "assistant: Two jobs, both in town."])

        _ = try await service.sendMessageCascading("Can you hear me")
        let second = try XCTUnwrap(HoldingProtocol.requests.last)
        XCTAssertFalse(second.contains("First question"))
    }
}

/// Answers from a queue, except that a request whose body holds `holdMarker` gets no answer until
/// its task is cancelled — a scheduled run still waiting on the network.
private final class HoldingProtocol: URLProtocol {
    nonisolated(unsafe) static var queue: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var holdMarker: String?
    nonisolated(unsafe) private static var recorded: [String] = []
    nonisolated(unsafe) private static var held = 0
    private static let lock = NSLock()

    static var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static var heldCount: Int {
        lock.lock(); defer { lock.unlock() }
        return held
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue = []
        holdMarker = nil
        recorded = []
        held = 0
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HoldingProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = String(decoding: request.httpBody ?? Self.drain(request.httpBodyStream), as: UTF8.self)
        Self.lock.lock()
        Self.recorded.append(body)
        if let marker = Self.holdMarker, body.contains(marker) {
            Self.held += 1
            Self.lock.unlock()
            return
        }
        let next = Self.queue.isEmpty ? (status: 200, body: "") : Self.queue.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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
