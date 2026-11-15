import XCTest
@testable import OpenGlasses

/// A Shortcut the assistant was going to run, then held, has to stay nameable. Field report: the
/// assistant offered to run a Shortcut, the call was held while the wearer was away, and nothing
/// more was said; asked later "what was the shortcut you were gonna run", it answered that
/// "run_shortcut" was only the internal action label and no Shortcut name was recorded.
///
/// Three things lost the name: the approval and hold summary read `name` where the tool's argument
/// is `shortcut_name` ("Run the Shortcut “?”"); the model was told only the tool's name about the
/// hold; and a finished turn keeps none of its tool calls, so a later turn had nothing to look at.
/// Invented Shortcut names only.
@MainActor
final class HeldShortcutNameTests: XCTestCase {

    private var workspace: URL!
    private var savedAgentMode = false

    override func setUp() {
        super.setUp()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeldShortcutNameTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        savedAgentMode = Config.agentModeEnabled
    }

    override func tearDown() {
        Config.setAgentModeEnabled(savedAgentMode)
        try? FileManager.default.removeItem(at: workspace)
        super.tearDown()
    }

    // MARK: - The summary names the Shortcut

    func testTheSummaryReadsTheToolsOwnArgument() {
        XCTAssertEqual(PromptInjectionPolicy.actionSummary(toolName: "run_shortcut",
                                                           args: ["shortcut_name": "Log Water"]),
                       "Run the Shortcut “Log Water”")
    }

    func testTheSummaryStillReadsTheOldKey() {
        XCTAssertEqual(PromptInjectionPolicy.actionSummary(toolName: "run_shortcut",
                                                           args: ["name": "Morning Routine"]),
                       "Run the Shortcut “Morning Routine”")
    }

    func testTheSummaryCarriesTheInput() {
        XCTAssertEqual(PromptInjectionPolicy.actionSummary(toolName: "run_shortcut",
                                                           args: ["shortcut_name": " Log Water ",
                                                                  "input": "500 ml"]),
                       "Run the Shortcut “Log Water” with the input “500 ml”")
    }

    func testANamelessCallSaysSoRatherThanAQuestionMark() {
        let summary = PromptInjectionPolicy.actionSummary(toolName: "run_shortcut",
                                                          args: ["shortcut_name": "  "])
        XCTAssertEqual(summary, "Run a Shortcut (no Shortcut name was given)")
        XCTAssertFalse(summary.contains("“?”"))
    }

    // MARK: - What the model is told

    func testTheHoldTellsTheModelWhichShortcutAndToSaySo() {
        let input = ToolAuthorizationPolicy.Input(
            call: .root(name: "run_shortcut", arguments: ToolArguments(["shortcut_name": "Check Email"]),
                        origin: .model),
            agentModeEnabled: true,
            safetyContext: SafetyContext(now: Date(), location: nil, homeRegion: nil, enabledRules: [],
                                         quietHoursStart: 22, quietHoursEnd: 7, autonomy: .paused),
            effectClass: .unknown)
        guard case .hold(let summary, let message) = ToolAuthorizationPolicy.evaluate(input) else {
            return XCTFail("away, an acting call is held")
        }
        XCTAssertEqual(summary, "Run the Shortcut “Check Email”")
        XCTAssertTrue(message.contains("Run the Shortcut “Check Email”"), message)
        XCTAssertTrue(message.contains("has NOT run"), message)
        XCTAssertTrue(message.contains("naming it"), message)
        XCTAssertTrue(message.hasPrefix(ToolAuthorizationPolicy.holdMessage("run_shortcut")),
                      "a plan's stop is still recognised by the fixed opening")
    }

    func testAPlanStillReadsANamedHoldAsAHold() {
        let reason = ToolAuthorizationPolicy.holdMessage("run_shortcut", held: "Run the Shortcut “Check Email”")
        XCTAssertEqual(PlanStop.kind(of: .rejected(reason: reason), tool: "run_shortcut"), .held)
    }

    func testABusyAskIsNotADecline() {
        let reason = ToolAuthorizationPolicy.busyConfirmationMessage("run_shortcut",
                                                                     held: "Run the Shortcut “Check Email”")
        XCTAssertFalse(reason.hasPrefix(ToolAuthorizationPolicy.declineMessage("run_shortcut")))
        XCTAssertTrue(reason.contains("Run the Shortcut “Check Email”"))
        XCTAssertEqual(PlanStop.kind(of: .rejected(reason: reason), tool: "run_shortcut"), .needsApproval)
    }

    // MARK: - The router keeps what the turn held

    private final class FakeShortcutTool: NativeTool {
        let name = "run_shortcut"
        let description = "held shortcut fixture"
        var parametersSchema: [String: Any] { ["type": "object"] }
        private(set) var runs = 0
        func execute(args: [String: Any]) async throws -> String {
            runs += 1
            return "ran"
        }
    }

    private func router() -> (NativeToolRouter, FakeShortcutTool, ToolConfirmationCoordinator) {
        let registry = NativeToolRegistry(locationService: LocationService())
        let tool = FakeShortcutTool()
        registry.register(tool)
        let router = NativeToolRouter(registry: registry)
        router.operationJournal = ProtectedOperationJournal(
            directory: workspace.appendingPathComponent("journal", isDirectory: true))
        let coordinator = ToolConfirmationCoordinator()
        router.confirmationCoordinator = coordinator
        return (router, tool, coordinator)
    }

    func testAHeldShortcutIsKeptForTheTurnByName() async {
        let (router, tool, _) = router()
        Config.setAgentModeEnabled(true)
        router.safetyContextProvider = {
            SafetyContext(now: Date(), location: nil, homeRegion: nil, enabledRules: [],
                          quietHoursStart: 22, quietHoursEnd: 7, autonomy: .paused)
        }
        var heard: [String] = []
        router.onActionHeld = { heard.append($0) }

        let outcome = await router.executeRoot(name: "run_shortcut", args: ["shortcut_name": "Check Email"])
        guard case .rejected(let reason) = outcome else { return XCTFail("held, not run") }
        XCTAssertTrue(reason.contains("Run the Shortcut “Check Email”"), reason)
        XCTAssertEqual(tool.runs, 0)
        XCTAssertEqual(heard, ["Run the Shortcut “Check Email”"], "the re-engagement line names it too")

        XCTAssertEqual(router.takeTurnUnrunActions(), ["Run the Shortcut “Check Email”"])
        XCTAssertEqual(router.takeTurnUnrunActions(), [], "taken once")
    }

    func testAHoldOutsideTheModelsTurnBelongsToNoReply() async {
        let (router, _, _) = router()
        Config.setAgentModeEnabled(true)
        router.safetyContextProvider = {
            SafetyContext(now: Date(), location: nil, homeRegion: nil, enabledRules: [],
                          quietHoursStart: 22, quietHoursEnd: 7, autonomy: .paused)
        }
        _ = await LLMService.OffConversationScope.$isActive.withValue(true) {
            await router.executeRoot(name: "run_shortcut", args: ["shortcut_name": "Check Email"])
        }
        XCTAssertEqual(router.takeTurnUnrunActions(), [], "a scheduled run's hold is not the next reply's")
    }

    func testASecondAskWhileACardIsUpIsNamedNotDeclined() async {
        let (router, tool, coordinator) = router()
        Config.setAgentModeEnabled(false)

        // The first Shortcut's card goes up and stays up.
        async let first = router.executeRoot(name: "run_shortcut", args: ["shortcut_name": "Log Water"])
        for _ in 0..<200 where coordinator.pending == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(coordinator.pending)
        XCTAssertEqual(coordinator.pending?.summary, "Run the Shortcut “Log Water”",
                       "the card names the Shortcut")

        let second = await router.executeRoot(name: "run_shortcut", args: ["shortcut_name": "Check Email"])
        guard case .rejected(let reason) = second else { return XCTFail("not asked, so not run") }
        XCTAssertFalse(reason.contains("did NOT approve"), "the wearer never saw it: " + reason)
        XCTAssertTrue(reason.contains("Run the Shortcut “Check Email”"), reason)
        XCTAssertEqual(router.takeTurnUnrunActions(), ["Run the Shortcut “Check Email”"])

        coordinator.resolve(false)
        _ = await first
        XCTAssertEqual(tool.runs, 0)
    }

    // MARK: - The saved reply carries it, on screen and to the model

    func testTheModelNoteNamesWhatWasHeld() throws {
        let note = try XCTUnwrap(HeldActionNote.modelNote(["Run the Shortcut “Check Email”"]))
        XCTAssertTrue(note.contains("Run the Shortcut “Check Email”"))
        XCTAssertTrue(note.contains("has NOT run"))
        XCTAssertNil(HeldActionNote.modelNote([]))
        XCTAssertNil(HeldActionNote.modelNote(["  "]))
    }

    func testTheLiveHistoryGetsTheNoteOnTheLastReplyOnly() {
        let history: [[String: Any]] = [
            ["role": "assistant", "content": "Earlier."],
            ["role": "user", "content": "Check my email"],
            ["role": "assistant", "content": "I'll run your Check Email Shortcut."],
        ]
        let noted = HeldActionNote.appendingToLastAssistant(history, held: ["Run the Shortcut “Check Email”"])
        XCTAssertEqual(noted[0]["content"] as? String, "Earlier.")
        let last = noted[2]["content"] as? String ?? ""
        XCTAssertTrue(last.hasPrefix("I'll run your Check Email Shortcut."))
        XCTAssertTrue(last.contains("Run the Shortcut “Check Email”"))
        XCTAssertEqual(noted.count, history.count, "no message is added: the turn order is unchanged")
    }

    func testTheLiveHistoryKeepsABlockReplysShape() {
        let history: [[String: Any]] = [
            ["role": "assistant", "content": [["type": "text", "text": "On it."]]],
        ]
        let noted = HeldActionNote.appendingToLastAssistant(history, held: ["Run the Shortcut “Log Water”"])
        let blocks = noted[0]["content"] as? [[String: Any]]
        XCTAssertEqual(blocks?.count, 1)
        XCTAssertTrue((blocks?.first?["text"] as? String ?? "").contains("“Log Water”"))
    }

    func testNothingHeldLeavesTheHistoryAlone() {
        let history: [[String: Any]] = [["role": "assistant", "content": "Done."]]
        let noted = HeldActionNote.appendingToLastAssistant(history, held: [])
        XCTAssertEqual(noted[0]["content"] as? String, "Done.")
    }

    func testTheSavedReplyKeepsItsHeldActionsAndReplaysThemToTheModel() throws {
        let store = ConversationStore(directory: workspace)
        let thread = store.startThread(mode: "direct").id
        store.appendMessage(role: "user", content: "Check my email")
        store.appendMessage(role: "assistant", content: "I'll run your Check Email Shortcut.",
                            toolNames: ["run_shortcut"],
                            heldActions: ["Run the Shortcut “Check Email”"])
        store.appendMessage(role: "assistant", content: "Tomorrow will be mostly cloudy.")

        // Saved and read back, as after a relaunch.
        let reopened = ConversationStore(directory: workspace)
        let messages = try XCTUnwrap(reopened.threads.first?.messages)
        XCTAssertEqual(messages[1].held, ["Run the Shortcut “Check Email”"])
        XCTAssertNil(messages[2].heldActions, "an ordinary reply stores nothing")

        let replay = reopened.replayMessages(for: thread)
        let held = try XCTUnwrap(replay.first { $0.content.hasPrefix("I'll run your Check Email") })
        XCTAssertTrue(held.content.contains("Run the Shortcut “Check Email”"),
                      "asked later which Shortcut, the model can say")
        XCTAssertEqual(replay.last?.content, "Tomorrow will be mostly cloudy.")
    }

    func testAnOldSavedReplyDecodesWithNothingHeld() throws {
        let json = #"{"id":"m1","role":"assistant","content":"Hi","imageAttached":false,"timestamp":0}"#
        let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.held, [])
    }

    // MARK: - A plan that stopped at the Shortcut names it

    func testAPlansHeldStepNamesTheShortcutItsRationaleLeftOut() {
        let plan = AgentPlan(goal: "check email", steps: [
            AgentStep(tool: "run_shortcut", args: ["shortcut_name": "Check Email"], rationale: "Run the shortcut."),
            AgentStep(tool: "speak", rationale: "tell you what's urgent"),
        ])
        let run = PlanRunResult(completedSteps: 0, aborted: true,
                                stop: PlanStop(stepIndex: 0, kind: .held), transcript: [])
        XCTAssertEqual(AgentRunner.summary(plan: plan, run: run),
                       "I didn't run the shortcut (the “Check Email” Shortcut) — you've been away, so I've held it for when you're back. I stopped there.")
    }

    func testARationaleThatAlreadyNamesTheShortcutIsLeftAsItIs() {
        let step = AgentStep(tool: "run_shortcut", args: ["shortcut_name": "Check Email"],
                             rationale: "Run the Check Email shortcut.")
        XCTAssertEqual(AgentRunner.described(step), "run the Check Email shortcut")
    }
}
