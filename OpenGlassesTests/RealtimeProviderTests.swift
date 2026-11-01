import XCTest
import UIKit
@testable import OpenGlasses

final class RealtimeProviderTests: XCTestCase {
    private func model(_ provider: String) -> RealtimeModelConfig {
        var model = RealtimeProviderCatalog.template(provider)!.modelConfiguration()
        model.apiKey = "fixture-key"
        model.endpoint = model.endpoint.replacingOccurrences(of: "{workspace}", with: "fixture-workspace")
        return model
    }
    private func fixture(_ name: String) throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/Realtime/\(name).json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
    func testNativeAuthenticationAndModelQueryAreProtocolSpecific() throws {
        let qwen = try model("qwen").request(build: .release)
        XCTAssertEqual(qwen.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        XCTAssertNil(qwen.value(forHTTPHeaderField: "OpenAI-Beta"))
        XCTAssertTrue(qwen.url!.absoluteString.contains("model=qwen3.8-omni-flash-realtime"))
        let doubao = try model("doubao").request(build: .release)
        XCTAssertEqual(doubao.value(forHTTPHeaderField: "X-Api-Key"), "fixture-key")
        XCTAssertNil(doubao.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(doubao.url!.query)
        var geminiModel = model("gemini"); geminiModel.apiKey = "key+with&reserved?"
        let gemini = try geminiModel.request(build: .release)
        XCTAssertNil(gemini.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(URLComponents(url: gemini.url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [.init(name: "key", value: "key+with&reserved?")])
    }
    func testUnknownProtocolsNeverFallBackToOpenAI() {
        var unknown = model("qwen"); unknown.profileID = "qwen.omni.v99"
        XCTAssertThrowsError(try unknown.request())
        XCTAssertThrowsError(try RealtimeAdapterRegistry.make(for: unknown))
        XCTAssertNil(unknown.capabilities)
    }
    func testWorkspaceAndDoubaoVersionAreRequired() {
        var qwen = RealtimeProviderCatalog.template("qwen")!.modelConfiguration(); qwen.apiKey = "fixture-key"
        XCTAssertThrowsError(try qwen.request())
        var doubao = model("doubao"); doubao.model = "Seeduplex"
        XCTAssertThrowsError(try doubao.request())
        doubao.model = "1.2.6.1"; doubao.voice = ""
        XCTAssertThrowsError(try doubao.request())
    }
    func testGeminiBuiltInRouteDoesNotInheritLANException() {
        var gemini = model("gemini"); gemini.endpoint = "wss://192.168.1.10/socket"
        XCTAssertThrowsError(try gemini.request(build: .release))
        gemini.providerID = "compatible"
        XCTAssertNoThrow(try gemini.request(build: .release))
    }
    func testQwenSessionUsesItsAudioAndNestedFunctionSchema() throws {
        let adapter = QwenRealtimeAdapter(voice: "Tina")
        let messages = try adapter.encode(.configure(instructions: "fixture", tools: [["type": "function", "name": "fixture_tool", "parameters": ["type": "object"]]]))
        let session = try XCTUnwrap(messages.first?["session"] as? [String: Any])
        XCTAssertNil(session["input_audio_format"])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        XCTAssertEqual((input["format"] as? [String: Any])?["sample_rate"] as? Int, 16000)
        XCTAssertEqual(((session["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["name"] as? String, "fixture_tool")
        XCTAssertNil((session["turn_detection"] as? [String: Any])?["interrupt_response"])
    }
    func testQwenImageOrderingSizeAndUnsupportedOperations() throws {
        let adapter = QwenRealtimeAdapter(voice: "Tina")
        XCTAssertThrowsError(try adapter.encode(.image(Data([0]), prompt: nil)))
        _ = try adapter.encode(.audio(Data([0, 0])))
        XCTAssertEqual(try adapter.encode(.image(Data([0]), prompt: nil)).first?["type"] as? String, "input_image_buffer.append")
        XCTAssertThrowsError(try adapter.encode(.image(Data(repeating: 0, count: 200_000), prompt: nil)))
        XCTAssertThrowsError(try adapter.encode(.text("fixture", completeTurn: true)))
        XCTAssertEqual(try adapter.encode(.interrupt(itemID: "reply", contentIndex: 0, playedMilliseconds: 100)).count, 1)
        adapter.reset()
        XCTAssertThrowsError(try adapter.encode(.image(Data([0]), prompt: nil)))
    }
    func testQwenFixtureCoversReadinessAudioTranscriptToolsAndUsage() throws {
        let adapter = QwenRealtimeAdapter(voice: "Tina")
        let events = try fixture("qwen-omni-v1").flatMap(adapter.decode)
        XCTAssertTrue(events.contains { if case .ready = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .audio(let data, _, _) = $0 { return data == Data([0, 0, 1, 0]) }; return false })
        XCTAssertTrue(events.contains { if case .inputTranscript(let text, _) = $0 { return text == "你好" }; return false })
        XCTAssertTrue(events.contains { if case .toolCalls(let calls) = $0 { return calls.first?.name == "fixture_tool" }; return false })
        XCTAssertTrue(events.contains { if case .usage(let input, let output) = $0 { return input == 3 && output == 4 }; return false })
    }
    func testDoubaoCreatesSessionAndRequestsInt16NotFloatAudio() throws {
        let model = model("doubao")
        let adapter = DoubaoRealtimeAdapter(model: model.model, voice: model.voice)
        XCTAssertTrue(adapter.createsSessionOnOpen)
        let setup = try XCTUnwrap(adapter.encode(.configure(instructions: "fixture", tools: [])).first)
        XCTAssertEqual(setup["type"] as? String, "session.create")
        let session = try XCTUnwrap(setup["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        XCTAssertEqual((output["format"] as? [String: Any])?["type"] as? String, "pcm_s16le")
        _ = adapter.decode(["type": "session.created"])
        XCTAssertEqual(try adapter.encode(.configure(instructions: "updated", tools: [])).first?["type"] as? String, "session.update")
    }
    func testDoubaoToolResultsWaitForTheWholeBatchAndDoNotRequestAnotherReply() throws {
        let adapter = DoubaoRealtimeAdapter(model: "1.2.6.1", voice: "fixture-voice")
        let input = try fixture("doubao-duplex-v3").first { $0["type"] as? String == "response.function_call_arguments.done" }!
        XCTAssertEqual(adapter.decode(input).count, 1)
        XCTAssertTrue(try adapter.encode(.toolResult(id: "fixture-b", output: "B")).isEmpty)
        let result = try adapter.encode(.toolResult(id: "fixture-a", output: "A"))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?["type"] as? String, "conversation.item.create")
        XCTAssertEqual((result.first?["items"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue(adapter.decode(input).isEmpty, "Redelivered calls must not execute again")
        XCTAssertTrue(try adapter.encode(.toolResult(id: "fixture-a", output: "duplicate")).isEmpty)
    }
    func testDoubaoFixtureUsesItsOutputEventNamesAndNoImagesOrTextInjection() throws {
        let adapter = DoubaoRealtimeAdapter(model: "1.2.6.1", voice: "fixture-voice")
        let events = try fixture("doubao-duplex-v3").flatMap(adapter.decode)
        XCTAssertTrue(events.contains { if case .audio = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .turnComplete = $0 { return true }; return false })
        XCTAssertThrowsError(try adapter.encode(.image(Data(), prompt: nil)))
        XCTAssertThrowsError(try adapter.encode(.text("fixture", completeTurn: false)))
        XCTAssertFalse(RealtimeProtocolProfile.doubaoDuplexV3.capabilities.vision)
        XCTAssertEqual(try adapter.encode(.mute(true)).first?["type"] as? String, "input_audio_mute.commit")
        XCTAssertEqual(try adapter.encode(.mute(false)).first?["type"] as? String, "input_audio_unmute.commit")
        XCTAssertEqual(try adapter.encode(.close).first?["type"] as? String, "session.close")
    }
    func testPacketizerPreservesSamplesAcrossArbitraryCaptureBuffers() {
        var packetizer = RealtimeAudioPacketizer(packetBytes: 640)
        let input = Data((0..<3200).map { UInt8($0 % 251) })
        XCTAssertTrue(packetizer.append(Data(input.prefix(123))).isEmpty)
        let packets = packetizer.append(Data(input.dropFirst(123)))
        XCTAssertEqual(packets.count, 5)
        XCTAssertTrue(packets.allSatisfy { $0.count == 640 })
        XCTAssertEqual(packets.reduce(into: Data()) { $0.append($1) }, input)
        _ = packetizer.append(Data([1, 2])); packetizer.reset()
        XCTAssertTrue(packetizer.append(Data(repeating: 0, count: 638)).isEmpty)
    }
    func testProtocolProfilesDriveActualAudioEngineRates() {
        for profile in RealtimeProtocolProfile.allCases {
            XCTAssertEqual(profile.audioConfiguration.inputSampleRate, profile.isOpenAIShape ? 24000 : 16000)
            XCTAssertEqual(profile.audioConfiguration.outputSampleRate, 24000)
            XCTAssertEqual(profile.audioConfiguration.bitsPerSample, 16)
        }
    }
    func testAuthenticationErrorsAreTerminalAndUnknownEventsAreIgnored() {
        let adapter = OpenAIRealtimeAdapter()
        let events = adapter.decode(["type": "error", "error": ["code": "invalid_api_key", "message": "secret-url-key"]])
        guard case .failure(let message, let retryable)? = events.first else { return XCTFail("Expected a failure") }
        XCTAssertFalse(retryable)
        XCTAssertFalse(message.contains("secret"))
        XCTAssertTrue(adapter.decode(["type": "error", "error": ["type": "invalid_request_error", "code": "invalid_value", "message": "No active response to cancel"]]).isEmpty)
        XCTAssertTrue(adapter.decode(["type": "new_unknown_event"]).isEmpty)
        XCTAssertTrue(adapter.decode(["type": "response.audio.delta", "delta": "invalid base64!"]).isEmpty)
    }
}

/// Drives the production service through its transport interface without a network or audio lease.
private final class FakeRealtimeTransport: RealtimeConnectionTransport {
    // In-memory protocol fixture: no connection or user data leaves the test process.
    func authorize(_ request: URLRequest) async throws {}
    var onOpen: ((String?) -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    var onError: ((Error?) -> Void)?
    var audioPacketInterval: TimeInterval = 0
    var httpStatusCode: Int?
    var sent: [[String: Any]] = []
    var request: URLRequest?
    var cancelled = false
    var onSend: (([String: Any]) -> Void)?
    private let receiveLock = NSLock()
    private var incoming: [Data] = []
    private var waiting: CheckedContinuation<Data, Error>?
    func start(_ request: URLRequest) throws { self.request = request; onOpen?(nil) }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            receiveLock.withLock {
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else if !incoming.isEmpty { continuation.resume(returning: incoming.removeFirst()) }
                else { waiting = continuation }
            }
        }
    }
    func emit(_ json: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        receiveLock.withLock {
            if let waiting { self.waiting = nil; waiting.resume(returning: data) }
            else { incoming.append(data) }
        }
    }
    func send(_ json: [String: Any]) { sent.append(json); onSend?(json) }
    func perform(_ work: @escaping () -> Void) { work() }
    func cancel() {
        receiveLock.withLock {
            cancelled = true
            waiting?.resume(throwing: CancellationError())
            waiting = nil
        }
    }
}

/// Explicitly release backoff and setup deadlines; no wall-clock retry sleeps in tests.
@MainActor
private final class RealtimeTestClock {
    private var waiters: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
    var onWait: ((TimeInterval) -> Void)?
    func sleep(_ seconds: TimeInterval) async {
        guard !Task.isCancelled else { return }
        await withCheckedContinuation { continuation in
            waiters.append((seconds, continuation))
            onWait?(seconds)
        }
    }
    func release(_ seconds: TimeInterval) {
        let matching = waiters.filter { $0.0 == seconds }
        waiters.removeAll { $0.0 == seconds }
        for (_, continuation) in matching { continuation.resume() }
    }
    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        for (_, continuation) in pending { continuation.resume() }
    }
}

@MainActor
final class RealtimeSessionEngineTests: XCTestCase {
    private var previousMedicalMode: (() -> MedicalEgressGuard.Mode)!
    override func setUp() { previousMedicalMode = MedicalEgressGuard.currentMode; MedicalEgressGuard.currentMode = { .off } }
    override func tearDown() { MedicalEgressGuard.currentMode = previousMedicalMode }
    private func model(_ provider: String) -> RealtimeModelConfig {
        var config = RealtimeProviderCatalog.template(provider)!.modelConfiguration()
        config.apiKey = "fixture-key"
        config.endpoint = config.endpoint.replacingOccurrences(of: "{workspace}", with: "fixture")
        return config
    }
    func testQwenWaitsForConfigurationAckAndKeepsSessionSnapshot() async throws {
        let transport = FakeRealtimeTransport()
        let service = RealtimeJSONSessionService(transportFactory: { _ in transport })
        let config = model("qwen")
        service.configure(model: config, systemInstruction: "fixture")
        let configured = expectation(description: "Qwen configured")
        transport.onSend = { json in if json["type"] as? String == "session.update" { configured.fulfill() } }
        let connect = Task { await service.connect() }
        transport.emit(["type": "session.created"])
        await fulfillment(of: [configured], timeout: 2)
        XCTAssertEqual(service.connectionState, .settingUp)
        transport.emit(["type": "session.updated"])
        let connected = await connect.value
        XCTAssertTrue(connected)
        XCTAssertEqual(service.connectionState, .ready)
        XCTAssertEqual(try service.connectionRequest(), try config.request())
        service.disconnect()
        XCTAssertTrue(transport.cancelled)
    }
    func testQwenBackgroundImagesAreBoundedInPixelsAndBase64Bytes() async throws {
        let transport = FakeRealtimeTransport()
        let service = RealtimeJSONSessionService(transportFactory: { _ in transport })
        defer { service.disconnect() }
        service.configure(model: model("qwen"), systemInstruction: "fixture")
        transport.onSend = { json in
            if json["type"] as? String == "session.update" { transport.emit(["type": "session.updated"]) }
        }
        transport.emit(["type": "session.created"])
        let connected = await service.connect()
        XCTAssertTrue(connected)
        service.sendAudio(data: Data([0, 0]))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 800), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 800))
        }
        let sent = expectation(description: "Bounded Qwen image")
        var encoded: String?
        transport.onSend = { json in
            if json["type"] as? String == "input_image_buffer.append" {
                encoded = json["image"] as? String
                sent.fulfill()
            }
        }
        service.sendImage(image: image)
        await fulfillment(of: [sent], timeout: 2)
        let payload = try XCTUnwrap(encoded)
        XCTAssertLessThanOrEqual(payload.utf8.count, 256 * 1024)
        let data = try XCTUnwrap(Data(base64Encoded: payload))
        let decoded = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 720)
    }
    func testDoubaoStartsClientHandshakeThenPacketizesAndMutes() async {
        let transport = FakeRealtimeTransport()
        let service = RealtimeJSONSessionService(transportFactory: { _ in transport })
        service.configure(model: model("doubao"), systemInstruction: "fixture")
        let handshake = expectation(description: "Client creates Doubao session")
        transport.onSend = { json in
            if json["type"] as? String == "session.create" { handshake.fulfill(); transport.emit(["type": "session.created"]) }
        }
        let connect = Task { await service.connect() }
        await fulfillment(of: [handshake], timeout: 2)
        let connected = await connect.value
        XCTAssertTrue(connected)
        service.sendAudio(data: Data(repeating: 0, count: 3200))
        XCTAssertEqual(transport.sent.filter { $0["type"] as? String == "input_audio_buffer.append" }.count, 5)
        XCTAssertEqual(transport.audioPacketInterval, 0.02)
        service.setMuted(true); service.setMuted(true)
        service.sendAudio(data: Data(repeating: 0, count: 640))
        XCTAssertEqual(transport.sent.filter { $0["type"] as? String == "input_audio_mute.commit" }.count, 1)
        XCTAssertEqual(transport.sent.filter { $0["type"] as? String == "input_audio_unmute.commit" }.count, 1)
        service.disconnect()
        XCTAssertEqual(transport.sent.last?["type"] as? String, "session.close")
    }
    func testStopDuringHandshakeRejectsLateReadyAndAudio() async {
        let transport = FakeRealtimeTransport()
        let service = RealtimeJSONSessionService(transportFactory: { _ in transport })
        service.configure(model: model("qwen"), systemInstruction: "fixture")
        let configured = expectation(description: "Setup sent")
        transport.onSend = { json in if json["type"] as? String == "session.update" { configured.fulfill() } }
        var played = 0; service.onAudioReceived = { _ in played += 1 }
        let connect = Task { await service.connect() }
        transport.emit(["type": "session.created"])
        await fulfillment(of: [configured], timeout: 2)
        service.disconnect()
        transport.emit(["type": "session.updated"])
        transport.emit(["type": "response.audio.delta", "delta": "AAAA"])
        let connected = await connect.value
        XCTAssertFalse(connected)
        await Task.yield()
        XCTAssertEqual(service.connectionState, .disconnected)
        XCTAssertEqual(played, 0)
    }
    func testMedicalPolicyBlocksBeforeTransportIsCreated() async {
        MedicalEgressGuard.currentMode = { .localOnly }
        var created = false
        let service = RealtimeJSONSessionService(transportFactory: { _ in created = true; return FakeRealtimeTransport() })
        service.configure(model: model("doubao"), systemInstruction: "fixture")
        let connected = await service.connect()
        XCTAssertFalse(connected)
        XCTAssertFalse(created)
    }
    func testReconnectUsesSnapshotAndRejectsCallbacksFromOldSocket() async {
        let first = FakeRealtimeTransport()
        let second = FakeRealtimeTransport()
        let clock = RealtimeTestClock()
        var created = 0
        let service = RealtimeJSONSessionService(transportFactory: { _ in
            created += 1
            return created == 1 ? first : second
        }, sleep: { await clock.sleep($0) })
        defer { service.disconnect(); clock.releaseAll() }
        service.configure(model: model("qwen"), systemInstruction: "fixture")
        for transport in [first, second] {
            transport.onSend = { json in
                if json["type"] as? String == "session.update" { transport.emit(["type": "session.updated"]) }
            }
            transport.emit(["type": "session.created"])
        }
        let connected = await service.connect()
        XCTAssertTrue(connected)
        service.updateContext("Job 1005", key: "job")
        let backoff = expectation(description: "Retry scheduled")
        clock.onWait = { if $0 == 1 { backoff.fulfill() } }
        let recovered = expectation(description: "Second session ready")
        service.onReconnected = { recovered.fulfill() }
        first.onClose?(.goingAway, nil)
        await fulfillment(of: [backoff], timeout: 2)
        XCTAssertTrue(service.reconnecting)
        clock.release(1)
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(created, 2)
        XCTAssertEqual(first.request, second.request)
        let restored = (second.sent.first?["session"] as? [String: Any])?["instructions"] as? String
        XCTAssertTrue(restored?.contains("Job 1005") == true, "Automatic reconnect retains current app context")
        var played = 0
        service.onAudioReceived = { _ in played += 1 }
        first.emit(["type": "response.audio.delta", "delta": "AAAA"])
        first.onClose?(.policyViolation, nil)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(service.connectionState, .ready)
        XCTAssertEqual(played, 0)
        XCTAssertFalse(service.reconnecting)
    }
    func testStopCancelsPendingBackoffWithoutCreatingAnotherSocket() async {
        let transport = FakeRealtimeTransport()
        let clock = RealtimeTestClock()
        var created = 0
        let service = RealtimeJSONSessionService(transportFactory: { _ in created += 1; return transport },
                                                sleep: { await clock.sleep($0) })
        defer { service.disconnect(); clock.releaseAll() }
        service.configure(model: model("qwen"), systemInstruction: "fixture")
        transport.onSend = { json in
            if json["type"] as? String == "session.update" { transport.emit(["type": "session.updated"]) }
        }
        transport.emit(["type": "session.created"])
        let connected = await service.connect()
        XCTAssertTrue(connected)
        let backoff = expectation(description: "Retry pending")
        clock.onWait = { if $0 == 1 { backoff.fulfill() } }
        transport.onError?(URLError(.networkConnectionLost))
        await fulfillment(of: [backoff], timeout: 2)
        service.disconnect()
        clock.release(1)
        await Task.yield()
        XCTAssertEqual(created, 1)
        XCTAssertEqual(service.connectionState, .disconnected)
    }
    func testAuthenticationFailureDoesNotScheduleRetry() async {
        let transport = FakeRealtimeTransport()
        let clock = RealtimeTestClock()
        let service = RealtimeJSONSessionService(transportFactory: { _ in transport }, sleep: { await clock.sleep($0) })
        defer { service.disconnect(); clock.releaseAll() }
        service.configure(model: model("qwen"), systemInstruction: "fixture")
        transport.onSend = { json in
            if json["type"] as? String == "session.update" { transport.emit(["type": "session.updated"]) }
        }
        transport.emit(["type": "session.created"])
        let connected = await service.connect()
        XCTAssertTrue(connected)
        var retryWaits = 0
        clock.onWait = { if $0 < 15 { retryWaits += 1 } }
        let rejected = expectation(description: "Terminal authentication error")
        service.onDisconnected = { _ in rejected.fulfill() }
        transport.emit(["type": "error", "error": ["code": "invalid_api_key", "message": "fixture-key"]])
        await fulfillment(of: [rejected], timeout: 2)
        XCTAssertFalse(service.reconnecting)
        XCTAssertTrue(transport.cancelled)
        XCTAssertEqual(retryWaits, 0)
    }

}

extension RealtimeSessionEngineTests {
    func testContextLanesReachTheWireWithoutCreatingResponses() async throws {
        let transport = FakeRealtimeTransport()
        let service = RealtimeJSONSessionService(transportFactory: { _ in transport })
        defer { service.disconnect() }
        service.configure(model: model("qwen"), systemInstruction: "base instruction")
        transport.onSend = { json in
            if json["type"] as? String == "session.update" { transport.emit(["type": "session.updated"]) }
        }
        transport.emit(["type": "session.created"])
        let connected = await service.connect()
        XCTAssertTrue(connected)
        service.updateContext("old job", key: "job")
        service.updateContext("debrief active", key: "debrief")
        service.updateContext("new job", key: "job")
        let instructions = try XCTUnwrap((transport.sent.last?["session"] as? [String: Any])?["instructions"] as? String)
        XCTAssertTrue(instructions.hasPrefix("base instruction"))
        XCTAssertTrue(instructions.contains("new job")); XCTAssertTrue(instructions.contains("debrief active"))
        XCTAssertFalse(instructions.contains("old job"))
        XCTAssertFalse(transport.sent.contains { $0["type"] as? String == "response.create" })
        XCTAssertNil((transport.sent.last?["session"] as? [String: Any])?["audio"])
    }
    func testDoubaoAnnouncementKeepsContextAndClearsSpeechBusyState() async throws {
        let transport = FakeRealtimeTransport()
        let service = RealtimeJSONSessionService(transportFactory: { _ in transport })
        defer { service.disconnect() }
        service.configure(model: model("doubao"), systemInstruction: "base instruction")
        transport.onSend = { json in
            if json["type"] as? String == "session.create" { transport.emit(["type": "session.created"]) }
        }
        let connected = await service.connect()
        XCTAssertTrue(connected)
        service.speakText("Your report is ready.")
        XCTAssertTrue(service.isModelSpeaking)
        let messages = Array(transport.sent.suffix(3))
        XCTAssertEqual(messages.map { $0["type"] as? String }, ["session.update", "speech_text_buffer.replacement.append", "speech_text_buffer.replacement.commit"])
        let instructions = try XCTUnwrap((messages[0]["session"] as? [String: Any])?["instructions"] as? String)
        XCTAssertTrue(instructions.hasPrefix("base instruction"))
        XCTAssertTrue(instructions.contains("Your report is ready."))
        XCTAssertEqual(messages[1]["text"] as? String, "Your report is ready.")
        transport.emit(["type": "response.output_audio.done"])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(service.isModelSpeaking)
    }
}
