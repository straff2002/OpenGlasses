import XCTest
@testable import OpenGlasses

/// Plan EX — the reset state machine, with every backend faked.
///
/// The rules under test are the ones a wearer can be lied to about: a confirmation must follow the
/// backend crossing the boundary, not precede it; a reset that did not reach a backend must not
/// clear the phone and call it a fresh start; two utterances must not make two threads; and
/// anything the retired conversation produces afterwards must be rejected by the generation gate.
@MainActor
final class ConversationResetCoordinatorTests: XCTestCase {

    // MARK: - Fakes

    /// An adapter with a scripted outcome and, optionally, a completion the test controls.
    private final class FakeAdapter: ConversationContextResetting {
        let backend: ConversationBackendID
        private let outcome: ConversationResetOutcome
        private let recorder: Recorder
        /// When set, the reset parks here until the test resumes it.
        private var gate: CheckedContinuation<Void, Never>?
        private(set) var isParked = false
        var waitsForRelease = false

        init(_ backend: ConversationBackendID, outcome: ConversationResetOutcome, recorder: Recorder) {
            self.backend = backend
            self.outcome = outcome
            self.recorder = recorder
        }

        func resetConversationContext() async -> ConversationResetOutcome {
            recorder.log.append("reset:\(backend.rawValue)")
            if waitsForRelease {
                isParked = true
                await withCheckedContinuation { self.gate = $0 }
                isParked = false
            }
            return outcome
        }

        func release() {
            gate?.resume()
            gate = nil
        }
    }

    /// Everything the coordinator did, in order, plus the counters the rules are stated in.
    private final class Recorder {
        var log: [String] = []
        var historyClears = 0
        var threadsStarted = 0
        var speechStops = 0
        var announced: [String] = []
        var reports: [ConversationResetReport] = []
    }

    private func makeCoordinator(recorder: Recorder,
                                 plan: [ConversationBackendID],
                                 adapters: [ConversationBackendID: FakeAdapter],
                                 awaitBoundary: (@MainActor () async -> Void)? = nil)
        -> ConversationResetCoordinator {
        let coordinator = ConversationResetCoordinator()
        coordinator.configure(.init(
            plan: { plan },
            adapter: { adapters[$0] },
            awaitTurnBoundary: {
                recorder.log.append("boundary")
                await awaitBoundary?()
            },
            clearLocalHistory: {
                recorder.log.append("clearHistory")
                recorder.historyClears += 1
            },
            startSavedThread: {
                recorder.log.append("startThread")
                recorder.threadsStarted += 1
            },
            stopSpeech: {
                recorder.log.append("stopSpeech")
                recorder.speechStops += 1
            },
            announce: { report in
                recorder.log.append("announce")
                recorder.announced.append(ConversationResetCopy.confirmation(for: report))
            },
            record: { recorder.reports.append($0) }))
        return coordinator
    }

    // MARK: - The completed path

    func testCompletedResetClearsHistoryStartsExactlyOneThreadAndAdvancesTheGeneration() async {
        let recorder = Recorder()
        let gateway = FakeAdapter(.openClaw, outcome: .completed(.openClaw), recorder: recorder)
        let coordinator = makeCoordinator(recorder: recorder, plan: [.openClaw],
                                          adapters: [.openClaw: gateway])
        let before = coordinator.currentGeneration

        let report = await coordinator.requestReset(source: .voiceCommand)

        XCTAssertTrue(report.didRetireLocalContext)
        XCTAssertTrue(report.isFullySuccessful)
        XCTAssertEqual(recorder.historyClears, 1)
        XCTAssertEqual(recorder.threadsStarted, 1, "exactly one saved thread per successful reset")
        XCTAssertEqual(coordinator.currentGeneration, before + 1)
        XCTAssertEqual(report.outcomes, [.completed(.phoneHistory), .completed(.openClaw)],
                       "the phone's own history is reported as a backend like any other")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /// The order is the whole point: the tool result a turn still owes the model goes out first,
    /// then the backends are retired, and only then is anything local cleared or announced.
    func testOrderIsBoundaryThenBackendsThenLocalCommitThenConfirmation() async {
        let recorder = Recorder()
        let live = FakeAdapter(.geminiLive, outcome: .completed(.geminiLive), recorder: recorder)
        let gateway = FakeAdapter(.openClaw, outcome: .completed(.openClaw), recorder: recorder)
        let coordinator = makeCoordinator(recorder: recorder, plan: [.geminiLive, .openClaw],
                                          adapters: [.geminiLive: live, .openClaw: gateway])

        await coordinator.requestReset(source: .modelToolCall)

        XCTAssertEqual(recorder.log,
                       ["stopSpeech", "boundary", "reset:geminiLive", "reset:openClaw",
                        "clearHistory", "startThread", "announce"])
    }

    func testAnUnverifiedBackendStillCrossesTheBoundaryButDowngradesTheConfirmation() async {
        let recorder = Recorder()
        let bridge = FakeAdapter(.hermes,
                                 outcome: .issuedUnverified(.hermes, note: "no ack"),
                                 recorder: recorder)
        let coordinator = makeCoordinator(recorder: recorder, plan: [.hermes],
                                          adapters: [.hermes: bridge])

        let report = await coordinator.requestReset(source: .voiceCommand)

        XCTAssertTrue(report.didRetireLocalContext)
        XCTAssertFalse(report.isFullySuccessful)
        XCTAssertEqual(recorder.threadsStarted, 1)
        XCTAssertEqual(report.unverified, [.hermes])
        XCTAssertTrue(recorder.announced.first?.contains("doesn't confirm resets") == true,
                      "got: \(recorder.announced)")
    }

    // MARK: - The failed path

    func testAFailedBackendLeavesThePhoneAloneAndMakesNoThread() async {
        let recorder = Recorder()
        let live = FakeAdapter(.geminiLive,
                               outcome: .failed(.geminiLive, reason: "socket refused"),
                               recorder: recorder)
        let coordinator = makeCoordinator(recorder: recorder, plan: [.geminiLive],
                                          adapters: [.geminiLive: live])

        let report = await coordinator.requestReset(source: .voiceCommand)

        XCTAssertFalse(report.didRetireLocalContext)
        XCTAssertEqual(recorder.historyClears, 0, "clearing only the phone would be the false claim")
        XCTAssertEqual(recorder.threadsStarted, 0)
        XCTAssertEqual(report.heldBack, [.geminiLive])
        XCTAssertTrue(recorder.announced.first?.contains("left this conversation as it is") == true,
                      "got: \(recorder.announced)")
    }

    func testABackendWithNoRegisteredAdapterIsReportedUnsupportedNotSilentlySkipped() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder, plan: [.openAIRealtime], adapters: [:])

        let report = await coordinator.requestReset(source: .userInterface)

        XCTAssertEqual(report.outcomes.last,
                       .unsupported(.openAIRealtime, reason: "no reset is wired for this backend"))
        XCTAssertFalse(report.didRetireLocalContext)
        XCTAssertEqual(recorder.threadsStarted, 0)
    }

    // MARK: - Coalescing

    func testASecondRequestDuringAResetJoinsItAndDoesNotMakeASecondThread() async {
        let recorder = Recorder()
        let gateway = FakeAdapter(.openClaw, outcome: .completed(.openClaw), recorder: recorder)
        gateway.waitsForRelease = true
        let coordinator = makeCoordinator(recorder: recorder, plan: [.openClaw],
                                          adapters: [.openClaw: gateway])

        async let first = coordinator.requestReset(source: .voiceCommand)
        await waitUntil("the first reset to park in the adapter") { gateway.isParked }
        async let second = coordinator.requestReset(source: .voiceCommand)
        await waitUntil("the second request to join the run") { coordinator.coalescedRequests == 1 }
        gateway.release()

        let reports = await [first, second]
        XCTAssertEqual(reports[0], reports[1], "the second request joins the run already going")
        XCTAssertEqual(recorder.threadsStarted, 1)
        XCTAssertEqual(recorder.historyClears, 1)
        XCTAssertEqual(recorder.announced.count, 1, "one reset, one confirmation")
        XCTAssertEqual(coordinator.currentGeneration, 1, "one generation per run, not per request")
    }

    // MARK: - The confirmation follows the backend

    func testNoConfirmationIsEmittedBeforeTheBackendHasFinished() async {
        let recorder = Recorder()
        let live = FakeAdapter(.geminiLive, outcome: .completed(.geminiLive), recorder: recorder)
        live.waitsForRelease = true
        let coordinator = makeCoordinator(recorder: recorder, plan: [.geminiLive],
                                          adapters: [.geminiLive: live])

        async let run = coordinator.requestReset(source: .modelToolCall)
        await waitUntil("the adapter to park") { live.isParked }

        XCTAssertTrue(recorder.announced.isEmpty, "a fresh start was announced before it happened")
        XCTAssertEqual(recorder.historyClears, 0)
        XCTAssertEqual(coordinator.phase, .inFlight)

        live.release()
        _ = await run
        XCTAssertEqual(recorder.announced.count, 1)
    }

    // MARK: - The generation boundary

    /// The generation advances when the reset is *requested*, not when it finishes: while the
    /// reset runs, the conversation being retired is still producing an answer, and that answer
    /// must not reach the transcript or the speaker.
    func testTheGenerationAdvancesAtRequestSoOutputInFlightIsAlreadyStale() async {
        let recorder = Recorder()
        let gateway = FakeAdapter(.openClaw, outcome: .completed(.openClaw), recorder: recorder)
        gateway.waitsForRelease = true
        let coordinator = makeCoordinator(recorder: recorder, plan: [.openClaw],
                                          adapters: [.openClaw: gateway])
        let turnGeneration = coordinator.currentGeneration
        XCTAssertTrue(coordinator.isCurrent(turnGeneration))

        async let run = coordinator.requestReset(source: .modelToolCall)
        await waitUntil("the adapter to park") { gateway.isParked }

        XCTAssertFalse(coordinator.isCurrent(turnGeneration),
                       "the in-flight turn belongs to the conversation being retired")

        gateway.release()
        _ = await run
        XCTAssertFalse(coordinator.isCurrent(turnGeneration))
    }

    func testSpeechInFlightIsStoppedAsSoonAsTheResetIsRequested() async {
        let recorder = Recorder()
        let gateway = FakeAdapter(.openClaw, outcome: .completed(.openClaw), recorder: recorder)
        gateway.waitsForRelease = true
        let coordinator = makeCoordinator(recorder: recorder, plan: [.openClaw],
                                          adapters: [.openClaw: gateway])

        async let run = coordinator.requestReset(source: .voiceCommand)
        await waitUntil("the adapter to park") { gateway.isParked }

        XCTAssertEqual(recorder.speechStops, 1, "the old context must stop talking immediately")
        gateway.release()
        _ = await run
    }

    // MARK: - Turn boundary

    func testAResetRequestedMidTurnWaitsForTheTurnToFinishFirst() async {
        let recorder = Recorder()
        let gateway = FakeAdapter(.openClaw, outcome: .completed(.openClaw), recorder: recorder)
        var turnFinished = false
        let coordinator = makeCoordinator(
            recorder: recorder, plan: [.openClaw], adapters: [.openClaw: gateway],
            awaitBoundary: {
                // Stands in for the tool result the turn still owes the model.
                recorder.log.append("toolResponseDelivered")
                turnFinished = true
            })

        await coordinator.requestReset(source: .modelToolCall)

        XCTAssertTrue(turnFinished)
        let boundary = recorder.log.firstIndex(of: "toolResponseDelivered")
        let reset = recorder.log.firstIndex(of: "reset:openClaw")
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(reset)
        XCTAssertLessThan(boundary ?? .max, reset ?? .min,
                          "the gateway key must not rotate while a tool result is still owed")
    }

    func testTurnBoundaryReturnsOnceTheTurnClearsAndGivesUpAtTheDeadline() async {
        var polls = 0
        let clearedInTime = await ConversationTurnBoundary.wait(
            isBusy: { polls += 1; return polls < 3 }, timeout: 5, pollInterval: 0,
            sleep: { _ in })
        XCTAssertTrue(clearedInTime)
        XCTAssertEqual(polls, 3)

        var clock = Date(timeIntervalSince1970: 0)
        let gaveUp = await ConversationTurnBoundary.wait(
            isBusy: { true }, timeout: 1, pollInterval: 0,
            now: { clock },
            sleep: { _ in clock = clock.addingTimeInterval(0.6) })
        XCTAssertFalse(gaveUp, "a wedged turn must delay the reset, not hang it forever")
    }

    // MARK: - Copy

    func testConfirmationCopyNeverClaimsSuccessAfterAHeldBackBackend() {
        let held = ConversationResetReport(
            source: .voiceCommand, generation: 1,
            outcomes: [.failed(.openClaw, reason: "offline")],
            didRetireLocalContext: false)
        let line = ConversationResetCopy.confirmation(for: held)
        XCTAssertTrue(line.contains("the gateway agent"))
        XCTAssertFalse(line.lowercased().contains("fresh start"))

        let clean = ConversationResetReport(
            source: .voiceCommand, generation: 2,
            outcomes: [.completed(.phoneHistory)], didRetireLocalContext: true)
        XCTAssertEqual(ConversationResetCopy.confirmation(for: clean),
                       "Okay — fresh start. What would you like to talk about?")
    }

    func testHeldBackListNamesEveryBackendThatKeptItsContext() {
        let report = ConversationResetReport(
            source: .userInterface, generation: 3,
            outcomes: [.failed(.openClaw, reason: "offline"),
                       .unsupported(.hermes, reason: "nothing wired")],
            didRetireLocalContext: false)
        let line = ConversationResetCopy.confirmation(for: report)
        XCTAssertTrue(line.contains("the gateway agent"), line)
        XCTAssertTrue(line.contains("the bridge agent"), line)
    }

    // MARK: - Helpers

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }
}
