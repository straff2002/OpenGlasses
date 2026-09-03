import XCTest
@testable import OpenGlasses

/// Tests for the agent session state machine, the OpenClaw adapter's normalization/parsing, and the
/// `code_agent` tool gate (Plan N). Harness-agnostic core driven by a mock harness.
@MainActor
final class AgentSessionTests: XCTestCase {

    // BK P0: dispatch is now gated at the service layer on Agent Mode. These tests exercise the
    // dispatch/confirmation success paths, so enable it (restoring the real value after each).
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

    // MARK: - AgentSessionService state machine

    func testDispatchFailsWhenHarnessUnconfigured() async {
        let service = AgentSessionService()
        let mock = MockAgentHarness(); mock.configuredFlag = false
        service.setHarness(mock)
        let result = await service.dispatch(prompt: "do x", project: nil)
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .notConfigured(.custom))
        XCTAssertNil(service.activeRun)
    }

    func testDispatchSuccessSetsRunningRun() async {
        let service = AgentSessionService()
        service.setHarness(MockAgentHarness())
        let result = await service.dispatch(prompt: "add a toggle", project: "my-app")
        guard case .success(let run) = result else { return XCTFail("expected success") }
        XCTAssertEqual(run.status, .running)
        XCTAssertEqual(service.activeRun?.project, "my-app")
    }

    func testHandleCompletedSpeaksSummaryAndSetsStatus() {
        let service = AgentSessionService()
        var spoken: [String] = []
        service.speak = { spoken.append($0) }
        service.setHarness(MockAgentHarness())
        // Seed an active run (normally set by dispatch).
        service.handle(.started(AgentRun(id: "r", harness: .custom, prompt: "p", project: nil,
                                         status: .running, startedAt: Date())))

        service.handle(.fileCreated("a.swift"))
        service.handle(.completed(AgentRunResult(filesCreated: ["a.swift"])))

        XCTAssertEqual(service.activeRun?.status, .completed)
        XCTAssertEqual(service.lastSummary, "The agent created one file. Done.")
        XCTAssertEqual(spoken.last, "The agent created one file. Done.")
    }

    func testHandleErrorMarksFailed() {
        let service = AgentSessionService()
        service.handle(.started(AgentRun(id: "r", harness: .custom, prompt: "p", project: nil, status: .running, startedAt: Date())))
        service.handle(.error("kaboom"))
        XCTAssertEqual(service.activeRun?.status, .failed)
        XCTAssertEqual(service.lastSummary, "The agent run failed: kaboom.")
    }

    func testAwaitingInputSetsPromptAndStatus() {
        let service = AgentSessionService()
        var spoken: [String] = []
        service.speak = { spoken.append($0) }
        service.handle(.started(AgentRun(id: "r", harness: .custom, prompt: "p", project: nil, status: .running, startedAt: Date())))
        service.handle(.awaitingInput(prompt: "I'm about to push to main — confirm?"))
        XCTAssertEqual(service.activeRun?.status, .awaitingInput)
        XCTAssertEqual(service.awaitingInputPrompt, "I'm about to push to main — confirm?")
        XCTAssertTrue(spoken.contains("I'm about to push to main — confirm?"))
    }

    func testDeclineConfirmationCancels() async {
        let service = AgentSessionService()
        let mock = MockAgentHarness()
        service.setHarness(mock)
        _ = await service.dispatch(prompt: "p", project: nil)
        service.handle(.awaitingInput(prompt: "Push?"))
        await service.respondToConfirmation(approved: false)
        XCTAssertEqual(service.activeRun?.status, .cancelled)
        XCTAssertEqual(mock.respondedApproved, false)
    }

    func testApproveConfirmationResumes() async {
        let service = AgentSessionService()
        let mock = MockAgentHarness()
        service.setHarness(mock)
        _ = await service.dispatch(prompt: "p", project: nil)
        service.handle(.awaitingInput(prompt: "Push?"))
        await service.respondToConfirmation(approved: true)
        XCTAssertEqual(service.activeRun?.status, .running)
        XCTAssertEqual(mock.respondedApproved, true)
    }

    func testCancelSpeaksSummary() async {
        let service = AgentSessionService()
        var spoken: [String] = []
        service.speak = { spoken.append($0) }
        let mock = MockAgentHarness()
        service.setHarness(mock)
        _ = await service.dispatch(prompt: "p", project: nil)
        await service.cancel()
        XCTAssertEqual(service.activeRun?.status, .cancelled)
        XCTAssertTrue(mock.cancelled)
        XCTAssertEqual(spoken.last, "Cancelled the agent run.")
    }

    func testStatusLineByState() {
        let service = AgentSessionService()
        XCTAssertEqual(service.currentStatusLine(), "No agent run is active.")
        service.handle(.started(AgentRun(id: "r", harness: .custom, prompt: "p", project: "repo", status: .running, startedAt: Date())))
        XCTAssertEqual(service.currentStatusLine(), "The agent is working on repo.")
    }

    // MARK: - OpenClawAgentHarness normalization + parsing

    func testNormalizeMapsEachKind() {
        XCTAssertEqual(OpenClawAgentHarness.normalize(["kind": "file_created", "path": "a"]), .fileCreated("a"))
        XCTAssertEqual(OpenClawAgentHarness.normalize(["kind": "file_modified", "path": "b"]), .fileModified("b"))
        XCTAssertEqual(OpenClawAgentHarness.normalize(["kind": "command", "command": "swift test", "ok": false]),
                       .commandRun(command: "swift test", ok: false))
        XCTAssertEqual(OpenClawAgentHarness.normalize(["kind": "pr_opened", "url": "u"]), .prOpened(url: "u"))
        XCTAssertEqual(OpenClawAgentHarness.normalize(["kind": "pushed"]), .pushed)
        XCTAssertEqual(OpenClawAgentHarness.normalize(["kind": "progress", "text": "hi"]), .progress("hi"))
        XCTAssertEqual(OpenClawAgentHarness.normalize(["kind": "awaiting_input", "prompt": "ok?"]), .awaitingInput(prompt: "ok?"))
        XCTAssertEqual(OpenClawAgentHarness.normalize(["kind": "error", "message": "x"]), .error("x"))
    }

    func testNormalizeCompletedParsesResult() {
        let event = OpenClawAgentHarness.normalize(["kind": "completed", "result": ["filesModified": ["a.swift"], "pushed": true]])
        guard case .completed(let result) = event else { return XCTFail("expected completed") }
        XCTAssertEqual(result.filesModified, ["a.swift"])
        XCTAssertTrue(result.pushed)
    }

    func testNormalizeUnknownIsNil() {
        XCTAssertNil(OpenClawAgentHarness.normalize(["kind": "nonsense"]))
        XCTAssertNil(OpenClawAgentHarness.normalize(["no_kind": "x"]))
    }

    func testParseStatusTolerantSpellings() {
        XCTAssertEqual(OpenClawAgentHarness.parseStatus("in_progress"), .running)
        XCTAssertEqual(OpenClawAgentHarness.parseStatus("DONE"), .completed)
        XCTAssertEqual(OpenClawAgentHarness.parseStatus("canceled"), .cancelled)
        XCTAssertNil(OpenClawAgentHarness.parseStatus("weird"))
    }

    func testRunIDExtractionAcrossKeysAndNesting() {
        XCTAssertEqual(OpenClawAgentHarness.runID(in: ["id": "x"]), "x")
        XCTAssertEqual(OpenClawAgentHarness.runID(in: ["run_id": "y"]), "y")
        XCTAssertEqual(OpenClawAgentHarness.runID(in: ["result": ["runId": "z"]]), "z")
        XCTAssertEqual(OpenClawAgentHarness.runID(in: ["ok": true, "payload": ["runId": "p", "status": "ok"]]), "p",
                       "the real gateway answers sessions.send with payload.runId")
        XCTAssertNil(OpenClawAgentHarness.runID(in: ["nope": "x"]))
    }

    func testStartParsesRunAndThrowsOnError() async {
        let harness = OpenClawAgentHarness(
            send: { method, params in
                XCTAssertEqual(method, "sessions.send", "there is no agent.* family on the gateway")
                XCTAssertEqual(params["key"] as? String, OpenClawAgentHarness.taskSessionKey)
                XCTAssertEqual(params["message"] as? String, "Project: proj\n\np")
                XCTAssertNotNil(params["idempotencyKey"])
                return ["ok": true, "payload": ["runId": "run-1", "status": "ok"]]
            }, configured: { true })
        let run = try? await harness.start(prompt: "p", project: "proj")
        XCTAssertEqual(run?.id, "run-1")
        XCTAssertEqual(run?.status, .running)

        let failing = OpenClawAgentHarness(send: { _, _ in ["error": "no agent method"] }, configured: { true })
        do { _ = try await failing.start(prompt: "p", project: nil); XCTFail("expected throw") }
        catch let e as AgentHarnessError { XCTAssertEqual(e, .transport("no agent method")) }
        catch { XCTFail("wrong error: \(error)") }
    }

    func testStatusAndCancelRideTheRunTracker() async throws {
        var aborted: [String: Any] = [:]
        let harness = OpenClawAgentHarness(
            send: { method, params in
                if method == "sessions.abort" { aborted = params; return ["ok": true, "payload": [:]] }
                return ["ok": true, "payload": ["runId": "run-9", "status": "ok"]]
            },
            configured: { true },
            runState: { runId in
                runId == "run-9" ? ChatRunTracker.RunState(phase: .answered("done")) : nil
            })
        let run = try await harness.start(prompt: "p", project: nil)
        let status = try await harness.status(run)
        XCTAssertEqual(status, .completed)
        let unknown = try await harness.status(AgentRun(id: "unknown", harness: .openclaw, prompt: "", project: nil, startedAt: Date()))
        XCTAssertEqual(unknown, .running, "an untracked run is still running as far as we know")
        try await harness.cancel(run)
        XCTAssertEqual(aborted["key"] as? String, OpenClawAgentHarness.taskSessionKey)
        XCTAssertEqual(aborted["runId"] as? String, "run-9")
        XCTAssertEqual(OpenClawAgentHarness.status(for: ChatRunTracker.RunState(phase: .aborted)), .cancelled)
        XCTAssertEqual(OpenClawAgentHarness.status(for: ChatRunTracker.RunState(phase: .failed("x"))), .failed)
    }

    func testEventsCompleteWithTheFinalText() async throws {
        var harness = OpenClawAgentHarness(
            send: { _, _ in ["ok": true, "payload": ["runId": "run-3"]] },
            configured: { true },
            runState: { _ in ChatRunTracker.RunState(phase: .answered("The answer.")) })
        harness.pollInterval = 0.01
        let run = try await harness.start(prompt: "p", project: nil)
        var seen: [AgentEvent] = []
        for await event in harness.events(for: run) { seen.append(event) }
        XCTAssertEqual(seen.first, .started(run))
        var expected = AgentRunResult()
        expected.finalText = "The answer."
        XCTAssertEqual(seen.last, .completed(expected))
    }

    // MARK: - code_agent tool gate

    func testToolGatedOffWhenAgentModeDisabled() async throws {
        let prior = Config.agentModeEnabled
        defer { Config.setAgentModeEnabled(prior) }
        Config.setAgentModeEnabled(false)
        let out = try await AgentControlTool().execute(args: ["action": "start", "prompt": "x"])
        XCTAssertTrue(out.contains("Agent Mode is off"))
    }

    func testToolStartRequiresPrompt() async throws {
        let prior = Config.agentModeEnabled
        defer { Config.setAgentModeEnabled(prior) }
        Config.setAgentModeEnabled(true)
        let out = try await AgentControlTool().execute(args: ["action": "start", "prompt": "   "])
        XCTAssertTrue(out.contains("What should the agent do?"))
    }

    func testToolUnknownAction() async throws {
        let prior = Config.agentModeEnabled
        defer { Config.setAgentModeEnabled(prior) }
        Config.setAgentModeEnabled(true)
        let out = try await AgentControlTool().execute(args: ["action": "frobnicate"])
        XCTAssertTrue(out.lowercased().contains("unknown agent action"))
    }
}

/// Scripted in-memory harness for the session state-machine tests.
private final class MockAgentHarness: AgentHarness {
    let kind: AgentHarnessKind = .custom
    var displayName: String { "Mock" }
    var configuredFlag = true
    var isConfigured: Bool { configuredFlag }
    var scriptedEvents: [AgentEvent] = []
    private(set) var cancelled = false
    private(set) var respondedApproved: Bool?

    func start(prompt: String, project: String?) async throws -> AgentRun {
        AgentRun(id: "run1", harness: kind, prompt: prompt, project: project, status: .running, startedAt: Date())
    }
    func events(for run: AgentRun) -> AsyncStream<AgentEvent> {
        AsyncStream { cont in
            for e in scriptedEvents { cont.yield(e) }
            cont.finish()
        }
    }
    func status(_ run: AgentRun) async throws -> AgentRunStatus { run.status }
    func cancel(_ run: AgentRun) async throws { cancelled = true }
    func respondToInput(_ run: AgentRun, approved: Bool) async throws { respondedApproved = approved }
}
