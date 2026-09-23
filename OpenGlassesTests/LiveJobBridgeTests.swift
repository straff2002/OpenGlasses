import XCTest
@testable import OpenGlasses

/// The guided job flow applied to a live backend (Plan FO P3a): the refresh triggers, the
/// generation guard, and the classification that runs before the app treats an utterance as a turn.
@MainActor
final class LiveJobBridgeTests: XCTestCase {

    // MARK: - Fixtures

    private var session: FieldSession?
    private var generation = 1
    private var canInject = true
    private var busy = false
    private var injected: [String] = []
    private var consumedAnswers: [String] = []
    private var consumeResult = false
    private var pendingQuestionsPut = 0
    private var recorded: [(String, String)] = []

    private func makeBridge() -> LiveJobBridge {
        let bridge = LiveJobBridge()
        bridge.connect(.init(
            activeSession: { [weak self] in self?.session },
            generation: { [weak self] in self?.generation ?? 0 },
            canInject: { [weak self] in self?.canInject ?? false },
            isBusy: { [weak self] in self?.busy ?? false },
            injectText: { [weak self] text in self?.injected.append(text) },
            consumeUtterance: { [weak self] text in
                self?.consumedAnswers.append(text)
                return self?.consumeResult ?? false
            },
            speakPendingQuestion: { [weak self] in self?.pendingQuestionsPut += 1 },
            recordTurn: { [weak self] text, sourceID in self?.recorded.append((text, sourceID)) }))
        return bridge
    }

    private func openJob(intake: JobIntakeState = .needsReference,
                         reference: String? = nil) -> FieldSession {
        var open = FieldSession(id: "s1", vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                endedAt: nil, pausedAt: nil, resumedAt: nil,
                                outcome: .inProgress, startLocation: nil, endLocation: nil,
                                escalations: [], billableSeconds: 0)
        open.jobIntake = intake
        open.jobReference = reference
        return open
    }

    // MARK: - Setup

    func testSetupBlockIsNilWithoutAJobAndRecordsWhatWasSent() {
        let bridge = makeBridge()
        XCTAssertNil(bridge.setupBlock())
        XCTAssertNil(bridge.lastSentBlock)

        session = openJob()
        let block = bridge.setupBlock()
        XCTAssertNotNil(block)
        XCTAssertEqual(bridge.lastSentBlock, block)
        // The setup carried it, so the first refresh has nothing new to say.
        XCTAssertNil(bridge.refresh())
        XCTAssertTrue(injected.isEmpty)
    }

    // MARK: - Refresh

    func testARefreshSendsOnlyWhatTheModelCanSeeChange() {
        session = openJob()
        let bridge = makeBridge()
        _ = bridge.setupBlock()

        // A change with no visible effect sends nothing.
        session?.billableSeconds = 90
        XCTAssertNil(bridge.refresh())

        // The number being recorded is visible, so it goes.
        session?.jobIntake = .recorded(reference: "1005")
        session?.jobReference = "1005"
        XCTAssertNotNil(bridge.refresh())
        XCTAssertEqual(injected.count, 1)
        XCTAssertTrue(injected[0].contains("\"1005\""))
    }

    func testAClosedJobIsSaidOnce() {
        session = openJob()
        let bridge = makeBridge()
        _ = bridge.setupBlock()
        session?.endedAt = Date()
        session?.outcome = .resolved
        XCTAssertNotNil(bridge.refresh())
        XCTAssertEqual(injected.last, LiveJobContract.heading + "\nNo job is open.")
        // …and not again.
        XCTAssertNil(bridge.refresh())
        XCTAssertEqual(injected.count, 1)
    }

    func testNoJobEverMeansNothingIsInjected() {
        let bridge = makeBridge()
        _ = bridge.setupBlock()
        XCTAssertNil(bridge.refresh())
        XCTAssertTrue(injected.isEmpty)
    }

    // MARK: - Generation safety

    /// The rule the whole guard exists for: a block assembled before a reset never lands after it.
    func testASnapshotBuiltBeforeAResetDoesNotApplyAfterIt() {
        session = openJob()
        let bridge = makeBridge()
        _ = bridge.setupBlock()
        busy = true
        session?.jobIntake = .recorded(reference: "1005")
        XCTAssertNotNil(bridge.refresh())          // held, because the session was busy
        XCTAssertNotNil(bridge.heldBlock)
        XCTAssertTrue(injected.isEmpty)

        // EX resets by cycling the session, which bumps its identity.
        generation = 2
        busy = false
        XCTAssertNil(bridge.flushHeldBlock())
        XCTAssertTrue(injected.isEmpty, "a block for session 1 must never reach session 2")
        XCTAssertNil(bridge.heldBlock)
    }

    func testTheSamePolicyStatedAsAValue() {
        let snapshot = LiveJobSnapshot(generation: 1, text: "x")
        XCTAssertEqual(LiveJobSnapshotPolicy.decide(snapshot, currentGeneration: 1,
                                                    canInject: true, isBusy: false),
                       LiveJobSnapshotDecision.apply("x"))
        XCTAssertEqual(LiveJobSnapshotPolicy.decide(snapshot, currentGeneration: 2,
                                                    canInject: true, isBusy: false),
                       LiveJobSnapshotDecision.discardStaleGeneration)
        XCTAssertEqual(LiveJobSnapshotPolicy.decide(snapshot, currentGeneration: 1,
                                                    canInject: false, isBusy: false),
                       LiveJobSnapshotDecision.discardStaleGeneration)
        XCTAssertEqual(LiveJobSnapshotPolicy.decide(snapshot, currentGeneration: 1,
                                                    canInject: true, isBusy: true),
                       LiveJobSnapshotDecision.holdBusy)
    }

    func testABlockHeldWhileBusyGoesOutAtTheTurnBoundary() async {
        session = openJob()
        let bridge = makeBridge()
        _ = bridge.setupBlock()
        busy = true
        session?.jobIntake = .recorded(reference: "1005")
        _ = bridge.refresh()
        XCTAssertTrue(injected.isEmpty)

        busy = false
        await bridge.turnCompleted()
        XCTAssertEqual(injected.count, 1)
        XCTAssertEqual(pendingQuestionsPut, 1)
        XCTAssertNil(bridge.heldBlock)
    }

    func testANewSessionIsToldEverythingAgain() {
        session = openJob(intake: .recorded(reference: "1005"), reference: "1005")
        let bridge = makeBridge()
        _ = bridge.setupBlock()
        XCTAssertNil(bridge.refresh())

        bridge.sessionEnded()
        generation = 2
        // The new session has been told nothing, so the same state is news again.
        XCTAssertNotNil(bridge.refresh())
        XCTAssertEqual(injected.count, 1)
    }

    // MARK: - The turn

    func testAnUtteranceIsRecordedAndOfferedToTheFlow() async {
        session = openJob(intake: .asked(attempts: 1))
        consumeResult = true
        let bridge = makeBridge()
        let consumed = await bridge.handleTranscript("1005", sourceID: "turn-1")
        XCTAssertTrue(consumed)
        XCTAssertEqual(consumedAnswers, ["1005"])
        // The audit hook is the gap P0 found on Gemini Live, and it fires whether or not the flow
        // had a use for the sentence.
        XCTAssertEqual(recorded.map(\.0), ["1005"])
        XCTAssertEqual(recorded.map(\.1), ["turn-1"])
    }

    func testAnUnrelatedUtterancePassesThroughWithTheQuestionStillOpen() async {
        session = openJob(intake: .asked(attempts: 1))
        consumeResult = false
        let bridge = makeBridge()
        let consumed = await bridge.handleTranscript("what's this error code?", sourceID: "turn-2")
        XCTAssertFalse(consumed)
        XCTAssertEqual(consumedAnswers, ["what's this error code?"])
        XCTAssertEqual(recorded.count, 1)
    }

    func testNothingIsRecordedWithoutAJobOrForAnEmptyTurn() async {
        let bridge = makeBridge()
        _ = await bridge.handleTranscript("1005", sourceID: "a")
        XCTAssertTrue(recorded.isEmpty)

        session = openJob()
        _ = await bridge.handleTranscript("   ", sourceID: "b")
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertTrue(consumedAnswers.isEmpty)
    }

    /// The classifier runs before the app treats the utterance as a turn, on both providers — the
    /// bridge is the same object, so this is one assertion about both.
    func testTheFlowSeesTheUtteranceBeforeAnythingElseDoes() async {
        session = openJob(intake: .asked(attempts: 1))
        consumeResult = true
        let bridge = makeBridge()
        _ = await bridge.handleTranscript("1005", sourceID: "turn-1")
        // The question is only put again at the *next* boundary, never inside the answer.
        XCTAssertEqual(pendingQuestionsPut, 0)
        await bridge.turnCompleted()
        XCTAssertEqual(pendingQuestionsPut, 1)
    }
}

/// Both live backends apply the seam, and apply it in the same three places. The managers
/// themselves cannot be constructed headlessly — each builds a `RealtimeAudioEngine` at init — so
/// what is provable without a device is that each one owns the bridge and reaches it where it has
/// to. That is exactly the claim that would otherwise be a reading of the code.
@MainActor
final class LiveJobBridgeWiringTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testBothManagersOwnTheSameBridge() throws {
        for file in ["Services/GeminiLive/GeminiLiveSessionManager.swift",
                     "Services/OpenAIRealtime/OpenAIRealtimeSessionManager.swift"] {
            let text = try source(file)
            XCTAssertTrue(text.contains("let jobBridge = LiveJobBridge()"), file)
            // The setup instruction carries the block…
            XCTAssertTrue(text.contains("jobBridge.setupBlock()"), file)
            // …the wearer's completed turn is recorded and classified…
            XCTAssertTrue(text.contains("jobBridge.handleTranscript("), file)
            // …the turn boundary is where the question goes out…
            XCTAssertTrue(text.contains("jobBridge.turnCompleted()"), file)
            // …and nothing it was told survives the session.
            XCTAssertTrue(text.contains("jobBridge.sessionEnded()"), file)
        }
    }

    func testTheAppRefreshesBothBackendsFromOneTrigger() throws {
        let app = try source("App/OpenGlassesApp.swift")
        XCTAssertTrue(app.contains("geminiLiveSession.jobBridge.refresh()"))
        XCTAssertTrue(app.contains("openAIRealtimeSession.jobBridge.refresh()"))
        XCTAssertTrue(app.contains("JobSurfaceRefresh.key(for:"))
    }

    /// OpenAI Realtime reaches the native tools for the first time (Plan FO P3a), and the CarPlay
    /// Jobs list resumes through the P1 chokepoint rather than by assigning a thread id.
    func testTheNewlyWiredSurfacesUseTheSeamsTheyAreRequiredTo() throws {
        let app = try source("App/OpenGlassesApp.swift")
        XCTAssertTrue(app.contains("openAIRealtimeSession.nativeToolRouter = nativeToolRouter"))

        let carPlay = try source("App/CarPlaySceneDelegate.swift")
        let start = try XCTUnwrap(carPlay.range(of: "case .resumeActiveJob"))
        let body = carPlay[start.lowerBound...].prefix(600)
        XCTAssertTrue(body.contains("guidedJobFlow.requestResume(threadId:"), String(body))
        XCTAssertFalse(body.contains("activeThreadId ="), String(body))
    }
}
