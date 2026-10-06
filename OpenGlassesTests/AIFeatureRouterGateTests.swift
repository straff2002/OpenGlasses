import XCTest
@testable import OpenGlasses

/// Plan HR P2 item 6 — a switched-off AI feature is unreachable at the router, on every seam and
/// from every origin, with the same words the tool's own inline check gives.
///
/// The tools here are spies registered under the real tool names, so "refused" is a counting claim
/// (the tool never ran) rather than a reading of whatever the real tool would have answered, and
/// the switches are the real ones, flipped and restored, so the gate under test is the shipping one.
@MainActor
final class AIFeatureRouterGateTests: XCTestCase {

    // MARK: - Fixtures

    private final class ExecutionSpy {
        var count = 0
    }

    private struct SpyTool: NativeTool {
        let name: String
        let description = "spy"
        let spy: ExecutionSpy
        var parametersSchema: [String: Any] { ["type": "object"] }
        func execute(args: [String: Any]) async throws -> String {
            spy.count += 1
            return "ran:\(name)"
        }
    }

    private var restore: [String: Any?] = [:]

    override func tearDown() {
        for (key, value) in restore {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        restore.removeAll()
        super.tearDown()
    }

    private func set(_ feature: AIFeature, enabled: Bool) {
        let sw = feature.record.disableSwitch
        if restore.index(forKey: sw.key) == nil {
            restore[sw.key] = UserDefaults.standard.object(forKey: sw.key)
        }
        sw.setEnabled(enabled)
    }

    private func router(with names: [String], spy: ExecutionSpy) -> NativeToolRouter {
        let registry = NativeToolRegistry(locationService: LocationService())
        for name in names { registry.register(SpyTool(name: name, spy: spy)) }
        return NativeToolRouter(registry: registry)
    }

    private func composed(target: String, router: NativeToolRouter) -> SkillPackToolWrapper {
        SkillPackToolWrapper(
            packId: "com.example.pack",
            action: SkillPackAction(name: "do_it", description: "Fixture.",
                                    parametersSchema: ["type": "object"],
                                    binding: .tool(name: target, boundArgs: [:])),
            dispatchChild: { [weak router] call in
                await router?.execute(call) ?? .failedBeforeExecution(reason: "no authority")
            })
    }

    // MARK: - Refused at the router

    func testADisabledFeaturesToolIsRefusedWithTheInlineMessage() async {
        set(.firstAidAssist, enabled: false)
        let spy = ExecutionSpy()
        let router = router(with: ["first_aid"], spy: spy)

        let outcome = await router.executeRoot(name: "first_aid", args: ["action": "start"])

        XCTAssertEqual(outcome, .rejected(reason: AIFeatureGate.disabledMessage(.firstAidAssist)))
        XCTAssertEqual(spy.count, 0, "a refusal that still executes is the bug")
        // The same sentence the real tool's inline check returns, so the model hears one answer
        // whichever gate caught the call.
        let inline = try? await FirstAidTool().execute(args: ["action": "start"])
        XCTAssertEqual(outcome.text, inline)
        XCTAssertEqual(outcome.retryDisposition, .retryWillBeRefused)
    }

    func testAnEnabledFeaturesToolPasses() async {
        set(.firstAidAssist, enabled: true)
        let spy = ExecutionSpy()
        let router = router(with: ["first_aid"], spy: spy)

        let outcome = await router.executeRoot(name: "first_aid", args: [:])

        XCTAssertEqual(outcome, .completed("ran:first_aid"))
        XCTAssertEqual(spy.count, 1)
        XCTAssertTrue(router.authorizationEvents.events.isEmpty)
    }

    /// One feature off leaves every other feature's tools, and tools with no feature, alone.
    func testOnlyTheDisabledFeaturesToolsAreRefused() async {
        set(.messaging, enabled: false)
        set(.healthVault, enabled: true)
        let spy = ExecutionSpy()
        let router = router(with: ["send_message", "send_via", "asian_messaging", "health_vault",
                                   "get_weather"], spy: spy)

        for name in ["send_message", "send_via", "asian_messaging"] {
            let outcome = await router.executeRoot(name: name, args: [:])
            XCTAssertEqual(outcome, .rejected(reason: AIFeatureGate.disabledMessage(.messaging)), name)
        }
        XCTAssertEqual(spy.count, 0)
        let vault = await router.executeRoot(name: "health_vault", args: [:])
        XCTAssertEqual(vault, .completed("ran:health_vault"))
        let weather = await router.executeRoot(name: "get_weather", args: [:])
        XCTAssertEqual(weather, .completed("ran:get_weather"))
    }

    /// A tool with no inline check of its own — `home_assistant` — is now covered too.
    func testAToolWithoutAnInlineCheckIsRefusedAtTheRouter() async {
        set(.smartHomeControl, enabled: false)
        let spy = ExecutionSpy()
        let router = router(with: ["home_assistant"], spy: spy)

        let outcome = await router.executeRoot(name: "home_assistant", args: ["action": "list"])

        XCTAssertEqual(outcome, .rejected(reason: AIFeatureGate.disabledMessage(.smartHomeControl)))
        XCTAssertEqual(spy.count, 0)
    }

    /// Reached through a skill pack's composed binding, the same tool is refused the same way.
    func testAComposedToolCannotReachADisabledFeature() async throws {
        set(.fitnessCoaching, enabled: false)
        let spy = ExecutionSpy()
        let router = router(with: ["fitness_coach"], spy: spy)

        let result = try await composed(target: "fitness_coach", router: router).execute(args: [:])

        XCTAssertEqual(result, AIFeatureGate.disabledMessage(.fitnessCoaching))
        XCTAssertEqual(spy.count, 0)
        let event = try XCTUnwrap(router.authorizationEvents.events.first)
        XCTAssertEqual(event.verdict, ToolRefusalReason.featureDisabled.rawValue)
        XCTAssertEqual(event.toolName, "fitness_coach")
        XCTAssertEqual(event.depth, 1, "the composed child, not the pack action, is what was refused")
    }

    /// Every origin funnels through `execute`, so Siri and the live modes are covered alike.
    func testEveryOriginIsRefused() async {
        set(.healthSummaries, enabled: false)
        let spy = ExecutionSpy()
        let router = router(with: ["health_summary"], spy: spy)

        for origin in [ToolInvocationOrigin.model, .siriAction] {
            let outcome = await router.executeRoot(name: "health_summary", args: [:], origin: origin)
            XCTAssertEqual(outcome, .rejected(reason: AIFeatureGate.disabledMessage(.healthSummaries)),
                           "\(origin)")
        }
        XCTAssertEqual(spy.count, 0)
    }

    func testTheRefusalIsRecordedAsAContentFreeSecurityEvent() async throws {
        set(.healthVault, enabled: false)
        let router = router(with: ["health_vault"], spy: ExecutionSpy())

        _ = await router.executeRoot(name: "health_vault", args: ["query": "blood pressure"])

        let event = try XCTUnwrap(router.authorizationEvents.events.first)
        XCTAssertEqual(event.verdict, "featureDisabled")
        XCTAssertEqual(event.toolName, "health_vault")
        XCTAssertFalse(String(describing: event).contains("blood pressure"),
                       "the arguments are never recorded")
    }

    // MARK: - The dispatch profile agrees

    func testTheDispatchProfileReportsADisabledToolAsUnrouted() {
        let router = router(with: ["first_aid", "get_weather"], spy: ExecutionSpy())
        let call = ResolvedToolCall.root(name: "first_aid", origin: .model)

        set(.firstAidAssist, enabled: true)
        let on = router.dispatchProfile(for: call)
        XCTAssertEqual(on.seam, .native)
        XCTAssertFalse(on.definitionDigest.isEmpty)

        set(.firstAidAssist, enabled: false)
        XCTAssertEqual(router.dispatchProfile(for: call), .unrouted,
                       "nothing will dispatch, so nothing is held in front of a wearer")
        XCTAssertEqual(router.dispatchProfile(for: .root(name: "get_weather", origin: .model)).seam,
                       .native, "a tool with no feature is unaffected")
    }

    /// Switched off while the wearer was being asked: the approval does not carry the call through.
    func testAFeatureSwitchedOffDuringConfirmationIsRefusedAfterApproval() async throws {
        let savedAgent = Config.agentModeEnabled
        Config.setAgentModeEnabled(false)
        defer { Config.setAgentModeEnabled(savedAgent) }
        set(.smartHomeControl, enabled: true)

        let spy = ExecutionSpy()
        let router = router(with: ["smart_home"], spy: spy)
        let coordinator = ToolConfirmationCoordinator()
        router.confirmationCoordinator = coordinator

        async let outcome = router.executeRoot(name: "smart_home",
                                               args: ["action": "unlock", "device": "Front Door"])
        var asked = false
        for _ in 0..<50 {
            if coordinator.pending != nil {
                asked = true
                set(.smartHomeControl, enabled: false)
                coordinator.resolve(true)
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(asked, "an unlock is confirmed first")

        let result = await outcome
        XCTAssertEqual(result, .rejected(reason: AIFeatureGate.disabledMessage(.smartHomeControl)))
        XCTAssertEqual(spy.count, 0, "an approval given before the switch went off does not actuate")
    }

    // MARK: - The registry's answer

    func testTheGateNamesTheFeatureThatOwnsTheTool() {
        set(.messaging, enabled: false)
        XCTAssertEqual(AIFeatureGate.disabledFeature(forTool: "send_via"), .messaging)
        XCTAssertTrue(AIFeatureGate.isToolDisabled("send_via"))
        XCTAssertNil(AIFeatureGate.disabledFeature(forTool: "get_weather"))
        set(.messaging, enabled: true)
        XCTAssertNil(AIFeatureGate.disabledFeature(forTool: "send_via"))
        XCTAssertFalse(AIFeatureGate.isToolDisabled("send_via"))
    }
}
