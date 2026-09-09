import AVFoundation
import XCTest
@testable import OpenGlasses

/// Counts every HTTP request that reaches the transport, and answers it locally so nothing is
/// actually sent. Registered for the duration of a canary test only.
///
/// This is the honest way to assert "no bytes left": a guard test that only checks the guard's own
/// return value proves the policy, not the wiring. Here the assertion is made below the service,
/// at the layer `URLSession` hands a request to.
final class EgressCanaryURLProtocol: URLProtocol, @unchecked Sendable {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URL] = []

    static func begin() {
        lock.lock(); requests = []; lock.unlock()
        URLProtocol.registerClass(EgressCanaryURLProtocol.self)
    }

    static func end() {
        URLProtocol.unregisterClass(EgressCanaryURLProtocol.self)
        lock.lock(); requests = []; lock.unlock()
    }

    static var seen: [URL] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        if let url = request.url { requests.append(url) }
        lock.unlock()
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

/// Roadmap W04.2 — the synthetic canary.
///
/// Each probe drives a guarded service through its real request-construction point twice: once
/// with medical local-only on, asserting the transport saw nothing, and once with it off,
/// asserting the same drive does reach the transport. The second half is what stops a probe from
/// passing because the service was broken rather than because the guard worked.
@MainActor
final class MedicalEgressCanaryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        EgressCanaryURLProtocol.begin()
    }

    override func tearDown() {
        EgressCanaryURLProtocol.end()
        MedicalEgressGuard.currentMode = Self.liveMode
        super.tearDown()
    }

    private static let liveMode: () -> MedicalEgressGuard.Mode = {
        MedicalEgressGuard.Mode(hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly)
    }

    private func setMode(_ mode: MedicalEgressGuard.Mode) {
        MedicalEgressGuard.currentMode = { mode }
    }

    // MARK: - Speech to text

    func testDeepgramBatchUploadNeverReachesTheTransportInLocalOnly() async {
        let service = DeepgramBatchService()
        let url = URL(string: "https://api.deepgram.com/v1/listen")!
        let audio = Data(repeating: 0x41, count: 512)

        setMode(.localOnly)
        do {
            _ = try await service.diarize(audioData: audio, mimeType: "audio/m4a", key: "k", url: url)
            XCTFail("the upload was allowed in local-only mode")
        } catch let refusal as MedicalEgressRefusal {
            XCTAssertEqual(refusal.route, .deepgramBatchTranscription)
        } catch {
            XCTFail("expected a MedicalEgressRefusal, got \(error)")
        }
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [], "audio reached the transport")

        setMode(.off)
        _ = try? await service.diarize(audioData: audio, mimeType: "audio/m4a", key: "k", url: url)
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [url],
                       "with the guard off the same drive must reach the transport")
    }

    /// The live socket is a `URLSessionWebSocketTask`, which no `URLProtocol` sees, so the probe
    /// asserts on the service's own connection state: `connected` is set on the line after the
    /// socket is built, so never reaching it is the same claim.
    func testDeepgramLiveSocketIsNeverBuiltInLocalOnly() {
        let service = DeepgramSTTService()
        service.isConfigured = { true }   // bypass the opt-in gate; the medical rule is the subject

        setMode(.localOnly)
        service.start()
        service.sendAudio(Self.silentBuffer())
        XCTAssertNotEqual(service.state, .connected, "the diarization socket opened in local-only mode")
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])
        service.stop()
    }

    // MARK: - Text to speech

    func testElevenLabsSynthesisNeverReachesTheTransportInLocalOnly() async {
        let service = TextToSpeechService()

        setMode(.localOnly)
        do {
            try await service.speakWithElevenLabs(text: "vitals are stable", apiKey: "canary-key")
            XCTFail("the synthesis request was allowed in local-only mode")
        } catch let refusal as MedicalEgressRefusal {
            XCTAssertEqual(refusal.route, .elevenLabsSpeechSynthesis)
        } catch {
            XCTFail("expected a MedicalEgressRefusal, got \(error)")
        }
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [], "reply text reached the transport")

        setMode(.off)
        try? await service.speakWithElevenLabs(text: "vitals are stable", apiKey: "canary-key")
        XCTAssertEqual(EgressCanaryURLProtocol.seen.count, 1,
                       "with the guard off the same drive must reach the transport")
        XCTAssertEqual(EgressCanaryURLProtocol.seen.first?.host, "api.elevenlabs.io")
    }

    func testElevenLabsVoiceCatalogNeverReachesTheTransportInLocalOnly() async {
        setMode(.localOnly)
        do {
            _ = try await TextToSpeechService.fetchElevenLabsVoices(apiKey: "canary-key")
            XCTFail("the voice catalog request was allowed in local-only mode")
        } catch let refusal as MedicalEgressRefusal {
            XCTAssertEqual(refusal.route, .elevenLabsVoiceCatalog)
        } catch {
            XCTFail("expected a MedicalEgressRefusal, got \(error)")
        }
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])

        setMode(.off)
        _ = try? await TextToSpeechService.fetchElevenLabsVoices(apiKey: "canary-key")
        XCTAssertEqual(EgressCanaryURLProtocol.seen.count, 1)
    }

    // MARK: - Realtime

    /// The realtime sessions are websockets, so the probe asserts on the two things that are
    /// observable without a socket: `connect()` reports failure, and its state carries the mode's
    /// message rather than a network error. Nothing reaches the transport either way.
    func testOpenAIRealtimeRefusesToConnectInLocalOnly() async {
        let service = OpenAIRealtimeService()
        service.configure(apiKey: "canary-key", model: "gpt-realtime", systemInstruction: "")

        setMode(.localOnly)
        let connected = await service.connect()
        XCTAssertFalse(connected)
        XCTAssertEqual(service.connectionState, .error(MedicalEgressRefusal.userMessage))
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])
    }

    func testGeminiLiveRefusesToConnectInLocalOnly() async {
        let service = GeminiLiveService()

        setMode(.localOnly)
        let connected = await service.connect()
        XCTAssertFalse(connected)
        XCTAssertEqual(service.connectionState, .error(MedicalEgressRefusal.userMessage))
        // The model catalog is fetched inside connect(); refusing early must skip it too.
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])
    }

    func testGeminiModelCatalogNeverReachesTheTransportInLocalOnly() async {
        setMode(.localOnly)
        let models = await GeminiLiveModelCatalog().liveModels(apiKey: "canary-key")
        XCTAssertEqual(models, [])
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])
    }

    // MARK: - Translation

    func testCloudTranslationRefusesToStartInLocalOnly() {
        let provider = GeminiTranslationProvider()
        provider.isConfigured = { true }   // bypass the opt-in; the medical rule is the subject

        setMode(.localOnly)
        XCTAssertThrowsError(try provider.start(direction: .oneWay(target: "es"))) { error in
            XCTAssertEqual((error as? MedicalEgressRefusal)?.route, .cloudTranslationCaptions)
        }
        provider.sendAudio(Self.silentBuffer())
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])
    }

    // MARK: - Model reasoning

    func testProviderModelCatalogNeverReachesTheTransportInLocalOnly() async {
        setMode(.localOnly)
        let models = await ModelFetcher.fetchModels(provider: .openai, apiKey: "canary-key",
                                                    baseURL: "https://api.openai.com/v1")
        XCTAssertEqual(models.count, 0)
        let test = await ModelFetcher.testConnection(provider: .openai, apiKey: "canary-key",
                                                     baseURL: "https://api.openai.com/v1")
        XCTAssertEqual(test, .unreachable(MedicalEgressRefusal.userMessage))
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])

        setMode(.off)
        _ = await ModelFetcher.fetchModels(provider: .openai, apiKey: "canary-key",
                                           baseURL: "https://api.openai.com/v1")
        XCTAssertFalse(EgressCanaryURLProtocol.seen.isEmpty,
                       "with the guard off the same drive must reach the transport")
    }

    /// Inference keeps its own message — the wearer is being told which *model* can serve them,
    /// not that a feature is off — but the decision now comes from the shared guard.
    func testRemoteInferenceStillRefusesThroughTheSharedGuard() async {
        let service = LLMService()
        setMode(.localOnly)
        do {
            _ = try await service.sendAnthropic("patient vitals are stable", systemPrompt: "",
                                                config: Self.cloudConfig(), includeTools: false,
                                                imageData: nil)
            XCTFail("a cloud model served a request in local-only mode")
        } catch {
            XCTAssertTrue("\(error)".contains("on-device"), "unexpected error: \(error)")
        }
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])
    }

    // MARK: - Tools

    /// One drive per tool, through `execute` — the surface the model actually reaches — asserting
    /// the transport saw nothing and the wearer got a sentence rather than an empty result.
    func testNoNativeToolReachesTheTransportInLocalOnly() async throws {
        setMode(.localOnly)

        let webSearch = try await WebSearchTool().execute(args: ["query": "chest pain protocol"])
        XCTAssertTrue(webSearch.contains("Cloud search is unavailable"), webSearch)

        let weather = try await WeatherTool(locationService: LocationService()).execute(args: [:])
        XCTAssertEqual(weather, MedicalEgressRefusal.userMessage)

        let news = try await NewsTool().execute(args: ["topic": "cardiology"])
        XCTAssertEqual(news, MedicalEgressRefusal.userMessage)

        let currency = try await CurrencyTool().execute(args: ["amount": 10, "from": "USD", "to": "NZD"])
        XCTAssertEqual(currency, MedicalEgressRefusal.userMessage)

        let aircraft = try await AircraftOverheadTool(locationService: LocationService()).execute(args: [:])
        XCTAssertEqual(aircraft, MedicalEgressRefusal.userMessage)

        let home = try await HomeAssistantTool().execute(args: ["action": "list"])
        XCTAssertEqual(home, MedicalEgressRefusal.userMessage)

        let skills = try await OpenClawSkillsTool().execute(args: ["action": "list"])
        XCTAssertEqual(skills, MedicalEgressRefusal.userMessage)

        XCTAssertEqual(EgressCanaryURLProtocol.seen, [], "a native tool reached the transport")
    }

    /// The counterpart: with the mode off, the same drive must reach the transport. Without this
    /// half a tool that is simply broken would pass the probe above.
    ///
    /// **Known limitation:** `URLProtocol.registerClass` reaches `URLSession.shared` but not a
    /// session built from a freshly constructed configuration, so the tools that make their own
    /// session (news, currency, Home Assistant, the web-search providers) are covered above by
    /// their refusal text rather than by the counter. The AED lookup runs on the shared session,
    /// so it carries the "the drive really does reach the wire" half for this group.
    func testTheSameToolDriveReachesTheTransportWithTheGuardOff() async {
        setMode(.off)
        _ = try? await AEDFinder().nearestAED(latitude: -41.29, longitude: 174.78)
        XCTAssertEqual(EgressCanaryURLProtocol.seen.count, 1)
        XCTAssertEqual(EgressCanaryURLProtocol.seen.first?.host, "overpass-api.de")
    }

    func testAEDLookupRefusesRatherThanPinningTheWearerOnAPublicMap() async {
        setMode(.localOnly)
        do {
            _ = try await AEDFinder().nearestAED(latitude: -41.29, longitude: 174.78)
            XCTFail("the wearer's coordinates went to a public directory in local-only mode")
        } catch let refusal as MedicalEgressRefusal {
            XCTAssertEqual(refusal.route, .aedDirectory)
        } catch {
            XCTFail("expected a MedicalEgressRefusal, got \(error)")
        }
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])
    }

    // MARK: - Gateways, bridges and sinks

    /// The gateway socket is reached through an injectable factory, which makes the strongest
    /// assertion available anywhere in this file: the factory is never called, so no socket
    /// object is even constructed.
    func testTheGatewayEventSocketIsNeverEvenConstructedInLocalOnly() {
        var factoryCalls = 0
        let client = OpenClawEventClient(socketFactory: { _ in
            factoryCalls += 1
            return NeverSpeakingSocket()
        })

        setMode(.localOnly)
        client.connect()
        XCTAssertEqual(factoryCalls, 0, "a gateway socket was created in local-only mode")
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])
    }

    func testTheExpertWebhookIsNeverPOSTedInLocalOnly() async throws {
        setMode(.localOnly)
        let notified = try await WebhookExpertNotifier().notifyExpertPool(
            reason: "needs a second opinion", assetId: nil, sessionId: "s-1", roomURL: nil)
        XCTAssertFalse(notified)
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])
    }

    /// A queued work record can carry a clinical fact, so the flush must not drain in local-only
    /// mode — and it must report a *transient* outcome so the record stays queued for later.
    func testQueuedRecordsAreNotFlushedInLocalOnly() async {
        let sink = EndpointSyncSink(fallback: RefusingSink(),
                                    endpoint: { URL(string: "https://ops.example.com/job-reports") },
                                    token: { "tok" })
        setMode(.localOnly)
        let outcome = await sink.deliver(QueuedOp.make(partsRequest: Self.partsRequest(),
                                                       sessionId: "s-1"))
        guard case .transient = outcome else {
            return XCTFail("a queued record was dropped or delivered instead of held: \(outcome)")
        }
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])
    }

    func testACustomAgentHarnessIsNotDispatchedInLocalOnly() async {
        var config = CustomHarnessConfig()
        config.startURL = "https://agent.example.com/start"
        config.statusURLTemplate = "https://agent.example.com/runs/{id}"
        let harness = CustomAgentHarness(config: config)

        setMode(.localOnly)
        do {
            _ = try await harness.start(prompt: "summarise the visit", project: nil)
            XCTFail("an agent run was dispatched in local-only mode")
        } catch let refusal as MedicalEgressRefusal {
            XCTAssertEqual(refusal.route, .customAgentHarness)
        } catch {
            XCTFail("expected a MedicalEgressRefusal, got \(error)")
        }
        XCTAssertEqual(EgressCanaryURLProtocol.seen, [])
    }

    // MARK: - Helpers

    private static func partsRequest() -> PartsRequest {
        PartsRequest(id: "req-1",
                     part: TaskPart(number: "14T65", partDescription: "Pressure switch",
                                    verified: true, page: nil),
                     quantity: 2)
    }

    private static func cloudConfig() -> ModelConfig {
        ModelConfig(id: "canary", name: "canary", provider: LLMProvider.anthropic.rawValue,
                    apiKey: "canary-key", model: "claude-test", baseURL: "")
    }

    private static func silentBuffer(sampleRate: Double = 16_000, frames: AVAudioFrameCount = 160) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }
}

/// A socket that would fail loudly if it were ever used. The canary asserts it is never made.
private final class NeverSpeakingSocket: GatewaySocket {
    func send(_ text: String) async throws { XCTFail("a gateway frame was sent in local-only mode") }
    func receive() async throws -> String {
        XCTFail("a gateway socket was read in local-only mode")
        return ""
    }
    func cancel() {}
}

/// A fallback sink that must never be reached: a refused flush is held, not handed on.
private final class RefusingSink: SyncSink {
    func deliver(_ op: QueuedOp) async -> SyncOutcome {
        XCTFail("a refused delivery fell through to the fallback sink")
        return .done
    }
}
