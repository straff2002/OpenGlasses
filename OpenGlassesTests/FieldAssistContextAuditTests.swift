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
    /// What must be left for three exchanges of history and the turn itself.
    private static let historyAndTurnFloor = 400

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
        // rest of the lean prompt, the tools' quarter and room for the conversation and the turn.
        let turn = "what's the high fire manifold pressure on natural gas"
        let unfitted = try XCTUnwrap(service.localPromptContext(turn: turn, fieldToolsOffered: true,
                                                                budgetTokens: .max, modelSettingsPath: "Settings > Assistant"))
        print("  compact tier, unfitted (all states above): \(Self.blockTokens(unfitted))")
        for entry in LocalModelCatalog.entries {
            let id = entry.id.rawValue
            let budget = LocalModelBudget.promptBudget(for: id)
            let jobBudget = LocalModelBudget.jobContextBudget(for: id)
            let tier = try XCTUnwrap(service.localPromptContext(turn: turn, fieldToolsOffered: true,
                                                                budgetTokens: jobBudget,
                                                                modelSettingsPath: "Settings > Assistant"))
            let tierTokens = Self.blockTokens(tier)
            let base = HandoffTranscriptBridge.estimatedTokens(await LLMService.leanOnDevicePrompt(
                locationContext: "Auckland, New Zealand", memoryContext: nil, hasImage: false, turn: turn,
                localModelID: id))
            let tools = LocalModelBudget.toolDefinitionBudget(for: id)
            let left = budget - base - tierTokens - tools
            print("  \(entry.descriptor.displayName): compact tier \(tierTokens) of \(jobBudget); lean prompt \(base); tools \(tools); left for history and the turn \(left)")
            XCTAssertLessThanOrEqual(tierTokens, jobBudget + Self.wrapperTokens, "\(id): the tier is fitted to its budget")
            XCTAssertTrue(tier.contains("Never fabricate"), "\(id): the vault's rules stay")
            XCTAssertTrue(tier.contains("MANUALS:"), "\(id): the manuals line stays")
            XCTAssertFalse(tier.contains("=== service_values.md ==="), "\(id): no core file rides along")
            XCTAssertGreaterThanOrEqual(left, Self.historyAndTurnFloor,
                                        "\(id): the lean prompt, the tier and the tools leave room for the conversation")
        }

        XCTAssertTrue(procedureStarted, "the Lennox no-ignition procedure should start")
        XCTAssertGreaterThan(measurements[0].tokens, 0)
        XCTAssertGreaterThan(measurements[2].tokens, measurements[1].tokens, "a manual question adds passages")
        // The estimate is the one the local path budgets with.
        XCTAssertEqual(HandoffTranscriptBridge.estimatedTokens(String(repeating: "x", count: 400)), 100)
    }
}
