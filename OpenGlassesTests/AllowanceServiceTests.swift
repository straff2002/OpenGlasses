import XCTest
@testable import OpenGlasses

/// Plan NH P1 — the allowance on the turn path and in a Live session, driven by hand: each service
/// is built over its own temporary ledger, its own clock and its own exemption inputs, with its
/// timers off. Nothing here reads StoreKit, the shared service or the glasses SDK.
@MainActor
final class AllowanceServiceTests: XCTestCase {

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private var workspace: URL!
    private var clock: Clock!
    private var inputs: AllowanceExemption.Inputs!
    private var refusals: [AllowanceRefusalSurface] = []

    override func setUp() {
        super.setUp()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllowanceServiceTests_\(UUID().uuidString)", isDirectory: true)
        clock = Clock()
        var metered = AllowanceExemption.Inputs()
        metered.isStoreBuild = true
        inputs = metered
        refusals = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
        RecordingQueueProtocol.reset()
        super.tearDown()
    }

    private func service(used: Int = 0) -> AllowanceService {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let ledger = AssistantTimeLedger(directory: workspace, calendar: { utc })
        let clock = self.clock!
        ledger.add(used, at: clock.now)
        let service = AllowanceService(ledger: ledger, inputs: { [unowned self] in self.inputs },
                                       now: { clock.now }, runsTimers: false)
        service.onRefused = { [unowned self] in self.refusals.append($0) }
        return service
    }

    // MARK: - The turn gate

    func testAnExhaustedTurnIsAnsweredWithTheLineAndOpensTheSheet() {
        let allowance = service(used: 900)
        XCTAssertEqual(allowance.turnOutcome(utterance: "what's the weather"),
                       .answer(DailyAllowancePolicy.exhaustedLine))
        XCTAssertEqual(refusals, [.turn])
    }

    func testFirstAidAtZeroIsNeverRefusedOrCounted() {
        let allowance = service(used: 900)
        XCTAssertEqual(allowance.turnOutcome(utterance: "someone is choking, what do I do"), .proceed)
        allowance.turnBegan(utterance: "someone is choking, what do I do")
        clock.advance(40)
        allowance.turnEnded()
        clock.advance(5)
        allowance.tick()
        XCTAssertEqual(allowance.ledger.secondsUsed(on: clock.now), 900, "an emergency is never counted")
        XCTAssertEqual(refusals, [])
    }

    func testARunningFirstAidSessionIsNeverRefused() {
        inputs.firstAidSessionActive = true
        let allowance = service(used: 900)
        XCTAssertEqual(allowance.turnOutcome(utterance: "next"), .proceed)
    }

    func testTheNoticeComesBelowThreeMinutes() {
        let allowance = service(used: 800)
        XCTAssertEqual(allowance.turnOutcome(utterance: "hello"), .proceedWithNotice(remainingSeconds: 100))
    }

    func testATurnIsChargedFromSendUntilItsReplyIsSpoken() {
        let allowance = service()
        var speaking = false
        allowance.speechIsActive = { speaking }
        XCTAssertEqual(allowance.turnOutcome(utterance: "hello"), .proceed)
        allowance.turnBegan(utterance: "hello")
        clock.advance(8)
        allowance.turnEnded()
        clock.advance(0.5)
        speaking = true
        allowance.speechActivityChanged(true)
        clock.advance(6)
        allowance.tick()
        XCTAssertEqual(allowance.usedTodaySeconds, 0, "still speaking")
        speaking = false
        allowance.speechActivityChanged(false)
        XCTAssertEqual(allowance.usedTodaySeconds, 15)
        XCTAssertEqual(allowance.homeStatus?.remainingSeconds, 885)
    }

    func testATurnThatStartsWithOneSecondLeftFinishes() {
        let allowance = service(used: 899)
        XCTAssertEqual(allowance.turnOutcome(utterance: "plan my week"), .proceedWithNotice(remainingSeconds: 1))
        allowance.turnBegan(utterance: "plan my week")
        // The day runs out while the turn is still going (a Live second elsewhere, say).
        allowance.ledger.add(10, at: clock.now)
        clock.advance(30)
        // The cascade's next attempt and a hop after tools are the same turn: never refused.
        XCTAssertEqual(allowance.turnOutcome(utterance: "plan my week"), .proceed)
        allowance.turnBegan(utterance: "plan my week")
        allowance.turnEnded()
        clock.advance(20)
        allowance.turnEnded()
        clock.advance(2)
        allowance.tick()
        XCTAssertEqual(allowance.ledger.secondsUsed(on: clock.now), 899 + 10 + 50)
        XCTAssertEqual(refusals, [], "the turn finished")
        XCTAssertEqual(allowance.turnOutcome(utterance: "and the week after"),
                       .answer(DailyAllowancePolicy.exhaustedLine), "the next one is refused")
    }

    func testAQuickTurnCountsTheFloor() {
        let allowance = service()
        allowance.turnBegan(utterance: "hi")
        clock.advance(0.4)
        allowance.turnEnded()
        clock.advance(2)
        allowance.tick()
        XCTAssertEqual(allowance.usedTodaySeconds, 5)
    }

    // MARK: - An exempt user

    func testAnExemptUserIsNeverCountedAndNeverSeesACounter() {
        let base = inputs!
        for exempt in [\AllowanceExemption.Inputs.standardActive, \.voiceOverRunning, \.accessibilityModeOn,
                       \.assistiveModeActive, \.fieldAssistGranted, \.organisationProfile] {
            inputs = base
            inputs[keyPath: exempt] = true
            workspace = FileManager.default.temporaryDirectory
                .appendingPathComponent("AllowanceServiceTests_\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: workspace) }
            let allowance = service(used: 900)
            XCTAssertEqual(allowance.turnOutcome(utterance: "hello"), .proceed, "\(exempt)")
            allowance.turnBegan(utterance: "hello")
            clock.advance(30)
            allowance.turnEnded()
            clock.advance(5)
            allowance.tick()
            allowance.refresh()
            XCTAssertNil(allowance.homeStatus, "\(exempt): no counter")
            XCTAssertEqual(allowance.ledger.secondsUsed(on: clock.now), 900, "\(exempt): nothing counted")
            XCTAssertNil(allowance.liveConnectRefusal(), "\(exempt)")
        }
        XCTAssertEqual(refusals, [])
    }

    func testATestBuildIsUnmeteredUntilTheDeveloperSettingIsOn() {
        inputs.isStoreBuild = false
        let allowance = service(used: 900)
        XCTAssertEqual(allowance.turnOutcome(utterance: "hello"), .proceed)
        inputs.meterAsStoreBuild = true
        XCTAssertEqual(allowance.turnOutcome(utterance: "hello"), .answer(DailyAllowancePolicy.exhaustedLine))
    }

    func testSubscribingLiftsTheLimitAtOnce() {
        let allowance = service(used: 900)
        XCTAssertNotNil(allowance.homeStatus)
        inputs.standardActive = true
        allowance.refresh()
        XCTAssertNil(allowance.homeStatus)
        XCTAssertEqual(allowance.turnOutcome(utterance: "hello"), .proceed)
    }

    // MARK: - Live

    private final class LiveProbe {
        var connected = true
        var answering = false
        var warnings: [String] = []
        var closes: [String] = []
    }

    private func startLive(_ allowance: AllowanceService, probe: LiveProbe) {
        allowance.startLiveMeter(.init(
            isConnected: { probe.connected },
            answerInProgress: { probe.answering },
            warn: { probe.warnings.append($0) },
            close: { probe.closes.append($0) }))
    }

    func testALiveSessionAtZeroClosesAfterItsGrace() {
        let allowance = service(used: 880)
        let probe = LiveProbe()
        probe.answering = true
        startLive(allowance, probe: probe)
        for _ in 0..<20 { clock.advance(1); allowance.liveTick() }
        XCTAssertEqual(allowance.ledger.secondsUsed(on: clock.now), 900)
        XCTAssertEqual(probe.warnings, [DailyAllowancePolicy.liveWarningLine], "one warning")
        XCTAssertTrue(probe.closes.isEmpty, "the answer under way finishes")
        XCTAssertNil(allowance.liveConnectRefusal(), "a metered session may reconnect in its grace")
        for _ in 0..<59 { clock.advance(1); allowance.liveTick() }
        XCTAssertTrue(probe.closes.isEmpty, "59 seconds after zero")
        clock.advance(1)
        allowance.liveTick()
        XCTAssertEqual(probe.closes, [DailyAllowancePolicy.exhaustedLine])
        XCTAssertFalse(allowance.isLiveMetered)
        XCTAssertEqual(refusals, [.live])
        XCTAssertEqual(allowance.liveConnectRefusal(), DailyAllowancePolicy.exhaustedLine,
                       "no new session today")
    }

    func testALiveSessionAtZeroClosesWhenItsAnswerFinishes() {
        let allowance = service(used: 895)
        let probe = LiveProbe()
        probe.answering = true
        startLive(allowance, probe: probe)
        for _ in 0..<5 { clock.advance(1); allowance.liveTick() }
        XCTAssertTrue(probe.closes.isEmpty)
        probe.answering = false
        clock.advance(1)
        allowance.liveTick()
        XCTAssertEqual(probe.closes.count, 1)
        XCTAssertEqual(probe.warnings.count, 1)
    }

    func testOnlyConnectedSecondsCount() {
        let allowance = service()
        let probe = LiveProbe()
        startLive(allowance, probe: probe)
        for _ in 0..<10 { clock.advance(1); allowance.liveTick() }
        probe.connected = false
        for _ in 0..<10 { clock.advance(1); allowance.liveTick() }
        allowance.stopLiveMeter()
        XCTAssertEqual(allowance.ledger.secondsUsed(on: clock.now), 10)
        XCTAssertTrue(probe.warnings.isEmpty)
    }

    func testAnExemptLiveSessionIsNeverCountedOrClosed() {
        inputs.voiceOverRunning = true
        let allowance = service(used: 900)
        XCTAssertNil(allowance.liveConnectRefusal())
        let probe = LiveProbe()
        startLive(allowance, probe: probe)
        for _ in 0..<120 { clock.advance(1); allowance.liveTick() }
        XCTAssertTrue(probe.closes.isEmpty)
        XCTAssertTrue(probe.warnings.isEmpty)
        XCTAssertEqual(allowance.ledger.secondsUsed(on: clock.now), 900)
        allowance.stopLiveMeter()
    }

    func testALiveSessionCannotStartAtZero() {
        let allowance = service(used: 900)
        XCTAssertEqual(allowance.liveConnectRefusal(), DailyAllowancePolicy.exhaustedLine)
        XCTAssertEqual(refusals, [.live])
    }

    // MARK: - The gate in LLMService

    private func llm(_ allowance: AllowanceService) -> LLMService {
        let service = LLMService()
        service.processingConsent = CloudConsentFixture.conversation()
        let session = RecordingQueueProtocol.session()
        service.streamingSession = session
        service.dataSession = session
        service.allowance = allowance
        return service
    }

    /// The stub transport records what a provider path sends, so the control proves it would see an
    /// exhausted turn if one slipped through.
    func testTheGateNeverSendsAnExhaustedTurn() async throws {
        RecordingQueueProtocol.reset()
        let allowance = service(used: 900)
        let llm = llm(allowance)

        let config = ModelConfig(id: "nh", name: "nh", provider: LLMProvider.anthropic.rawValue,
                                 apiKey: "test", model: "claude-sonnet-5-5", baseURL: "https://api.test",
                                 reasoningEffort: nil)
        RecordingQueueProtocol.queue = [(200, #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#)]
        _ = try? await llm.sendAnthropic("control", systemPrompt: "sys", config: config, includeTools: false,
                                         imageData: nil)
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1, "control: the stub sees a request that is sent")

        RecordingQueueProtocol.reset()
        RecordingQueueProtocol.queue = [(200, #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#)]
        let reply = try await llm.sendMessage("what's the weather")
        XCTAssertEqual(reply, DailyAllowancePolicy.exhaustedLine)
        let cascaded = try await llm.sendMessageCascading("and tomorrow")
        XCTAssertEqual(cascaded, DailyAllowancePolicy.exhaustedLine)
        XCTAssertTrue(RecordingQueueProtocol.requests.isEmpty, "an exhausted turn reached a model")
        XCTAssertEqual(llm.allowanceOutcome(utterance: "hello"), .answer(DailyAllowancePolicy.exhaustedLine))
        XCTAssertEqual(allowance.ledger.secondsUsed(on: clock.now), 900, "a refused turn costs nothing")
        XCTAssertFalse(llm.isProcessing)
    }

    func testWithNoAllowanceTheGateIsOpen() {
        let llm = LLMService()
        XCTAssertEqual(llm.allowanceOutcome(utterance: "hello"), .proceed)
    }
}
