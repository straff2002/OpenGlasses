import XCTest
@testable import OpenGlasses

/// Plan LP §3–§4: a new job while one runs steers it or asks before replacing it, and a blocker
/// that keeps coming back is asked about on the third time.
@MainActor
final class AgentFollowUpRoutingTests: XCTestCase {

    private var savedAgentMode = false
    override func setUp() {
        super.setUp()
        savedAgentMode = Config.agentModeEnabled
        Config.setAgentModeEnabled(true)
    }
    override func tearDown() {
        Config.setAgentModeEnabled(savedAgentMode)
        super.tearDown()
    }

    // MARK: - Routing (pure)

    func testNothingRunningStartsFresh() {
        for support in [AgentFollowUpSupport.accepts, .unsupported, .unknown] {
            XCTAssertEqual(AgentFollowUpRouting.route(phase: .idle, support: support), .startFresh)
        }
    }

    func testARunningJobIsSteeredOnlyWhenTheHarnessTakesFollowUps() {
        XCTAssertEqual(AgentFollowUpRouting.route(phase: .running, support: .accepts), .steer)
        XCTAssertEqual(AgentFollowUpRouting.route(phase: .running, support: .unsupported), .askToReplace)
        XCTAssertEqual(AgentFollowUpRouting.route(phase: .running, support: .unknown), .askToReplace,
                       "unknown means ask")
    }

    func testAJobWaitingOnAnAnswerIsNeverSteered() {
        XCTAssertEqual(AgentFollowUpRouting.route(phase: .awaitingInput, support: .accepts), .askToReplace)
    }

    func testShippedHarnessesDeclareNoFollowUpChannel() {
        let custom = CustomAgentHarness(config: CustomHarnessConfig())
        XCTAssertEqual(custom.followUpSupport, .unsupported)
        XCTAssertEqual(FollowUpHarness(support: .unknown).followUpSupport, .unknown)
    }

    // MARK: - The session

    private func running(_ service: AgentSessionService, harness: FollowUpHarness) async {
        service.setHarness(harness)
        guard case .success = await service.dispatch(prompt: "first", project: nil) else {
            return XCTFail("the first job starts")
        }
    }

    func testDispatchRefusesWhileAJobIsRunning() async {
        let service = AgentSessionService()
        let harness = FollowUpHarness(support: .unknown)
        await running(service, harness: harness)
        guard case .failure(let error) = await service.dispatch(prompt: "second", project: nil) else {
            return XCTFail("a second dispatch must not replace the first")
        }
        XCTAssertEqual(error, .runInFlight)
        XCTAssertEqual(harness.starts, ["first"])
        XCTAssertFalse(harness.cancelled)
    }

    func testAStartDuringARunAsksAndAYesStopsTheOldJobExplicitly() async {
        let service = AgentSessionService()
        let harness = FollowUpHarness(support: .unsupported)
        var asked: [RemoteActionConsentRequest] = []
        service.requestUserConsent = { asked.append($0); return true }
        await running(service, harness: harness)

        let outcome = await service.startOrSteer(prompt: "second", project: nil)
        guard case .started(let run) = outcome else { return XCTFail("expected the new job: \(outcome)") }
        XCTAssertEqual(run.prompt, "second")
        XCTAssertEqual(asked.map(\.spokenPrompt),
                       ["That job's still running. Stop it and start this one instead?"])
        XCTAssertTrue(harness.cancelled, "the old job was stopped at the far end, not abandoned")
        XCTAssertEqual(harness.starts, ["first", "second"])
        XCTAssertTrue(service.spokenLog.contains("Cancelled the agent run."), "the stop is recorded")
    }

    func testANoLeavesTheRunningJobAlone() async {
        let service = AgentSessionService()
        let harness = FollowUpHarness(support: .unknown)
        service.requestUserConsent = { _ in false }
        await running(service, harness: harness)
        let outcome = await service.startOrSteer(prompt: "second", project: nil)
        XCTAssertEqual(outcome, .keptRunning)
        XCTAssertFalse(harness.cancelled)
        XCTAssertEqual(harness.starts, ["first"])
        XCTAssertEqual(service.activeRun?.prompt, "first")
    }

    func testWithNoWayToAskNothingChanges() async {
        let service = AgentSessionService()
        let harness = FollowUpHarness(support: .unknown)
        await running(service, harness: harness)
        let outcome = await service.startOrSteer(prompt: "second", project: nil)
        XCTAssertEqual(outcome, .couldNotAsk)
        XCTAssertFalse(harness.cancelled)
        XCTAssertEqual(harness.starts, ["first"])
    }

    func testAJobThatCannotBeStoppedIsNotReplaced() async {
        let service = AgentSessionService()
        let harness = FollowUpHarness(support: .unknown)
        harness.cancelError = .unsupported("Cancel")
        service.requestUserConsent = { _ in true }
        await running(service, harness: harness)
        let outcome = await service.startOrSteer(prompt: "second", project: nil)
        XCTAssertEqual(outcome, .couldNotStop)
        XCTAssertEqual(harness.starts, ["first"])
        XCTAssertEqual(service.activeRun?.status, .running)
    }

    func testAHarnessThatTakesFollowUpsIsSteeredWithoutAsking() async {
        let service = AgentSessionService()
        let harness = FollowUpHarness(support: .accepts)
        var asked = 0
        service.requestUserConsent = { _ in asked += 1; return true }
        await running(service, harness: harness)
        let outcome = await service.startOrSteer(prompt: "also make the button blue", project: nil)
        XCTAssertEqual(outcome, .steered)
        XCTAssertEqual(harness.followUps, ["also make the button blue"])
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(harness.cancelled)
        XCTAssertEqual(harness.starts, ["first"])
    }

    func testAFailedFollowUpFallsBackToAskingNeverToReplacing() async {
        let service = AgentSessionService()
        let harness = FollowUpHarness(support: .accepts)
        harness.followUpError = .transport("down")
        service.requestUserConsent = { _ in false }
        await running(service, harness: harness)
        let outcome = await service.startOrSteer(prompt: "more", project: nil)
        XCTAssertEqual(outcome, .keptRunning)
        XCTAssertFalse(harness.cancelled)
    }

    func testNothingRunningStartsWithoutAsking() async {
        let service = AgentSessionService()
        service.setHarness(FollowUpHarness(support: .unknown))
        var asked = 0
        service.requestUserConsent = { _ in asked += 1; return true }
        guard case .started = await service.startOrSteer(prompt: "first", project: nil) else { return XCTFail() }
        XCTAssertEqual(asked, 0)
    }

    // MARK: - Recurring blocker (pure)

    func testTheThirdRepeatAsks() {
        var blocker = RecurringBlocker()
        XCTAssertEqual(blocker.note(.question, text: "Which branch should I use?"), .announce)
        XCTAssertEqual(blocker.note(.question, text: "which branch should I use"), .quiet)
        XCTAssertEqual(blocker.note(.question, text: "Which branch should I use?"), .askToStop)
        XCTAssertEqual(blocker.note(.question, text: "Which branch should I use?"), .quiet, "asked once")
        XCTAssertEqual(blocker.note(.question, text: "Run the tests?"), .announce, "a different question is new")
        XCTAssertEqual(blocker.note(.error, text: "Which branch should I use?"), .announce,
                       "questions and errors are counted apart")
    }

    func testErrorsNormaliseDigitsAndPunctuation() {
        XCTAssertEqual(RecurringBlocker.normalise("Exit code 1 at 10:42!"),
                       RecurringBlocker.normalise("exit code 2 at 10:43"))
    }

    func testTheStopAskQuotesTheBlocker() {
        XCTAssertEqual(RecurringBlocker.stopPrompt(.question, text: "Which branch should I use?"),
                       "It keeps asking: “Which branch should I use?” Do you want me to stop it?")
    }

    // MARK: - Recurring blocker (session)

    private static func question(_ prompt: String, id: String) -> AgentQuestion {
        AgentQuestion(id: id, revision: 0, kind: .freeText, prompt: prompt, runID: "run1")
    }

    func testARepeatedQuestionIsSaidOnceKeptOnceThenAskedAbout() async {
        let service = AgentSessionService()
        let harness = FollowUpHarness(support: .unknown)
        var spoken: [String] = []
        service.speak = { spoken.append($0) }
        var asked: [RemoteActionConsentRequest] = []
        service.requestUserConsent = { asked.append($0); return true }
        await running(service, harness: harness)

        for round in 1...3 {
            // A fresh identity each round, as the poll derives one after the job runs again.
            service.handle(.awaitingInput(Self.question("Which branch should I use?", id: "q\(round)")))
            XCTAssertEqual(service.pendingQuestion?.id, "q\(round)", "every round stays answerable")
            service.handle(.progress(""))   // nothing said for an empty progress line
            if round < 3 { service.handle(.assistantText("back to work")) }
        }
        await service.awaitStopAsk()

        XCTAssertEqual(spoken.filter { $0 == "Which branch should I use?" }.count, 1, "\(spoken)")
        XCTAssertEqual(asked.map(\.spokenPrompt),
                       ["It keeps asking: “Which branch should I use?” Do you want me to stop it?"])
        XCTAssertTrue(harness.cancelled, "a yes stops the job explicitly")
        XCTAssertEqual(service.activeRun?.status, .cancelled)
    }

    func testANoToStoppingLeavesTheQuestionPending() async {
        let service = AgentSessionService()
        let harness = FollowUpHarness(support: .unknown)
        service.requestUserConsent = { _ in false }
        await running(service, harness: harness)
        for round in 1...3 {
            service.handle(.awaitingInput(Self.question("Which branch?", id: "q\(round)")))
        }
        await service.awaitStopAsk()
        XCTAssertFalse(harness.cancelled)
        XCTAssertEqual(service.pendingQuestion?.id, "q3")
    }

    func testARepeatedFailedCommandIsSaidOnceThenAskedAbout() async {
        let service = AgentSessionService()
        let harness = FollowUpHarness(support: .unknown)
        var spoken: [String] = []
        service.speak = { spoken.append($0) }
        var asked = 0
        service.requestUserConsent = { _ in asked += 1; return false }
        await running(service, harness: harness)
        for _ in 1...3 { service.handle(.commandRun(command: "swift test", ok: false)) }
        await service.awaitStopAsk()
        XCTAssertEqual(spoken.filter { $0.hasPrefix("A command failed") }.count, 1)
        XCTAssertEqual(asked, 1)
    }

    func testANewJobStartsTheCountAgain() async {
        let service = AgentSessionService()
        let harness = FollowUpHarness(support: .unknown)
        var spoken: [String] = []
        service.speak = { spoken.append($0) }
        await running(service, harness: harness)
        service.handle(.awaitingInput(Self.question("Which branch?", id: "q1")))
        service.handle(.completed(AgentRunResult()))
        guard case .success = await service.dispatch(prompt: "again", project: nil) else { return XCTFail() }
        service.handle(.awaitingInput(Self.question("Which branch?", id: "q1b")))
        XCTAssertEqual(spoken.filter { $0 == "Which branch?" }.count, 2)
    }
}

/// A harness whose follow-up channel, cancel and starts are observable.
private final class FollowUpHarness: AgentHarness {
    let kind: AgentHarnessKind = .custom
    var displayName: String { "FollowUp" }
    var isConfigured: Bool { true }
    let support: AgentFollowUpSupport
    var followUpSupport: AgentFollowUpSupport { support }
    private(set) var starts: [String] = []
    private(set) var followUps: [String] = []
    private(set) var cancelled = false
    var cancelError: AgentHarnessError?
    var followUpError: AgentHarnessError?

    init(support: AgentFollowUpSupport) { self.support = support }

    func start(prompt: String, project: String?) async throws -> AgentRun {
        starts.append(prompt)
        return AgentRun(id: "run\(starts.count)", harness: kind, prompt: prompt, project: project,
                        status: .running, startedAt: Date())
    }
    // An open stream, so the session keeps the run as running until a test ends it.
    func events(for run: AgentRun) -> AsyncStream<AgentEvent> { AsyncStream { _ in } }
    func status(_ run: AgentRun) async throws -> AgentRunStatus { run.status }
    func cancel(_ run: AgentRun) async throws {
        if let cancelError { throw cancelError }
        cancelled = true
    }
    func sendFollowUp(_ run: AgentRun, text: String) async throws {
        if let followUpError { throw followUpError }
        followUps.append(text)
    }
}
