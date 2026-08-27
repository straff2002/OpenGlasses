import XCTest
@testable import OpenGlasses

/// Plan DJ P1 — every acting call, composed or direct, reaches one authorization authority exactly
/// once, and it decides on the *resolved* target with its final merged arguments. These cover the
/// pure policy (no registry, no confirmation UI, no `Config`), the routed child path a skill pack's
/// `.tool` binding now takes, and the invariant that the classifier's LLM-free fast path can't
/// smuggle an acting tool past the gate.
@MainActor
final class ToolExecutionAuthorityTests: XCTestCase {

    // MARK: - Fixtures

    /// Counts executions: "confirmed once" and "declined, never ran" are both counting claims.
    private final class ExecutionSpy {
        var invocations: [[String: Any]] = []
        var count: Int { invocations.count }
    }

    private struct SpyTool: NativeTool {
        let name: String
        let description = "spy"
        let spy: ExecutionSpy
        var parametersSchema: [String: Any] { ["type": "object"] }
        func execute(args: [String: Any]) async throws -> String {
            spy.invocations.append(args)
            return "ran:\(name)"
        }
    }

    /// Records the resolved call it was handed, then answers — a stand-in for the router when the
    /// test is about what the wrapper *asks for*, not what the router decides.
    @MainActor
    private final class RecordingAuthority: ToolExecutionAuthority {
        private(set) var calls: [ResolvedToolCall] = []
        var result: ToolResult = .success("dispatched")
        func execute(_ call: ResolvedToolCall) async -> ToolResult {
            calls.append(call)
            return result
        }
    }

    private func wrapper(packId: String = "com.example.pack",
                         action name: String = "do_it",
                         target: String,
                         boundArgs: [String: String] = [:],
                         dispatch: @escaping @MainActor (ResolvedToolCall) async -> ToolResult)
        -> SkillPackToolWrapper {
        SkillPackToolWrapper(
            packId: packId,
            action: SkillPackAction(name: name, description: "Fixture.",
                                    parametersSchema: ["type": "object"],
                                    binding: .tool(name: target, boundArgs: boundArgs)),
            dispatchChild: dispatch)
    }

    private func agentContext(rules: Set<SafetyRuleKind> = [],
                              autonomy: Autonomy = .autoAct) -> SafetyContext {
        SafetyContext(now: Date(), location: nil, homeRegion: nil, enabledRules: rules,
                      quietHoursStart: 22, quietHoursEnd: 7, autonomy: autonomy)
    }

    /// Spin until the coordinator publishes a pending confirmation, then resolve it.
    private func resolveWhenPending(_ coordinator: ToolConfirmationCoordinator,
                                    _ approved: Bool) async -> PendingToolConfirmation? {
        for _ in 0..<50 {
            if let pending = coordinator.pending {
                coordinator.resolve(approved)
                return pending
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("confirmation never became pending")
        return nil
    }

    // MARK: - Invocation model

    func testArgumentsSurviveTheSendableRoundTrip() {
        let raw: [String: Any] = [
            "text": "hello", "count": 3, "ratio": 1.5, "flag": true,
            "nested": ["items": [1, 2], "on": false],
        ]
        let round = ToolArguments(raw).rawValues

        XCTAssertEqual(round["text"] as? String, "hello")
        XCTAssertEqual(round["count"] as? Int, 3)
        XCTAssertEqual(round["ratio"] as? Double, 1.5)
        // A bridged Bool is an NSNumber too — the round trip must not turn `true` into 1.
        XCTAssertEqual(round["flag"] as? Bool, true)
        XCTAssertEqual(ToolArguments(raw)["flag"], .bool(true))
        XCTAssertEqual(ToolArguments(raw)["count"], .int(3))
        let nested = round["nested"] as? [String: Any]
        XCTAssertEqual(nested?["items"] as? [Int], [1, 2])
        XCTAssertEqual(nested?["on"] as? Bool, false)
    }

    func testProvenanceIsAdditiveAcrossNestedDispatch() {
        let root = ResolvedToolCall.root(name: "pack_com_example_pack_do_it", origin: .model)
        let child = root.child(name: "set_timer", arguments: ["seconds": 300],
                               composerID: "com.example.pack")
        let grandchild = child.child(name: "save_note", arguments: [:], composerID: "com.other.pack")

        XCTAssertEqual(child.context.rootInvocationID, root.context.invocationID)
        XCTAssertEqual(grandchild.context.rootInvocationID, root.context.invocationID,
                       "the root invocation survives every hop")
        XCTAssertEqual(child.context.parent?.toolName, "pack_com_example_pack_do_it")
        XCTAssertEqual(child.context.parent?.composerID, "com.example.pack")
        XCTAssertEqual(grandchild.context.parent?.invocationID, child.context.invocationID)
        XCTAssertEqual(grandchild.context.depth, 2)
        XCTAssertEqual(grandchild.context.ancestry,
                       ["pack_com_example_pack_do_it", "set_timer"])
        XCTAssertTrue(grandchild.context.wouldCycle("set_timer"))
        XCTAssertFalse(grandchild.context.wouldCycle("save_note"))
    }

    // MARK: - Pure policy

    func testCompositionFloorRefusesChainingCyclesAndDepth() {
        let root = ResolvedToolCall.root(name: "pack_a_run", origin: .model)

        let chained = root.child(name: "pack_b_run", arguments: [:], composerID: "a")
        guard case .refuse(let chainReason, _) = ToolAuthorizationPolicy.evaluate(
            .init(call: chained, agentModeEnabled: false)) else {
            return XCTFail("one pack calling another must be refused")
        }
        XCTAssertEqual(chainReason, .packChaining)

        var cycling = root.child(name: "get_weather", arguments: [:], composerID: "a")
        cycling = cycling.child(name: "pack_a_run", arguments: [:], composerID: "a")
        cycling = cycling.child(name: "get_weather", arguments: [:], composerID: "a")
        guard case .refuse(let cycleReason, _) = ToolAuthorizationPolicy.evaluate(
            .init(call: cycling, agentModeEnabled: false)) else {
            return XCTFail("re-entering a call already on the stack must be refused")
        }
        XCTAssertEqual(cycleReason, .parentCycle)

        var deep = root
        for step in 0...ToolInvocationContext.maxDepth {
            deep = deep.child(name: "step_\(step)", arguments: [:], composerID: "a")
        }
        XCTAssertGreaterThan(deep.context.depth, ToolInvocationContext.maxDepth)
        guard case .refuse(let depthReason, _) = ToolAuthorizationPolicy.evaluate(
            .init(call: deep, agentModeEnabled: false)) else {
            return XCTFail("composition past the depth ceiling must be refused")
        }
        XCTAssertEqual(depthReason, .depthLimit)
    }

    func testRestrictedTargetsAreRefusedForCompositionByDefaultOnly() {
        let root = ResolvedToolCall.root(name: "pack_a_unlock", origin: .model)
        let child = root.child(name: "smart_home", arguments: ["action": "unlock"], composerID: "a")

        guard case .refuse(let reason, let message) = ToolAuthorizationPolicy.evaluate(
            .init(call: child, agentModeEnabled: false)) else {
            return XCTFail("the shipping default keeps the composition floor closed")
        }
        XCTAssertEqual(reason, .restrictedTarget)
        XCTAssertTrue(message.contains("smart_home"))

        // Routed instead: the same call becomes a confirmation on the real action, not a refusal.
        guard case .confirm(let summary) = ToolAuthorizationPolicy.evaluate(
            .init(call: child, agentModeEnabled: false, composedTargets: .confirmResolved)) else {
            return XCTFail("routed composition must reach the confirmation gate")
        }
        XCTAssertTrue(summary.lowercased().contains("unlock"), "copy names the real action: \(summary)")
        XCTAssertTrue(summary.contains("‘a’"), "copy names the originating pack: \(summary)")

        // A direct model call to a *non*-restricted tool is untouched by the floor.
        if case .allow = ToolAuthorizationPolicy.evaluate(
            .init(call: .root(name: "get_weather", origin: .model), agentModeEnabled: false)) {} else {
            XCTFail("read-only direct calls must not be gated")
        }
    }

    func testSiriOriginIsGovernedByTheCompositionFloorAtDepthZero() {
        let siri = ResolvedToolCall.root(name: "smart_home", arguments: ["action": "unlock"],
                                         origin: .siriAction)
        guard case .refuse(let reason, _) = ToolAuthorizationPolicy.evaluate(
            .init(call: siri, agentModeEnabled: false)) else {
            return XCTFail("a saved Siri Action is composition even at the root")
        }
        XCTAssertEqual(reason, .restrictedTarget)

        if case .allow = ToolAuthorizationPolicy.evaluate(
            .init(call: .root(name: "teleprompter", origin: .siriAction), agentModeEnabled: false)) {} else {
            XCTFail("a read-only Siri Action still runs")
        }
    }

    func testAgentModeRulesApplyToChildCalls() {
        let root = ResolvedToolCall.root(name: "pack_a_send", origin: .model)
        let child = root.child(name: "send_message", arguments: ["to": "mum"], composerID: "a")

        guard case .confirm(let summary) = ToolAuthorizationPolicy.evaluate(.init(
            call: child, agentModeEnabled: true,
            safetyContext: agentContext(rules: [.needsVoiceApproval]),
            composedTargets: .confirmResolved)) else {
            return XCTFail("supervisor rules must reach the child call")
        }
        XCTAssertTrue(summary.contains("‘a’"))

        guard case .hold = ToolAuthorizationPolicy.evaluate(.init(
            call: child, agentModeEnabled: true,
            safetyContext: agentContext(rules: [.needsVoiceApproval], autonomy: .paused),
            composedTargets: .confirmResolved)) else {
            return XCTFail("the presence ceiling must hold an acting child call")
        }
    }

    // MARK: - Routed child execution

    /// The confirmation a wrapped high-impact call raises must be indistinguishable from the one a
    /// direct call raises, and it must carry the arguments the pack actually bound.
    func testWrappedHighImpactCallConfirmsLikeADirectCall() async throws {
        let saved = Config.agentModeEnabled
        Config.setAgentModeEnabled(false)
        defer { Config.setAgentModeEnabled(saved) }

        let spy = ExecutionSpy()
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(SpyTool(name: "smart_home", spy: spy))
        let coordinator = ToolConfirmationCoordinator()
        let router = NativeToolRouter(registry: registry)
        router.confirmationCoordinator = coordinator
        router.composedTargetPolicy = .confirmResolved

        let composed = wrapper(target: "smart_home",
                               boundArgs: ["action": "unlock", "device": "{{door}}"],
                               dispatch: { [weak router] call in
                                   await router?.execute(call) ?? .failure("no authority")
                               })

        // Direct: what the user is asked when the model calls the tool itself.
        async let direct = router.handleToolCall(name: "smart_home",
                                                 args: ["action": "unlock", "device": "Front Door"])
        let directPrompt = await resolveWhenPending(coordinator, true)
        _ = await direct
        XCTAssertEqual(spy.count, 1)

        // Wrapped: the same ask, reached through the pack.
        async let approvedComposed = composed.execute(args: ["door": "Front Door"])
        let composedPrompt = await resolveWhenPending(coordinator, true)
        _ = try await approvedComposed

        let directSummary = try XCTUnwrap(directPrompt?.summary)
        let composedSummary = try XCTUnwrap(composedPrompt?.summary)
        XCTAssertEqual(composedPrompt?.toolName, "smart_home",
                       "the card names the resolved target, not the wrapper")
        XCTAssertTrue(composedSummary.hasPrefix(directSummary),
                      "same ask as the direct call: \(composedSummary) vs \(directSummary)")
        XCTAssertTrue(composedSummary.contains("Front Door"), "with the final bound arguments")
        XCTAssertTrue(composedSummary.contains("com.example.pack"), "attributed to the pack")

        // Approve → executed exactly once, with the merged arguments.
        XCTAssertEqual(spy.count, 2)
        XCTAssertEqual(spy.invocations.last?["action"] as? String, "unlock")
        XCTAssertEqual(spy.invocations.last?["device"] as? String, "Front Door")

        // Decline → the fake executor is never reached again.
        async let declined = composed.execute(args: ["door": "Front Door"])
        _ = await resolveWhenPending(coordinator, false)
        let declinedResult = try await declined
        XCTAssertEqual(spy.count, 2, "a declined composed call must not execute")
        XCTAssertTrue(declinedResult.contains("did NOT approve"))
    }

    func testComposedCallFailsClosedWithoutConfirmationUI() async throws {
        let saved = Config.agentModeEnabled
        Config.setAgentModeEnabled(false)
        defer { Config.setAgentModeEnabled(saved) }

        let spy = ExecutionSpy()
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(SpyTool(name: "smart_home", spy: spy))
        let router = NativeToolRouter(registry: registry)
        router.composedTargetPolicy = .confirmResolved   // no confirmationCoordinator wired

        let composed = wrapper(target: "smart_home", boundArgs: ["action": "unlock"],
                               dispatch: { [weak router] call in
                                   await router?.execute(call) ?? .failure("no authority")
                               })
        let result = try await composed.execute(args: [:])
        XCTAssertEqual(spy.count, 0, "no confirmation surface means no actuation")
        XCTAssertTrue(result.contains("requires user confirmation"))
    }

    func testWrapperWithNoAuthorityRefusesInsteadOfExecuting() async throws {
        let composed = SkillPackToolWrapper(
            packId: "com.example.pack",
            action: SkillPackAction(name: "do_it", description: "Fixture.",
                                    parametersSchema: ["type": "object"],
                                    binding: .tool(name: "get_weather", boundArgs: [:])))
        let result = try await composed.execute(args: [:])
        XCTAssertTrue(result.contains("couldn't be checked for safety"),
                      "composition with no authorization boundary is not a supported mode")
    }

    func testWrapperResolvesTheChildCallBeforeHandingItOver() async throws {
        let authority = RecordingAuthority()
        let composed = wrapper(target: "set_timer", boundArgs: ["seconds": "{{minutes}}0"],
                               dispatch: { await authority.execute($0) })

        _ = try await composed.execute(args: ["minutes": 3, "label": "tea"])

        let call = try XCTUnwrap(authority.calls.first)
        XCTAssertEqual(call.name, "set_timer", "the authority sees the real target")
        XCTAssertEqual(call.arguments["seconds"], .int(30), "coerced, substituted, merged")
        XCTAssertEqual(call.arguments["label"], .string("tea"), "caller args pass through underneath")
        XCTAssertEqual(call.context.origin, .skillPack)
        XCTAssertEqual(call.context.parent?.composerID, "com.example.pack")
        XCTAssertEqual(call.context.depth, 1)
    }

    func testReadOnlyWrappedToolIsUnchangedByRouting() async throws {
        let spy = ExecutionSpy()
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(SpyTool(name: "get_weather", spy: spy))
        let router = NativeToolRouter(registry: registry)

        let composed = wrapper(target: "get_weather",
                               dispatch: { [weak router] call in
                                   await router?.execute(call) ?? .failure("no authority")
                               })
        let result = try await composed.execute(args: [:])
        XCTAssertEqual(result, "ran:get_weather")
        XCTAssertEqual(spy.count, 1)
        XCTAssertEqual(router.takeTurnToolNames(), ["get_weather"],
                       "the resolved target is recorded for the turn")
    }

    func testRouterRefusesPackChainingAndRecordsAContentFreeEvent() async throws {
        let spy = ExecutionSpy()
        let registry = NativeToolRegistry(locationService: LocationService())
        let inner = wrapper(packId: "com.example.inner", action: "inner", target: "get_weather",
                            dispatch: { _ in .success("unreachable") })
        registry.register(inner)
        registry.register(SpyTool(name: "get_weather", spy: spy))
        let router = NativeToolRouter(registry: registry)

        let outer = wrapper(packId: "com.example.outer", action: "outer", target: inner.name,
                            dispatch: { [weak router] call in
                                await router?.execute(call) ?? .failure("no authority")
                            })
        let result = try await outer.execute(args: [:])
        XCTAssertTrue(result.contains("one skill can't call another"))
        XCTAssertEqual(spy.count, 0)

        let event = try XCTUnwrap(router.authorizationEvents.events.first)
        XCTAssertEqual(event.verdict, ToolRefusalReason.packChaining.rawValue)
        XCTAssertEqual(event.toolName, inner.name)
        XCTAssertEqual(event.depth, 1)
        XCTAssertNotNil(event.composerFingerprint)
        XCTAssertNotEqual(event.composerFingerprint, "com.example.outer",
                          "pack ids are fingerprinted, never logged in the clear")
        XCTAssertEqual(event.composerFingerprint,
                       ToolAuthorizationEventLog.fingerprint("com.example.outer"))
    }

    func testComposedCallCannotReachTheGatewayFallback() async throws {
        let registry = NativeToolRegistry(locationService: LocationService())
        let router = NativeToolRouter(registry: registry)
        let composed = wrapper(target: "definitely_not_registered",
                               dispatch: { [weak router] call in
                                   await router?.execute(call) ?? .failure("no authority")
                               })
        let result = try await composed.execute(args: [:])
        XCTAssertTrue(result.contains("isn't available on this device"),
                      "a binding composes over native tools only")
    }

    // MARK: - The LLM-free fast path

    /// Tier-0 dispatch now goes through the authority, so the classifier's allowlist is a routing
    /// shortcut rather than the only thing standing between a pattern match and an action. This
    /// pins the second half of that: nothing reachable from the allowlist is an acting tool the
    /// router would have gated.
    func testEveryClassifierFastPathToolIsUngated() {
        let classifier = ConversationClassifier()
        let utterances = [
            "what time is it", "play music", "pause", "next track", "flashlight on",
            "turn off the flashlight", "how many steps have i taken", "what's my battery",
            "what's the weather", "what's on my calendar", "what's on my calendar tomorrow",
            "new topic",
        ]
        var matched: Set<String> = []
        for utterance in utterances {
            guard let direct = classifier.classify(utterance).directToolCall else { continue }
            matched.insert(direct.toolName)
            XCTAssertFalse(ComposedToolPolicy.isRestrictedTarget(direct.toolName),
                           "\(direct.toolName) is gated by the router and must not be pattern-dispatched")
        }
        XCTAssertTrue(matched.contains("get_datetime"), "the fixtures must actually exercise tier-0")
        XCTAssertTrue(matched.contains("flashlight"))
        XCTAssertTrue(matched.contains("get_weather"))
    }
}
