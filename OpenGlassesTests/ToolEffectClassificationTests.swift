import XCTest
@testable import OpenGlasses

/// Plan DJ P2 — every registered tool says what running it does to the world, and the router says
/// honestly what happened when it stops waiting.
///
/// Two properties are pinned here. The first is the migration gate: an unclassified tool inherits
/// the worst case, and a *newly registered* one that does so fails the build, so the debt can only
/// shrink. The second is that a timeout on side-effecting work produces an uncertain outcome rather
/// than a failure — the shape the old success/failure pair could not express, and the one that let a
/// model retry a message that had already been sent.
@MainActor
final class ToolEffectClassificationTests: XCTestCase {

    // MARK: - Fixtures

    /// A one-shot signal with no polling and no sleeping: the test releases the tool, or waits for
    /// the tool to be cancelled, by awaiting a continuation the other side resumes.
    private final class AsyncSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func fire() {
            lock.lock()
            let pending = waiters
            waiters = []
            fired = true
            lock.unlock()
            for waiter in pending { waiter.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if fired {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }

        var hasFired: Bool {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }
    }

    /// Parks until the test releases it, and records whether it was ever asked to stop.
    private struct ParkedTool: NativeTool {
        let name: String
        let description = "parked test fixture"
        let executionSemantics: ToolExecutionSemantics
        let release: AsyncSignal
        let cancelled: AsyncSignal
        var parametersSchema: [String: Any] { ["type": "object"] }

        func execute(args: [String: Any]) async throws -> String {
            await withTaskCancellationHandler {
                await release.wait()
                return "finished"
            } onCancel: {
                cancelled.fire()
            }
        }
    }

    private func parked(_ name: String, _ semantics: ToolExecutionSemantics)
        -> (tool: ParkedTool, release: AsyncSignal, cancelled: AsyncSignal) {
        let release = AsyncSignal(), cancelled = AsyncSignal()
        return (ParkedTool(name: name, executionSemantics: semantics,
                           release: release, cancelled: cancelled), release, cancelled)
    }

    private func router(with tool: any NativeTool, timeout: TimeInterval = 0.05) -> NativeToolRouter {
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(tool)
        let router = NativeToolRouter(registry: registry)
        router.toolTimeoutSeconds = timeout
        return router
    }

    // MARK: - Migration gate

    /// The one assertion that stops the unclassified set growing. A tool registered without an
    /// `executionSemantics` row inherits the worst case silently; here it doesn't.
    ///
    /// The registry is built as wide as it can be built headlessly — camera, conversation store, and
    /// the entitlement-gated families switched on for the duration — so the families that register
    /// conditionally are covered too.
    func testEveryRegisteredToolDeclaresItsExecutionSemantics() {
        // Tool *names* whose worst-case classification is the intended answer rather than
        // outstanding debt. Empty today: the two types that legitimately can't be inspected — a
        // user-authored HTTP call and a skill-pack wrapper — are excluded by type below, because
        // their names come from user content and can't be listed here.
        let intentionallyConservative: Set<String> = []

        let registry = widestRegistry()
        var unclassified: [String] = []
        for tool in registry.allTools {
            guard !(tool is SkillPackToolWrapper), !(tool is CustomToolWrapper),
                  !intentionallyConservative.contains(tool.name) else { continue }
            if tool.executionSemantics == .conservativeDefault { unclassified.append(tool.name) }
        }

        XCTAssertEqual(unclassified.sorted(), [],
                       "these tools inherit the conservative default; give each a row in "
                           + "ToolEffectClassification.swift, or list it as deliberate debt here")
        XCTAssertGreaterThan(registry.allTools.count, 60,
                             "the fixture registry must actually be wide, or the gate proves little")
    }

    func testConservativeDefaultIsTheWorstCaseOnEveryAxis() {
        let fallback = ToolExecutionSemantics.conservativeDefault
        XCTAssertEqual(fallback.effect, .externalMutation)
        XCTAssertEqual(fallback.cancellation, .notCancellable)
        XCTAssertEqual(fallback.idempotency, .none)
        XCTAssertFalse(fallback.timeoutIsAuthoritative,
                       "an unclassified tool must never be reported as not having run")
        XCTAssertFalse(fallback.isSafeToRepeat)

        // A tool that declares nothing gets exactly that.
        struct Undeclared: NativeTool {
            let name = "undeclared"
            let description = ""
            var parametersSchema: [String: Any] { [:] }
            func execute(args: [String: Any]) async throws -> String { "" }
        }
        XCTAssertEqual(Undeclared().executionSemantics, .conservativeDefault)
    }

    // MARK: - Coherence with the composition floor

    /// The classification and the composition floor must not drift apart. Everything the router
    /// would stop and confirm is an acting tool by its own declaration — if one were ever marked
    /// read-only, a timeout on it would start claiming it hadn't run.
    func testEveryRestrictedTargetIsClassifiedAsActing() {
        let registry = widestRegistry()
        let restricted = registry.allTools.filter { ComposedToolPolicy.isRestrictedTarget($0.name) }

        // The gateway pseudo-tool has no registry entry; every other restricted name does.
        let names = Set(restricted.map(\.name))
        for expected in ["smart_home", "home_assistant", "send_message", "send_via", "phone_call",
                         "run_shortcut", "medical_export", "code_agent"] {
            XCTAssertTrue(names.contains(expected),
                          "\(expected) must be present for this check to mean anything")
        }

        for tool in restricted {
            XCTAssertTrue(
                [.externalMutation, .physicalActuation].contains(tool.executionSemantics.effect),
                "\(tool.name) is confirmed by the router but declares "
                    + "\(tool.executionSemantics.effect.rawValue)")
            XCTAssertFalse(tool.executionSemantics.timeoutIsAuthoritative,
                           "\(tool.name) must never report a timeout as not having happened")
        }
    }

    /// The read-only classification is load-bearing in the other direction too: these are the tools
    /// a timeout *may* honestly call a failure.
    func testReadOnlyToolsAreTheOnlyAuthoritativeTimeouts() {
        let registry = widestRegistry()
        for tool in registry.allTools {
            XCTAssertEqual(tool.executionSemantics.timeoutIsAuthoritative,
                           tool.executionSemantics.effect == .readOnly,
                           "\(tool.name)")
        }
    }

    // MARK: - Typed outcomes

    func testRetryDispositionMatchesTheOutcome() {
        XCTAssertEqual(ToolExecutionOutcome.completed("x").retryDisposition, .safeToRetry)
        XCTAssertEqual(ToolExecutionOutcome.failedBeforeExecution(reason: "x").retryDisposition,
                       .safeToRetry)
        XCTAssertEqual(ToolExecutionOutcome.rejected(reason: "x").retryDisposition,
                       .retryWillBeRefused)
        XCTAssertEqual(ToolExecutionOutcome.outcomeUnknown(operationID: "op", message: "x")
            .retryDisposition, .unsafeToRetry)

        // Only a completion is a success on the wire.
        XCTAssertTrue(ToolExecutionOutcome.completed("x").toolResult.isSuccess)
        XCTAssertFalse(ToolExecutionOutcome.outcomeUnknown(operationID: "op", message: "x")
            .toolResult.isSuccess)
    }

    func testOnlyAnUnresolvedOutcomeSurfacesAUserFacingStatus() {
        XCTAssertNil(ToolExecutionOutcome.completed("x").userFacingStatus)
        XCTAssertNil(ToolExecutionOutcome.rejected(reason: "x").userFacingStatus)
        let status = ToolExecutionOutcome.outcomeUnknown(operationID: "op", message: "x")
            .userFacingStatus
        XCTAssertEqual(status, "Status unknown — checking")

        // No internal vocabulary reaches the wearer.
        let shown = ToolCallStatus.outcomeUnknown("send_message").displayText
        XCTAssertTrue(shown.contains("status unknown"), shown)
        XCTAssertFalse(shown.lowercased().contains("idempot"))
        XCTAssertFalse(shown.lowercased().contains("outcome_unknown"))
        XCTAssertTrue(ToolCallStatus.outcomeUnknown("send_message").isActive,
                      "the wearer is owed the fact that we don't know yet")
    }

    // MARK: - Timeout behaviour per class

    /// The regression this phase exists for: the timer wins on a side-effecting tool and the caller
    /// is told the outcome is unknown, not that the call failed.
    func testTimeoutOnSideEffectingToolIsUnknownRatherThanFailure() async {
        let (tool, release, cancelled) = parked("send_it", .external(.cooperative))
        let router = router(with: tool)

        let outcome = await router.executeRoot(name: "send_it", args: [:])
        guard case .outcomeUnknown(let operationID, let message) = outcome else {
            return XCTFail("expected an unresolved outcome, got \(outcome)")
        }
        XCTAssertFalse(operationID.isEmpty, "the operation must be identifiable for reconciliation")
        XCTAssertTrue(message.contains("timed out"), message)
        XCTAssertTrue(message.lowercased().contains("unknown"), message)
        XCTAssertTrue(message.contains("Do NOT retry"), message)
        XCTAssertEqual(outcome.retryDisposition, .unsafeToRetry)

        // Cooperative work is still asked to stop.
        await cancelled.wait()
        XCTAssertTrue(cancelled.hasFired)
        release.fire()
    }

    /// A tool that cannot observe cancellation is not asked to stop — and, critically, is not
    /// reported as failed either.
    func testNotCancellableToolIsNeitherCancelledNorCalledFailed() async {
        let (tool, release, cancelled) = parked("actuate", .actuation(.notCancellable))
        let router = router(with: tool)

        let outcome = await router.executeRoot(name: "actuate", args: [:])
        guard case .outcomeUnknown = outcome else {
            return XCTFail("a non-cancellable actuation must not be reported as failed: \(outcome)")
        }
        XCTAssertFalse(cancelled.hasFired,
                       "asking work that can't hear it to stop only hides that it's still running")
        release.fire()
    }

    /// A read leaves nothing behind, so the timer winning really is "it didn't happen".
    func testTimeoutOnReadOnlyToolIsAuthoritative() async {
        let (tool, release, cancelled) = parked("look_it_up", .read())
        let router = router(with: tool)

        let outcome = await router.executeRoot(name: "look_it_up", args: [:])
        guard case .failedBeforeExecution(let reason) = outcome else {
            return XCTFail("expected an authoritative failure, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("no effect"), reason)
        XCTAssertEqual(outcome.retryDisposition, .safeToRetry)

        await cancelled.wait()
        release.fire()
    }

    /// A tool with its own budget is not held to the router's.
    func testPerToolTimeoutOverridesTheRouterDefault() async {
        let (tool, release, _) = parked("slow_read", .read(timeout: .seconds(30)))
        let router = router(with: tool, timeout: 0.05)

        // The router's 0.05s would have fired long before this returns; the tool's own budget wins,
        // so the call is still parked and only finishes when the test releases it.
        async let pending = router.executeRoot(name: "slow_read", args: [:])
        release.fire()
        guard case .completed(let text) = await pending else {
            return XCTFail("the tool's own budget must win over the router default")
        }
        XCTAssertEqual(text, "finished")
    }

    /// A tool that finishes in time is unaffected by any of this.
    func testCompletedCallIsAuthoritativeSuccess() async {
        let (tool, release, _) = parked("quick", .external(.cooperative))
        let router = router(with: tool, timeout: 30)

        async let pending = router.executeRoot(name: "quick", args: [:])
        release.fire()
        let outcome = await pending
        XCTAssertEqual(outcome, .completed("finished"))
    }

    // MARK: - The tool loop

    /// The wire text tells the model not to retry. The loop doesn't rely on it being obeyed.
    func testLoopRefusesToRepeatACallWhoseOutcomeIsUnresolved() async throws {
        var dispatched: [String] = []
        let dispatcher = ToolDispatcher(
            execute: { name, _, _, _ in
                dispatched.append(name)
                return .outcomeUnknown(operationID: "op-1", message: "may still land")
            },
            onStatus: { _ in })

        let call = ToolInvocation(id: "1", name: "send_message", arguments: ["to": "mum"])
        var turns = 0
        let adapter = ProviderLoopAdapter(
            label: "Test",
            dispatcher: dispatcher,
            performTurn: {
                defer { turns += 1 }
                // The model tries the same call again after being told the outcome is unknown.
                return turns < 2
                    ? AssistantTurn(text: "", toolCalls: [call])
                    : AssistantTurn(text: "done")
            },
            appendAssistantToolCall: { _ in },
            appendToolResults: { _ in },
            finalize: { $0.text })

        let answer = try await runToolLoop(maxIterations: 5, adapter: adapter, setStatus: { _ in })
        XCTAssertEqual(answer, "done")
        XCTAssertEqual(dispatched, ["send_message"],
                       "the second attempt at an unresolved call must not reach the executor")
    }

    /// A *different* call to the same tool is unaffected — the block is on the exact operation.
    func testLoopStillAllowsADifferentCallToTheSameTool() async throws {
        var dispatched: [[String: Any]] = []
        let dispatcher = ToolDispatcher(
            execute: { _, args, _, _ in
                dispatched.append(args)
                return .outcomeUnknown(operationID: "op", message: "may still land")
            },
            onStatus: { _ in })

        var turns = 0
        let adapter = ProviderLoopAdapter(
            label: "Test",
            dispatcher: dispatcher,
            performTurn: {
                defer { turns += 1 }
                switch turns {
                case 0:
                    return AssistantTurn(text: "", toolCalls: [
                        ToolInvocation(id: "1", name: "send_message", arguments: ["to": "mum"])])
                case 1:
                    return AssistantTurn(text: "", toolCalls: [
                        ToolInvocation(id: "2", name: "send_message", arguments: ["to": "dad"])])
                default:
                    return AssistantTurn(text: "done")
                }
            },
            appendAssistantToolCall: { _ in },
            appendToolResults: { _ in },
            finalize: { $0.text })

        _ = try await runToolLoop(maxIterations: 5, adapter: adapter, setStatus: { _ in })
        XCTAssertEqual(dispatched.count, 2)
        XCTAssertEqual(dispatched.last?["to"] as? String, "dad")
    }

    func testDispatcherReportsAnUnresolvedOutcomeAsItsOwnStatus() async {
        var statuses: [ToolCallStatus] = []
        let dispatcher = ToolDispatcher(
            execute: { _, _, _, _ in .outcomeUnknown(operationID: "op", message: "may still land") },
            onStatus: { statuses.append($0) })

        let outcome = await dispatcher.dispatch(
            ToolInvocation(id: "1", name: "smart_home", arguments: [:]))

        XCTAssertEqual(statuses, [.executing("smart_home"), .outcomeUnknown("smart_home")])
        XCTAssertEqual(outcome.retryDisposition, .unsafeToRetry)
        XCTAssertFalse(outcome.result.isSuccess)
    }

    // MARK: - Helpers

    /// The widest registry this process can build: the conditional families are switched on so their
    /// tools register, and the cheap services they need are supplied.
    private func widestRegistry() -> NativeToolRegistry {
        let savedFieldAssist = Config.fieldAssistEnabled
        let savedAccessibility = Config.accessibilityModeEnabled
        let savedEntitlement = EntitlementTestScope.grant()
        Config.setFieldAssistEnabled(true)
        Config.setAccessibilityModeEnabled(true)
        defer {
            Config.setFieldAssistEnabled(savedFieldAssist)
            Config.setAccessibilityModeEnabled(savedAccessibility)
            EntitlementTestScope.restore(savedEntitlement)
        }

        let registry = NativeToolRegistry(
            locationService: LocationService(),
            conversationStore: ConversationStore(),
            cameraService: CameraService(),
            medicalExportService: MedicalExportService())
        // Families whose registration needs a service that isn't cheap to build headlessly, but
        // whose types are: registered directly so the gate still covers them.
        registry.register(MemorySearchTool())
        registry.register(AgentDiaryTool())
        registry.register(DocumentRAGTool())
        registry.register(StudyTool())
        registry.register(OpenClawSkillsTool())
        return registry
    }
}
