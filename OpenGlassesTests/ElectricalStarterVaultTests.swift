import XCTest
@testable import OpenGlasses

/// Plan JJ P4 — the electrical starter vault. It is bundled and offered like the refrigeration and
/// IT vaults, its folder imports as a template once an organisation adds its own code PDFs, and its
/// `chains.md` parses clean and holds the vault guide's invented example. Every table, rule and
/// value in it is invented (`RuleChainFixtures`, `TableFixtureLayouts`); nothing is a fact from any
/// book, and no standard's text, table or rule ships in it.
@MainActor
final class ElectricalStarterVaultTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private static let templateId = "electrical_starter"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElectricalStarterVaultTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        // A technician's overlay edit on this simulator must not stand in for the bundled files.
        try? FileManager.default.removeItem(at: VaultImporter.overlayDirectory(for: VaultRegistry.electricalStarterId))
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        VaultImporter.uninstall(id: Self.templateId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - Fixture

    /// The bundled folder, as the app ships it.
    private var bundledFolder: URL {
        get throws {
            try XCTUnwrap(Bundle.main.url(forResource: "Vaults/\(VaultRegistry.electricalStarterId)", withExtension: nil),
                          "the electrical starter is bundled")
        }
    }

    /// A working copy of the template folder.
    private func templateCopy() throws -> URL {
        let copy = tempRoot.appendingPathComponent("electrical-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.copyItem(at: try bundledFolder, to: copy)
        return copy
    }

    private func templateManifest(in folder: URL) throws -> VaultManifest {
        try JSONDecoder().decode(VaultManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    private func chainsFile() throws -> String {
        try String(contentsOf: try bundledFolder.appendingPathComponent("chains.md"), encoding: .utf8)
    }

    // MARK: - Bundled and offered

    func testTheStarterIsBundledAndOfferedLikeTheOtherStarterVaults() throws {
        let manifest = try XCTUnwrap(VaultRegistry.shared.manifest(id: VaultRegistry.electricalStarterId))
        XCTAssertEqual(manifest.name, "Electrical Service")
        XCTAssertEqual(manifest.trades, ["electrical"])
        XCTAssertEqual(FieldTrade.known(manifest.trades ?? []), [.electrical])
        XCTAssertEqual(manifest.gating.iap, "field_assist_electrical")
        XCTAssertTrue(VaultRegistry.shared.isUnlocked(manifest), "unlocked with Field Assist, as the other starters are")
        XCTAssertEqual(VaultRegistry.builtInManifest(id: VaultRegistry.electricalStarterId), manifest)
        XCTAssertFalse(manifest.hasDocuments, "the bundled starter carries no book")

        let store = VaultRegistry.shared.store(for: manifest)
        for file in manifest.files {
            let contents = try XCTUnwrap(store.read(file), "\(file) is bundled")
            XCTAssertFalse(contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, file)
        }
        XCTAssertTrue(store.read("safety.md")?.contains("prove") == true, "prove dead before touching")

        // The template's manifest is the same vault as the bundled one, for an organisation to copy.
        let template = try templateManifest(in: try bundledFolder)
        XCTAssertNotEqual(template.id, manifest.id, "an imported copy never shadows the bundled starter")
        XCTAssertEqual(template.files, manifest.files)
        XCTAssertEqual(template.promptRules, manifest.promptRules)
        XCTAssertEqual(template.trades, manifest.trades)
        XCTAssertEqual(template.gating.iap, "enterprise", "an organisation's own vault")
        XCTAssertEqual(template.documentsDir, "documents")
        XCTAssertTrue(template.documents.isEmpty)
    }

    func testThePromptRulesAreInTheHouseStyle() throws {
        let rules = try XCTUnwrap(VaultRegistry.shared.manifest(id: VaultRegistry.electricalStarterId)).promptRules
            .joined(separator: " ").lowercased()
        for theme in VaultValidator.requiredRuleThemes { XCTAssertTrue(rules.contains(theme), theme) }
        XCTAssertTrue(rules.contains("never guess a rating"), rules)
        XCTAssertTrue(rules.contains("isolate") && rules.contains("prove it dead"), rules)
        XCTAssertTrue(rules.contains("cite the rule"), rules)
    }

    // MARK: - The template validates and its chains parse

    func testTheTemplateValidatesAtImportAndItsChainsParseClean() throws {
        let folder = try templateCopy()
        let result = VaultValidator.validate(directory: folder)
        XCTAssertEqual(result.issues, [], "the template imports as it is")
        // Its example names invented tables no book in it prints: warned of, and kept.
        for chain in ["Example: size a conductor for a load", "Example: check an installed conductor"] {
            XCTAssertTrue(result.warnings.contains(VaultValidator.missingTablesWarning(
                file: "chains.md", chain: chain, missing: ["Table 90", "Table 98", "Table 99"])), "\(result.warnings)")
        }
        XCTAssertTrue(result.warnings.contains(VaultValidator.missingTablesWarning(
            file: "chains.md", chain: "Example: voltage drop on a run", missing: ["Table 97"])), "\(result.warnings)")

        let parsed = ChainParser.parse(try chainsFile())
        XCTAssertEqual(parsed.problems, [], "the chains file parses with zero problems")
        XCTAssertEqual(parsed.chains.map(\.name), ["Example: size a conductor for a load",
                                                   "Example: check an installed conductor",
                                                   "Example: voltage drop on a run"])
        for chain in parsed.chains {
            XCTAssertTrue(chain.answers.hasPrefix("an invented example"), chain.answers)
        }

        // The steps are the guide's worked example, exactly (the guide is held to the fixture).
        let example = ChainParser.parse(RuleChainFixtures.chainsMarkdown).chains
        XCTAssertEqual(parsed.chains.map(\.steps), example.map(\.steps))

        let report = try VaultImporter.installReporting(from: folder)
        XCTAssertEqual(report.manifest.id, Self.templateId)
    }

    func testTheTemplateShipsNoStandardOnlyInventedLabels() throws {
        let folder = try bundledFolder
        let names = try FileManager.default.subpathsOfDirectory(atPath: folder.path)
        XCTAssertFalse(names.contains { $0.lowercased().hasSuffix(".pdf") }, "no book ships: \(names)")
        var labels = Set<String>()
        for name in names where name.hasSuffix(".md") {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            labels.formUnion(TableReference.labels(in: text))
            XCTAssertNil(text.range(of: #"\d+(\.\d+)?\s*mm²"#, options: .regularExpression), "no conductor size: \(name)")
        }
        XCTAssertTrue(labels.isSubset(of: ["Table 90", "Table 97", "Table 98", "Table 99"]), "\(labels)")
        let rules = try chainsFile().components(separatedBy: "\n").filter { $0.hasPrefix("cite ") }
        XCTAssertFalse(rules.isEmpty)
        XCTAssertTrue(rules.allSatisfy { $0.hasPrefix("cite Rule QR-") }, "only the invented rules: \(rules)")
    }

    // MARK: - On a job

    func testListOnTheStarterNamesTheExampleChainsAsNeedingTheirTables() async throws {
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        _ = try service.startSession(vaultId: VaultRegistry.electricalStarterId, assetId: nil)
        let list = try await RuleChainTool(documentStore: nil, sessionService: service).execute(args: ["action": "list"])
        // Plan JW P0: names first, and a chain whose tables no loaded manual prints can't start.
        XCTAssertTrue(list.contains("• Example: size a conductor for a load (can't start: needs Table 90, Table 98, Table 99)"), list)
        XCTAssertTrue(list.contains("• Example: voltage drop on a run (can't start: needs Table 97"), list)
        XCTAssertFalse(list.contains("answers:"), list)
        XCTAssertFalse(list.contains("problem"), list)
    }

    /// The plan's exit test: the guide's example validates against the template once a book that
    /// prints its (invented) tables is in the template's `documents/` slot, and runs to its result.
    func testTheExampleChainRunsOnTheTemplateWithTheFixtureTablesLoaded() async throws {
        let folder = try templateCopy()
        let docs = folder.appendingPathComponent("documents", isDirectory: true)
        _ = try TableFixtures.write(TableFixtures.pdf([TableFixtures.prosePage(), TableFixtureLayouts.simpleGrid(printed: "12"),
                                                       TableFixtureLayouts.twoLevelHeader(),
                                                       TableFixtureLayouts.unitsInHeader(),
                                                       TableFixtureLayouts.groupingBands()]),
                                    named: "invented-book.pdf", in: docs)
        let template = try templateManifest(in: folder)
        let manifest = VaultManifest(id: template.id, name: template.name, version: template.version, files: template.files,
                                     documentsDir: template.documentsDir,
                                     documents: [VaultDocument(file: "invented-book.pdf", title: "Invented Book A")],
                                     gating: template.gating, promptRules: template.promptRules,
                                     sourceAttributionFormat: template.sourceAttributionFormat,
                                     sourceAttributionRequired: template.sourceAttributionRequired, trades: template.trades)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))

        let result = VaultValidator.validate(directory: folder)
        XCTAssertEqual(result.issues, [])
        XCTAssertFalse(result.warnings.contains { $0.contains("chain") }, "every table is printed now: \(result.warnings)")

        let storeDir = tempRoot.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = DocumentStore(directory: storeDir)
        let installed = try VaultImporter.install(from: folder)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        _ = try await VaultImporter.syncDocuments(manifest: installed, into: store)
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        service.documentStore = store
        service.sourceCenter = ShowSourceCenter()
        service.sourceCenter.isAppActive = { true }
        service.sourceCenter.announce = { _ in }
        _ = try service.startSession(vaultId: installed.id, assetId: nil)

        let tool = RuleChainTool(documentStore: store, sessionService: service)
        let list = try await tool.execute(args: ["action": "list"])
        XCTAssertFalse(list.contains("(needs"), list)
        _ = try await tool.execute(args: ["action": "start", "chain": "Example: size a conductor for a load"])
        var reply = ""
        for answer in ["32", "14", "5", "2"] {
            reply = try await RuleChainFixtures.run(tool, ["action": "answer", "value": answer], service)
        }
        XCTAssertTrue(reply.contains("Use QMX90 › two conductors: rated 45 A in rating group 2"), reply)
        XCTAssertTrue(reply.contains("Rule QR-17"), reply)
    }
}
