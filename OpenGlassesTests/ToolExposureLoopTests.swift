import XCTest
@testable import OpenGlasses

/// Plan IU — on-demand tool schemas through the real tool loop (`sendOpenAICompatible` on Chat
/// Completions, over a fake transport): a core turn declares the core set and `lookup_tools`; a
/// lookup promotes the tool for the next round; a call to an available tool that was not declared
/// is turned back without running and declared from the next round; full exposure is unchanged.
@MainActor
final class ToolExposureLoopTests: XCTestCase {

    private var usagePath: URL!
    private var services: [LLMService] = []

    override func setUp() {
        super.setUp()
        RecordingQueueProtocol.reset()
        LLMService.resetLearnedRouteStateForTesting()
        usagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("it-usage-\(UUID().uuidString).sqlite")
    }

    override func tearDown() async throws {
        RecordingQueueProtocol.reset()
        LLMService.resetLearnedRouteStateForTesting()
        services.forEach { $0.usageTrackerOverride = nil }
        services = []
        for _ in 0..<200 { await Task.yield() }
        try? FileManager.default.removeItem(at: usagePath)
        try await super.tearDown()
    }

    private func service() -> LLMService {
        let s = LLMService()
        s.processingConsent = CloudConsentFixture.conversation()
        let session = RecordingQueueProtocol.session()
        s.streamingSession = session
        s.dataSession = session
        s.usageTrackerOverride = UsageTracker(store: UsageStore(path: usagePath))
        s.nativeToolRouter = NativeToolRouter(registry: NativeToolRegistry(locationService: LocationService()))
        services.append(s)
        return s
    }

    private let config = ModelConfig(id: "it", name: "it", provider: LLMProvider.openai.rawValue,
                                     apiKey: "test", model: "gpt-4o", baseURL: "", reasoningEffort: nil)

    private func call(_ name: String, _ arguments: String, id: String = "call_1") -> String {
        let escaped = arguments.replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"\#(id)","type":"function","function":{"name":"\#(name)","arguments":"\#(escaped)"}}]}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#
    }

    private func answer(_ text: String = "Done.") -> String {
        #"{"choices":[{"message":{"role":"assistant","content":"\#(text)"}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#
    }

    private func declaredNames(_ request: RecordingQueueProtocol.Recorded) -> [String] {
        ((request.json?["tools"] as? [[String: Any]]) ?? []).compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
    }

    private func toolMessages(_ request: RecordingQueueProtocol.Recorded) -> [String] {
        ((request.json?["messages"] as? [[String: Any]]) ?? [])
            .filter { $0["role"] as? String == "tool" }
            .compactMap { $0["content"] as? String }
    }

    private func coreTurn(_ svc: LLMService) -> ToolExposureTurn {
        let available = ToolDeclarations.availableToolSet(registry: svc.nativeToolRouter?.registry, mcpClient: nil)
        let decision = ToolExposurePolicy.decide(
            mode: .always, available: available.names, fullSetBytes: available.bytes,
            contextWindow: 128_000, core: ToolExposureCore.names(fieldJobActive: false, accessibilityMode: false),
            remembered: svc.toolExposureMemory)
        return ToolExposureTurn(decision: decision)
    }

    // MARK: -

    func testACoreTurnDeclaresTheCoreSetAndTheLookup() async throws {
        RecordingQueueProtocol.queue = [(200, answer())]
        let svc = service()
        let turn = coreTurn(svc)
        _ = try await ToolExposureScope.$turn.withValue(turn) {
            try await svc.sendOpenAICompatibleForTesting("hello", config: config)
        }
        let names = declaredNames(RecordingQueueProtocol.requests[0])
        XCTAssertTrue(names.contains(ToolLookupTool.toolName))
        XCTAssertTrue(names.contains("get_weather"))
        XCTAssertFalse(names.contains("define_word"), "a non-core tool waits to be looked up")
        XCTAssertEqual(names, names.sorted())
        XCTAssertLessThan(names.count, (svc.nativeToolRouter?.registry.toolNames.count ?? 0) / 2)
    }

    func testALookedUpToolIsDeclaredFromTheNextRound() async throws {
        RecordingQueueProtocol.queue = [
            (200, call(ToolLookupTool.toolName, #"{"names":["define_word"]}"#)),
            (200, answer()),
        ]
        let svc = service()
        let turn = coreTurn(svc)
        let reply = try await ToolExposureScope.$turn.withValue(turn) {
            try await svc.sendOpenAICompatibleForTesting("what does petrichor mean", config: config)
        }
        XCTAssertEqual(reply, "Done.")
        let requests = RecordingQueueProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(declaredNames(requests[0]).contains("define_word"))
        XCTAssertTrue(declaredNames(requests[1]).contains("define_word"), "declared in full from the next round")
        XCTAssertTrue(toolMessages(requests[1]).contains { $0.contains("\"name\":\"define_word\"") },
                      "the lookup's reply carries the definition")
        XCTAssertTrue(svc.toolExposureMemory.contains("define_word"), "and it stays for the conversation")
    }

    func testAnUndeclaredCallIsTurnedBackWithoutRunningAndDeclaredNext() async throws {
        RecordingQueueProtocol.queue = [
            (200, call("define_word", #"{"word":"petrichor"}"#)),
            (200, answer()),
        ]
        let svc = service()
        var dispatched: [String] = []
        svc.nativeToolRouter?.onToolDispatched = { dispatched.append($0) }
        let turn = coreTurn(svc)
        let log = LoopLineSink()
        let token = PrivacyLog.addTap { _, line in log.record(line) }
        defer { PrivacyLog.removeTap(token) }
        _ = try await ToolExposureScope.$turn.withValue(turn) {
            try await svc.sendOpenAICompatibleForTesting("what does petrichor mean", config: config)
        }
        let requests = RecordingQueueProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(toolMessages(requests[1]).contains { $0.contains("'define_word' was not run") })
        XCTAssertTrue(declaredNames(requests[1]).contains("define_word"))
        XCTAssertTrue(log.lines.contains { $0.contains("toolExposure") && $0.contains("reason=undeclaredCall") },
                      log.lines.joined(separator: "\n"))
        XCTAssertFalse(dispatched.contains("define_word"), "nothing was dispatched")
    }

    func testFullExposureDeclaresEveryToolAndNoLookup() async throws {
        RecordingQueueProtocol.queue = [(200, answer()), (200, answer())]
        let svc = service()
        _ = try await svc.sendOpenAICompatibleForTesting("hello", config: config)
        let withoutTurn = declaredNames(RecordingQueueProtocol.requests[0])

        let available = ToolDeclarations.availableToolSet(registry: svc.nativeToolRouter?.registry, mcpClient: nil)
        let full = ToolExposureTurn(decision: ToolExposurePolicy.decide(
            mode: .never, available: available.names, fullSetBytes: available.bytes, contextWindow: 8_192,
            core: [], remembered: []))
        _ = try await ToolExposureScope.$turn.withValue(full) {
            try await svc.sendOpenAICompatibleForTesting("hello", config: config)
        }
        let withFull = declaredNames(RecordingQueueProtocol.requests[1])
        XCTAssertEqual(withFull, withoutTurn, "Never is today's request")
        XCTAssertFalse(withFull.contains(ToolLookupTool.toolName))
        XCTAssertEqual(Set(withFull), Set(available.names))
    }

    func testClearingTheConversationForgetsWhatWasLookedUp() async throws {
        RecordingQueueProtocol.queue = [
            (200, call(ToolLookupTool.toolName, #"{"names":["define_word"]}"#)),
            (200, answer()),
        ]
        let svc = service()
        _ = try await ToolExposureScope.$turn.withValue(coreTurn(svc)) {
            try await svc.sendOpenAICompatibleForTesting("x", config: config)
        }
        XCTAssertTrue(svc.toolExposureMemory.contains("define_word"))
        svc.clearHistory()
        XCTAssertTrue(svc.toolExposureMemory.isEmpty)
    }
}

private final class LoopLineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func record(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
