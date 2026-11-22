import XCTest
@testable import OpenGlasses

/// Plan MQ P3: the device qualification app's fixture is what the app builds today.
///
/// `Scripts/local-model-qualification/Fixture/qualification-fixture.json` holds the offered tools'
/// declarations, from the real registry, and the lean on-device system prompts, from the real
/// prompt builder with the Lennox example vault's job open (`LocalModelQualificationFixture`). A
/// tool description, a parameter, the prompt head, the compact job tier or the corpus changing
/// without the fixture fails here, and the test writes the fresh file in place: review the diff and
/// commit it.
@MainActor
final class LocalModelQualificationFixtureTests: XCTestCase {

    private static let vaultID = "mq_qualification_fixture"

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LocalToolEval
            .deletingLastPathComponent()   // OpenGlassesTests
            .deletingLastPathComponent()   // repo root
    }

    private static var fixtureURL: URL {
        repoRoot.appendingPathComponent("Scripts/local-model-qualification/Fixture", isDirectory: true)
            .appendingPathComponent(LocalModelQualificationFixture.fileName)
    }

    private static var lennoxDirectory: URL {
        repoRoot.appendingPathComponent("examples/vaults/lennox-slp99", isDirectory: true)
    }

    /// The models a phone run may qualify: the tool candidates, whose job tier is fitted to their
    /// own budget.
    static var modelIDs: [String] { LocalModelCatalog.toolCandidateModelIDs.sorted() }

    private var root: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QualificationFixture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        VaultImporter.uninstall(id: Self.vaultID)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: root)
        if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    /// The Lennox vault, re-identified so it cannot collide with an installed copy, with one text
    /// manual built from its own service values and codes (as `FieldAssistContextAuditTests`).
    private func writeVault() throws -> URL {
        let source = Self.lennoxDirectory
        let dir = root.appendingPathComponent("vault", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("documents"), withIntermediateDirectories: true)
        for file in ["safety.md", "error_codes.md", "models.md", "service_values.md", "parts.md"] {
            try fm.copyItem(at: source.appendingPathComponent(file), to: dir.appendingPathComponent(file))
        }
        try fm.copyItem(at: source.appendingPathComponent("procedures"), to: dir.appendingPathComponent("procedures"))
        let manual = try ["service_values.md", "error_codes.md"].map {
            try String(contentsOf: source.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n\n")
        try manual.write(to: dir.appendingPathComponent("documents/manual.txt"), atomically: true, encoding: .utf8)
        var manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: source.appendingPathComponent("manifest.json"))) as? [String: Any] ?? [:]
        manifest["id"] = Self.vaultID
        manifest["documents"] = [["file": "manual.txt", "title": "SLP99 service values", "kind": "service_manual"]]
        manifest["gating"] = ["iap": "enterprise"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    private static func corpusBodySha256() throws -> String {
        let url = repoRoot.appendingPathComponent("Scripts/local-tool-eval/corpus")
            .appendingPathComponent(LocalToolEval.corpusFileName)
        let text = try String(contentsOf: url, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("// body-sha256: ") })
        return String(line.dropFirst("// body-sha256: ".count))
    }

    /// The lean prompt with the job's tier where `buildSystemPrompt` puts it: after the date and
    /// location, before the safety policy (the blocks between are empty with no other state).
    private static func inserting(tier: String, into base: String) throws -> String {
        let policy = "\n\n" + PromptInjectionPolicy.onDeviceSystemPromptPolicy
        let ranges = base.ranges(of: policy)
        XCTAssertEqual(ranges.count, 1, "the safety policy appears once in the lean prompt")
        let at = try XCTUnwrap(ranges.first)
        return String(base[..<at.lowerBound]) + "\n\n<field_assist_context>\n\(tier)\n</field_assist_context>"
            + String(base[at.lowerBound...])
    }

    private func build() async throws -> LocalModelQualificationFixture {
        let text = try String(contentsOf: Self.repoRoot.appendingPathComponent("Scripts/local-tool-eval/corpus")
            .appendingPathComponent(LocalToolEval.corpusFileName), encoding: .utf8)
        let cases = LocalToolEval.loadCorpus(text).cases
        let registry = NativeToolRegistry(locationService: LocationService())
        var tools: [String: LocalModelQualificationFixture.Tool] = [:]
        for name in Set(cases.flatMap(\.offered)).union(FieldAssistLocalToolSet.priority) {
            let tool = try XCTUnwrap(registry.tool(named: name), "\(name) is registered")
            XCTAssertTrue(JSONSerialization.isValidJSONObject(tool.parametersSchema), "\(name)'s schema is JSON")
            tools[name] = .init(description: tool.description, parameters: tool.parametersSchema)
        }

        let manifest = try VaultImporter.install(from: try writeVault())
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let storeDirectory = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let store = DocumentStore(directory: storeDirectory)
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
        let service = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        service.documentStore = store
        _ = try service.startSession(vaultId: manifest.id, assetId: nil, jobReference: "1005")
        service.setEquipment(EquipmentIdentity(modelToken: "SLP99UH090XV60CK", heading: "SLP99UH090XV60CK",
                                               file: "models.md", source: .spoken))
        _ = service.recordReading(quantity: "manifold pressure, low fire", value: "0.6", unit: "inWC")
        _ = service.recordReading(quantity: "manifold pressure, high fire", value: "3.5", unit: "inWC")
        _ = service.recordReading(quantity: "line pressure", value: "7.0", unit: "inWC")
        _ = service.recordReading(quantity: "flame signal", value: "2.9", unit: "µA")

        let settingsPath = "Settings > \(SettingsHub.path(to: .intelligence))"
        func tier(_ id: String) throws -> String {
            // Under qualification the job's tools are offered, as `sendLocal` decides with the flag on.
            try XCTUnwrap(service.localPromptContext(turn: nil, fieldToolsOffered: true,
                                                     budgetTokens: LocalModelBudget.jobContextBudget(for: id),
                                                     modelSettingsPath: settingsPath))
        }
        var bases: [String: String] = [:]
        var jobTiers: [String: String] = [:]
        for id in Self.modelIDs {
            let lean = await LLMService.leanOnDevicePrompt(locationContext: nil, memoryContext: nil, hasImage: false,
                                                           turn: "", localModelID: id)
            XCTAssertFalse(lean.contains("<field_assist_context>"), "the shared job service has no job open here")
            bases[id] = lean
            jobTiers[id] = try tier(id)
        }
        XCTAssertNotNil(try? service.startProcedure(id: "slp99_no_ignition"), "the no-ignition procedure starts")
        for n in 0..<30 {
            service.recordConversationTurn("Checked item \(n) on the burner box and the inducer, all as expected.",
                                           sourceID: "fixture-\(n)")
        }
        var prompts: [String: LocalModelQualificationFixture.Prompts] = [:]
        for id in Self.modelIDs {
            let base = try XCTUnwrap(bases[id])
            prompts[id] = .init(
                everyday: LocalModelQualificationFixture.withDatePlaceholder(base),
                job: LocalModelQualificationFixture.withDatePlaceholder(try Self.inserting(tier: try XCTUnwrap(jobTiers[id]), into: base)),
                longJob: LocalModelQualificationFixture.withDatePlaceholder(try Self.inserting(tier: try tier(id), into: base)))
        }
        return LocalModelQualificationFixture(version: LocalModelQualificationFixture.version,
                                              corpusBodySha256: try Self.corpusBodySha256(),
                                              assistantName: Config.assistantName, tools: tools, prompts: prompts)
    }

    func testTheCommittedFixtureIsWhatTheAppBuilds() async throws {
        let fresh = try await build()
        let data = try fresh.encoded()
        let committed = try? Data(contentsOf: Self.fixtureURL)
        if committed != data {
            try FileManager.default.createDirectory(at: Self.fixtureURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: Self.fixtureURL)
            XCTFail("the qualification fixture was stale and has been rewritten: review and commit "
                    + "Scripts/local-model-qualification/Fixture/\(LocalModelQualificationFixture.fileName)")
        }
        // Counts only.
        print("qualification fixture: \(fresh.tools.count) tools, \(fresh.prompts.count) models, \(data.count) bytes")
    }

    func testTheFixtureDecodesAndRendersEachCaseAsSendLocalWould() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let fixture = try XCTUnwrap(LocalModelQualificationFixture.decode(data))
        XCTAssertEqual(fixture.version, LocalModelQualificationFixture.version)
        XCTAssertEqual(fixture.corpusBodySha256, try Self.corpusBodySha256(), "built for this corpus")
        let text = try String(contentsOf: Self.repoRoot.appendingPathComponent("Scripts/local-tool-eval/corpus")
            .appendingPathComponent(LocalToolEval.corpusFileName), encoding: .utf8)
        let registry = NativeToolRegistry(locationService: LocationService())
        for testCase in LocalToolEval.loadCorpus(text).cases {
            for name in testCase.offered {
                let tool = try XCTUnwrap(registry.tool(named: name))
                // The same spec and root the app builds from the registry.
                let spec = try XCTUnwrap(fixture.toolSpec(name))
                let live = OnDeviceToolSchema.localToolSpec(name: name, description: tool.description,
                                                            parameters: tool.parametersSchema)
                XCTAssertEqual(try JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys]),
                               try JSONSerialization.data(withJSONObject: live, options: [.sortedKeys]), name)
                XCTAssertEqual(fixture.schemaRoot(name), OnDeviceToolSchema.root(toolName: name, parameters: tool.parametersSchema))
            }
            for id in Self.modelIDs {
                let prompt = try XCTUnwrap(fixture.systemPrompt(for: testCase, modelID: id, dateTimeLine: "today"))
                XCTAssertFalse(prompt.contains(LocalModelQualificationFixture.dateTimePlaceholder))
                XCTAssertTrue(prompt.contains("CURRENT DATE & TIME: today"))
                XCTAssertTrue(prompt.hasSuffix(LLMService.localNativeToolGuide(toolNames: testCase.offered)))
                XCTAssertEqual(prompt.contains("<field_assist_context>"), testCase.group == .fieldAssist, testCase.id)
            }
        }
        // The long tier carries more of the job than the plain one, within its budget.
        for id in Self.modelIDs {
            let prompts = try XCTUnwrap(fixture.prompts[id])
            XCTAssertGreaterThan(prompts.longJob.count, prompts.job.count, id)
            XCTAssertGreaterThan(prompts.job.count, prompts.everyday.count, id)
        }
    }

    /// The qualification app builds against the app's own mlx-swift-lm revision.
    func testTheQualificationAppPinsTheAppsRuntime() throws {
        func pin(_ path: String) throws -> String? {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            guard let range = text.range(of: "mlx-swift-lm:") else { return nil }
            let after = text[range.upperBound...]
            guard let revision = after.range(of: #"revision: ([0-9a-f]{40})"#, options: .regularExpression) else { return nil }
            return String(after[revision].dropFirst("revision: ".count))
        }
        let app = try XCTUnwrap(try pin("project.base.yml"))
        XCTAssertEqual(try pin("Scripts/local-model-qualification/project.yml"), app)
        let constant = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "Scripts/local-model-qualification/DeviceFacts.swift"), encoding: .utf8)
        XCTAssertTrue(constant.contains("\"\(app)\""), "the record names the revision the app was built against")
    }
}
