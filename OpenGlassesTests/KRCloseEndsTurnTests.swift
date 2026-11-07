import XCTest
@testable import OpenGlasses

/// Plan KR P5 — a close ends the turn, and a turn finishes when the phone is put away.
///
/// The partner's close went on to a status, the day's activity and another status until the tool
/// budget ran out, and the fallback read the activity count out as work done. Then the app went to
/// the background with the turn still running and nothing held it awake. Headless: jobs, turns and
/// results are invented; iOS's background time is behind `BackgroundTaskRunning`.

// MARK: - The close's result ends the turn

@MainActor
final class KRCloseEndsTurnTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("KRCloseEndsTurnTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    func testACloseWithNoReportAskedEndsTheTurnOnTheOutcomeAndTime() {
        let result = FieldSessionTool.endedResult(outcome: .resolved, billing: "45 min", said: "ok close the job")
        XCTAssertTrue(result.hasPrefix("Session ended. Status: Resolved."), result)
        XCTAssertEqual(ToolTurnEnd.parse(result), .afterConfirming(summary: "Job closed: resolved, 45 min billable."))
        XCTAssertFalse(result.contains("call deliver_report now"), "no invitation to call another tool")
    }

    func testACloseThatAsksForTheReportKeepsTheTurnOpen() {
        for said in ["close the job and send the report", "wrap it up and email it to the office",
                     "finish the job, send it"] {
            let result = FieldSessionTool.endedResult(outcome: .resolved, billing: "1 h", said: said)
            XCTAssertNil(ToolTurnEnd.parse(result), said)
            XCTAssertTrue(result.contains("call deliver_report now"), said)
        }
        let unspoken = FieldSessionTool.endedResult(outcome: .resolved, billing: "1 h", said: nil)
        XCTAssertNil(ToolTurnEnd.parse(unspoken), "a turn with no captured words is as before")
    }

    func testTheToolsEndResultCarriesTheLine() async throws {
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions"))
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil, jobReference: "J-4410")
        let tool = FieldSessionTool(service: service, currentUtterance: { "right, close the job" },
                                    previousReply: { nil })
        let ended = try await tool.execute(args: ["action": "end", "outcome": "resolved"])
        guard case .afterConfirming(let summary)? = ToolTurnEnd.parse(ended) else {
            return XCTFail("the close should end the turn: \(ended)")
        }
        XCTAssertTrue(summary.hasPrefix("Job closed: resolved, "), summary)
        XCTAssertTrue(summary.hasSuffix(" billable."), summary)
    }

    /// The partner's shape: end, then status, activity and status again. The loop stops after the
    /// end; every call batched after it is answered as not run, and the one request left is made
    /// with tools withheld.
    func testACloseFollowedByMoreToolCallsStopsAfterTheEnd() async throws {
        let withholding = ToolWithholding()
        let executed = Box<[String]>([]), appended = Box<[ToolDispatchOutcome]>([])
        var requests: [Bool] = []
        let endLine = FieldSessionTool.endedResult(outcome: .resolved, billing: "45 min", said: "close the job")
        let adapter = ProviderLoopAdapter(
            label: "Test",
            dispatcher: ToolDispatcher(
                execute: { name, args, _, _ in
                    executed.value.append("\(name):\(args["action"] as? String ?? "")")
                    if name == "field_session", args["action"] as? String == "end" { return .completed(endLine) }
                    return .completed("Today I did 12 things.")
                },
                onStatus: { _ in }),
            performTurn: {
                requests.append(withholding.active)
                if withholding.active { return AssistantTurn(text: "Closed: resolved, 45 minutes billable.") }
                return AssistantTurn(text: "", toolCalls: [
                    ToolInvocation(id: "1", name: "field_session", arguments: ["action": "end"]),
                    ToolInvocation(id: "2", name: "field_session", arguments: ["action": "status"]),
                    ToolInvocation(id: "3", name: "activity", arguments: ["action": "today"]),
                ])
            },
            appendAssistantToolCall: { _ in },
            appendToolResults: { appended.value.append(contentsOf: $0) },
            finalize: { $0.text }
        ).withholdingTools(withholding)

        let said = try await runToolLoop(maxIterations: 6, adapter: adapter, setStatus: { _ in })

        XCTAssertEqual(said, "Closed: resolved, 45 minutes billable.")
        XCTAssertEqual(executed.value, ["field_session:end"], "nothing after the close ran")
        XCTAssertEqual(requests, [false, true], "one ordinary request, then the words with tools withheld")
        XCTAssertEqual(appended.value.map(\.invocation.id), ["1", "2", "3"], "every call named has a result")
        XCTAssertEqual(appended.value[2].outcome, .failedBeforeExecution(reason: ToolTurnEnd.notRun("activity")))
    }

    /// No words from the wrap-up: the confirmation is what is said, never the day's activity.
    func testAWrapUpWithNoWordsSaysTheConfirmation() async throws {
        let endLine = FieldSessionTool.endedResult(outcome: .resolved, billing: "45 min", said: "close the job")
        var adapter = ProviderLoopAdapter(
            label: "Test",
            dispatcher: ToolDispatcher(execute: { _, _, _, _ in .completed(endLine) }, onStatus: { _ in }),
            performTurn: {
                AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "1", name: "field_session", arguments: ["action": "end"])])
            },
            appendAssistantToolCall: { _ in },
            appendToolResults: { _ in },
            finalize: { $0.text })
        adapter.performWrapUp = {
            AssistantTurn(text: "", toolCalls: [ToolInvocation(id: "2", name: "activity", arguments: ["action": "today"])])
        }
        let said = try await runToolLoop(maxIterations: 5, adapter: adapter, setStatus: { _ in })
        XCTAssertEqual(said, "Job closed: resolved, 45 min billable.")
    }

    /// Only the close may end the turn: another `field_session` result carrying the line — a
    /// recalled note, a vault's name — is read like any other.
    func testOnlyTheCloseOfFieldSessionMayEndTheTurn() {
        XCTAssertTrue(ToolTurnEnd.mayEndTurn(ToolInvocation(id: nil, name: "field_session", arguments: ["action": "end"])))
        XCTAssertTrue(ToolTurnEnd.mayEndTurn(ToolInvocation(id: nil, name: "field_session", arguments: ["action": "END"])))
        for action in ["status", "recall", "vaults", "list"] {
            XCTAssertFalse(ToolTurnEnd.mayEndTurn(ToolInvocation(id: nil, name: "field_session", arguments: ["action": action])), action)
        }
        XCTAssertFalse(ToolTurnEnd.mayEndTurn(ToolInvocation(id: nil, name: "field_session", arguments: nil)))
        XCTAssertTrue(ToolTurnEnd.mayEndTurn(ToolInvocation(id: nil, name: "rule_chain", arguments: [:])))
        XCTAssertFalse(ToolTurnEnd.mayEndTurn(ToolInvocation(id: nil, name: "activity", arguments: ["action": "end"])))
    }

    func testTheConfirmMarkerIsReadBack() {
        XCTAssertEqual(ToolTurnEnd.parse("Done.\n" + ToolTurnEnd.confirmLine("Job closed: resolved, 1 h billable.")),
                       .afterConfirming(summary: "Job closed: resolved, 1 h billable."))
        XCTAssertNil(ToolTurnEnd.parse(ToolTurnEnd.confirmPrefix), "a confirmation with no words ends nothing")
    }
}

// MARK: - "Done so far" leaves out what only read

@MainActor
final class KRDoneSoFarTests: XCTestCase {

    private func done(_ name: String, _ action: String, _ text: String) -> ToolDispatchOutcome {
        ToolDispatchOutcome(invocation: ToolInvocation(id: UUID().uuidString, name: name, arguments: ["action": action]),
                            outcome: .completed(text), yieldReason: nil)
    }

    /// The live classification, as `LLMService` reads it: a tool's declared effect, or the read
    /// action of one declared by its write.
    private func readsOnly(_ call: ToolInvocation) -> Bool {
        let declared: [String: ToolEffect] = [
            "field_session": FieldSessionTool().executionSemantics.effect,
            "activity": ActivityTool().executionSemantics.effect,
        ]
        if ToolEffectClassifier.isReadAction(tool: call.name, args: call.arguments ?? [:]) { return true }
        return declared[call.name] == .readOnly
    }

    func testTheFallbackOverEndStatusAndActivitySaysOnlyTheEnd() {
        let outcomes = [
            done("field_session", "end", "Session ended. Status: Resolved. Billable time: 45 min."),
            done("field_session", "status", "No active Field Assist session. Configured default for new jobs: X."),
            done("activity", "today", "Today I did 12 things."),
        ]
        XCTAssertEqual(ToolLoopBudget.spoken(from: outcomes, readsOnly: readsOnly),
                       "Done so far: Session ended.")
        XCTAssertEqual(ToolLoopBudget.spoken(from: Array(outcomes.dropFirst()), readsOnly: readsOnly),
                       ToolLoopBudget.spokenFallback, "reads alone are nothing done")
    }

    func testTheReadActionsOfFieldSessionAreReadsAndItsWritesAreNot() {
        for action in ["status", "list", "vaults", "STATUS"] {
            XCTAssertTrue(ToolEffectClassifier.isReadAction(tool: "field_session", args: ["action": action]), action)
        }
        for action in ["end", "start", "set_job_details", "pause", "recall", "export"] {
            XCTAssertFalse(ToolEffectClassifier.isReadAction(tool: "field_session", args: ["action": action]), action)
        }
        XCTAssertEqual(ActivityTool().executionSemantics.effect, .readOnly)
    }

    /// Without a classification (a test adapter, an old caller) every call counts, as before.
    func testWithNoClassificationEveryCallCounts() {
        let outcomes = [done("field_session", "status", "Active session: X."), done("activity", "today", "Today I did 3 things.")]
        XCTAssertEqual(ToolLoopBudget.spoken(from: outcomes), "Done so far: Active session: X. Today I did 3 things.")
    }

    /// Through the loop: the budget runs out on reads after a write, and the words say the write.
    func testTheLoopsFallbackUsesTheAdaptersClassification() async throws {
        var round = 0
        var adapter = ProviderLoopAdapter(
            label: "Test",
            dispatcher: ToolDispatcher(execute: { name, _, _, _ in
                round += 1
                return .completed(name == "van_stock" ? "Used one ignitor \(round)." : "Today I did \(round) things.")
            }, onStatus: { _ in }),
            performTurn: {
                AssistantTurn(text: "", toolCalls: [
                    ToolInvocation(id: "a\(round)", name: round == 0 ? "van_stock" : "activity", arguments: ["action": "today"]),
                ])
            },
            appendAssistantToolCall: { _ in },
            appendToolResults: { _ in },
            finalize: { $0.text })
        adapter.readsOnly = { $0.name == "activity" }
        let said = try await runToolLoop(maxIterations: 3, adapter: adapter, setStatus: { _ in })
        XCTAssertEqual(said, "Done so far: Used one ignitor 1.")
    }
}

// MARK: - A turn finishes when the phone is put away

@MainActor
final class KRTurnBackgroundTimeTests: XCTestCase {

    final class FakeTasks: BackgroundTaskRunning {
        var began: [String] = []
        var ended: [Int] = []
        var expiries: [@MainActor () -> Void] = []
        private var next = 100

        func begin(name: String) -> Int { begin(name: name, onExpiry: {}) }

        func begin(name: String, onExpiry: @escaping @MainActor () -> Void) -> Int {
            began.append(name)
            expiries.append(onExpiry)
            next += 1
            return next
        }

        func end(_ token: Int) { ended.append(token) }
    }

    func testATurnInFlightClaimsTimeWhenTheAppLeavesAndReleasesItWhenItEnds() {
        let tasks = FakeTasks()
        let time = TurnBackgroundTime(tasks: tasks)
        time.turnBegan(appInBackground: false)
        XCTAssertTrue(tasks.began.isEmpty, "nothing is claimed while the app is in front")
        time.appLeftForeground()
        XCTAssertEqual(tasks.began, [TurnBackgroundTime.taskName])
        time.appLeftForeground()
        XCTAssertEqual(tasks.began.count, 1, "one task per turn")
        XCTAssertTrue(time.isHoldingTask)
        time.turnEnded()
        XCTAssertEqual(tasks.ended, [101])
        XCTAssertFalse(time.isHoldingTask)
        time.turnEnded()
        XCTAssertEqual(tasks.ended, [101], "ended once")
    }

    func testNoTurnNoClaim() {
        let tasks = FakeTasks()
        let time = TurnBackgroundTime(tasks: tasks)
        time.appLeftForeground()
        XCTAssertTrue(tasks.began.isEmpty)
        time.turnBegan(appInBackground: false)
        time.turnEnded()
        time.appLeftForeground()
        XCTAssertTrue(tasks.began.isEmpty, "a finished turn claims nothing")
    }

    func testATurnStartedInTheBackgroundClaimsAtOnce() {
        let tasks = FakeTasks()
        let time = TurnBackgroundTime(tasks: tasks)
        time.turnBegan(appInBackground: true)
        XCTAssertEqual(tasks.began.count, 1)
        time.turnEnded()
        XCTAssertEqual(tasks.ended.count, 1)
    }

    /// iOS's allowance runs out: the runner has ended the task, so it is not ended again, and an
    /// expiry from an earlier claim never touches a later turn's.
    func testExpiryEndsTheClaimCleanly() {
        let tasks = FakeTasks()
        let time = TurnBackgroundTime(tasks: tasks)
        time.turnBegan(appInBackground: false)
        time.appLeftForeground()
        tasks.expiries[0]()
        XCTAssertTrue(time.expired)
        XCTAssertFalse(time.isHoldingTask)
        time.turnEnded()
        XCTAssertTrue(tasks.ended.isEmpty, "never ended twice")

        time.turnBegan(appInBackground: true)
        XCTAssertFalse(time.expired)
        tasks.expiries[0]()
        XCTAssertTrue(time.isHoldingTask, "a stale expiry leaves the new claim alone")
        time.turnEnded()
        XCTAssertEqual(tasks.ended, [102])
    }

    func testAReplyUnspokenWhileAwayIsMentionedOnceOnReturn() {
        let time = TurnBackgroundTime(tasks: FakeTasks())
        time.turnBegan(appInBackground: false)
        time.appLeftForeground()
        time.replyFinished(spoken: false, appInBackground: true)
        XCTAssertNil(time.appReturnedToForeground(), "not while the turn is still running")
        time.turnEnded()
        XCTAssertEqual(time.appReturnedToForeground(), TurnBackgroundTime.replyWaitingNotice)
        XCTAssertNil(time.appReturnedToForeground(), "once")
    }

    func testASpokenOrForegroundReplyLeavesNothingToSay() {
        let time = TurnBackgroundTime(tasks: FakeTasks())
        time.turnBegan(appInBackground: false)
        time.replyFinished(spoken: true, appInBackground: true)
        time.replyFinished(spoken: false, appInBackground: false)
        time.turnEnded()
        XCTAssertNil(time.appReturnedToForeground())
    }

    /// The fakes that predate expiry reporting still conform: the default never reports it.
    func testARunnerWithoutExpiryStillBegins() {
        final class Plain: BackgroundTaskRunning {
            var began = 0
            func begin(name: String) -> Int { began += 1; return 7 }
            func end(_ token: Int) {}
        }
        let plain = Plain()
        let time = TurnBackgroundTime(tasks: plain)
        time.turnBegan(appInBackground: true)
        XCTAssertEqual(plain.began, 1)
    }
}
