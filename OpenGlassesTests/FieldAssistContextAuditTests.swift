import XCTest
@testable import OpenGlasses

/// Plan MQ P0: what `<field_assist_context>` (`FieldSessionService.promptContext`) puts in a local
/// turn's prompt today, against each catalog model's window.
///
/// The job is realistic rather than minimal: the Lennox SLP99 example vault's core files and
/// procedures (`examples/vaults/lennox-slp99`), with a manual made of the vault's own service-value
/// and diagnostic-code text standing in for the manufacturer's PDFs (which are not committed), a
/// nameplate read, four readings, a running procedure and a long conversation. Sizes are measured
/// with the estimate the local path budgets with (`HandoffTranscriptBridge.estimatedTokens`, four
/// characters a token), and printed as counts — the numbers in Plan MQ's context-audit table.
@MainActor
final class FieldAssistContextAuditTests: XCTestCase {

    private static let vaultID = "mq_context_audit"
    private var root: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

    private static var lennoxDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenGlassesTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("examples/vaults/lennox-slp99", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FieldAssistContextAudit-\(UUID().uuidString)", isDirectory: true)
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
    /// manual built from its own service values and codes.
    private func writeVault() throws -> URL {
        let source = Self.lennoxDirectory
        let dir = root.appendingPathComponent("vault", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("documents"), withIntermediateDirectories: true)
        let core = ["safety.md", "error_codes.md", "models.md", "service_values.md", "parts.md"]
        for file in core {
            try fm.copyItem(at: source.appendingPathComponent(file), to: dir.appendingPathComponent(file))
        }
        try fm.copyItem(at: source.appendingPathComponent("procedures"), to: dir.appendingPathComponent("procedures"))
        let manual = try ["service_values.md", "error_codes.md"].map {
            try String(contentsOf: source.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n\n")
        try manual.write(to: dir.appendingPathComponent("documents/manual.txt"), atomically: true, encoding: .utf8)

        let original = try JSONSerialization.jsonObject(
            with: Data(contentsOf: source.appendingPathComponent("manifest.json"))) as? [String: Any] ?? [:]
        var manifest = original
        manifest["id"] = Self.vaultID
        manifest["name"] = "Context audit vault"
        manifest["documents"] = [["file": "manual.txt", "title": "SLP99 service values", "kind": "service_manual"]]
        manifest["gating"] = ["iap": "enterprise"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    /// `<field_assist_context>` and its newlines.
    private static let wrapperTokens = 12
    /// What must be left for three exchanges of history and the turn itself, on every catalog model.
    private static let historyAndTurnFloor = 400
    /// The same on Gemma 4 E2B, the first model under qualification, with its native tools declared.
    private static let gemmaNativeFloor = 600

    private static func blockTokens(_ context: String) -> Int {
        HandoffTranscriptBridge.estimatedTokens("\n\n<field_assist_context>\n\(context)\n</field_assist_context>")
    }

    private struct Measurement {
        let state: String
        let tokens: Int
        /// The compact tier (Plan MQ P1) in the same state, before it is fitted to a model.
        let compactTokens: Int
    }

    func testTheJobContextAgainstEveryCatalogWindow() async throws {
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

        func measure(_ state: String, turn: String? = nil) throws -> Measurement {
            let context = try XCTUnwrap(service.promptContext(turn: turn), state)
            let compact = try XCTUnwrap(service.localPromptContext(turn: turn, fieldToolsOffered: true,
                                                                   budgetTokens: .max,
                                                                   modelSettingsPath: "Settings > Assistant"), state)
            return Measurement(state: state, tokens: Self.blockTokens(context),
                               compactTokens: Self.blockTokens(compact))
        }

        var measurements: [Measurement] = []
        measurements.append(try measure("job open"))

        service.setEquipment(EquipmentIdentity(modelToken: "SLP99UH090XV60CK", heading: "SLP99UH090XV60CK",
                                               file: "models.md", source: .spoken))
        _ = service.recordReading(quantity: "manifold pressure, low fire", value: "0.6", unit: "inWC")
        _ = service.recordReading(quantity: "manifold pressure, high fire", value: "3.5", unit: "inWC")
        _ = service.recordReading(quantity: "line pressure", value: "7.0", unit: "inWC")
        _ = service.recordReading(quantity: "flame signal", value: "2.9", unit: "µA")
        measurements.append(try measure("+ unit and 4 readings"))

        measurements.append(try measure("+ a manual question",
                                        turn: "what's the high fire manifold pressure on natural gas"))

        let procedureStarted = (try? service.startProcedure(id: "slp99_no_ignition")) != nil
        if procedureStarted {
            measurements.append(try measure("+ a running procedure",
                                            turn: "what's the high fire manifold pressure on natural gas"))
        }

        for n in 0..<30 {
            service.recordConversationTurn("Checked item \(n) on the burner box and the inducer, all as expected.",
                                           sourceID: "audit-\(n)")
        }
        measurements.append(try measure("+ 30 conversation turns",
                                        turn: "what's the high fire manifold pressure on natural gas"))

        // Counts only: state, tokens, and each model's window and prompt budget.
        print("field-assist-context audit (estimated tokens, 4 characters a token)")
        for measurement in measurements {
            print("  \(measurement.state): \(measurement.tokens) (compact tier \(measurement.compactTokens))")
        }
        for entry in LocalModelCatalog.entries {
            let id = entry.id.rawValue
            let window = LocalModelBudget.contextWindow(for: id)
            let budget = LocalModelBudget.promptBudget(for: id)
            let shares = measurements.map { "\(Int((Double($0.tokens) / Double(budget) * 100).rounded()))%" }
            print("  \(entry.descriptor.displayName): window \(window), prompt budget \(budget), shares \(shares.joined(separator: " / "))")
        }

        // Plan MQ P1: the compact tier a downloaded model gets instead, fitted per model, beside the
        // rest of the lean prompt, the turn's real tool definitions and room for the conversation.
        //
        // `leanOnDevicePrompt` reads the shared job service, which has no job open here, so `base`
        // is the lean prompt *without* the job block (asserted), and the tier is added once.
        let turn = "what's the high fire manifold pressure on natural gas"
        let unfitted = try XCTUnwrap(service.localPromptContext(turn: turn, fieldToolsOffered: true,
                                                                budgetTokens: .max, modelSettingsPath: "Settings > Assistant"))
        print("  compact tier, unfitted (all states above): \(Self.blockTokens(unfitted))")
        let registry = NativeToolRegistry(locationService: LocationService())
        let registered = registry.toolNames
        // As `sendLocal` estimates: a native turn's definitions at Gemma's calibrated rate, at the
        // compact detail the runtime can always fall back to (Plan MQ P3); the single shot's with
        // the Apple path's figure, as before.
        func estimate(_ name: String, native: Bool) -> Int {
            guard let tool = registry.tool(named: name) else { return Int.max / 4 }
            if native {
                return OnDeviceToolSchema.localEstimatedTokens(spec: OnDeviceToolSchema.localToolSpec(
                    name: name, description: tool.description, parameters: tool.parametersSchema, limits: .compact))
            }
            let root = OnDeviceToolSchema.root(toolName: name, parameters: tool.parametersSchema)
            return OnDeviceToolSchema.estimatedTokens(name: name, description: OnDeviceToolSchema.toolDescription(tool.description),
                                                      root: root)
        }
        func spec(_ name: String, _ limits: OnDeviceToolSchema.Limits) -> [String: Any]? {
            registry.tool(named: name).map {
                OnDeviceToolSchema.localToolSpec(name: name, description: $0.description, parameters: $0.parametersSchema,
                                                 limits: limits)
            }
        }
        var gemmaLeft: [Int: Int] = [:]
        for entry in LocalModelCatalog.entries {
            let id = entry.id.rawValue
            let runtime = entry.descriptor.runtime
            // As `sendLocal` decides it, with the flag on: an allowlisted model is under
            // qualification and takes the Field Assist tools natively; the rest keep the single
            // shot's everyday list.
            let native = LocalNativeToolPolicy.usesNativeToolCalls(modelID: id, runtime: runtime, flagOn: true)
            // A native turn on Gemma 4 E2B runs on 4,096 on a 6 GB phone and 6,144 on a bigger one
            // with the room (`LocalModelBudget.toolTurnContextWindow`); both are audited.
            let ordinary = LocalModelBudget.contextWindow(for: id)
            let windows = native ? Array(Set([ordinary, LocalModelBudget.raisedToolTurnWindows[id] ?? ordinary])).sorted()
                : [ordinary]
            let jobBudget = LocalModelBudget.jobContextBudget(for: id)
            let fieldTools = LocalNativeToolPolicy.offersFieldAssistTools(
                modelID: id, runtime: runtime, flagOn: true,
                qualified: LocalModelCatalog.qualifiesForFieldAssistTools(entry.id))
            let tier = try XCTUnwrap(service.localPromptContext(turn: turn, fieldToolsOffered: fieldTools,
                                                                budgetTokens: jobBudget,
                                                                modelSettingsPath: "Settings > Assistant"))
            let tierTokens = Self.blockTokens(tier)
            let lean = await LLMService.leanOnDevicePrompt(
                locationContext: "Auckland, New Zealand", memoryContext: nil, hasImage: false, turn: turn,
                localModelID: id)
            XCTAssertFalse(lean.contains("<field_assist_context>"), "\(id): the base is measured without the job")
            let base = HandoffTranscriptBridge.estimatedTokens(lean)
            let everyday = LLMService.localToolNames(registered: registered, offlineHandoff: false)

            for window in windows {
                let budget = LocalModelBudget.promptBudget(for: id, contextWindow: window)
                let definitionBudget = LocalModelBudget.toolDefinitionBudget(for: id, contextWindow: window)
                let fieldNames = fieldTools
                    ? FieldAssistLocalToolSet.select(registered: registered, fieldAssistActive: true, modelQualified: true,
                                                     utterance: turn, estimatedTokens: { estimate($0, native: native) },
                                                     budgetTokens: definitionBudget)
                    : []
                let toolNames: [String]
                let tools: Int
                var detail = "single shot"
                if native {
                    toolNames = LocalNativeToolPolicy.nativeToolNames(
                        field: fieldNames, everyday: everyday, utterance: turn,
                        estimatedTokens: { estimate($0, native: true) }, budgetTokens: definitionBudget)
                    // The runtime's fit, with the calibrated estimate standing in for the tokenizer.
                    let standard = toolNames.compactMap { spec($0, .standard) }
                    let compact = toolNames.compactMap { spec($0, .compact) }
                    let guide = HandoffTranscriptBridge.estimatedTokens(LLMService.localNativeToolGuide(toolNames: toolNames))
                    let fixed = base + tierTokens + guide
                    // A job turn has a conversation behind it, so full detail must leave the reserve.
                    let choice = LocalToolFit.choose(offered: toolNames.count, budget: budget,
                                                     reserve: LocalToolFit.historyReserve) { kept, level in
                        fixed + (level == .compact ? compact : standard).prefix(kept)
                            .reduce(0) { $0 + OnDeviceToolSchema.localEstimatedTokens(spec: $1) }
                    }
                    tools = (choice.tokens ?? fixed) - base - tierTokens
                    detail = "native \(choice.kept) of \(toolNames.count) \(choice.detail.rawValue)"
                    XCTAssertEqual(choice.kept, toolNames.count, "\(id) at \(window): the selection leaves the fit nothing to drop")
                } else {
                    toolNames = everyday + fieldNames.filter { !everyday.contains($0) }
                    tools = HandoffTranscriptBridge.estimatedTokens(LLMService.localToolInstructions(toolNames: toolNames))
                }
                let left = budget - base - tierTokens - tools
                print("  \(entry.descriptor.displayName) (window \(window)): budget \(budget); compact tier \(tierTokens) of \(jobBudget); "
                      + "lean prompt without the job \(base); tools \(detail) = \(tools) (reserve \(definitionBudget)); "
                      + "left for history and the turn \(left)")
                XCTAssertLessThanOrEqual(tierTokens, jobBudget + Self.wrapperTokens, "\(id): the tier is fitted to its budget")
                XCTAssertGreaterThanOrEqual(left, Self.historyAndTurnFloor,
                                            "\(id): the lean prompt, the tier and the tools leave room for the conversation")
                if native {
                    XCTAssertLessThanOrEqual(toolNames.count, LocalNativeToolPolicy.perTurnLimit)
                    XCTAssertFalse(fieldNames.isEmpty, "\(id): under qualification, the job's tools are offered")
                    XCTAssertTrue(toolNames.contains("field_session"), "\(id): opening a job is always on offer")
                }
                if id == "mlx-community/gemma-4-e2b-it-4bit" { gemmaLeft[window] = left }
            }
            XCTAssertTrue(tier.contains("Never fabricate"), "\(id): the vault's rules stay")
            XCTAssertTrue(tier.contains("MANUALS:"), "\(id): the manuals line stays")
            XCTAssertFalse(tier.contains("=== service_values.md ==="), "\(id): no core file rides along")
            XCTAssertTrue(lean.contains(PromptInjectionPolicy.onDeviceSystemPromptPolicy), "\(id): the safety policy stays")
            XCTAssertTrue(lean.contains("Never address"), "\(id): the speaker line stays")
        }
        let gemma4K = try XCTUnwrap(gemmaLeft[4_096], "Gemma 4 E2B is in the catalog")
        XCTAssertGreaterThanOrEqual(gemma4K, Self.gemmaNativeFloor,
                                    "Gemma 4 E2B with the Field Assist tools declared natively keeps room for three exchanges")
        let gemma6K = try XCTUnwrap(gemmaLeft[6_144], "the raised window is audited")
        XCTAssertGreaterThan(gemma6K, gemma4K, "the raised window leaves more for the conversation")

        XCTAssertTrue(procedureStarted, "the Lennox no-ignition procedure should start")
        XCTAssertGreaterThan(measurements[0].tokens, 0)
        XCTAssertGreaterThan(measurements[2].tokens, measurements[1].tokens, "a manual question adds passages")
        // The estimate is the one the local path budgets with.
        XCTAssertEqual(HandoffTranscriptBridge.estimatedTokens(String(repeating: "x", count: 400)), 100)
    }

    // MARK: - The tool estimate, against the phone (Plan MQ P3)

    /// The first phone run (2026-11-22: iPhone Air, 12 GB, `mlx-community/gemma-4-e2b-it-4bit`,
    /// mlx-swift-lm `4c21c84`) threw `promptTooLong(tokens: 4,317–4,326, limit: 3,456)` on its tool
    /// turns. The device app sent each case's offered tools as they were, so its first tool turns
    /// (`sv-001-log-in` on: a 52–75 character turn, no history, the Field Assist job prompt and the
    /// standard definitions of `reading`, `field_session`, `table_lookup` and `domain_calc`) are the
    /// calibration point. The calibrated estimate the native selection now budgets with
    /// (`OnDeviceToolSchema.localEstimatedTokens`, beside four characters a token for the prompt and
    /// the turn) must never come in under what the phone measured, and not far over it; the Apple
    /// path's `estimatedTokens`, which the selection used before, came in under.
    static let phoneMeasuredTokens = 4_317...4_326
    static let phoneTools = ["reading", "field_session", "table_lookup", "domain_calc"]

    func testTheCalibratedToolEstimateAgainstThePhone() throws {
        let repo = Self.lennoxDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try XCTUnwrap(LocalModelQualificationFixture.decode(Data(contentsOf: repo.appendingPathComponent(
            "Scripts/local-model-qualification/Fixture/\(LocalModelQualificationFixture.fileName)"))))
        let corpus = try String(contentsOf: repo.appendingPathComponent("Scripts/local-tool-eval/corpus")
            .appendingPathComponent(LocalToolEval.corpusFileName), encoding: .utf8)
        let phoneCases = LocalToolEval.loadCorpus(corpus).cases
            .filter { $0.category == .toolChoice && $0.offered == Self.phoneTools && ($0.history ?? []).isEmpty }
            .prefix(8)
        XCTAssertEqual(phoneCases.count, 8)
        let gemma = "mlx-community/gemma-4-e2b-it-4bit"
        let dateLine = "Sunday, 22 November 2026 at 10:15 AM (Pacific/Auckland)"
        for testCase in phoneCases {
            let system = try XCTUnwrap(fixture.systemPrompt(for: testCase, modelID: gemma, dateTimeLine: dateLine))
            let specs = testCase.offered.compactMap { fixture.toolSpec($0) }
            XCTAssertEqual(specs.count, 4)
            let prompt = HandoffTranscriptBridge.estimatedTokens(system) + HandoffTranscriptBridge.estimatedTokens(testCase.turn)
            let calibrated = prompt + specs.reduce(0) { $0 + OnDeviceToolSchema.localEstimatedTokens(spec: $1) }
            let apple = prompt + testCase.offered.reduce(0) { total, name in
                let tool = fixture.tools[name]!
                return total + OnDeviceToolSchema.estimatedTokens(
                    name: name, description: OnDeviceToolSchema.toolDescription(tool.description),
                    root: OnDeviceToolSchema.root(toolName: name, parameters: tool.parameters))
            }
            let jsonBytes = specs.reduce(0) { $0 + ((try? JSONSerialization.data(withJSONObject: $1, options: [.sortedKeys]))?.count ?? 0) }
            // Counts only.
            print("phone calibration: prompt \(prompt) (system \(system.count) chars, turn \(testCase.turn.count)); "
                  + "spec JSON \(jsonBytes) bytes; calibrated \(calibrated); apple-path estimate \(apple); "
                  + "phone \(Self.phoneMeasuredTokens.lowerBound)–\(Self.phoneMeasuredTokens.upperBound)")
            XCTAssertGreaterThanOrEqual(calibrated, Self.phoneMeasuredTokens.upperBound, "never under the phone")
            XCTAssertLessThanOrEqual(Double(calibrated), Double(Self.phoneMeasuredTokens.lowerBound) * 1.15,
                                     "and not far over it")
            XCTAssertLessThan(apple, Self.phoneMeasuredTokens.lowerBound, "the figure the selection used was low")
        }
    }
}
