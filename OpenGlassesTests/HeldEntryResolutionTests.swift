import XCTest
@testable import OpenGlasses

/// Plan LE P1 §3 — a held entry resolves when the same call reaches the authorization boundary
/// again. The hold carries a key (seam, tool, definition, argument digest); the answer to the same
/// call finds it by that key; a different call, or a hold past its lifetime, is left alone. Invented
/// names only.
@MainActor
final class HeldEntryResolutionTests: XCTestCase {
    private typealias F = OpenLoopFixture

    private var workspace: URL!
    private var savedAgentMode = false

    override func setUp() {
        super.setUp()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeldEntryResolutionTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        savedAgentMode = Config.agentModeEnabled
    }

    override func tearDown() {
        Config.setAgentModeEnabled(savedAgentMode)
        try? FileManager.default.removeItem(at: workspace)
        super.tearDown()
    }

    // MARK: Fixtures

    private final class FakeTool: NativeTool {
        let name: String
        let description = "held entry fixture"
        var parametersSchema: [String: Any] { ["type": "object"] }
        let executionSemantics: ToolExecutionSemantics
        private(set) var runs = 0
        init(_ name: String, _ semantics: ToolExecutionSemantics) {
            self.name = name
            self.executionSemantics = semantics
        }
        func execute(args: [String: Any]) async throws -> String {
            runs += 1
            return "done"
        }
    }

    private struct Rig {
        let router: NativeToolRouter
        let store: ActivityStore
        let tool: FakeTool
        let coordinator: ToolConfirmationCoordinator
    }

    /// `.external` asks for a bound approval whatever the ladder says; `.local()` lets the ladder
    /// alone decide, which with Agent Mode on and the wearer present is to let it run.
    private func rig(_ semantics: ToolExecutionSemantics = .external(.bestEffort)) -> Rig {
        let registry = NativeToolRegistry(locationService: LocationService())
        let tool = FakeTool("send_message", semantics)
        registry.register(tool)
        let router = NativeToolRouter(registry: registry)
        router.operationJournal = ProtectedOperationJournal(
            directory: workspace.appendingPathComponent("journal", isDirectory: true))
        let store = ActivityStore(directory: workspace.appendingPathComponent("trail", isDirectory: true),
                                  hipaaMode: { false }, hipaaRetentionDays: { nil })
        router.activityRecorder = ActivityRecorder(store: store)
        let coordinator = ToolConfirmationCoordinator()
        router.confirmationCoordinator = coordinator
        return Rig(router: router, store: store, tool: tool, coordinator: coordinator)
    }

    /// Hold the call: Agent Mode on and the wearer away, so the presence ceiling holds it.
    private func hold(_ rig: Rig, args: [String: Any]) async {
        Config.setAgentModeEnabled(true)
        rig.router.safetyContextProvider = {
            SafetyContext(now: Date(), location: nil, homeRegion: nil, enabledRules: [],
                          quietHoursStart: 22, quietHoursEnd: 7, autonomy: .paused)
        }
        _ = await rig.router.executeRoot(name: "send_message", args: args)
        // Back with the wearer: Agent Mode off, so the actuation floor asks before it runs.
        Config.setAgentModeEnabled(false)
        rig.router.safetyContextProvider = nil
    }

    private func answer(_ coordinator: ToolConfirmationCoordinator, approve: Bool) async {
        for _ in 0..<200 {
            if coordinator.pending != nil {
                coordinator.resolve(approve)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("confirmation never became pending")
    }

    // MARK: The hold carries a key

    func testAHeldCallIsFiledUnderAKeyThatHoldsNoneOfItsWords() async throws {
        let rig = rig()
        await hold(rig, args: ["to": "Mere", "body": "running late"])
        let entry = try XCTUnwrap(rig.store.entries.first)
        XCTAssertEqual(entry.kind, .held)
        let key = try XCTUnwrap(entry.holdKey)
        XCTAssertEqual(key.count, 32, "a 16-byte digest")
        XCTAssertFalse(key.contains("Mere"))
        XCTAssertNil(entry.detail)
        XCTAssertTrue(rig.router.canReplayHeld(key: key), "the call is kept, in memory, to put back")
        XCTAssertEqual(rig.tool.runs, 0)
    }

    func testTheKeyRoundTripsOnDiskAndAnOldEntryHasNone() throws {
        let entry = F.held(1, at: F.at(9))
        XCTAssertNil(entry.holdKey)
        let keyed = ActivityEntry(id: F.uuid(9), at: F.at(9), kind: .held, title: "Your OK", tool: "send_message",
                                  authorisation: .heldForYou, origin: .agent, outcome: .waitingOnYou,
                                  holdKey: "abc123")
        let data = try RecordJSONCodec.encoder().encode([entry, keyed])
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(json.components(separatedBy: "holdKey").count - 1, 1, "written only when set")
        XCTAssertEqual(try RecordJSONCodec.decoder().decode([ActivityEntry].self, from: data), [entry, keyed])
    }

    // MARK: Approve, decline, unmatched

    func testApprovingTheSameCallLaterResolvesTheHoldApproved() async throws {
        let rig = rig()
        await hold(rig, args: ["to": "Mere", "body": "running late"])

        async let outcome = rig.router.executeRoot(name: "send_message",
                                                   args: ["to": "Mere", "body": "running late"])
        await answer(rig.coordinator, approve: true)
        let result = await outcome
        XCTAssertEqual(result, .completed("done"))

        let entry = try XCTUnwrap(rig.store.entries.first { $0.kind == .held })
        XCTAssertEqual(entry.resolution, .approved)
        XCTAssertNotNil(entry.resolvedAt)
        XCTAssertFalse(entry.isAwaitingWearer)
        XCTAssertFalse(rig.router.canReplayHeld(key: try XCTUnwrap(entry.holdKey)), "the kept copy goes once answered")
        XCTAssertTrue(OpenLoopApprovals.loops(from: rig.store.entries, now: Date(), calendar: .current).isEmpty)
    }

    func testDecliningTheSameCallLaterResolvesTheHoldDeclined() async throws {
        let rig = rig()
        await hold(rig, args: ["to": "Mere", "body": "running late"])

        async let outcome = rig.router.executeRoot(name: "send_message",
                                                   args: ["to": "Mere", "body": "running late"])
        await answer(rig.coordinator, approve: false)
        let result = await outcome
        guard case .rejected = result else { return XCTFail("a declined call does not run") }

        let entry = try XCTUnwrap(rig.store.entries.first { $0.kind == .held })
        XCTAssertEqual(entry.resolution, .declined)
        XCTAssertEqual(rig.tool.runs, 0)
    }

    func testAnAnswerToADifferentCallLeavesTheHoldAlone() async throws {
        let rig = rig()
        await hold(rig, args: ["to": "Mere", "body": "running late"])

        async let outcome = rig.router.executeRoot(name: "send_message",
                                                   args: ["to": "Tama", "body": "on my way"])
        await answer(rig.coordinator, approve: true)
        let result = await outcome
        XCTAssertEqual(result, .completed("done"))

        let entry = try XCTUnwrap(rig.store.entries.first { $0.kind == .held })
        XCTAssertNil(entry.resolution, "another recipient is another question")
        XCTAssertTrue(entry.isAwaitingWearer)
        XCTAssertTrue(rig.router.canReplayHeld(key: try XCTUnwrap(entry.holdKey)))
    }

    // MARK: Replay from the check-in

    func testPuttingAHeldCallBackRunsItsOwnConfirmationAndItsAnswerResolvesTheHold() async throws {
        let rig = rig()
        await hold(rig, args: ["to": "Mere", "body": "running late"])
        let key = try XCTUnwrap(rig.store.entries.first?.holdKey)

        async let replayed = rig.router.replayHeld(key: key)
        await answer(rig.coordinator, approve: true)
        let result = await replayed
        XCTAssertEqual(result, .completed("done"))
        XCTAssertEqual(rig.tool.runs, 1)
        XCTAssertEqual(rig.store.entries.first { $0.kind == .held }?.resolution, .approved)
        let again = await rig.router.replayHeld(key: key)
        XCTAssertNil(again, "answered: nothing left to put back")
    }

    /// Agent Mode on with the wearer present and no rules: the ladder lets the call run by itself.
    private func presentWithAgentMode(_ rig: Rig) {
        Config.setAgentModeEnabled(true)
        rig.router.safetyContextProvider = {
            SafetyContext(now: Date(), location: nil, homeRegion: nil, enabledRules: [],
                          quietHoursStart: 22, quietHoursEnd: 7, autonomy: .autoAct)
        }
    }

    func testTheSameCallRunningByItselfLaterResolvesTheHoldApproved() async throws {
        let rig = rig(.local())
        await hold(rig, args: ["to": "Mere", "body": "running late"])
        presentWithAgentMode(rig)
        // No coordinator: were the ladder to ask after all, the call fails closed rather than wait
        // on an answer nobody gives.
        rig.router.confirmationCoordinator = nil
        let result = await rig.router.executeRoot(name: "send_message",
                                                  args: ["to": "Mere", "body": "running late"])
        XCTAssertEqual(result, .completed("done"))
        XCTAssertEqual(rig.tool.runs, 1, "the ladder let it run without asking")
        XCTAssertEqual(rig.store.entries.first { $0.kind == .held }?.resolution, .approved)
    }

    func testAReplayAsksEvenWhereTheLadderWouldLetItRun() async throws {
        // The same call the ladder would now let through by itself: put back from the check-in, it
        // still asks, because the wearer's tap is a request to see it, not a yes.
        let rig = rig(.local())
        await hold(rig, args: ["to": "Mere", "body": "running late"])
        let key = try XCTUnwrap(rig.store.entries.first?.holdKey)
        presentWithAgentMode(rig)

        async let replayed = rig.router.replayHeld(key: key)
        await answer(rig.coordinator, approve: false)
        let result = await replayed
        guard case .rejected? = result else { return XCTFail("a declined replay does not run") }
        XCTAssertEqual(rig.tool.runs, 0)
        XCTAssertEqual(rig.store.entries.first { $0.kind == .held }?.resolution, .declined)
    }

    // MARK: Expiry

    func testAHoldPastItsLifetimeReadsAsExpiredAndAnAnswerCannotReachIt() {
        let entry = ActivityEntry(id: F.uuid(1), at: F.at(9, day: 11), kind: .held, title: "Your OK",
                                  tool: "send_message", authorisation: .heldForYou, origin: .agent,
                                  outcome: .waitingOnYou, holdKey: "k1")
        XCTAssertTrue(entry.isAwaitingWearer, "nothing was written")
        XCTAssertFalse(entry.isAwaitingWearer(at: F.now), "but three days on it is not waiting")
        XCTAssertEqual(entry.effectiveResolution(at: F.now), .expired)
        XCTAssertNil(entry.effectiveResolution(at: F.at(10, day: 11)))

        let store = ActivityStore(directory: workspace.appendingPathComponent("expiry", isDirectory: true),
                                  clock: { F.at(10, day: 11) }, hipaaMode: { false }, hipaaRetentionDays: { nil })
        store.append(entry)
        XCTAssertEqual(store.resolveHold(key: "k1", resolution: .approved, at: F.now), 0)
        XCTAssertNil(store.entries.first?.resolution)
    }

    func testTheSameCallHeldTwiceIsOneApprovalAndOneAnswerResolvesBoth() {
        let first = ActivityEntry(id: F.uuid(1), at: F.at(9), kind: .held, title: "Your OK to use the shortcut tool",
                                  tool: "shortcut", authorisation: .heldForYou, origin: .scheduled,
                                  outcome: .waitingOnYou, holdKey: "k1")
        let second = ActivityEntry(id: F.uuid(2), at: F.at(9, 15), kind: .held, title: "Your OK to use the shortcut tool",
                                   tool: "shortcut", authorisation: .heldForYou, origin: .scheduled,
                                   outcome: .waitingOnYou, holdKey: "k1")
        let loops = OpenLoopApprovals.loops(from: [first, second], now: F.now, calendar: F.calendar)
        XCTAssertEqual(loops.map(\.id), [OpenLoopApprovals.id(for: second)], "the newest hold of the call")

        let store = ActivityStore(directory: workspace.appendingPathComponent("twice", isDirectory: true),
                                  clock: { F.at(10) }, hipaaMode: { false }, hipaaRetentionDays: { nil })
        store.append(first)
        store.append(second)
        XCTAssertEqual(store.resolveHold(key: "k1", resolution: .declined, at: F.at(10)), 2)
        XCTAssertTrue(store.entries.allSatisfy { $0.resolution == .declined })
    }

    func testDecliningOneEntryFromTheRowAnswersOnlyAHeldEntryStillWaiting() {
        let store = ActivityStore(directory: workspace.appendingPathComponent("row", isDirectory: true),
                                  clock: { F.at(10) }, hipaaMode: { false }, hipaaRetentionDays: { nil })
        let waiting = F.held(1, at: F.at(9))
        let action = ActivityEntry(id: F.uuid(2), at: F.at(9), kind: .action, title: "Sent a message",
                                   authorisation: .asked, origin: .wearer, outcome: .done)
        store.append(waiting)
        store.append(action)
        XCTAssertTrue(store.resolve(entryID: waiting.id, as: .declined, at: F.at(10)))
        XCTAssertFalse(store.resolve(entryID: waiting.id, as: .approved, at: F.at(10)), "answered once")
        XCTAssertFalse(store.resolve(entryID: action.id, as: .declined, at: F.at(10)), "not a hold")
        XCTAssertEqual(store.entries.first { $0.id == waiting.id }?.resolution, .declined)
    }
}
