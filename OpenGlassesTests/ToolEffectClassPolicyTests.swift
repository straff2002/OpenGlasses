import XCTest
@testable import OpenGlasses

/// W04.4 — every tool says what running it does that a person would want to have been asked about,
/// and everything above a read is on the confirmation path however the call arrived.
///
/// The finding this answers: the native high-impact policy covered a handful of named tools, and
/// the external dispatch seam established no write-effect classification at all — so what a call
/// was allowed to do depended on which list somebody had remembered to add it to, and on whether
/// agent mode happened to be on.
@MainActor
final class ToolEffectClassPolicyTests: XCTestCase {

    // MARK: - Native classification is total and stable

    /// The exhaustiveness gate. Every registered tool gets a class, and the only tools allowed to
    /// land on the unreviewable one are the ones that genuinely are unreviewable: a user-authored
    /// HTTP call, a skill-pack wrapper, and the three tools whose effect is whatever a third party
    /// or an arbitrary script decided it is.
    func testEveryRegisteredNativeToolIsClassified() {
        let registry = widestRegistry()
        var unreviewable: [String] = []

        for tool in registry.allTools {
            if tool is SkillPackToolWrapper || tool is CustomToolWrapper { continue }
            let effectClass = ToolEffectClassifier.nativeClass(
                name: tool.name, args: [:], semantics: tool.executionSemantics)
            if effectClass == .unknown { unreviewable.append(tool.name) }
        }

        let registered = Set(registry.allTools.map(\.name))
        let expected = ["code_agent", "execute", "run_shortcut"].filter(registered.contains).sorted()
        XCTAssertEqual(unreviewable.sorted(), expected,
                       "a tool whose effect this app cannot state must be named here on purpose, "
                           + "not by accident")
        XCTAssertGreaterThan(registry.allTools.count, 60,
                             "the fixture registry must actually be wide, or the gate proves little")
    }

    /// The class is the *authorization* axis, so it must agree with the execution-semantics axis
    /// wherever the two overlap: nothing that leaves a trace may be called a read.
    func testNoSideEffectingToolIsClassifiedAsARead() {
        let registry = widestRegistry()
        for tool in registry.allTools where tool.executionSemantics.effect != .readOnly {
            let effectClass = ToolEffectClassifier.nativeClass(
                name: tool.name, args: [:], semantics: tool.executionSemantics)
            XCTAssertNotEqual(effectClass, .readOnly, tool.name)
        }
    }

    func testTheNamedElevatedFamiliesAreClassifiedAsSuch() {
        let semantics = ToolExecutionSemantics.external(.bestEffort)
        for name in ToolEffectClassifier.messagingTools {
            XCTAssertEqual(ToolEffectClassifier.nativeClass(name: name, args: [:],
                                                            semantics: semantics),
                           .messaging, name)
        }
        XCTAssertEqual(ToolEffectClassifier.nativeClass(name: "medical_export", args: [:],
                                                        semantics: semantics),
                       .sensitiveDisclosure)
        XCTAssertEqual(ToolEffectClassifier.nativeClass(name: "smart_home",
                                                        args: ["action": "unlock"],
                                                        semantics: .actuation()),
                       .physicalActuation)
    }

    /// Classification is argument-aware exactly where the tool is. Putting a prompt in front of
    /// "turn the lamp on" or "how is that agent run going" is how a wearer learns to approve
    /// without reading.
    func testRoutineActionsOnAnElevatedToolStayRoutine() {
        XCTAssertEqual(ToolEffectClassifier.nativeClass(name: "smart_home",
                                                        args: ["action": "on", "device": "lamp"],
                                                        semantics: .actuation()),
                       .write)
        XCTAssertEqual(ToolEffectClassifier.nativeClass(name: "code_agent",
                                                        args: ["action": "status"],
                                                        semantics: .external()),
                       .write)
        XCTAssertEqual(ToolEffectClassifier.nativeClass(name: "code_agent", args: [:],
                                                        semantics: .external()),
                       .unknown, "an absent action starts a run, so it is classified as one")
    }

    // MARK: - Anything above a read is on the confirmation path

    func testEveryClassAboveAReadRequiresABoundApproval() {
        for effectClass in ToolEffectClass.allCases where effectClass != .readOnly {
            XCTAssertTrue(effectClass.requiresExplicitAuthorization, effectClass.rawValue)
            XCTAssertTrue(effectClass.requiresBoundApproval(on: .mcpServer(id: "s")),
                          "\(effectClass.rawValue) on an external seam")
        }
        XCTAssertFalse(ToolEffectClass.readOnly.requiresExplicitAuthorization)
        XCTAssertFalse(ToolEffectClass.readOnly.requiresBoundApproval(on: .mcpServer(id: "s")))
    }

    /// The native seam's one exemption, stated where it can be seen: a write to the wearer's own
    /// device and stores is authorized by their asking for it. Everything that reaches another
    /// person, the physical world, sensitive data or money is not.
    func testNativeWritesArePermittedButNativeElevatedClassesAreNot() {
        XCTAssertFalse(ToolEffectClass.write.requiresBoundApproval(on: .native))
        for effectClass in [ToolEffectClass.messaging, .physicalActuation, .sensitiveDisclosure,
                            .financial, .unknown] {
            XCTAssertTrue(effectClass.requiresBoundApproval(on: .native), effectClass.rawValue)
        }
    }

    /// The floor is not an agent-mode feature, and it is not an origin feature either.
    func testTheFloorHoldsAcrossAgentModeAndEveryArrivalPath() {
        for agentMode in [false, true] {
            for origin in [ToolInvocationOrigin.model, .user, .appInternal] {
                let call = ResolvedToolCall.root(name: "send_message",
                                                 arguments: ["to": "Mum"], origin: origin)
                let decision = ToolAuthorizationPolicy.evaluate(.init(
                    call: call, agentModeEnabled: agentMode,
                    seam: .native, effectClass: .messaging))
                guard case .confirm = decision else {
                    return XCTFail("agentMode=\(agentMode) origin=\(origin.rawValue): \(decision)")
                }
            }
        }
    }

    /// The floor may only strengthen the ladder. A refusal, a safety block and a presence hold all
    /// still win — an elevated class must never turn "no" into "ask".
    func testTheFloorNeverWeakensARefusal() {
        let parent = ResolvedToolCall.root(name: "pack_do_it", origin: .skillPack)
        let child = parent.child(name: "smart_home", arguments: ["action": "unlock"],
                                 composerID: "pack-1")
        let decision = ToolAuthorizationPolicy.evaluate(.init(
            call: child, agentModeEnabled: false, seam: .native,
            effectClass: .physicalActuation))
        guard case .refuse(let reason, _) = decision else {
            return XCTFail("the composition floor must still refuse: \(decision)")
        }
        XCTAssertEqual(reason, .restrictedTarget)
    }

    /// A read stays a read: the floor adds nothing to a call that was going to be allowed and
    /// carries no effect.
    func testAReadIsStillAllowedWithoutAsking() {
        let call = ResolvedToolCall.root(name: "get_weather", origin: .model)
        guard case .allow = ToolAuthorizationPolicy.evaluate(.init(
            call: call, agentModeEnabled: false, seam: .native, effectClass: .readOnly)) else {
            return XCTFail("a read must not acquire a prompt")
        }
    }

    // MARK: - Composition cannot escalate by argument

    /// A composed step is classified on its *resolved* target and its *merged* arguments, never on
    /// the template a person saved. A binding that looks harmless until its arguments arrive is the
    /// escalation this closes.
    func testAComposedStepIsClassifiedOnItsResolvedArgumentsNotItsTemplate() {
        let authored = ToolEffectClassifier.nativeClass(name: "smart_home",
                                                        args: ["action": "list"],
                                                        semantics: .actuation())
        let merged = ToolEffectClassifier.nativeClass(name: "smart_home",
                                                      args: ["action": "unlock", "device": "front"],
                                                      semantics: .actuation())
        XCTAssertEqual(authored, .write)
        XCTAssertEqual(merged, .physicalActuation,
                       "the arguments that actually run decide the class")

        // And with composed targets routed rather than refused, the resolved call is confirmed —
        // it is never simply allowed.
        let parent = ResolvedToolCall.root(name: "pack_lights", origin: .skillPack)
        let child = parent.child(name: "smart_home", arguments: ["action": "unlock"],
                                 composerID: "pack-1")
        guard case .confirm(let summary) = ToolAuthorizationPolicy.evaluate(.init(
            call: child, agentModeEnabled: false, composedTargets: .confirmResolved,
            seam: .native, effectClass: .physicalActuation)) else {
            return XCTFail("a routed composed actuation must be confirmed")
        }
        XCTAssertTrue(summary.contains("pack-1"), "the composing skill is named in the ask: \(summary)")
    }

    // MARK: - External seams

    /// Everything the classifier is given about an external tool was written by the party being
    /// classified, so a hostile server must not be able to buy itself an unbound call by asserting
    /// that its tool only reads.
    func testAnExternalToolIsNeverClassifiedAsARead() {
        let hinted = ToolEffectClassifier.externalClass(
            name: "search", description: "just a harmless read-only lookup",
            annotations: ["readOnlyHint": true])
        XCTAssertNotEqual(hinted, .readOnly)
        XCTAssertTrue(hinted.requiresBoundApproval(on: .mcpServer(id: "s")))
    }

    func testAnExternalDescriptionCanOnlyRaiseTheClass() {
        XCTAssertEqual(ToolEffectClassifier.externalClass(name: "quiet", description: ""),
                       .unknown)
        XCTAssertEqual(ToolEffectClassifier.externalClass(
            name: "pay_invoice", description: "settle an invoice"), .financial)
        XCTAssertEqual(ToolEffectClassifier.externalClass(
            name: "unlock_door", description: "opens the front door"), .physicalActuation)
        XCTAssertEqual(ToolEffectClassifier.externalClass(
            name: "notify", description: "send a message to a channel"), .messaging)
        // A destructive hint volunteered against the server's own interest is believed, and can
        // still be raised further by what the description says.
        XCTAssertEqual(ToolEffectClassifier.externalClass(
            name: "wipe", description: "", annotations: ["destructiveHint": true]),
                       .physicalActuation)
    }

    func testTheSeamIsPartOfTheIdentityAnApprovalBindsTo() {
        XCTAssertEqual(ToolDispatchSeam.native.identity, "native")
        XCTAssertNotEqual(ToolDispatchSeam.mcpServer(id: "a").identity,
                          ToolDispatchSeam.mcpServer(id: "b").identity)
        XCTAssertNotEqual(ToolDispatchSeam.mcpServer(id: "a").identity,
                          ToolDispatchSeam.custom(id: "a").identity,
                          "an id from one seam must not collide with an id from another")
        XCTAssertFalse(ToolDispatchSeam.native.isExternal)
        for seam in [ToolDispatchSeam.mcpServer(id: "a"), .gateway, .custom(id: "a")] {
            XCTAssertTrue(seam.isExternal)
        }
    }

    // MARK: - The router resolves the real seam and class

    func testTheRouterClassifiesAUserAuthoredHTTPToolAsUnreviewed() {
        let registry = NativeToolRegistry(locationService: LocationService())
        let router = NativeToolRouter(registry: registry)

        let native = router.dispatchProfile(
            for: .root(name: "get_weather", origin: .model))
        XCTAssertEqual(native.seam, .native)
        XCTAssertEqual(native.effectClass, .readOnly)
        XCTAssertFalse(native.definitionDigest.isEmpty)

        let missing = router.dispatchProfile(for: .root(name: "not_a_tool", origin: .model))
        XCTAssertEqual(missing, .unrouted,
                       "nothing dispatches, so nothing is held in front of a wearer")
    }

    func testTheRouterBindsAnMCPCallToItsOwnServer() {
        let client = MCPClient()
        client.definitionDigests = nil
        client.servers = [MCPServerConfig(id: "s1", label: "Notion",
                                          url: "http://127.0.0.1:9/mcp", headers: [:],
                                          enabled: true, policy: .allow)]
        client.discoveredTools = [MCPTool(name: "create_page", description: "make a page",
                                          inputSchema: ["type": "object"],
                                          serverId: "s1", serverLabel: "Notion")]
        let router = NativeToolRouter(registry: NativeToolRegistry(locationService: LocationService()))
        router.mcpClient = client

        let profile = router.dispatchProfile(for: .root(name: "notion__create_page", origin: .model))
        XCTAssertEqual(profile.seam, .mcpServer(id: "s1"))
        XCTAssertTrue(profile.effectClass.requiresBoundApproval(on: profile.seam))
        XCTAssertFalse(profile.definitionDigest.isEmpty)
    }

    // MARK: - Helpers

    /// The widest registry this process can build headlessly, mirroring the fixture the execution
    /// semantics gate uses so the two gates cover the same population.
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
        registry.register(MemorySearchTool())
        registry.register(AgentDiaryTool())
        registry.register(DocumentRAGTool())
        registry.register(StudyTool())
        registry.register(OpenClawSkillsTool())
        return registry
    }
}
