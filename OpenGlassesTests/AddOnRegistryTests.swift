import XCTest
@testable import OpenGlasses

/// Plan GF P2 — add-on skills in the registry: their names, the live gates that decide whether
/// the model is offered them (the add-ons switch, each add-on's switch, organisation policy,
/// Medical Compliance, coverage), the dispatch seam, and the composition floor.
@MainActor
final class AddOnRegistryTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AddOnRegistryTests_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func loaded(_ data: Data, enabled: Bool = true) throws -> AddOnStore.Loaded {
        let store = AddOnStore(directory: root.appendingPathComponent(UUID().uuidString), backupDirectory: root)
        let candidate = try XCTUnwrap(AddOnAdmission.review(data, installed: { _ in nil }, context: .init()).candidate)
        store.install(candidate, origin: .installed(via: .link))
        store.setEnabled(enabled, id: candidate.manifest.id)
        return try store.loaded(id: candidate.manifest.id).get()
    }

    private var currency: Data { Data(RecipeAddOnFixtures.currency.utf8) }

    /// An add-on with no network: it only says something.
    private func offline(id: String = "org.example.offline") -> Data {
        RecipeAddOnFixtures.file(skills: [RecipeAddOnFixtures.skill(name: "greet", steps: [["say": "Hello."]])],
                                 permissions: [:], overrides: ["id": id])
    }

    private func registry() -> NativeToolRegistry { NativeToolRegistry(locationService: LocationService()) }

    // MARK: - Names

    func testSkillsRegisterUnderTheAddOnPrefix() throws {
        let registry = registry()
        let report = registry.registerAddOnTools([try loaded(currency)], conditions: { .init() },
                                                 run: { _, _, _ in "ran" })
        XCTAssertEqual(report.registered, ["addon_dev_frankfurter_currency_convert_currency"])
        let tool = try XCTUnwrap(registry.tool(named: "addon_dev_frankfurter_currency_convert_currency"))
        XCTAssertTrue(tool is AddOnToolWrapper)
        XCTAssertTrue(tool.description.contains("Currency"), "the description attributes the add-on")
        XCTAssertTrue(registry.toolNames.contains("addon_dev_frankfurter_currency_convert_currency"))
        let schema = tool.parametersSchema
        XCTAssertEqual(schema["required"] as? [String], ["amount"])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual((properties["from"] as? [String: Any])?["pattern"] as? String, "^[A-Z]{3}$")
        XCTAssertEqual((properties["amount"] as? [String: Any])?["type"] as? String, "number")
    }

    func testEveryNameFitsAProviderFunctionName() {
        let longID = "com.example." + String(repeating: "verylongsegment.", count: 3) + "addon"
        let skill = String(repeating: "s", count: 40)
        let name = AddOnToolNaming.toolName(addOnID: longID, skill: skill)
        XCTAssertLessThanOrEqual(name.count, AddOnToolNaming.maxLength)
        XCTAssertTrue(name.hasPrefix(AddOnToolNaming.prefix))
        XCTAssertTrue(name.hasSuffix("_" + skill), "the skill name is kept whole")
        XCTAssertNil(name.range(of: #"[^A-Za-z0-9_]"#, options: .regularExpression))
        let other = AddOnToolNaming.toolName(addOnID: longID + "x", skill: skill)
        XCTAssertNotEqual(name, other, "two long ids that share a start still differ")
        XCTAssertEqual(AddOnToolNaming.toolName(addOnID: "a.b", skill: "c"), "addon_a_b_c")
    }

    func testAFlattenedNameCollisionKeepsTheFirstAndSaysSo() throws {
        let first = RecipeAddOnFixtures.file(skills: [RecipeAddOnFixtures.skill(name: "greet", steps: [["say": "A."]])],
                                             permissions: [:], overrides: ["id": "org.example-a"])
        let second = RecipeAddOnFixtures.file(skills: [RecipeAddOnFixtures.skill(name: "greet", steps: [["say": "B."]])],
                                              permissions: [:], overrides: ["id": "org.example.a"])
        let registry = registry()
        let report = registry.registerAddOnTools([try loaded(first), try loaded(second)], conditions: { .init() },
                                                 run: { id, _, _ in id })
        XCTAssertEqual(report.registered, ["addon_org_example_a_greet"])
        XCTAssertEqual(report.collisions, ["addon_org_example_a_greet"])
    }

    func testAnAddOnCanNeverShadowANativeTool() throws {
        let registry = registry()
        let before = Set(registry.toolNames)
        registry.registerAddOnTools([try loaded(currency)], conditions: { .init() }, run: { _, _, _ in "" })
        let added = Set(registry.toolNames).subtracting(before)
        XCTAssertTrue(added.allSatisfy { $0.hasPrefix("addon_") })
        XCTAssertTrue(before.isSubset(of: Set(registry.toolNames)), "no native tool was replaced")
    }

    // MARK: - Rebuild and switches

    func testAReMergeDropsWhatIsGoneOrSwitchedOff() throws {
        let registry = registry()
        registry.registerAddOnTools([try loaded(currency), try loaded(offline())], conditions: { .init() },
                                    run: { _, _, _ in "" })
        XCTAssertNotNil(registry.tool(named: "addon_org_example_offline_greet"))
        registry.registerAddOnTools([try loaded(currency), try loaded(offline(), enabled: false)],
                                    conditions: { .init() }, run: { _, _, _ in "" })
        XCTAssertNil(registry.tool(named: "addon_org_example_offline_greet"), "a switched-off add-on leaves")
        XCTAssertNotNil(registry.tool(named: "addon_dev_frankfurter_currency_convert_currency"))
        registry.registerAddOnTools([], conditions: { .init() }, run: { _, _, _ in "" })
        XCTAssertFalse(registry.allTools.contains { $0 is AddOnToolWrapper })
    }

    func testTheAddOnsSwitchHidesEverySkillAtOnce() throws {
        var conditions = AddOnAvailability.Conditions()
        let registry = registry()
        registry.registerAddOnTools([try loaded(currency), try loaded(offline())], conditions: { conditions },
                                    run: { _, _, _ in "" })
        conditions.addOnsEnabled = false
        XCTAssertFalse(registry.toolNames.contains { $0.hasPrefix("addon_") })
        XCTAssertNil(registry.tool(named: "addon_org_example_offline_greet"))
        conditions.addOnsEnabled = true
        XCTAssertNotNil(registry.tool(named: "addon_org_example_offline_greet"), "the gate is live, no rebuild")
    }

    // MARK: - Medical Compliance (decision 5)

    func testMedicalComplianceHidesNetworkAddOnsButNotOthers() throws {
        var conditions = AddOnAvailability.Conditions()
        let registry = registry()
        registry.registerAddOnTools([try loaded(currency), try loaded(offline())], conditions: { conditions },
                                    run: { _, _, _ in "" })
        conditions.hipaaMode = true
        XCTAssertFalse(registry.toolNames.contains("addon_dev_frankfurter_currency_convert_currency"),
                       "a transcript-derived parameter must not leave through an add-on")
        XCTAssertNil(registry.tool(named: "addon_dev_frankfurter_currency_convert_currency"))
        XCTAssertTrue(registry.toolNames.contains("addon_org_example_offline_greet"),
                      "an add-on that reaches no host stays")
        XCTAssertTrue(registry.toolDescriptions(for: ["addon_dev_frankfurter_currency_convert_currency"]).isEmpty)
    }

    func testAvailabilityRule() throws {
        let manifest = RecipeAddOnFixtures.currencyManifest
        let conditions = AddOnAvailability.Conditions()
        XCTAssertNil(AddOnAvailability.hidden(manifest, trust: .community, enabled: true, conditions: conditions))
        XCTAssertEqual(AddOnAvailability.hidden(manifest, trust: .community, enabled: false, conditions: conditions),
                       .turnedOff)
        var hipaa = conditions
        hipaa.hipaaMode = true
        XCTAssertEqual(AddOnAvailability.hidden(manifest, trust: .community, enabled: true, conditions: hipaa),
                       .medicalCompliance)
        var managed = conditions
        managed.policy = AddOnPolicy(ceiling: .signedOnly)
        XCTAssertEqual(AddOnAvailability.hidden(manifest, trust: .community, enabled: true, conditions: managed),
                       .policy(.communityNotAllowed))
        XCTAssertNil(AddOnAvailability.hidden(manifest, trust: .vendorSigned, enabled: true, conditions: managed))
        var disabled = conditions
        disabled.policy = AddOnPolicy(ceiling: .addOnsDisabled)
        XCTAssertEqual(AddOnAvailability.hidden(manifest, trust: .vendorSigned, enabled: true, conditions: disabled),
                       .policy(.addOnsDisabled))
    }

    // MARK: - Coverage

    func testOutsideCoverageTheSkillsAreNotDeclared() throws {
        let covered = RecipeAddOnFixtures.file(skills: [RecipeAddOnFixtures.skill(name: "greet", steps: [["say": "Kia ora."]])],
                                               permissions: [:], overrides: ["id": "nz.example.local", "coverage": ["NZ", "AU"]])
        var conditions = AddOnAvailability.Conditions(region: "NZ")
        let registry = registry()
        registry.registerAddOnTools([try loaded(covered)], conditions: { conditions }, run: { _, _, _ in "" })
        XCTAssertTrue(registry.toolNames.contains("addon_nz_example_local_greet"))
        conditions.region = "GB"
        XCTAssertFalse(registry.toolNames.contains("addon_nz_example_local_greet"))
        conditions.region = nil
        XCTAssertTrue(registry.toolNames.contains("addon_nz_example_local_greet"), "an unknown region doesn't hide it")
        XCTAssertTrue(AddOnAvailability.isCovered(["*"], region: "GB"))
        XCTAssertTrue(AddOnAvailability.isCovered(nil, region: "GB"))
        XCTAssertTrue(AddOnAvailability.isCovered(["gb"], region: "GB"))
    }

    // MARK: - Execution

    func testExecuteHandsTheSkillToTheRunner() async throws {
        let registry = registry()
        registry.registerAddOnTools([try loaded(currency)], conditions: { .init() },
                                    run: { id, skill, args in "\(id)/\(skill)/\(args["amount"] ?? "")" })
        let tool = try XCTUnwrap(registry.tool(named: "addon_dev_frankfurter_currency_convert_currency"))
        let result = try await tool.execute(args: ["amount": 5])
        XCTAssertEqual(result, "dev.frankfurter.currency/convert_currency/5")
    }

    func testAWrapperBuiltWithoutARunnerRunsNothing() async throws {
        let wrapper = AddOnToolWrapper(addOnID: "a.b", addOnName: "A",
                                       skill: RecipeAddOnFixtures.currencyManifest.skills[0],
                                       permissions: .empty)
        let result = try await wrapper.execute(args: [:])
        XCTAssertEqual(result, "That add-on isn't available right now.")
    }

    func testSemanticsAndEffectClassFollowThePermissions() throws {
        let skill = RecipeAddOnFixtures.currencyManifest.skills[0]
        let reader = AddOnToolWrapper(addOnID: "a.b", addOnName: "A", skill: skill,
                                      permissions: .init(network: ["api.example.org"], location: false,
                                                         memory: false, display: false))
        XCTAssertEqual(reader.executionSemantics.effect, .readOnly)
        XCTAssertEqual(reader.effectClass, .readOnly)
        XCTAssertEqual(reader.egressProfile?.route, .recipeAddOn)
        XCTAssertEqual(reader.egressProfile?.argumentKeys, ["from", "to"], "the text parameters leave the device")
        let writer = AddOnToolWrapper(addOnID: "a.b", addOnName: "A", skill: skill,
                                      permissions: .init(network: [], location: false, memory: true, display: false))
        XCTAssertEqual(writer.executionSemantics.effect, .localMutation)
        XCTAssertEqual(writer.effectClass, .write)
        XCTAssertNil(writer.egressProfile, "nothing leaves an add-on without network")
    }

    func testTheRouterDispatchesAnAddOnOnItsOwnSeam() throws {
        let registry = registry()
        registry.registerAddOnTools([try loaded(currency)], conditions: { .init() }, run: { _, _, _ in "" })
        let router = NativeToolRouter(registry: registry)
        let call = ResolvedToolCall.root(name: "addon_dev_frankfurter_currency_convert_currency",
                                         arguments: ToolArguments(["amount": 5]), origin: .model)
        let profile = router.dispatchProfile(for: call)
        XCTAssertEqual(profile.seam, .addOn(id: "dev.frankfurter.currency"))
        XCTAssertEqual(profile.seam.identity, "addon:dev.frankfurter.currency")
        XCTAssertTrue(profile.seam.isExternal)
        XCTAssertEqual(profile.effectClass, .readOnly)
        XCTAssertFalse(profile.definitionDigest.isEmpty)
    }

    func testAWithheldAddOnNameNeverFallsThroughToAnotherSeam() async throws {
        var conditions = AddOnAvailability.Conditions()
        let registry = registry()
        registry.registerAddOnTools([try loaded(currency)], conditions: { conditions }, run: { _, _, _ in "ran" })
        conditions.hipaaMode = true
        let router = NativeToolRouter(registry: registry)
        let call = ResolvedToolCall.root(name: "addon_dev_frankfurter_currency_convert_currency",
                                         arguments: ToolArguments(["amount": 5]), origin: .model)
        XCTAssertEqual(router.dispatchProfile(for: call), .unrouted)
        let outcome = await router.execute(call)
        guard case .failedBeforeExecution = outcome else {
            return XCTFail("a withheld add-on must fail before anything runs, got \(outcome)")
        }
    }

    // MARK: - Composition floor

    func testNoCompositionMayCallAnAddOn() {
        let root = ResolvedToolCall.root(name: "pack_a_run", origin: .model)
        let child = root.child(name: "addon_dev_frankfurter_currency_convert_currency", arguments: [:], composerID: "a")
        guard case .refuse(let reason, _) = ToolAuthorizationPolicy.evaluate(.init(call: child, agentModeEnabled: false)) else {
            return XCTFail("an add-on is never a composition target")
        }
        XCTAssertEqual(reason, .packChaining)
    }
}
