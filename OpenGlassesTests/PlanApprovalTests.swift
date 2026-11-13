import XCTest
@testable import OpenGlasses

/// Plan LP §1–§2: one ask before a plan runs, a bound grant per step, and the spoken opener.
///
/// The security half is the point of most of these: a plan's yes is still a set of single-use
/// grants bound to each step's exact call, it cannot be spent outside its own plan run, and it dies
/// with the plan.
@MainActor
final class PlanApprovalTests: XCTestCase {

    private var savedAgentMode = false

    override func setUp() {
        super.setUp()
        savedAgentMode = Config.agentModeEnabled
        // Agent mode off: messaging still needs a bound approval (the effect-class floor), and the
        // supervisor's own rules stay out of the way, so what asks is the floor's alone.
        Config.setAgentModeEnabled(false)
    }

    override func tearDown() {
        Config.setAgentModeEnabled(savedAgentMode)
        super.tearDown()
    }

    // MARK: - Fixtures

    private static func binding(_ tool: String = "send_message", args: [String: Any] = [:],
                                session: String = "s") -> ApprovalBinding {
        ApprovalBinding(seam: .native, toolName: tool, definitionDigest: "d", args: args, sessionID: session)
    }

    private final class CountingTool: NativeTool {
        let name: String
        let description = "plan approval fixture"
        var parametersSchema: [String: Any] { ["type": "object"] }
        var executionSemantics: ToolExecutionSemantics { .external(.bestEffort) }
        private(set) var calls: [[String: Any]] = []
        var runs: Int { calls.count }
        init(name: String) { self.name = name }
        func execute(args: [String: Any]) async throws -> String {
            calls.append(args)
            return "sent"
        }
    }

    private final class ReadTool: NativeTool {
        let name: String
        let description = "read fixture"
        var parametersSchema: [String: Any] { ["type": "object"] }
        var executionSemantics: ToolExecutionSemantics { .read(.notCancellable) }
        private(set) var runs = 0
        init(name: String) { self.name = name }
        func execute(args: [String: Any]) async throws -> String { runs += 1; return "read" }
    }

    private struct Rig {
        let router: NativeToolRouter
        let coordinator: ToolConfirmationCoordinator
        let messages: CountingTool
    }

    private func rig() -> Rig {
        let messages = CountingTool(name: "send_message")
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(messages)
        registry.register(ReadTool(name: "lp_lookup"))
        let router = NativeToolRouter(registry: registry)
        let coordinator = ToolConfirmationCoordinator()
        router.confirmationCoordinator = coordinator
        return Rig(router: router, coordinator: coordinator, messages: messages)
    }

    private func planner(_ json: String) -> AgentPlanner {
        let planner = AgentPlanner()
        planner.complete = { _, _ in json }
        return planner
    }

    /// Answer each prompt as it appears, recording what was asked. Stops after `answers` runs out.
    private func answering(_ coordinator: ToolConfirmationCoordinator,
                           _ answers: [Bool]) -> Task<[PendingToolConfirmation], Never> {
        Task { @MainActor in
            var seen: [PendingToolConfirmation] = []
            var remaining = answers
            for _ in 0..<2_000 where !remaining.isEmpty {
                if let pending = coordinator.pending, !seen.contains(where: { $0.id == pending.id }) {
                    seen.append(pending)
                    coordinator.resolve(remaining.removeFirst())
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return seen
        }
    }

    private static let twoMessages = """
    {"goal":"tell both","steps":[
      {"tool":"send_message","args":{"to":"Sam","body":"running late"},"rationale":"text Sam"},
      {"tool":"send_message","args":{"to":"Alex","body":"running late"},"rationale":"text Alex"}
    ]}
    """

    // MARK: - Shape (pure)

    func testNoConfirmableStepAsksNothing() {
        XCTAssertEqual(PlanApproval.shape(for: [.noAsk, .noAsk]), .none)
    }

    func testOneConfirmableStepAsksAtItsOwnCallAsBefore() {
        XCTAssertEqual(PlanApproval.shape(for: [.noAsk, .confirm(summary: "Send", binding: Self.binding())]),
                       .atTheCall)
    }

    func testTwoConfirmableStepsAreOneAskWithBothActions() {
        let shape = PlanApproval.shape(for: [
            .confirm(summary: "Send a message to Sam: “running late”", binding: Self.binding(args: ["to": "Sam"])),
            .noAsk,
            .confirm(summary: "Lock the front door.", binding: Self.binding("smart_home")),
        ])
        guard case .asks(let parts) = shape else { return XCTFail("expected one ask") }
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].items.map(\.stepIndex), [0, 2])
        XCTAssertEqual(parts[0].spokenPrompt,
                       "I'll send a message to Sam: “running late” and lock the front door. OK?")
        XCTAssertEqual(parts[0].cardSummary,
                       "• Send a message to Sam: “running late”\n• Lock the front door.")
    }

    func testMoreThanThreeConfirmableStepsAskInTwoHalves() {
        let preflights = (0..<5).map { PlanStepPreflight.confirm(summary: "Send \($0)",
                                                                 binding: Self.binding(args: ["n": $0])) }
        guard case .asks(let parts) = PlanApproval.shape(for: preflights) else { return XCTFail() }
        XCTAssertEqual(parts.map { $0.items.map(\.stepIndex) }, [[0, 1, 2], [3, 4]])
        XCTAssertTrue(parts[1].spokenPrompt.hasPrefix("Then I'll send 3"), parts[1].spokenPrompt)
        XCTAssertTrue(parts.allSatisfy { $0.items.count <= PlanApproval.maxItemsPerAsk })
    }

    func testThePhraserKeepsCapitalisedWords() {
        XCTAssertEqual(PlanApprovalPhraser.lowerFirst("TV on"), "TV on")
        XCTAssertEqual(PlanApprovalPhraser.lowerFirst("Call Sam"), "call Sam")
    }

    // MARK: - Opener (pure)

    private func plan(_ rationales: [String], goal: String = "g") -> AgentPlan {
        AgentPlan(goal: goal, steps: rationales.map { AgentStep(tool: "lp_lookup", rationale: $0) })
    }

    func testAPlanOfTwoOrMoreStepsOpensWithOneSentence() {
        XCTAssertEqual(PlanOpener.sentence(for: plan(["find the manual", "Summarise it"]), request: "r",
                                           asking: false, quietEndsEveryStep: false),
                       "I'll find the manual and summarise it.")
    }

    func testAOneStepPlanHasNoOpener() {
        XCTAssertNil(PlanOpener.sentence(for: plan(["find it"]), request: "r", asking: false,
                                         quietEndsEveryStep: false))
    }

    func testTheOpenerIsNeverSaidAlongsideTheAsk() {
        XCTAssertNil(PlanOpener.sentence(for: plan(["a", "b"]), request: "r", asking: true,
                                         quietEndsEveryStep: false))
    }

    func testTheOpenerIsSkippedWhenEveryStepWouldEndQuietly() {
        XCTAssertNil(PlanOpener.sentence(for: plan(["a", "b"]), request: "r", asking: false,
                                         quietEndsEveryStep: true))
    }

    func testALongPlanOpensWithItsGoalNotEveryStep() {
        let long = plan(["check A", "check B", "check C", "check D", "note it"],
                        goal: "Check three suppliers' prices and put them in a note")
        XCTAssertEqual(PlanOpener.sentence(for: long, request: "compare suppliers", asking: false,
                                           quietEndsEveryStep: false),
                       "I'll check three suppliers' prices and put them in a note.")
        let echoed = plan(["a", "b", "c", "d"], goal: "compare suppliers")
        XCTAssertEqual(PlanOpener.sentence(for: echoed, request: "compare suppliers", asking: false,
                                           quietEndsEveryStep: false),
                       "I'll work through this in 4 steps.", "the request echoed back is not a goal")
    }

    func testTheOpenerTakesThePlaceOfTheFirstStillWorkingOnly() {
        let narration = PlanTurnNarration()
        XCTAssertTrue(narration.absorbsStillWorking())
        XCTAssertFalse(narration.absorbsStillWorking())
        XCTAssertFalse(narration.absorbsStillWorking())
    }

    // MARK: - Grants: scope and revocation (store)

    func testAPlanGrantIsSpentOnlyInsideItsOwnPlanRun() {
        let store = ApprovalGrantStore(sessionID: "s")
        let call = store.binding(seam: .native, toolName: "send_message", definitionDigest: "d",
                                 args: ["to": "Sam"])
        let grant = store.issue(for: call, scope: "plan-A")
        XCTAssertEqual(store.redeem(nonce: grant.nonce, against: call, scope: "plan-B"),
                       .refused(.scopeMismatch), "plan B cannot spend plan A's yes")
        XCTAssertEqual(store.redeem(nonce: grant.nonce, against: call), .refused(.scopeMismatch),
                       "nor can a call outside any plan")
        XCTAssertEqual(store.liveGrantCount, 1, "a refused presentation spends nothing")
        guard case .consumed = store.redeem(nonce: grant.nonce, against: call, scope: "plan-A") else {
            return XCTFail("its own plan spends it")
        }
        XCTAssertEqual(store.redeem(nonce: grant.nonce, against: call, scope: "plan-A"), .refused(.replayed))
    }

    func testAnOrdinaryYesCannotBeSpentByAPlan() {
        let store = ApprovalGrantStore(sessionID: "s")
        let call = store.binding(seam: .native, toolName: "send_message", definitionDigest: "d", args: [:])
        let grant = store.issue(for: call)
        XCTAssertEqual(store.redeem(nonce: grant.nonce, against: call, scope: "plan-A"), .refused(.scopeMismatch))
    }

    func testAPlanGrantFromAnotherSessionIsRefused() {
        let store = ApprovalGrantStore(sessionID: "s1")
        let call = store.binding(seam: .native, toolName: "send_message", definitionDigest: "d", args: [:])
        let grant = store.issue(for: call, scope: "plan-A")
        let elsewhere = ApprovalBinding(serverIdentity: "native", toolName: "send_message",
                                        definitionDigest: "d", argumentsDigest: call.argumentsDigest,
                                        sessionID: "s2")
        XCTAssertEqual(store.redeem(nonce: grant.nonce, against: elsewhere, scope: "plan-A"),
                       .refused(.sessionMismatch))
        store.rotateSession()
        XCTAssertEqual(store.redeem(nonce: grant.nonce, against: call, scope: "plan-A"), .refused(.noGrant))
    }

    func testRevokingAPlanDropsOnlyItsUnspentGrants() {
        let store = ApprovalGrantStore(sessionID: "s")
        let call = store.binding(seam: .native, toolName: "send_message", definitionDigest: "d", args: [:])
        let a1 = store.issue(for: call, scope: "plan-A")
        _ = store.issue(for: call, scope: "plan-A")
        let other = store.issue(for: call, scope: "plan-B")
        let single = store.issue(for: call)
        XCTAssertEqual(store.revoke(scope: "plan-A"), 2)
        XCTAssertEqual(store.liveGrantCount, 2)
        XCTAssertEqual(store.redeem(nonce: a1.nonce, against: call, scope: "plan-A"), .refused(.noGrant),
                       "a revoked grant was never spent, and cannot be")
        guard case .consumed = store.redeem(nonce: other.nonce, against: call, scope: "plan-B"),
              case .consumed = store.redeem(nonce: single.nonce, against: call) else {
            return XCTFail("other grants are untouched")
        }
    }

    func testThePlanGrantLifetimeIsCapped() async {
        let coordinator = ToolConfirmationCoordinator()
        let approval = PlanApproval(items: [.init(stepIndex: 0, summary: "a", binding: coordinator.approvalGrants.binding(
            seam: .native, toolName: "send_message", definitionDigest: "d", args: [:]))], isSecondHalf: false)
        let answers = answering(coordinator, [true])
        let start = Date()
        let outcome = await coordinator.requestPlanApproval(approval, scope: "p", at: start, ttl: 86_400)
        _ = await answers.value
        guard case .approved(let grants) = outcome, let grant = grants[0] else { return XCTFail() }
        let call = coordinator.approvalGrants.binding(seam: .native, toolName: "send_message",
                                                      definitionDigest: "d", args: [:])
        XCTAssertEqual(coordinator.approvalGrants.redeem(
            nonce: grant.nonce, against: call,
            at: start.addingTimeInterval(PlanApproval.grantLifetimeCeiling + 1), scope: "p"),
            .refused(.expired), "however long a caller asks for, the ceiling holds")
    }

    func testNoGrantIsIssuedForANo() async {
        let coordinator = ToolConfirmationCoordinator()
        let approval = PlanApproval(items: [.init(stepIndex: 0, summary: "a", binding: Self.binding())],
                                    isSecondHalf: false)
        let answers = answering(coordinator, [false])
        let outcome = await coordinator.requestPlanApproval(approval, scope: "p")
        _ = await answers.value
        XCTAssertEqual(outcome, .declined)
        XCTAssertEqual(coordinator.approvalGrants.liveGrantCount, 0)
    }

    func testABusySurfaceAsksNothingAndIssuesNothing() async {
        let coordinator = ToolConfirmationCoordinator()
        let other = Task { await coordinator.requestConfirmation(toolName: "x", summary: "other") }
        for _ in 0..<200 where coordinator.pending == nil { try? await Task.sleep(nanoseconds: 2_000_000) }
        let approval = PlanApproval(items: [.init(stepIndex: 0, summary: "a", binding: Self.binding())],
                                    isSecondHalf: false)
        let outcome = await coordinator.requestPlanApproval(approval, scope: "p")
        XCTAssertEqual(outcome, .busy)
        XCTAssertEqual(coordinator.approvalGrants.liveGrantCount, 0)
        coordinator.resolve(false)
        _ = await other.value
    }

    // MARK: - Preflight comes from the policy ladder

    func testPreflightAsksExactlyWhereTheRouterWould() {
        let rig = rig()
        guard case .confirm(let summary, let binding) = rig.router.planPreflight(
            name: "send_message", args: ["to": "Sam", "body": "running late"]) else {
            return XCTFail("messaging is bound whatever agent mode says")
        }
        XCTAssertEqual(summary, "Send a message to Sam: “running late”")
        XCTAssertEqual(binding.toolName, "send_message")
        XCTAssertEqual(binding.argumentsDigest,
                       CanonicalArgumentDigest.digest(["to": "Sam", "body": "running late"]))
        XCTAssertEqual(binding.sessionID, rig.coordinator.approvalGrants.sessionID)
        XCTAssertEqual(rig.router.planPreflight(name: "lp_lookup", args: [:]), .noAsk, "a read never asks")
        XCTAssertTrue(rig.router.authorizationEvents.events.isEmpty, "a preflight records nothing")
    }

    func testPreflightIgnoresTheValidatorFlag() {
        // `requiresConfirmation` is a reversibility flag; the ladder decides. A read flagged by
        // hand still does not ask, and a message unflagged still does.
        let rig = rig()
        let flagged = AgentStep(tool: "lp_lookup", reversibility: .irreversible, requiresConfirmation: true)
        XCTAssertEqual(rig.router.planPreflight(name: flagged.tool, args: flagged.args), .noAsk)
    }

    func testWithoutAConfirmationSurfaceNothingIsPreflightedAsAsking() {
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(CountingTool(name: "send_message"))
        let router = NativeToolRouter(registry: registry)
        XCTAssertEqual(router.planPreflight(name: "send_message", args: ["to": "Sam"]), .noAsk)
    }

    // MARK: - End to end

    func testATwoMessagePlanAsksOnceAndBothRun() async {
        let rig = rig()
        let runner = AgentRunner(router: rig.router, planner: planner(Self.twoMessages), approvals: rig.router)
        var spoken: [String] = []
        runner.onSpeak = { spoken.append($0) }
        let prompts = answering(rig.coordinator, [true, true, true])

        let result = await runner.run(request: "text Sam and Alex I'm running late",
                                      availableTools: ["send_message"])
        prompts.cancel()
        let asked = await prompts.value

        XCTAssertEqual(asked.count, 1, "one ask for the whole plan")
        XCTAssertEqual(asked.first?.toolName, ToolConfirmationCoordinator.planToolName)
        XCTAssertEqual(asked.first?.summary,
                       "• Send a message to Sam: “running late”\n• Send a message to Alex: “running late”")
        XCTAssertEqual(rig.messages.calls.compactMap { $0["to"] as? String }, ["Sam", "Alex"])
        XCTAssertEqual(result?.completedSteps, 2)
        XCTAssertEqual(result?.aborted, false)
        XCTAssertTrue(spoken.isEmpty, "the ask was the opener; no second sentence: \(spoken)")
        XCTAssertEqual(rig.coordinator.approvalGrants.liveGrantCount, 0, "every grant spent or revoked")
    }

    func testTheAskIsSpokenAsOneSentence() async {
        let rig = rig()
        var spokenPrompts: [String] = []
        rig.coordinator.onSpeakPrompt = { spokenPrompts.append($0) }
        let runner = AgentRunner(router: rig.router, planner: planner(Self.twoMessages), approvals: rig.router)
        let prompts = answering(rig.coordinator, [true])
        _ = await runner.run(request: "x", availableTools: ["send_message"])
        prompts.cancel()
        _ = await prompts.value
        XCTAssertEqual(spokenPrompts, [
            "I'll send a message to Sam: “running late” and send a message to Alex: “running late”. OK?",
        ])
    }

    func testANoAbortsBeforeAnyStepRuns() async {
        let rig = rig()
        let json = """
        {"steps":[
          {"tool":"lp_lookup","rationale":"look it up"},
          {"tool":"send_message","args":{"to":"Sam","body":"a"},"rationale":"text Sam"},
          {"tool":"send_message","args":{"to":"Alex","body":"b"},"rationale":"text Alex"}
        ]}
        """
        let runner = AgentRunner(router: rig.router, planner: planner(json), approvals: rig.router)
        var steps: [Int] = []
        runner.onStep = { index, _, _ in steps.append(index) }
        let prompts = answering(rig.coordinator, [false])
        let result = await runner.run(request: "x", availableTools: ["send_message", "lp_lookup"])
        prompts.cancel()
        _ = await prompts.value
        XCTAssertEqual(rig.messages.runs, 0)
        XCTAssertTrue(steps.isEmpty, "not even the read ran")
        XCTAssertEqual(result?.summary, PlanApprovalPhraser.declinedLine)
        XCTAssertEqual(result?.completedSteps, 0)
        XCTAssertEqual(result?.aborted, true)
        XCTAssertEqual(rig.coordinator.approvalGrants.liveGrantCount, 0)
    }

    func testAOneStepPlanAsksAtTheCallExactlyAsNow() async {
        let rig = rig()
        let json = """
        {"steps":[
          {"tool":"lp_lookup","rationale":"look it up"},
          {"tool":"send_message","args":{"to":"Sam","body":"a"},"rationale":"text Sam"}
        ]}
        """
        let runner = AgentRunner(router: rig.router, planner: planner(json), approvals: rig.router)
        var spoken: [String] = []
        runner.onSpeak = { spoken.append($0) }
        let prompts = answering(rig.coordinator, [true])
        let result = await runner.run(request: "x", availableTools: ["send_message", "lp_lookup"])
        prompts.cancel()
        let asked = await prompts.value
        XCTAssertEqual(asked.map(\.toolName), ["send_message"], "the step's own prompt, not a plan card")
        XCTAssertEqual(asked.first?.summary, "Send a message to Sam: “a”")
        XCTAssertEqual(rig.messages.runs, 1)
        XCTAssertEqual(result?.completedSteps, 2)
        XCTAssertEqual(spoken, ["I'll look it up and text Sam."], "a two-step plan still opens")
    }

    func testFourConfirmableStepsAskInTwoHalvesAndANoToTheSecondRunsNothing() async {
        let rig = rig()
        let json = """
        {"steps":[
          {"tool":"send_message","args":{"to":"A","body":"1"}},
          {"tool":"send_message","args":{"to":"B","body":"2"}},
          {"tool":"send_message","args":{"to":"C","body":"3"}},
          {"tool":"send_message","args":{"to":"D","body":"4"}}
        ]}
        """
        let runner = AgentRunner(router: rig.router, planner: planner(json), approvals: rig.router)
        let prompts = answering(rig.coordinator, [true, false])
        let result = await runner.run(request: "x", availableTools: ["send_message"])
        prompts.cancel()
        let asked = await prompts.value
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(rig.messages.runs, 0, "a no to either half stops the plan before it starts")
        XCTAssertEqual(result?.aborted, true)
        XCTAssertEqual(rig.coordinator.approvalGrants.liveGrantCount, 0,
                       "the first half's grants died with the plan")
    }

    func testGrantsDieWithThePlanWhenAStepStopsIt() async {
        let rig = rig()
        // The first message's tool is switched off, so the plan stops at step 1 with step 2's
        // grant unspent.
        let json = """
        {"steps":[
          {"tool":"lp_missing","rationale":"nothing"},
          {"tool":"send_message","args":{"to":"Sam","body":"a"}},
          {"tool":"send_message","args":{"to":"Alex","body":"b"}}
        ]}
        """
        let runner = AgentRunner(router: rig.router, planner: planner(json), approvals: rig.router)
        let prompts = answering(rig.coordinator, [true])
        let result = await runner.run(request: "x", availableTools: ["send_message", "lp_missing"])
        prompts.cancel()
        _ = await prompts.value
        XCTAssertEqual(result?.aborted, true)
        XCTAssertEqual(rig.messages.runs, 0)
        XCTAssertEqual(rig.coordinator.approvalGrants.liveGrantCount, 0, "unspent grants are revoked")
    }

    /// The other half of "a changed argument still asks": a grant bound to Sam presented by a call
    /// to Alex spends nothing, and the call raises its own prompt.
    func testAStepWhoseArgumentsChangedAsksOnItsOwn() async {
        let rig = rig()
        let approvedFor = rig.coordinator.approvalGrants.binding(
            seam: .native, toolName: "send_message",
            definitionDigest: ToolDefinitionDigest.digest(name: rig.messages.name,
                                                          description: rig.messages.description,
                                                          schema: rig.messages.parametersSchema),
            args: ["to": "Sam", "body": "a"])
        let grant = rig.coordinator.approvalGrants.issue(for: approvedFor, scope: "plan-A")
        let prompts = answering(rig.coordinator, [false])
        let outcome = await PlanApprovalScope.$stepGrant.withValue(PlanStepGrant(nonce: grant.nonce, scope: "plan-A")) {
            await rig.router.executeRoot(name: "send_message", args: ["to": "Alex", "body": "a"])
        }
        prompts.cancel()
        let asked = await prompts.value
        XCTAssertEqual(asked.map(\.toolName), ["send_message"], "the changed call asked on its own")
        guard case .rejected = outcome else { return XCTFail("declined, so it did not run") }
        XCTAssertEqual(rig.messages.runs, 0)
        XCTAssertEqual(rig.coordinator.approvalGrants.liveGrantCount, 1, "Sam's grant is untouched")
        XCTAssertEqual(rig.router.authorizationEvents.events.last?.verdict,
                       ApprovalRefusalReason.argumentsChanged.rawValue)
    }

    func testAGrantFromAnotherPlanRunAsksAtTheCall() async {
        let rig = rig()
        let args: [String: Any] = ["to": "Sam", "body": "a"]
        guard case .confirm(_, let binding) = rig.router.planPreflight(name: "send_message", args: args) else {
            return XCTFail()
        }
        let grant = rig.coordinator.approvalGrants.issue(for: binding, scope: "plan-A")
        let prompts = answering(rig.coordinator, [false])
        _ = await PlanApprovalScope.$stepGrant.withValue(PlanStepGrant(nonce: grant.nonce, scope: "plan-B")) {
            await rig.router.executeRoot(name: "send_message", args: args)
        }
        prompts.cancel()
        let asked = await prompts.value
        XCTAssertEqual(asked.count, 1, "plan B's step could not ride plan A's yes")
        XCTAssertEqual(rig.messages.runs, 0)
    }

    func testAMatchingPlanGrantRunsTheStepWithoutAPrompt() async {
        let rig = rig()
        let args: [String: Any] = ["to": "Sam", "body": "a"]
        guard case .confirm(_, let binding) = rig.router.planPreflight(name: "send_message", args: args) else {
            return XCTFail()
        }
        let grant = rig.coordinator.approvalGrants.issue(for: binding, scope: "plan-A")
        let scoped = PlanStepGrant(nonce: grant.nonce, scope: "plan-A")
        let first = await PlanApprovalScope.$stepGrant.withValue(scoped) {
            await rig.router.executeRoot(name: "send_message", args: args)
        }
        XCTAssertEqual(first, .completed("sent"))
        XCTAssertNil(rig.coordinator.pending)
        // Single use: the same grant presented again asks.
        let prompts = answering(rig.coordinator, [false])
        _ = await PlanApprovalScope.$stepGrant.withValue(scoped) {
            await rig.router.executeRoot(name: "send_message", args: args)
        }
        prompts.cancel()
        let askedAgain = await prompts.value
        XCTAssertEqual(askedAgain.count, 1)
        XCTAssertEqual(rig.messages.runs, 1)
    }

    func testAPlanWithoutAnApprovalSeamBehavesAsBefore() async {
        let rig = rig()
        let runner = AgentRunner(router: rig.router, planner: planner(Self.twoMessages))
        let prompts = answering(rig.coordinator, [true, true])
        _ = await runner.run(request: "x", availableTools: ["send_message"])
        prompts.cancel()
        let asked = await prompts.value
        XCTAssertEqual(asked.map(\.toolName), ["send_message", "send_message"], "each step at its call")
    }
}
