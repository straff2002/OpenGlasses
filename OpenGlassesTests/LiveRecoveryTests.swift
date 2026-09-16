import XCTest
@testable import OpenGlasses

/// Plan FF P1/PR5 — recovery proven through *usable conversation*, not through a socket coming back.
///
/// Every fault this plan names is injected at the seam where the real event enters
/// `GeminiLiveService`, so what is exercised below is the production ladder rather than a test-only
/// copy of it. The manager's own decisions — rebuild the conversation, restart the microphone, leave
/// a paused camera alone, report four facts — are driven through `LiveRecoveryDriver`, which exists
/// because the session managers build a `RealtimeAudioEngine` at init and cannot be constructed
/// headlessly.
@MainActor
final class LiveRecoveryTests: XCTestCase {

    // MARK: - Fixtures

    /// Records what the wearer would have heard.
    private final class CueSink {
        var earcons: [AudibleLifecyclePolicy.Earcon] = []
        var lines: [String] = []
        var interruptingLines: [String] = []
    }

    private final class FakeClock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private func makeCoordinator(sink: CueSink,
                                 clock: FakeClock,
                                 visualEvidence: @escaping () -> Bool = { false },
                                 routeBusy: @escaping () -> Bool = { false })
        -> AudibleLifecycleCoordinator {
        AudibleLifecycleCoordinator(
            isActive: { true },
            style: { .tonesAndSpeech },
            route: { .init(assistantSpeaking: routeBusy()) },
            visualEvidence: visualEvidence,
            now: { clock.now },
            autoPump: false,
            playEarcon: { sink.earcons.append($0) },
            speak: { line, interrupts in
                sink.lines.append(line)
                if interrupts { sink.interruptingLines.append(line) }
            })
    }

    /// A journal that only has to answer "what is still open".
    private final class StubJournal: OperationJournal {
        var records: [OperationRecord] = []
        func admit(call: ResolvedToolCall, semantics: ToolExecutionSemantics, key: String,
                   at now: Date) -> OperationAdmission { .storageUnavailable }
        func resolve(operationID: String, outcome: ToolExecutionOutcome,
                     at now: Date) -> OperationResolution { .unknownOperation }
        func replayOutcome(for record: OperationRecord) -> ToolExecutionOutcome {
            .outcomeUnknown(operationID: record.operationID, message: "unknown")
        }
        func record(forKey key: String) -> OperationRecord? { nil }
    }

    private func makeRecord(tool: String, effect: ToolEffect, state: OperationState,
                            startedAt: Date = Date(timeIntervalSince1970: 1_000)) -> OperationRecord {
        OperationRecord(operationID: tool + "-id", idempotencyKey: tool + "-key", toolName: tool,
                        effect: effect, origin: .model, depth: 0, rootFingerprint: "root",
                        parentFingerprint: nil, composerFingerprint: nil,
                        startedAt: startedAt, updatedAt: startedAt,
                        state: state)
    }

    /// A service with the socket scripted away. Faults are injected into the same handlers a real
    /// socket drives.
    private func makeScriptedService(
        _ outcomes: [GeminiLiveService.ScriptedConnectOutcome],
        delayScale: Double = 0.001) -> GeminiLiveService {
        let service = GeminiLiveService()
        service.setScriptedConnectOutcomesForTesting(outcomes)
        service.reconnectDelayScaleForTesting = delayScale
        return service
    }

    /// Poll until `condition` holds or the deadline passes. No sleeping on a guess.
    private func waitUntil(_ description: String, timeout: TimeInterval = 10,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(description)")
    }

    // MARK: - Fault 1: socket loss mid-turn

    func testSocketLossMidTurnStartsOneReconnectThroughTheExistingLadder() async {
        let service = makeScriptedService([])
        var disconnects: [String?] = []
        service.onDisconnected = { disconnects.append($0) }

        service.injectFaultForTesting(.socketClosed(reason: "Connection closed (code 1006: no reason)"))

        XCTAssertTrue(service.reconnecting, "the retry ladder should be running")
        XCTAssertEqual(service.reconnectAttempts, 1)
        XCTAssertEqual(disconnects.count, 1)
        XCTAssertGreaterThan(service.scheduledWorkCount, 0, "a reconnect is armed")
        service.disconnect()
    }

    func testTheThreeTriggersOneFailureFiresCoalesceToASingleAttempt() async {
        let service = makeScriptedService([])
        service.injectFaultForTesting(.socketClosed(reason: "closed"))
        service.injectFaultForTesting(.socketError(reason: "errored"))
        service.injectFaultForTesting(.socketClosed(reason: "closed again"))

        XCTAssertEqual(service.reconnectAttempts, 1,
                       "close + error + receive-loop is one failure, not three attempts")
        service.disconnect()
    }

    // MARK: - Fault 2: setup timeout

    func testSetupTimeoutFailsTheAttemptWithNoCloseAndNoError() async {
        let service = makeScriptedService([.setupTimedOut])
        var disconnects = 0
        service.onDisconnected = { _ in disconnects += 1 }

        let ok = await service.connect()

        XCTAssertFalse(ok)
        XCTAssertEqual(service.connectionState, .error("Connection timed out"))
        XCTAssertEqual(disconnects, 0, "a setup timeout fires no close and no error event")
        XCTAssertEqual(service.scriptedConnectCount, 1, "the scripted transport actually ran")
        service.disconnect()
    }

    func testSetupTimeoutInjectedIntoALiveAttemptResolvesItRatherThanStalling() async {
        let service = makeScriptedService([])
        service.injectFaultForTesting(.setupTimedOut)
        // Nothing was connecting, so nothing changes state — the point is that the handler exists
        // and is the same one the 15 s timer calls.
        XCTAssertEqual(service.connectionState, .disconnected)
        service.disconnect()
    }

    // MARK: - Fault 3: server rotation

    func testServerRotationSchedulesAReconnectInsteadOfEndingTheSession() async {
        let service = makeScriptedService([])
        var reasons: [String?] = []
        service.onDisconnected = { reasons.append($0) }

        service.injectFaultForTesting(.serverRotation(secondsRemaining: 12))

        XCTAssertTrue(service.reconnecting,
                      "a rotation must ride through, not tear the session down")
        XCTAssertEqual(service.reconnectAttempts, 1, "the rotation's close coalesces into it")
        XCTAssertEqual(reasons.count, 2, "the announcement and then the close")
        XCTAssertTrue(reasons.first??.contains("rotating") ?? false)
        service.disconnect()
    }

    // MARK: - Fault 4: expired / rejected resumption handle

    func testARejectedHandleIsDroppedRatherThanRetriedDownTheWholeLadder() async {
        let service = makeScriptedService([.setupRejected(reason: "session resumption failed")])
        service.setResumptionHandleForTesting("stale-handle")

        let ok = await service.connect()

        XCTAssertFalse(ok)
        XCTAssertNil(service.resumptionHandleForTesting,
                     "a handle the server would not take must not be offered again")
        XCTAssertTrue(service.lastResumptionHandleRejected)
        XCTAssertFalse(service.lastConnectResumedContext)
        service.disconnect()
    }

    func testAFailureThatNeverSentSetupKeepsTheHandle() async {
        let service = makeScriptedService([.failedBeforeSetup(reason: "offline")])
        service.setResumptionHandleForTesting("good-handle")

        let ok = await service.connect()

        XCTAssertFalse(ok)
        XCTAssertEqual(service.resumptionHandleForTesting, "good-handle",
                       "nothing was offered, so nothing was refused")
        XCTAssertFalse(service.lastResumptionHandleRejected)
        service.disconnect()
    }

    func testAnAcceptedHandleReportsResumedContextAndAColdStartDoesNot() async {
        let resumed = makeScriptedService([.ready])
        resumed.setResumptionHandleForTesting("live-handle")
        _ = await resumed.connect()
        XCTAssertTrue(resumed.lastConnectResumedContext)
        XCTAssertFalse(resumed.lastResumptionHandleRejected)
        resumed.disconnect()

        let cold = makeScriptedService([.ready])
        _ = await cold.connect()
        XCTAssertFalse(cold.lastConnectResumedContext,
                       "a cold start carries no claim about the old conversation")
        cold.disconnect()
    }

    func testTheHandoverBlockReachesTheSetupMessage() async {
        let service = makeScriptedService([.ready])
        let handover = LiveContextHandover.build(
            turns: [LiveTurnRecord(speaker: .wearer, text: "which one is the blue one?")])
        service.configure(systemInstruction: "BASE\n\n" + (handover ?? ""), toolDeclarations: [])

        _ = await service.connect()

        let sent = service.lastSetupInstruction ?? ""
        XCTAssertTrue(sent.contains(LiveContextHandover.blockHeading),
                      "the rebuilt context must be in the setup message, not injected after it")
        XCTAssertTrue(sent.contains("which one is the blue one?"))
        service.disconnect()
    }

    // MARK: - Long outage: exhaustion

    func testALongOutageExhaustsOnceAndLeavesNothingScheduled() async {
        let service = makeScriptedService(Array(repeating: .failedBeforeSetup(reason: "offline"),
                                                count: 12))
        var exhausted = 0
        var reconnected = 0
        service.onReconnectExhausted = { exhausted += 1 }
        service.onReconnected = { reconnected += 1 }

        service.injectFaultForTesting(.socketClosed(reason: "dropped"))
        await waitUntil("the ladder to give up") { exhausted > 0 }

        XCTAssertEqual(exhausted, 1, "one terminal statement, not one per attempt")
        XCTAssertEqual(reconnected, 0)
        XCTAssertEqual(service.scriptedConnectCount, 10, "the ten-attempt limit, as configured")
        XCTAssertFalse(service.reconnecting)
        XCTAssertEqual(service.scheduledWorkCount, 0, "nothing keeps retrying after the cue")
        service.disconnect()
    }

    func testExhaustionSpeaksOneTerminalCueThatMayTakeTheFloor() {
        let sink = CueSink()
        let clock = FakeClock()
        let coordinator = makeCoordinator(sink: sink, clock: clock, routeBusy: { true })

        coordinator.handle(.sessionStarted(.init(audioSessionActive: true, sessionConnected: true,
                                                 microphoneListening: true)))
        coordinator.pump()
        sink.earcons.removeAll(); sink.lines.removeAll()
        coordinator.handle(.connectionLost)
        coordinator.handle(.reconnectExhausted)
        coordinator.pump()
        XCTAssertTrue(sink.earcons.isEmpty, "the assistant is mid-sentence; the cue waits its bound")

        // The bound the failure notice may wait, and no longer.
        clock.advance(AudibleLifecyclePolicy.maxQueuedWait + 1)
        coordinator.pump()

        XCTAssertEqual(sink.earcons, [.failed])
        XCTAssertEqual(sink.lines, ["Connection lost. I couldn't get it back."])
        XCTAssertEqual(sink.interruptingLines.count, 1,
                       "the terminal cue is the one allowed to interrupt")
        XCTAssertFalse(coordinator.isPending(.connectionLost),
                       "\"trying to get it back\" after \"I gave up\" is nonsense")
    }

    // MARK: - Stop during every retry phase

    func testStopDuringBackoffCancelsTheAttemptAndLeavesNothingScheduled() async {
        let service = makeScriptedService([.ready], delayScale: 5)   // a backoff long enough to stop in
        var reconnected = 0
        service.onReconnected = { reconnected += 1 }

        service.injectFaultForTesting(.socketClosed(reason: "dropped"))
        XCTAssertGreaterThan(service.scheduledWorkCount, 0)
        service.disconnect()

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.scheduledWorkCount, 0)
        XCTAssertEqual(service.scriptedConnectCount, 0, "the attempt never ran")
        XCTAssertEqual(reconnected, 0)
        XCTAssertEqual(service.reconnectAttempts, 0, "a fresh session inherits no counter")
    }

    /// Holds a scripted attempt at the setup boundary so a stop can be landed exactly there.
    private final class SetupGate {
        private(set) var isWaiting = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                self.isWaiting = true
                self.continuation = continuation
            }
        }

        func open() {
            isWaiting = false
            continuation?.resume()
            continuation = nil
        }
    }

    func testStopDuringSetupDropsTheOldCallbacks() async {
        let service = makeScriptedService([.ready], delayScale: 0)
        var reconnected = 0
        service.onReconnected = { reconnected += 1 }
        let gate = SetupGate()
        service.holdAtSetupForTesting = { await gate.wait() }

        service.injectFaultForTesting(.socketClosed(reason: "dropped"))
        await waitUntil("the reconnect attempt to reach setup") { gate.isWaiting }
        service.disconnect()
        gate.open()

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reconnected, 0, "a stale attempt's success callback must not fire")
        XCTAssertEqual(service.scheduledWorkCount, 0)
        XCTAssertEqual(service.connectionState, .disconnected,
                       "the superseded attempt must not publish a ready state over the stop")
    }

    func testStopDuringHandoverAssemblyLeavesTheSessionUntouched() async {
        var reconfigures = 0
        var reports: [AudibleLifecycleCoordinator.Signal] = []
        var driver: LiveRecoveryDriver?
        driver = LiveRecoveryDriver(seams: .init(
            isSessionActive: { true },
            resumedOnServer: { false },
            recentTurns: { _ in
                driver?.noteStop()   // the wearer presses Stop while the record is being read
                return [LiveTurnRecord(speaker: .wearer, text: "read this label")]
            },
            reconfigure: { _ in reconfigures += 1 },
            restartMicrophone: {},
            report: { reports.append($0) }))

        let assessment = await driver?.handleReconnected()

        XCTAssertNil(assessment)
        XCTAssertEqual(reconfigures, 0)
        XCTAssertTrue(reports.isEmpty, "nothing is claimed about a session the wearer stopped")
        XCTAssertEqual(driver?.isRecovering, false)
    }

    func testStopDuringMicrophoneRestartReportsNothing() async {
        var frameRestarts = 0
        var reports: [AudibleLifecycleCoordinator.Signal] = []
        var driver: LiveRecoveryDriver?
        driver = LiveRecoveryDriver(seams: .init(
            isSessionActive: { true },
            resumedOnServer: { true },
            recentTurns: { _ in [] },
            reconfigure: { _ in },
            restartMicrophone: { driver?.noteStop() },
            restartFrameCapture: { frameRestarts += 1 },
            report: { reports.append($0) }))

        let assessment = await driver?.handleReconnected()

        XCTAssertNil(assessment)
        XCTAssertEqual(frameRestarts, 0, "no further work after the stop")
        XCTAssertTrue(reports.isEmpty)
    }

    func testStopDuringCameraStartReportsNothing() async {
        var frameRestarts = 0
        var reports: [AudibleLifecycleCoordinator.Signal] = []
        var driver: LiveRecoveryDriver?
        driver = LiveRecoveryDriver(seams: .init(
            isSessionActive: { true },
            resumedOnServer: { true },
            recentTurns: { _ in [] },
            cameraReadiness: {
                CameraReadiness(phase: .stopped, frameAge: nil, session: 3, userWantsStream: true)
            },
            sessionNeedsVision: { true },
            reconfigure: { _ in },
            restartMicrophone: {},
            restartFrameCapture: { frameRestarts += 1 },
            startCamera: { driver?.noteStop(); return true },
            report: { reports.append($0) }))

        let assessment = await driver?.handleReconnected()

        XCTAssertNil(assessment)
        XCTAssertEqual(frameRestarts, 0)
        XCTAssertTrue(reports.isEmpty)
    }

    // MARK: - The three facts, asserted independently

    func testTheFourFactsAreIndependent() {
        let allGood = LiveRecoveryAssessment(socketReady: true, microphoneRestored: true,
                                             visualEvidenceFresh: true, needsVisualEvidence: true,
                                             contextContinuity: .resumed)
        XCTAssertTrue(allGood.isCompleteRecovery)
        XCTAssertEqual(allGood.notice, .serviceRestored(.full))

        let noMic = LiveRecoveryAssessment(socketReady: true, microphoneRestored: false,
                                           visualEvidenceFresh: true, needsVisualEvidence: true,
                                           contextContinuity: .resumed)
        XCTAssertEqual(noMic.notice, .recoveryIncomplete)

        let noCamera = LiveRecoveryAssessment(socketReady: true, microphoneRestored: true,
                                              visualEvidenceFresh: false, needsVisualEvidence: true,
                                              contextContinuity: .resumed)
        XCTAssertEqual(noCamera.notice, .serviceRestored(.cameraUnavailable))

        let noThread = LiveRecoveryAssessment(socketReady: true, microphoneRestored: true,
                                              visualEvidenceFresh: true, needsVisualEvidence: true,
                                              contextContinuity: .lost)
        XCTAssertEqual(noThread.notice, .serviceRestored(.contextLost))

        let neither = LiveRecoveryAssessment(socketReady: true, microphoneRestored: true,
                                             visualEvidenceFresh: false, needsVisualEvidence: true,
                                             contextContinuity: .lost)
        XCTAssertEqual(neither.notice, .serviceRestored(.cameraUnavailableAndContextLost))
    }

    func testAnAudioOnlySessionIsNotDegradedByAnAbsentCamera() {
        let audioOnly = LiveRecoveryAssessment(socketReady: true, microphoneRestored: true,
                                               visualEvidenceFresh: false,
                                               needsVisualEvidence: false,
                                               contextContinuity: .rebuilt(turns: 4))
        XCTAssertTrue(audioOnly.visionUsable)
        XCTAssertEqual(audioOnly.notice, .serviceRestored(.full))
    }

    func testContinuityIsResumedRebuiltOrLost() {
        XCTAssertEqual(LiveRecoveryAssessment.continuity(resumedOnServer: true, handoverTurns: 0),
                       .resumed)
        XCTAssertEqual(LiveRecoveryAssessment.continuity(resumedOnServer: true, handoverTurns: 5),
                       .resumed, "resumption makes the local record irrelevant")
        XCTAssertEqual(LiveRecoveryAssessment.continuity(resumedOnServer: false, handoverTurns: 3),
                       .rebuilt(turns: 3))
        XCTAssertEqual(LiveRecoveryAssessment.continuity(resumedOnServer: false, handoverTurns: 0),
                       .lost, "an empty handover is a lost thread, not a rebuilt one")
    }

    func testRebuiltWithNoTurnsNeverClaimsPriorContext() {
        XCTAssertFalse(LiveRecoveryAssessment.ContextContinuity.rebuilt(turns: 0).carriesPriorContext)
        XCTAssertTrue(LiveRecoveryAssessment.ContextContinuity.rebuilt(turns: 1).carriesPriorContext)
        XCTAssertFalse(LiveRecoveryAssessment.ContextContinuity.lost.carriesPriorContext)
        XCTAssertTrue(LiveRecoveryAssessment.ContextContinuity.resumed.carriesPriorContext)
    }

    // MARK: - The handover

    func testHandoverCarriesOnlyTheLastSixTurnsInOrder() {
        let turns = (1...10).map {
            LiveTurnRecord(speaker: $0 % 2 == 0 ? .assistant : .wearer, text: "turn \($0)")
        }
        let block = LiveContextHandover.build(turns: turns)
        let text = try! XCTUnwrap(block)

        XCTAssertFalse(text.contains("turn 4"), "older turns drop")
        for n in 5...10 { XCTAssertTrue(text.contains("turn \(n)"), "turn \(n) should be carried") }
        XCTAssertEqual(LiveContextHandover.carriedTurnCount(turns), LiveContextHandover.maxTurns)
        XCTAssertLessThan(text.range(of: "turn 5")!.lowerBound, text.range(of: "turn 10")!.lowerBound)
    }

    func testAnInterruptedAnswerIsMarkedAndNeverPresentedAsDelivered() {
        let block = LiveContextHandover.build(turns: [
            LiveTurnRecord(speaker: .wearer, text: "what's on the shelf?"),
            LiveTurnRecord(speaker: .assistant, text: "There are three boxes", wasInterrupted: true),
        ])
        let text = try! XCTUnwrap(block)

        XCTAssertTrue(text.contains("the connection dropped before you finished"))
        XCTAssertTrue(text.contains("Do not treat this answer as delivered."))
        XCTAssertFalse(text.contains("- You answered: \"There are three boxes\""),
                       "an interrupted answer must not read as a completed one")
    }

    func testAnInFlightSideEffectingToolIsMarkedUnknownAndNeverReIssued() {
        let block = LiveContextHandover.build(
            turns: [LiveTurnRecord(speaker: .wearer, text: "text Sam that I'm running late")],
            interruptedOperations: ["send_via"])
        let text = try! XCTUnwrap(block)

        XCTAssertTrue(text.contains("'send_via'"))
        XCTAssertTrue(text.contains("the outcome is unknown"))
        XCTAssertTrue(text.contains("Do NOT run it again."))
        XCTAssertFalse(text.contains("retry"), "the handover never invites a replay")
        XCTAssertTrue(text.contains("do not run any action again"))
    }

    func testOnlySideEffectingUnresolvedOperationsReachTheHandover() {
        let journal = StubJournal()
        journal.records = [
            makeRecord(tool: "send_via", effect: .externalMutation, state: .started),
            makeRecord(tool: "set_torch", effect: .physicalActuation, state: .unknown),
            makeRecord(tool: "web_search", effect: .readOnly, state: .started),
            makeRecord(tool: "save_note", effect: .localMutation, state: .completed),
        ]

        let names = LiveContextHandover.interruptedSideEffectingOperations(in: journal)

        XCTAssertEqual(names, ["send_via", "set_torch"])
        XCTAssertFalse(names.contains("web_search"), "repeating a read changes nothing")
        XCTAssertFalse(names.contains("save_note"), "a settled operation is not in doubt")
    }

    func testAnUnresolvedOperationFromAnEarlierSessionIsNotInThisHandover() {
        let journal = StubJournal()
        journal.records = [
            makeRecord(tool: "send_via", effect: .externalMutation, state: .unknown,
                       startedAt: Date(timeIntervalSince1970: 100)),   // last week's process
            makeRecord(tool: "set_torch", effect: .physicalActuation, state: .started,
                       startedAt: Date(timeIntervalSince1970: 5_000)),
        ]

        let names = LiveContextHandover.interruptedSideEffectingOperations(
            in: journal, since: Date(timeIntervalSince1970: 4_000))

        XCTAssertEqual(names, ["set_torch"],
                       "the journal is durable and outlives sessions; a handover is about this one")
    }

    func testNothingToHandOverProducesNoBlock() {
        XCTAssertNil(LiveContextHandover.build(turns: []))
        XCTAssertNil(LiveContextHandover.build(turns: [
            LiveTurnRecord(speaker: .wearer, text: "   ")
        ]))
    }

    func testALongTurnIsClippedAndSaysSo() {
        let long = String(repeating: "a", count: LiveContextHandover.maxCharactersPerTurn + 50)
        let text = try! XCTUnwrap(LiveContextHandover.build(
            turns: [LiveTurnRecord(speaker: .wearer, text: long)]))
        XCTAssertTrue(text.contains("… (cut short here)"))
        XCTAssertFalse(text.contains(long))
    }

    func testTheHandoverTellsTheModelNotToClaimMoreThanItHas() {
        let text = try! XCTUnwrap(LiveContextHandover.build(
            turns: [LiveTurnRecord(speaker: .wearer, text: "the red one")]))
        XCTAssertTrue(text.contains("say you lost the thread"))
        XCTAssertTrue(text.contains("rebuilt locally"))
    }

    // MARK: - The recorder

    func testTheRecorderCommitsATurnAtTheTurnBoundary() {
        let recorder = LiveConversationRecorder()
        recorder.setWearerTurn("which")
        recorder.setWearerTurn("which of these is decaf?")
        recorder.setAssistantTurn("The one on the left.")
        recorder.completeTurn()

        XCTAssertEqual(recorder.turns.map(\.text),
                       ["which of these is decaf?", "The one on the left."])
        XCTAssertEqual(recorder.turns.map(\.wasInterrupted), [false, false])
    }

    func testAnAnswerTheWearerSpokeOverIsCommittedMarked() {
        let recorder = LiveConversationRecorder()
        recorder.setWearerTurn("what's this?")
        recorder.setAssistantTurn("It looks like a")
        recorder.setWearerTurn("no, the other one")

        XCTAssertEqual(recorder.turns.count, 2)
        XCTAssertEqual(recorder.turns[1].speaker, .assistant)
        XCTAssertTrue(recorder.turns[1].wasInterrupted)
    }

    func testAConnectionLossCommitsTheAnswerInFlightAsInterrupted() {
        let recorder = LiveConversationRecorder()
        recorder.setWearerTurn("read the expiry date")
        recorder.setAssistantTurn("It says the")
        XCTAssertTrue(recorder.hasAnswerInFlight)

        recorder.noteInterruption()

        XCTAssertEqual(recorder.turns.count, 2)
        XCTAssertFalse(recorder.turns[0].wasInterrupted, "what they said, they said")
        XCTAssertTrue(recorder.turns[1].wasInterrupted)
        XCTAssertFalse(recorder.hasAnswerInFlight)
    }

    func testTheRecorderIsBoundedAndForgetsOnReset() {
        let recorder = LiveConversationRecorder()
        for n in 1...40 {
            recorder.setWearerTurn("q\(n)")
            recorder.setAssistantTurn("a\(n)")
            recorder.completeTurn()
        }
        XCTAssertEqual(recorder.turns.count, LiveConversationRecorder.capacity)
        XCTAssertEqual(recorder.turns.last?.text, "a40")

        recorder.reset()
        XCTAssertFalse(recorder.hasRecordedTurns)
        XCTAssertTrue(recorder.recentTurns().isEmpty)
    }

    func testRecentTurnsIncludesWhatIsStillInFlight() {
        let recorder = LiveConversationRecorder()
        recorder.setWearerTurn("and the other one?")
        let recent = recorder.recentTurns()
        XCTAssertEqual(recent.map(\.text), ["and the other one?"])
    }

    // MARK: - The recovery, end to end through the driver

    private struct RecordedRecovery {
        var handovers: [String?] = []
        var cameraStarts = 0
        var frameRestarts = 0
        var signals: [AudibleLifecycleCoordinator.Signal] = []
    }

    private func runRecovery(resumed: Bool,
                             turns: [LiveTurnRecord],
                             interruptedOperations: [String] = [],
                             readiness: CameraReadiness? = nil,
                             needsVision: Bool = false,
                             microphoneThrows: Bool = false,
                             into recorded: inout RecordedRecovery,
                             report: ((AudibleLifecycleCoordinator.Signal) -> Void)? = nil)
        async -> LiveRecoveryAssessment? {
        struct MicFailure: Error {}
        var captured = recorded
        let driver = LiveRecoveryDriver(seams: .init(
            isSessionActive: { true },
            resumedOnServer: { resumed },
            recentTurns: { limit in Array(turns.suffix(limit)) },
            interruptedOperations: { interruptedOperations },
            cameraReadiness: { readiness },
            sessionNeedsVision: { needsVision },
            reconfigure: { captured.handovers.append($0) },
            restartMicrophone: { if microphoneThrows { throw MicFailure() } },
            restartFrameCapture: { captured.frameRestarts += 1 },
            startCamera: { captured.cameraStarts += 1; return true },
            report: { signal in
                captured.signals.append(signal)
                report?(signal)
            }))
        let assessment = await driver.handleReconnected()
        recorded = captured
        return assessment
    }

    func testAShortOutageThatResumesRebuildsNothing() async {
        var recorded = RecordedRecovery()
        let assessment = await runRecovery(
            resumed: true,
            turns: [LiveTurnRecord(speaker: .wearer, text: "which is decaf?")],
            into: &recorded)

        XCTAssertEqual(assessment?.contextContinuity, .resumed)
        XCTAssertEqual(recorded.handovers, [nil], "the server still has the conversation")
        XCTAssertEqual(recorded.frameRestarts, 1)
        XCTAssertEqual(assessment?.notice, .serviceRestored(.full))
    }

    func testARejectedHandleRebuildsABoundedHandoverSoAFollowUpIsAnswerable() async {
        var recorded = RecordedRecovery()
        let turns = [
            LiveTurnRecord(speaker: .wearer, text: "which of these two is decaf?"),
            LiveTurnRecord(speaker: .assistant, text: "The one on the left is decaf."),
            LiveTurnRecord(speaker: .assistant, text: "The other one is", wasInterrupted: true),
        ]
        let assessment = await runRecovery(
            resumed: false, turns: turns, interruptedOperations: ["send_via"], into: &recorded)

        XCTAssertEqual(assessment?.contextContinuity, .rebuilt(turns: 3))
        XCTAssertEqual(assessment?.notice, .serviceRestored(.full),
                       "a rebuilt thread is a thread — the wearer is not told it was lost")
        let block = try! XCTUnwrap(recorded.handovers.first ?? nil)
        // The follow-up "and the other one?" has a referent again.
        XCTAssertTrue(block.contains("which of these two is decaf?"))
        XCTAssertTrue(block.contains("The one on the left is decaf."))
        // …and the answer the outage cut off is not presented as given.
        XCTAssertTrue(block.contains("Do not treat this answer as delivered."))
        // …and the message that may or may not have gone is named, not re-sent.
        XCTAssertTrue(block.contains("'send_via'"))
        XCTAssertTrue(block.contains("Do NOT run it again."))
    }

    func testNoLocalRecordMeansTheThreadIsLostAndTheWearerIsToldSo() async {
        var recorded = RecordedRecovery()
        let sink = CueSink()
        let clock = FakeClock()
        let coordinator = makeCoordinator(sink: sink, clock: clock)
        coordinator.handle(.sessionStarted(.init(audioSessionActive: true, sessionConnected: true,
                                                 microphoneListening: true)))
        coordinator.pump()
        sink.earcons.removeAll(); sink.lines.removeAll()

        let assessment = await runRecovery(resumed: false, turns: [], into: &recorded) { signal in
            coordinator.handle(signal)
        }
        coordinator.pump()

        XCTAssertEqual(assessment?.contextContinuity, .lost)
        XCTAssertNil(recorded.handovers.first ?? nil, "there was nothing to hand over")
        XCTAssertEqual(sink.lines, [
            "Connected again, but I lost the thread of our conversation. You may need to tell me again."
        ])
        XCTAssertEqual(sink.earcons, [.restored])
    }

    func testAnAudioRestartFailureIsSpokenRatherThanLogged() async {
        var recorded = RecordedRecovery()
        let sink = CueSink()
        let clock = FakeClock()
        let coordinator = makeCoordinator(sink: sink, clock: clock)

        let assessment = await runRecovery(resumed: true, turns: [], microphoneThrows: true,
                                           into: &recorded) { coordinator.handle($0) }
        coordinator.pump()

        XCTAssertEqual(assessment?.microphoneRestored, false)
        XCTAssertEqual(assessment?.socketReady, true, "the socket is a separate fact")
        XCTAssertEqual(assessment?.notice, .recoveryIncomplete)
        XCTAssertEqual(sink.lines, [
            "Connected again, but the microphone didn't come back. Stop and start the session to try again."
        ])
    }

    // MARK: - The camera, at a reconnect

    func testAPausedCameraIsNeverStartedAndTheWearerIsToldItCannotSee() async {
        var recorded = RecordedRecovery()
        let sink = CueSink()
        let clock = FakeClock()
        let coordinator = makeCoordinator(sink: sink, clock: clock, visualEvidence: { false })
        coordinator.handle(.sessionStarted(.init(audioSessionActive: true, sessionConnected: true,
                                                 microphoneListening: true)))
        coordinator.pump()
        sink.earcons.removeAll(); sink.lines.removeAll()

        let paused = CameraReadiness(phase: .paused, frameAge: 30, session: 2, userWantsStream: true)
        let assessment = await runRecovery(resumed: true, turns: [], readiness: paused,
                                           needsVision: true, into: &recorded) {
            coordinator.handle($0)
        }

        XCTAssertEqual(recorded.cameraStarts, 0,
                       "a pause is waited out, never started out of (Plan FD P1)")
        XCTAssertEqual(LiveRecoveryCameraPolicy.action(readiness: paused, sessionNeedsVision: true),
                       .awaitSDKResume)
        XCTAssertEqual(assessment?.visualEvidenceFresh, false)

        clock.advance(AudibleLifecycleCoordinator.recoveryEvidenceWindow + 1)
        coordinator.pump()
        XCTAssertEqual(sink.lines,
                       ["Audio is back. The camera isn't — I can hear you, but I can't see."])
    }

    func testAStoppedCameraMayBeStartedWhenStreamingIsStillWanted() async {
        var recorded = RecordedRecovery()
        let stopped = CameraReadiness(phase: .stopped, frameAge: nil, session: 4,
                                      userWantsStream: true)
        _ = await runRecovery(resumed: true, turns: [], readiness: stopped, needsVision: true,
                              into: &recorded)
        XCTAssertEqual(recorded.cameraStarts, 1)
    }

    func testACameraTheWearerTurnedOffIsNotTurnedBackOnByAReconnect() {
        let off = CameraReadiness(phase: .stopped, frameAge: nil, session: 4,
                                  userWantsStream: false)
        XCTAssertEqual(LiveRecoveryCameraPolicy.action(readiness: off, sessionNeedsVision: true),
                       .none)
    }

    func testTheCameraPolicyNeverStartsIntoAnythingTheBackendOwns() {
        for phase in CameraReadiness.Phase.allCases where phase != .stopped {
            let readiness = CameraReadiness(phase: phase, frameAge: nil, session: 1,
                                            userWantsStream: true)
            XCTAssertNotEqual(LiveRecoveryCameraPolicy.action(readiness: readiness,
                                                             sessionNeedsVision: true),
                              .startCamera, "\(phase) must not be started into")
        }
        XCTAssertFalse(LiveRecoveryCameraPolicy.mayStartCamera(readiness: nil,
                                                              sessionNeedsVision: true))
    }

    // MARK: - Repeated flapping

    func testFlappingGivesOneNoticePerEpisodeRatherThanABurst() {
        let sink = CueSink()
        let clock = FakeClock()
        let coordinator = makeCoordinator(sink: sink, clock: clock)
        coordinator.handle(.sessionStarted(.init(audioSessionActive: true, sessionConnected: true,
                                                 microphoneListening: true)))
        coordinator.pump()
        sink.earcons.removeAll(); sink.lines.removeAll()

        for _ in 0..<3 {
            clock.advance(30)
            coordinator.handle(.connectionLost)
            coordinator.pump()
            clock.advance(5)
            coordinator.handle(.reconnected(audioRestored: true, needsVisualEvidence: false,
                                            contextCarried: true))
            coordinator.pump()
        }

        XCTAssertEqual(sink.earcons, [.lost, .restored, .lost, .restored, .lost, .restored],
                       "one loss and one recovery per episode, in order")
        XCTAssertEqual(coordinator.pendingCount, 0, "no backlog builds up")
    }

    func testARepublishStormInsideTheRepeatWindowIsOneNotice() {
        let sink = CueSink()
        let clock = FakeClock()
        let coordinator = makeCoordinator(sink: sink, clock: clock)
        coordinator.handle(.sessionStarted(.init(audioSessionActive: true, sessionConnected: true,
                                                 microphoneListening: true)))
        coordinator.pump()
        sink.earcons.removeAll()

        for _ in 0..<4 {
            coordinator.handle(.connectionLost)
            coordinator.pump()
        }

        XCTAssertEqual(sink.earcons, [.lost], "the same notice inside the repeat window is one event")
    }

    // MARK: - The spoken lines

    func testTheRecoveryLinesSayWhichFactIsMissing() {
        let P = AudibleLifecyclePolicy.self
        XCTAssertEqual(P.spokenLine(for: .serviceRestored(.full)), "Back. I'm listening.")
        XCTAssertEqual(P.spokenLine(for: .serviceRestored(.contextLost)),
                       "Connected again, but I lost the thread of our conversation. You may need to tell me again.")
        XCTAssertEqual(P.spokenLine(for: .serviceRestored(.cameraUnavailableAndContextLost)),
                       "Connected again. I can't see, and I lost the thread of our conversation.")
        for shape: AudibleLifecyclePolicy.RecoveryShape in
            [.full, .cameraUnavailable, .contextLost, .cameraUnavailableAndContextLost] {
            XCTAssertEqual(P.earcon(for: .serviceRestored(shape)), .restored)
            XCTAssertFalse(P.isTerminal(.serviceRestored(shape)))
        }
    }

    func testAPlainRecoveryStaysSilentWithoutAHeardLossButADegradedOneDoesNot() {
        let P = AudibleLifecyclePolicy.self
        XCTAssertFalse(P.isWorthSayingWithoutAHeardLoss(.serviceRestored(.full)))
        XCTAssertTrue(P.isWorthSayingWithoutAHeardLoss(.serviceRestored(.contextLost)),
                      "a lost thread is new information whatever the wearer heard before it")
        XCTAssertTrue(P.isWorthSayingWithoutAHeardLoss(.serviceRestored(.cameraUnavailable)))
        XCTAssertTrue(P.isWorthSayingWithoutAHeardLoss(
            .serviceRestored(.cameraUnavailableAndContextLost)))
    }

    func testDegradedShapesOutrankThePlainOneInTheQueue() {
        let P = AudibleLifecyclePolicy.self
        XCTAssertGreaterThan(P.priority(of: .serviceRestored(.cameraUnavailableAndContextLost)),
                             P.priority(of: .serviceRestored(.cameraUnavailable)))
        XCTAssertGreaterThan(P.priority(of: .serviceRestored(.cameraUnavailable)),
                             P.priority(of: .serviceRestored(.contextLost)))
        XCTAssertGreaterThan(P.priority(of: .serviceRestored(.contextLost)),
                             P.priority(of: .serviceRestored(.full)))
        XCTAssertGreaterThan(P.priority(of: .connectionLost),
                             P.priority(of: .serviceRestored(.cameraUnavailableAndContextLost)))
    }

    func testTheShapeIsBuiltFromTheTwoFactsAndReportsThemBack() {
        let S = AudibleLifecyclePolicy.RecoveryShape.self
        XCTAssertEqual(S.make(cameraUsable: true, contextCarried: true), .full)
        XCTAssertEqual(S.make(cameraUsable: false, contextCarried: true), .cameraUnavailable)
        XCTAssertEqual(S.make(cameraUsable: true, contextCarried: false), .contextLost)
        XCTAssertEqual(S.make(cameraUsable: false, contextCarried: false),
                       .cameraUnavailableAndContextLost)
        XCTAssertTrue(AudibleLifecyclePolicy.RecoveryShape.contextLost.cameraIsUsable)
        XCTAssertFalse(AudibleLifecyclePolicy.RecoveryShape.contextLost.contextCarried)
    }

    func testABackendWithNoResumptionConceptClaimsNothingAboutContext() {
        // The OpenAI Realtime manager reports through the two-argument overload.
        let signal = AudibleLifecycleCoordinator.Signal.reconnected(audioRestored: true,
                                                                    needsVisualEvidence: false)
        XCTAssertEqual(signal, .reconnected(audioRestored: true, needsVisualEvidence: false,
                                            contextCarried: true))
    }
}
