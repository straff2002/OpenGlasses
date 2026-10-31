import XCTest
@testable import OpenGlasses

/// Plan HY P1 — ending a live session nobody is using: the pure decision, the clock that feeds it,
/// the setting, the words, and one session manager ending itself through the real `stopSession`.
final class LiveIdlePolicyTests: XCTestCase {

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let policy = LiveIdlePolicy()   // 10 minutes, 30 s lead

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    // MARK: - The decision

    func testDefaultsAreTenMinutesWithAThirtySecondLead() {
        XCTAssertEqual(policy.idleLimit, 600)
        XCTAssertEqual(policy.warningLead, 30)
        XCTAssertEqual(policy.idleMinutes, 10)
    }

    func testWarnsAtTheLimitMinusTheLead() {
        XCTAssertEqual(policy.decide(lastActivity: start, warned: false, now: at(569.9)), .none)
        XCTAssertEqual(policy.decide(lastActivity: start, warned: false, now: at(570)), .warn)
        XCTAssertEqual(policy.decide(lastActivity: start, warned: false, now: at(599)), .warn)
    }

    func testEndsAtTheLimit() {
        XCTAssertEqual(policy.decide(lastActivity: start, warned: true, now: at(599.9)), .none)
        XCTAssertEqual(policy.decide(lastActivity: start, warned: true, now: at(600)), .end)
        XCTAssertEqual(policy.decide(lastActivity: start, warned: true, now: at(3600)), .end)
    }

    /// A clock that slept through the warning window does not hold the session open another thirty
    /// seconds to announce a limit that has already passed.
    func testTheEndWinsEvenWhenTheWarningWasMissed() {
        XCTAssertEqual(policy.decide(lastActivity: start, warned: false, now: at(601)), .end)
    }

    func testOnceWarnedTheWindowIsQuietUntilTheEnd() {
        XCTAssertEqual(policy.decide(lastActivity: start, warned: true, now: at(580)), .none)
    }

    func testTheLimitFollowsTheConfiguredMinutes() throws {
        let five = try XCTUnwrap(LiveIdlePolicy.configured(minutes: 5))
        XCTAssertEqual(five.idleLimit, 300)
        XCTAssertEqual(five.decide(lastActivity: start, warned: false, now: at(270)), .warn)
        XCTAssertEqual(five.decide(lastActivity: start, warned: true, now: at(300)), .end)
        XCTAssertNil(LiveIdlePolicy.configured(minutes: 0), "Off times nothing")
    }

    // MARK: - The clock

    @MainActor
    private func makeClock(_ now: @escaping () -> Date) -> LiveIdleClock {
        let clock = LiveIdleClock()
        clock.runsTickLoop = false
        clock.now = now
        return clock
    }

    @MainActor
    func testWarningIsSaidOnceAndTheEndFollows() {
        var now = start
        let clock = makeClock { now }
        var warnings = 0
        var ends = 0
        clock.onWarn = { warnings += 1 }
        clock.onEnd = { ends += 1 }
        clock.start(policy: policy)

        for second in stride(from: 570.0, to: 600, by: 5) {
            now = at(second)
            clock.tick()
        }
        XCTAssertEqual(warnings, 1, "one warning per quiet spell, however many ticks land in it")
        XCTAssertEqual(ends, 0)

        now = at(600)
        XCTAssertEqual(clock.tick(), .end)
        XCTAssertEqual(ends, 1)
        XCTAssertFalse(clock.isRunning, "the clock stops itself at the end")
        now = at(700)
        XCTAssertEqual(clock.tick(), .none)
        XCTAssertEqual(ends, 1, "an end is reported once")
    }

    @MainActor
    func testActivityResetsTheSpellAndTheWarning() {
        var now = start
        let clock = makeClock { now }
        var warnings = 0
        var ends = 0
        clock.onWarn = { warnings += 1 }
        clock.onEnd = { ends += 1 }
        clock.start(policy: policy)

        now = at(575)
        clock.tick()
        XCTAssertEqual(warnings, 1)

        // The wearer answers the warning.
        now = at(580)
        clock.noteActivity()
        now = at(600)
        XCTAssertEqual(clock.tick(), .none, "the old deadline no longer applies")
        XCTAssertEqual(ends, 0)

        // A second quiet spell is warned about again — once.
        now = at(580 + 570)
        clock.tick()
        now = at(580 + 590)
        clock.tick()
        XCTAssertEqual(warnings, 2)
        now = at(580 + 600)
        XCTAssertEqual(clock.tick(), .end)
        XCTAssertEqual(ends, 1)
    }

    /// Model speech never reaches the clock: the session can talk for as long as it likes to an
    /// empty room, and it still ends. Here the "talking" is the passage of time with no wearer call.
    @MainActor
    func testWithoutTheWearerTheSessionEndsWhateverTheModelSays() {
        var now = start
        let clock = makeClock { now }
        var ended = false
        clock.onEnd = { ended = true }
        clock.start(policy: policy)
        for second in stride(from: 5.0, through: 600, by: 5) {
            now = at(second)
            clock.tick()
        }
        XCTAssertTrue(ended)
    }

    @MainActor
    func testOffNeverEnds() {
        var now = start
        let clock = makeClock { now }
        var ended = false
        clock.onEnd = { ended = true }
        clock.start(policy: nil)
        XCTAssertFalse(clock.isRunning)
        now = at(86_400)
        XCTAssertEqual(clock.tick(), .none)
        clock.noteActivity()
        XCTAssertFalse(ended)
    }

    @MainActor
    func testActivityBeforeAStartIsIgnored() {
        let clock = makeClock { self.start }
        clock.noteActivity()
        XCTAssertNil(clock.lastActivity)
    }

    // MARK: - Speech counts once it is answered

    @MainActor
    func testSpeechAloneDoesNotHoldTheSessionOpen() {
        var now = start
        let clock = makeClock { now }
        clock.start(policy: policy)
        for second in stride(from: 60.0, through: 590, by: 60) {
            now = at(second)
            clock.noteSpeechHeard()
        }
        XCTAssertEqual(clock.lastActivity, start, "a TV on in the room is not the wearer")
        now = at(620)
        XCTAssertEqual(clock.tick(), .end)
    }

    @MainActor
    func testAnsweredSpeechCounts() {
        var now = start
        let clock = makeClock { now }
        clock.start(policy: policy)
        now = at(500)
        clock.noteSpeechHeard()
        now = at(502)
        clock.noteModelReplied()
        XCTAssertEqual(clock.lastActivity, at(502))
        XCTAssertNil(clock.unansweredSpeech)
    }

    @MainActor
    func testModelSpeechWithNothingToAnswerCountsForNothing() {
        var now = start
        let clock = makeClock { now }
        clock.start(policy: policy)
        now = at(500)
        clock.noteModelReplied()
        XCTAssertEqual(clock.lastActivity, start)
    }

    @MainActor
    func testAToolCallAnswersTheSpeechBeforeIt() {
        var now = start
        let clock = makeClock { now }
        clock.start(policy: policy)
        now = at(500)
        clock.noteSpeechHeard()
        now = at(501)
        clock.noteActivity()
        XCTAssertNil(clock.unansweredSpeech)
        XCTAssertEqual(clock.lastActivity, at(501))
    }

    func testTheLimitWaitsForSomeoneMidSentence() {
        XCTAssertEqual(policy.decide(lastActivity: start, warned: true, now: at(600),
                                     unansweredSpeech: at(597)), .none)
    }

    func testThatWaitIsBoundedSoATVCannotHoldItOpen() {
        XCTAssertEqual(policy.decide(lastActivity: start, warned: true, now: at(615),
                                     unansweredSpeech: at(614)), .none)
        XCTAssertEqual(policy.decide(lastActivity: start, warned: true, now: at(620),
                                     unansweredSpeech: at(619)), .end)
    }

    func testOldSpeechDoesNotDelayTheEnd() {
        XCTAssertEqual(policy.decide(lastActivity: start, warned: true, now: at(600),
                                     unansweredSpeech: at(500)), .end)
    }

    @MainActor
    func testAStopForgetsUnansweredSpeech() {
        var now = start
        let clock = makeClock { now }
        clock.start(policy: policy)
        now = at(10)
        clock.noteSpeechHeard()
        clock.stop()
        XCTAssertNil(clock.unansweredSpeech)
    }

    // MARK: - Model speech is not activity (the wiring)

    /// The model's own transcript and audio handlers go through `noteModelReply`, which only
    /// resolves speech already heard, and never touch the clock themselves — read from the source,
    /// because that is the claim.
    func testTheManagerNeverCountsModelSpeech() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/Realtime/RealtimeSessionManager.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        for handler in ["providerSession.onOutputTranscription = {", "providerSession.onAudioReceived = {",
                        "providerSession.onTurnComplete = {"] {
            let start = try XCTUnwrap(text.range(of: handler), handler)
            let rest = text[start.upperBound...]
            let end = rest.range(of: "\n        providerSession.")?.lowerBound
                ?? rest.range(of: "\n        //")?.lowerBound ?? rest.endIndex
            XCTAssertFalse(rest[..<end].contains("idleClock"), "\(handler) must not count as activity")
        }
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "self.idleClock.noteActivity()").count - 1, 2,
                                    "tool call and result")
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: "self.idleClock.noteSpeechHeard()").count - 1, 3,
                                    "speech, speech-start, VAD barge-in")
    }

    // MARK: - The setting

    func testIdleMinutesDefaultsToTenAndClampsIntoTheStepper() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Config.liveIdleMinutesKey)
        defer { defaults.set(previous, forKey: Config.liveIdleMinutesKey) }

        defaults.removeObject(forKey: Config.liveIdleMinutesKey)
        XCTAssertEqual(Config.liveIdleMinutes, 10)
        Config.liveIdleMinutes = 0
        XCTAssertEqual(Config.liveIdleMinutes, 0, "Off")
        Config.liveIdleMinutes = 2
        XCTAssertEqual(Config.liveIdleMinutes, 5)
        Config.liveIdleMinutes = 90
        XCTAssertEqual(Config.liveIdleMinutes, 60)
        defaults.set(-3, forKey: Config.liveIdleMinutesKey)
        XCTAssertEqual(Config.liveIdleMinutes, 0)
        defaults.set(25, forKey: Config.liveIdleMinutesKey)
        XCTAssertEqual(Config.liveIdleMinutes, 25)
    }

    // MARK: - The words

    func testTheWarningLine() {
        XCTAssertEqual(LiveIdlePolicy.warningLine,
                       "I'll end this session in 30 seconds unless you say something.")
        XCTAssertTrue(LiveIdlePolicy.warningInstruction.contains(LiveIdlePolicy.warningLine))
        XCTAssertTrue(LiveIdlePolicy.warningInstruction.contains("say nothing else"))
    }

    func testTheStatusCardSaysWhyAndUsesTheConfiguredMinutes() {
        XCTAssertEqual(LiveSessionEndReason.idleEnded(minutes: 10).notice,
                       "Session ended after 10 minutes without activity")
        XCTAssertEqual(LiveSessionEndReason.idleEnded(minutes: 25).notice,
                       "Session ended after 25 minutes without activity")
        XCTAssertNil(LiveSessionEndReason.stopped.notice, "an ordinary stop explains nothing")
        XCTAssertNil(LiveSessionEndReason.cardNotice(sessionActive: true, reason: .idleEnded(minutes: 10)),
                     "a running session has nothing to explain")
        XCTAssertEqual(LiveSessionEndReason.cardNotice(sessionActive: false, reason: .idleEnded(minutes: 10)),
                       "Session ended after 10 minutes without activity")
        XCTAssertNil(LiveSessionEndReason.cardNotice(sessionActive: false, reason: nil))
    }

    func testTheSettingValue() {
        XCTAssertEqual(LiveIdlePolicy.settingValue(minutes: 0), "Off")
        XCTAssertEqual(LiveIdlePolicy.settingValue(minutes: 10), "After 10 min")
        XCTAssertEqual(LiveIdlePolicy.spokenSettingValue(minutes: 10), "After 10 minutes")
    }
}

/// Plan HY P1 — a realtime manager ending itself: the warning through its own voice seam, then
/// `stopSession(reason: .idleEnded)`, with the reason kept for the status card. Driven through the
/// startup's own seam (`onWillConnect`), which holds a real session open without a socket.
final class LiveIdleSessionManagerTests: XCTestCase {

    private func configuration() -> RealtimeConnectionConfiguration {
        RealtimeConnectionConfiguration(endpoint: "wss://gateway.example/realtime",
                                        apiKey: "gateway-key", model: "custom-model")
    }

    @MainActor
    func testAnIdleSessionWarnsOnceThenStopsWithTheIdleReason() async throws {
        let key = "compatibleRealtimeConfiguration"
        let previous = KeychainService.data(for: key)
        let previousMode = Config.appMode
        let previousMedicalMode = MedicalEgressGuard.currentMode
        let previousMinutes = UserDefaults.standard.object(forKey: Config.liveIdleMinutesKey)
        defer {
            KeychainService.setData(previous, for: key)
            Config.setAppMode(previousMode)
            MedicalEgressGuard.currentMode = previousMedicalMode
            UserDefaults.standard.set(previousMinutes, forKey: Config.liveIdleMinutesKey)
        }
        MedicalEgressGuard.currentMode = { .off }
        XCTAssertTrue(Config.setCompatibleRealtimeConfiguration(configuration()))
        Config.setAppMode(.openaiCompatibleRealtime)
        Config.liveIdleMinutes = 10

        let manager = OpenAIRealtimeSessionManager()
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        manager.idleClock.runsTickLoop = false
        manager.idleClock.now = { now }
        var spoken: [String] = []
        manager.idleWarningSpeaker = { spoken.append($0) }
        var cameraStops = 0
        manager.onRequestStopCamera = { cameraStops += 1 }

        let cue = expectation(description: "The startup is holding on its cue")
        var release: CheckedContinuation<Void, Never>?
        manager.onWillConnect = {
            await withCheckedContinuation { continuation in
                release = continuation
                cue.fulfill()
            }
        }
        let startup = Task { await manager.startSession() }
        await fulfillment(of: [cue], timeout: 2)
        XCTAssertTrue(manager.isActive)
        XCTAssertNil(manager.endReason)
        XCTAssertTrue(manager.idleClock.isRunning)

        // The wearer touches a control at four minutes; the spell restarts from there.
        now = now.addingTimeInterval(240)
        manager.noteWearerActivity()
        let lastActivity = now

        now = lastActivity.addingTimeInterval(570)
        manager.idleClock.tick()
        now = lastActivity.addingTimeInterval(585)
        manager.idleClock.tick()
        XCTAssertEqual(spoken, [LiveIdlePolicy.warningLine], "the warning, once")
        XCTAssertTrue(manager.isActive)

        now = lastActivity.addingTimeInterval(600)
        manager.idleClock.tick()
        XCTAssertFalse(manager.isActive, "the session ended itself")
        XCTAssertEqual(manager.endReason, .idleEnded(minutes: 10))
        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertFalse(manager.idleClock.isRunning)
        XCTAssertEqual(LiveSessionEndReason.cardNotice(sessionActive: manager.isActive,
                                                       reason: manager.endReason),
                       "Session ended after 10 minutes without activity")

        release?.resume()
        await startup.value
        XCTAssertFalse(manager.isActive, "the held startup does not bring the session back")
        XCTAssertEqual(spoken.count, 1)
        XCTAssertEqual(cameraStops, 0, "no camera was claimed, so none is given back")
    }

    @MainActor
    func testAnOrdinaryStopIsNotAnIdleEnd() async throws {
        let key = "compatibleRealtimeConfiguration"
        let previous = KeychainService.data(for: key)
        let previousMode = Config.appMode
        let previousMedicalMode = MedicalEgressGuard.currentMode
        defer {
            KeychainService.setData(previous, for: key)
            Config.setAppMode(previousMode)
            MedicalEgressGuard.currentMode = previousMedicalMode
        }
        MedicalEgressGuard.currentMode = { .off }
        XCTAssertTrue(Config.setCompatibleRealtimeConfiguration(configuration()))
        Config.setAppMode(.openaiCompatibleRealtime)

        let manager = OpenAIRealtimeSessionManager()
        manager.idleClock.runsTickLoop = false
        let cue = expectation(description: "The startup is holding on its cue")
        var release: CheckedContinuation<Void, Never>?
        manager.onWillConnect = {
            await withCheckedContinuation { continuation in
                release = continuation
                cue.fulfill()
            }
        }
        let startup = Task { await manager.startSession() }
        await fulfillment(of: [cue], timeout: 2)
        manager.stopSession()
        XCTAssertEqual(manager.endReason, .stopped)
        XCTAssertNil(LiveSessionEndReason.cardNotice(sessionActive: false, reason: manager.endReason))
        XCTAssertFalse(manager.idleClock.isRunning, "a stop stops the clock")
        release?.resume()
        await startup.value
    }
}
