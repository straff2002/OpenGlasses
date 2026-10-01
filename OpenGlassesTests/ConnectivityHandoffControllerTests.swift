import XCTest
@testable import OpenGlasses

/// Plan GE P1/P2 — the live controller, driven headlessly: a fake clock, a fake probe, recorded
/// speech and a recorded return.
@MainActor
final class ConnectivityHandoffControllerTests: XCTestCase {

    private final class World {
        var now = Date(timeIntervalSince1970: 5_000_000)
        var enabled = true
        var appActive = true
        var available = OfflineBrainSelector.Available(localModelConfigId: "local")
        var probeOutcome: ConnectivityProbe.Outcome = .reachable
        var probes = 0
        var busy = false
        var liveActive = false
        var queued = 0
        var spoken: [String] = []
        var statuses: [String] = []
        var notifications: [String] = []
        var conversation = "thread-1"
        var returns: [ConnectivityHandoffController.ReturnContext] = []
    }

    private var world: World!
    private var controller: ConnectivityHandoffController!

    override func setUp() async throws {
        let world = World()
        self.world = world
        controller = ConnectivityHandoffController(seams: .init(
            now: { world.now },
            isEnabled: { world.enabled },
            isAppActive: { world.appActive },
            availableBrains: { world.available },
            probe: { world.probes += 1; return world.probeOutcome },
            queuedItems: { world.queued },
            isBusy: { world.busy },
            liveSessionActive: { world.liveActive },
            speak: { world.spoken.append($0) },
            showStatus: { world.statuses.append($0) },
            notify: { _, body in world.notifications.append(body) },
            conversationId: { world.conversation },
            onReturnToCloud: { world.returns.append($0) },
            sleep: { _ in }))
        controller.autoSchedulesTicks = false
    }

    private func advance(_ seconds: TimeInterval) { world.now = world.now.addingTimeInterval(seconds) }

    /// Let the `Task` a cloud-attempt report starts run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: - Going to the phone

    func testLosingThePathMovesToThePhoneAndSaysSoOnce() async {
        await controller.pathChanged(online: false)
        XCTAssertEqual(controller.route, .phone)
        XCTAssertEqual(world.spoken, [HandoffAnnouncer.lostSignalLine])
        XCTAssertEqual(world.statuses, [HandoffAnnouncer.phoneStatusChip])
        // A flap: back up briefly, down again — nothing more is said.
        await controller.pathChanged(online: true)
        advance(5)
        await controller.pathChanged(online: false)
        XCTAssertEqual(world.spoken.count, 1)
    }

    func testTwoConnectivityFailuresOnALivePathMoveToThePhone() async {
        controller.noteCloudAttempt(error: URLError(.timedOut))
        await settle()
        XCTAssertEqual(controller.route, .cloud)
        controller.noteCloudAttempt(error: URLError(.cannotConnectToHost))
        await settle()
        XCTAssertEqual(controller.route, .phone)
    }

    func testOtherFailuresSayNothingAboutTheSignal() async {
        for _ in 0..<3 {
            controller.noteCloudAttempt(error: LLMError.apiError(provider: "x", statusCode: 429, message: nil))
        }
        await settle()
        XCTAssertEqual(controller.route, .cloud)
    }

    func testAChangeDuringATurnWaitsForTheTurnToEnd() async {
        world.busy = true
        await controller.pathChanged(online: false)
        XCTAssertEqual(controller.route, .cloud, "never mid-turn")
        XCTAssertTrue(world.spoken.isEmpty)
        world.busy = false
        await controller.turnEnded()
        XCTAssertEqual(controller.route, .phone)
        XCTAssertEqual(world.spoken, [HandoffAnnouncer.lostSignalLine])
    }

    func testQueuedWorkIsMentionedOnlyWhenThereIsSome() async {
        world.queued = 2
        await controller.pathChanged(online: false)
        XCTAssertEqual(world.spoken, [HandoffAnnouncer.lostSignalLine + " " + HandoffAnnouncer.workSavedSentence])
    }

    func testALiveSessionKeepsItsOwnCuesWhileItRetries() async {
        world.liveActive = true
        await controller.pathChanged(online: false)
        XCTAssertEqual(controller.route, .phone)
        XCTAssertTrue(world.spoken.isEmpty)
        XCTAssertTrue(world.statuses.isEmpty)
        await controller.liveSessionHandedToPhone(resume: .geminiLive)
        XCTAssertEqual(world.spoken, [HandoffAnnouncer.liveHandoffLine])
        XCTAssertEqual(controller.pendingLiveResume, .geminiLive)
    }

    // MARK: - Planning turns

    func testOnTheCloudEveryTurnIsACloudTurn() {
        XCTAssertEqual(controller.planTurn("set a timer for 5 minutes"), .cloud)
    }

    func testOnThePhoneADeterministicRequestNeedsNoModel() async {
        await controller.pathChanged(online: false)
        XCTAssertEqual(controller.planTurn("set a timer for 5 minutes"),
                       .deterministic(.init(toolName: "set_timer", seconds: 300)))
    }

    func testInTheForegroundTheOnDeviceModelAnswers() async {
        await controller.pathChanged(online: false)
        XCTAssertEqual(controller.planTurn("why is the sky blue"), .phoneModel(configId: "local"))
    }

    func testLockedInAPocketTheQuestionIsHeldAndSaidOnce() async {
        await controller.pathChanged(online: false)
        world.appActive = false
        XCTAssertEqual(controller.planTurn("why is the sky blue"), .hold)
        XCTAssertEqual(controller.hold("why is the sky blue"), HandoffAnnouncer.heldFirstLine)
        XCTAssertEqual(controller.hold("what about at sunset"), HandoffAnnouncer.heldReplacedLine)
        XCTAssertTrue(controller.heldQuestions.isHolding(conversationId: "thread-1"))
    }

    func testTheSettingOffLeavesEveryTurnOnTheCloud() async {
        world.enabled = false
        await controller.pathChanged(online: false)
        XCTAssertEqual(controller.planTurn("why is the sky blue"), .cloud)
        XCTAssertEqual(world.spoken, [HandoffAnnouncer.lostSignalPlainLine])
        XCTAssertEqual(world.statuses, [HandoffAnnouncer.offlineStatusChip])
    }

    // MARK: - Coming back

    func testReturnNeedsAStableWindowAndAProbe() async {
        await controller.pathChanged(online: false)
        advance(200)
        await controller.pathChanged(online: true)
        advance(10)
        await controller.tick()
        XCTAssertEqual(world.probes, 0, "the window is not up yet")
        XCTAssertEqual(controller.route, .phone)
        advance(10)
        await controller.tick()
        XCTAssertEqual(world.probes, 1)
        XCTAssertEqual(controller.route, .cloud)
        XCTAssertEqual(world.spoken.last, HandoffAnnouncer.backOnlineLine)
    }

    func testAFailedProbeKeepsTheConversationOnThePhone() async {
        world.probeOutcome = .unreachable
        await controller.pathChanged(online: false)
        advance(200)
        await controller.pathChanged(online: true)
        advance(20)
        await controller.tick()
        XCTAssertEqual(controller.route, .phone)
        advance(20)
        await controller.tick()
        XCTAssertEqual(world.probes, 1, "backed off to 40 s")
        world.probeOutcome = .reachable
        advance(20)
        await controller.tick()
        XCTAssertEqual(world.probes, 2)
        XCTAssertEqual(controller.route, .cloud)
    }

    func testNothingToProbeTrustsTheStablePath() async {
        world.probeOutcome = .notProbeable
        await controller.pathChanged(online: false)
        await controller.pathChanged(online: true)
        advance(20)
        await controller.tick()
        XCTAssertEqual(controller.route, .cloud)
    }

    func testTheReturnCarriesTheNoteAndTheHeldQuestion() async {
        await controller.pathChanged(online: false)
        controller.recordOnDeviceAnswer(question: "what's 15% of 80", answer: "12")
        world.appActive = false
        _ = controller.hold("when does the ferry leave")
        world.appActive = true
        await controller.pathChanged(online: true)
        advance(20)
        await controller.tick()
        let context = try? XCTUnwrap(world.returns.first)
        XCTAssertEqual(context?.heldQuestion, .fresh("when does the ferry leave"))
        XCTAssertTrue(context?.inboundNote?.contains("what's 15% of 80") ?? false)
        XCTAssertEqual(context?.answeredOnPhone, [.init(question: "what's 15% of 80", answer: "12")])
        XCTAssertTrue(controller.onDeviceAnswers.isEmpty, "the note is sent once")
    }

    func testAHeldQuestionPastHalfAnHourIsDroppedWithOneLineOrANotification() async {
        await controller.pathChanged(online: false)
        _ = controller.hold("q")
        advance(31 * 60)
        await controller.tick()
        XCTAssertEqual(world.notifications, [HandoffAnnouncer.heldExpiredNotificationBody])
        XCTAssertFalse(world.notifications.first?.contains("q ") ?? true, "the question never lands on a lock screen")

        _ = controller.hold("another")
        await controller.pathChanged(online: true)
        advance(29 * 60)   // still fresh when it is taken, despite the long wait for a stable path
        await controller.tick()
        XCTAssertEqual(world.returns.last?.heldQuestion, .fresh("another"))
    }

    func testAResetConversationIsNotNamedInTheNote() async {
        await controller.pathChanged(online: false)
        controller.recordOnDeviceAnswer(question: "old thread question", answer: "a")
        world.conversation = "thread-2"
        await controller.pathChanged(online: true)
        advance(20)
        await controller.tick()
        XCTAssertNil(world.returns.first?.inboundNote)
    }

    func testAReturnInsideTheSuppressionWindowIsSaidLaterOnce() async {
        await controller.pathChanged(online: false)        // "lost signal" at t
        await controller.pathChanged(online: true)
        advance(20)
        await controller.tick()                            // back at t+20 — too soon to say so
        XCTAssertEqual(controller.route, .cloud)
        XCTAssertEqual(world.spoken, [HandoffAnnouncer.lostSignalLine])
        advance(100)
        await controller.tick()                            // t+120: the owed line
        XCTAssertEqual(world.spoken, [HandoffAnnouncer.lostSignalLine, HandoffAnnouncer.backOnlineLine])
        advance(100)
        await controller.tick()
        XCTAssertEqual(world.spoken.count, 2)
    }

    func testTheSyncLineStandsInForTheReturnLine() async {
        await controller.pathChanged(online: false)
        advance(300)
        controller.noteSyncLineSpoken()
        await controller.pathChanged(online: true)
        advance(20)
        await controller.tick()
        XCTAssertEqual(controller.route, .cloud)
        XCTAssertEqual(world.spoken, [HandoffAnnouncer.lostSignalLine])
    }
}
