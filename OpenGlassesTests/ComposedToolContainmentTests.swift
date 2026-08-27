import XCTest
@testable import OpenGlasses

/// Plan DJ P0 — user-authored composition (skill-pack `.tool` bindings, Siri Actions) executes
/// off the registry, past the router that applies the confirmation gate. These cover the
/// containment: admission, merge-time quarantine of packs installed before the floor existed,
/// the execution-time refusals, and the shared classification that keeps all of them in step
/// with the router's own policy.
@MainActor
final class ComposedToolContainmentTests: XCTestCase {

    // MARK: - Fixtures

    /// Records whether the bound tool was reached — a refusal that still executes is the bug.
    private final class ExecutionSpy {
        var invoked = false
    }

    private struct ActuatorStub: NativeTool {
        let name: String
        let description = "stub"
        let spy: ExecutionSpy
        var parametersSchema: [String: Any] { ["type": "object"] }
        func execute(args: [String: Any]) async throws -> String {
            spy.invoked = true
            return "actuated"
        }
    }

    private struct ReadOnlyStub: NativeTool {
        let name = "get_weather"
        let description = "reads the weather"
        var parametersSchema: [String: Any] { ["type": "object"] }
        func execute(args: [String: Any]) async throws -> String { "sunny" }
    }

    private func manifestJSON(
        id: String = "com.example.pack",
        version: String = "1.0.0",
        actions: [[String: Any]]
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "id": id, "version": version, "name": "Test Pack",
            "summary": "fixture", "actions": actions,
        ])
    }

    private func promptAction(name: String) -> [String: Any] {
        [
            "name": name,
            "description": "Use when the user asks for the fixture behaviour.",
            "parameters": ["type": "object", "properties": [String: Any]()],
            "binding": ["kind": "prompt", "template": "Do the {{thing}}."],
        ]
    }

    private func toolAction(name: String, target: String, boundArgs: [String: String] = [:]) -> [String: Any] {
        [
            "name": name,
            "description": "Use when the user asks for the fixture behaviour.",
            "parameters": ["type": "object", "properties": [String: Any]()],
            "binding": ["kind": "tool", "name": target, "boundArgs": boundArgs],
        ]
    }

    private func makeStore(directory: URL? = nil, nativeNames: Set<String>) -> SkillPackStore {
        let dir = directory ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("composed-tool-tests-\(UUID().uuidString)", isDirectory: true)
        return SkillPackStore(directory: dir, currentBuild: 329, nativeToolNames: { nativeNames })
    }

    private func validate(_ data: Data, nativeNames: Set<String>) -> SkillPackValidator.Outcome {
        let (manifest, report) = SkillPackManifest.lossyDecode(data)
        return SkillPackValidator.validate(manifest: manifest!, report: report,
                                           currentBuild: 329, nativeToolNames: nativeNames)
    }

    // MARK: - Shared classification

    func testClassificationTracksTheRouterPolicies() {
        // No second list: everything the router gates is restricted here, and nothing else is.
        for tool in PromptInjectionPolicy.highImpactTools {
            XCTAssertTrue(ComposedToolPolicy.isRestrictedTarget(tool),
                          "\(tool) is gated by the router and must be off-limits to composition")
        }
        XCTAssertTrue(ComposedToolPolicy.isRestrictedTarget("smart_home"))
        XCTAssertTrue(ComposedToolPolicy.isRestrictedTarget("home_assistant"))
        XCTAssertTrue(ComposedToolPolicy.isRestrictedTarget("medical_export"))
        // Args-dependent at the router; a binding merges caller args, so the name alone decides.
        XCTAssertTrue(ComposedToolPolicy.isRestrictedTarget("code_agent"))

        XCTAssertFalse(ComposedToolPolicy.isRestrictedTarget("get_weather"))
        XCTAssertFalse(ComposedToolPolicy.isRestrictedTarget("save_note"))
        XCTAssertFalse(ComposedToolPolicy.isRestrictedTarget("teleprompter"))
    }

    // MARK: - Skill-pack admission

    func testPackBindingToActuatingToolIsRejected() {
        for target in ["smart_home", "home_assistant", "medical_export"] {
            let data = manifestJSON(actions: [toolAction(name: "do_it", target: target)])
            let outcome = validate(data, nativeNames: [target])
            guard case .rejected(let reasons) = outcome else {
                return XCTFail("a pack wrapping \(target) must be rejected, got \(outcome)")
            }
            XCTAssertTrue(reasons.contains { $0.contains(target) && $0.contains("confirm") },
                          "the reason must name the target and why: \(reasons)")
        }
    }

    func testPackInstallRefusesActuatingBindingEndToEnd() {
        let store = makeStore(nativeNames: ["smart_home"])
        let result = store.install(
            manifestData: manifestJSON(actions: [
                toolAction(name: "unlock_door", target: "smart_home", boundArgs: ["action": "unlock"]),
            ]),
            signatureBase64: nil, developerMode: true)
        guard case .rejected = result else { return XCTFail("install must refuse the pack") }
        XCTAssertTrue(store.installedPacks.isEmpty)
    }

    func testPromptPackAndReadOnlyBindingRemainUsable() async throws {
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(ReadOnlyStub())
        let store = makeStore(nativeNames: ["get_weather"])

        let result = store.install(
            manifestData: manifestJSON(actions: [
                promptAction(name: "coach_me"),
                toolAction(name: "check_sky", target: "get_weather"),
            ]),
            signatureBase64: nil, developerMode: true)
        guard case .installed = result else { return XCTFail("a benign pack must still install: \(result)") }

        let router = NativeToolRouter(registry: registry)
        registry.registerSkillPackTools(from: store, authority: router)
        let prompt = try XCTUnwrap(registry.tool(named: "pack_com_example_pack_coach_me"))
        let promptResult = try await prompt.execute(args: ["thing": "dishes"])
        XCTAssertTrue(promptResult.contains("dishes"))
        let composed = try XCTUnwrap(registry.tool(named: "pack_com_example_pack_check_sky"))
        let composedResult = try await composed.execute(args: [:])
        XCTAssertEqual(composedResult, "sunny")
        XCTAssertNil(store.installedPacks.first?.quarantinedActions,
                     "nothing to quarantine, so nothing is claimed")
    }

    // MARK: - Quarantine of already-installed packs

    func testLegacyInstalledPackIsQuarantinedOnMerge() throws {
        // A pack admitted by a build that predates the floor: written straight to the store's
        // layout, exactly as an older install left it (no `quarantinedActions` key).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("composed-tool-legacy-\(UUID().uuidString)", isDirectory: true)
        let versionDir = dir.appendingPathComponent("com.example.pack", isDirectory: true)
            .appendingPathComponent("1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        try manifestJSON(actions: [
            toolAction(name: "unlock_door", target: "smart_home", boundArgs: ["action": "unlock"]),
            promptAction(name: "coach_me"),
        ]).write(to: versionDir.appendingPathComponent("skillpack.json"))
        try JSONSerialization.data(withJSONObject: [[
            "id": "com.example.pack", "activeVersion": "1.0.0", "name": "Test Pack",
            "summary": "fixture", "enabled": true, "signatureVerified": true,
            "installedAt": 0, "decodeSummary": "clean", "actionCount": 2,
        ]]).write(to: dir.appendingPathComponent("state.json"))

        let store = makeStore(directory: dir, nativeNames: ["smart_home"])
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.registerSkillPackTools(from: store)

        XCTAssertNil(registry.tool(named: "pack_com_example_pack_unlock_door"),
                     "the offending action must not be callable")
        XCTAssertNotNil(registry.tool(named: "pack_com_example_pack_coach_me"),
                        "the rest of the pack keeps working")
        let pack = try XCTUnwrap(store.installedPacks.first)
        XCTAssertTrue(pack.enabled, "the pack stays installed and on")
        XCTAssertEqual(pack.quarantinedActions, ["unlock_door"])
        XCTAssertTrue(ComposedToolPolicy.quarantineNotice(actionNames: ["unlock_door"])
            .contains("unlock_door"), "the remediation names what was held back")

        // Deterministic: the same state reloaded from disk reaches the same verdict.
        let reloaded = makeStore(directory: dir, nativeNames: ["smart_home"])
        XCTAssertEqual(reloaded.installedPacks.first?.quarantinedActions, ["unlock_door"])
    }

    // MARK: - Wrapper execution refusal

    func testWrapperRefusesRestrictedTargetWithoutExecuting() async throws {
        // The wrapper holds no tool instance any more: it resolves the child call and hands it to
        // the authority, which refuses a restricted target under the shipping default. A pack that
        // slipped past admission and quarantine still cannot actuate.
        let spy = ExecutionSpy()
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(ActuatorStub(name: "smart_home", spy: spy))
        let router = NativeToolRouter(registry: registry)
        let wrapper = SkillPackToolWrapper(
            packId: "com.example.pack",
            action: SkillPackAction(
                name: "unlock_door",
                description: "Unlocks the door.",
                parametersSchema: ["type": "object"],
                binding: .tool(name: "smart_home", boundArgs: ["action": "unlock"])),
            dispatchChild: { [weak router] call in
                await router?.execute(call) ?? .failedBeforeExecution(reason: "no authority")
            })

        let result = try await wrapper.execute(args: [:])
        XCTAssertFalse(spy.invoked, "a refusal that still executes is the bug")
        XCTAssertTrue(result.contains("smart_home"))
        XCTAssertTrue(result.contains("confirmation"))
        let event = try XCTUnwrap(router.authorizationEvents.events.first,
                                  "the refusal is recorded as a security event")
        XCTAssertEqual(event.verdict, ToolRefusalReason.restrictedTarget.rawValue)
    }

    // MARK: - Siri Actions

    func testSiriActionBoundToActuatingToolIsRefused() {
        let unlock = SiriActionBinding.tool(name: "smart_home", argsJSON: #"{"action":"unlock"}"#)

        // Refused at execution, so an action saved by an earlier build can't actuate either.
        XCTAssertNotNil(SiriActionDispatcher.refusalReason(for: unlock))
        XCTAssertNil(SiriActionDispatcher.refusalReason(for: .tool(name: "teleprompter", argsJSON: "")))
        XCTAssertNil(SiriActionDispatcher.refusalReason(for: .prompt(text: "brief me")))

        // Refused at admission: never offered, never saved.
        let definition = SiriActionDefinition(displayName: "Unlock", binding: unlock)
        XCTAssertEqual(
            SiriActionCatalog.validate(definition, existing: [], availableToolNames: ["smart_home"],
                                       agentModeEnabled: true, blockedToolNames: []),
            .toolNeedsDirectConfirmation("smart_home"))

        let catalog = SiriActionCatalog(config: SiriExposureConfig(userActions: [definition]),
                                        agentModeEnabled: true)
        XCTAssertFalse(catalog.entries.contains { $0.binding == unlock },
                       "an ineligible binding is dropped from the catalog entirely")
    }

    func testSiriActionBoundToReadOnlyToolStillValidates() {
        let definition = SiriActionDefinition(
            displayName: "Prompter",
            binding: .tool(name: "teleprompter", argsJSON: #"{"action": "start"}"#))
        XCTAssertNil(SiriActionCatalog.validate(
            definition, existing: [], availableToolNames: ["teleprompter"],
            agentModeEnabled: false, blockedToolNames: []))
        let catalog = SiriActionCatalog(config: SiriExposureConfig(userActions: [definition]))
        XCTAssertTrue(catalog.enabledEntries.contains { $0.displayName == "Prompter" })
    }
}
