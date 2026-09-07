import XCTest
@testable import OpenGlasses

/// The example vault in `examples/vaults/lennox-slp99` is imported through the real validator,
/// importer, lookup tool and procedure runner, so the example the vault guide points at is proven
/// against the code rather than by hand.
///
/// The manuals are the manufacturer's copyright and are not committed. When they are present locally
/// (dropped into `documents/` per its README) the reference tier is indexed and searched too; when
/// they are absent the manifest is trimmed to its core and the document tests skip.
@MainActor
final class ExampleVaultLennoxTests: XCTestCase {

    private static let vaultId = "lennox_slp99"
    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    /// `examples/vaults/lennox-slp99`, located from this source file.
    private static var exampleDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenGlassesTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("examples/vaults/lennox-slp99", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExampleVaultLennoxTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        VaultImporter.uninstall(id: Self.vaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - Fixture

    /// A working copy of the example. `manualsPresent` says whether the reference tier is real;
    /// without the manuals the copy's manifest drops `documents` so the core still validates.
    private func stageExample() throws -> (directory: URL, manualsPresent: Bool) {
        let source = Self.exampleDirectory
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("example vault not found at \(source.path)")
        }
        let copy = tempRoot.appendingPathComponent("lennox-slp99", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: copy)

        let data = try Data(contentsOf: copy.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: data)
        let manualsPresent = manifest.documents.allSatisfy {
            FileManager.default.fileExists(atPath: copy.appendingPathComponent(manifest.documentRelativePath($0)).path)
        }
        if !manualsPresent {
            let trimmed = VaultManifest(id: manifest.id, name: manifest.name, version: manifest.version,
                                        files: manifest.files, proceduresDir: manifest.proceduresDir,
                                        documentsDir: nil, documents: [], gating: manifest.gating,
                                        promptRules: manifest.promptRules,
                                        sourceAttributionFormat: manifest.sourceAttributionFormat,
                                        sourceAttributionRequired: manifest.sourceAttributionRequired)
            try JSONEncoder().encode(trimmed).write(to: copy.appendingPathComponent("manifest.json"))
        }
        return (copy, manualsPresent)
    }

    private func startSession(from directory: URL, store: DocumentStore? = nil) throws -> FieldSessionService {
        let manifest = try VaultImporter.install(from: directory)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        service.documentStore = store
        _ = try service.startSession(vaultId: manifest.id, assetId: nil)
        return service
    }

    private func makeStore() -> DocumentStore {
        let dir = tempRoot.appendingPathComponent("store", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DocumentStore(directory: dir)
    }

    // MARK: - Validation

    func testExampleValidatesCleanAndStaysInsideTheCoreBudget() throws {
        let (directory, _) = try stageExample()
        let result = VaultValidator.validate(directory: directory)
        XCTAssertTrue(result.isValid, "issues: \(result.issues)")
        XCTAssertTrue(result.warnings.isEmpty, "warnings: \(result.warnings)")

        let manifest = try XCTUnwrap(result.manifest)
        XCTAssertEqual(manifest.id, Self.vaultId)
        XCTAssertEqual(manifest.files, ["safety.md", "error_codes.md", "models.md", "service_values.md"])
        XCTAssertEqual(manifest.gating.iap, "enterprise")

        let procedures = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("procedures"),
                                                                     includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(procedures.count, 3)
        for url in procedures {
            let procedure = try JSONDecoder().decode(Procedure.self, from: Data(contentsOf: url))
            XCTAssertEqual(procedure.vault, Self.vaultId, url.lastPathComponent)
            XCTAssertTrue(VaultValidator.validateProcedureGraph(procedure).isEmpty, url.lastPathComponent)
        }
    }

    func testEveryDiagnosticCodeInTheManualHasARowInTheCore() throws {
        // The manual's table runs E105–E390; each code must land in error_codes.md, at the start of a
        // table row, so the lookup tool finds it as a whole token.
        let (directory, _) = try stageExample()
        let core = try String(contentsOf: directory.appendingPathComponent("error_codes.md"), encoding: .utf8)
        let expected = ["E105", "E110", "E111", "E112", "E113", "E114", "E115", "E117", "E118", "E120", "E124", "E125",
                        "E126", "E180", "E200", "E201", "E202", "E203", "E204", "E205", "E207", "E223", "E224", "E225",
                        "E226", "E227", "E228", "E240", "E241", "E250", "E252", "E270", "E271", "E272", "E273", "E274",
                        "E275", "E276", "E290", "E291", "E292", "E294", "E295", "E310", "E311", "E312", "E313", "E331",
                        "E345", "E347", "E348", "E370", "E150", "E151", "E152", "E154", "E155", "E160", "E161", "E163",
                        "E164", "E390"]
        for code in expected {
            XCTAssertTrue(core.contains("| \(code) |"), "\(code) has no row in error_codes.md")
        }
    }

    // MARK: - Core lookups

    func testEquipmentLookupAnswersCodesModelsAndValuesFromTheCore() async throws {
        let (directory, _) = try stageExample()
        let service = try startSession(from: directory)
        let tool = EquipmentLookupTool(sessionService: service)

        let code = try await tool.execute(args: ["query": "E223"])
        XCTAssertTrue(code.contains("Low pressure switch failed open"), code)
        XCTAssertTrue(code.contains("(Source: error_codes.md)"), code)
        XCTAssertTrue(code.contains("## Ignition, pressure switches, flame and limit"), "a code lookup reads back its whole section: \(code)")

        let lockout = try await tool.execute(args: ["query": "E271"])
        XCTAssertTrue(lockout.contains("## Soft lockouts"), lockout)

        // Every spelling the manuals use for one unit lands on the same model section.
        for spelling in ["SLP99UH090XV60CK", "090XV60C", "SLP99UHXV-090-60C", "SLP99UH090V60CK"] {
            let model = try await tool.execute(args: ["query": spelling])
            XCTAssertTrue(model.contains("## SLP99UH090XV60CK"), "\(spelling) → \(model)")
            XCTAssertTrue(model.contains("models.md"), model)
        }

        let value = try await tool.execute(args: ["query": "Delta P", "file": "service_values.md"])
        XCTAssertTrue(value.contains("0.95 – 1.25"), value)

        let miss = try await tool.execute(args: ["query": "ZX9"])
        XCTAssertTrue(miss.contains("No vault entry found for 'ZX9'"), miss)
    }

    func testPromptContextCarriesRulesAndEveryCoreFile() throws {
        let (directory, _) = try stageExample()
        let service = try startSession(from: directory)
        let context = try XCTUnwrap(service.promptContext())
        XCTAssertTrue(context.contains("KNOWLEDGE VAULT — Lennox SLP99 Furnace Service"), context.prefix(200).description)
        XCTAssertTrue(context.contains("Never fabricate"))
        for file in ["safety.md", "error_codes.md", "models.md", "service_values.md"] {
            XCTAssertTrue(context.contains("=== \(file) ==="), file)
        }
        XCTAssertLessThan(context.count, VaultValidator.coreBudgetCharacters + 4_096, "core prompt stays near the budget")
    }

    // MARK: - Procedures

    func testUnitSizeCodeProcedureWalksToResolved() throws {
        let (directory, _) = try stageExample()
        let service = try startSession(from: directory)
        XCTAssertEqual(Set(service.availableProcedureDefinitions().map(\.id)),
                       ["slp99_pressure_switch_lockout", "slp99_unit_size_code", "slp99_no_ignition"])

        let entry = try service.startProcedure(id: "slp99_unit_size_code")
        XCTAssertEqual(entry.id, "confirm_symptom")

        guard case .moved(let read) = try service.advanceProcedure(choice: "unprogrammed") else { return XCTFail("expected a move") }
        XCTAssertEqual(read.id, "read_nameplate")
        guard case .moved(let enter) = try service.advanceProcedure(choice: nil) else { return XCTFail("expected a move") }
        XCTAssertEqual(enter.id, "enter_field_test")
        guard case .moved(let select) = try service.advanceProcedure(choice: nil) else { return XCTFail("expected a move") }
        XCTAssertEqual(select.id, "select_code")
        guard case .moved(let verify) = try service.advanceProcedure(choice: "timed_out") else { return XCTFail("expected a move") }
        XCTAssertEqual(verify.id, "enter_field_test", "a timed-out programming attempt loops back")
        _ = try service.advanceProcedure(choice: nil)
        guard case .moved(let verify2) = try service.advanceProcedure(choice: "stored") else { return XCTFail("expected a move") }
        XCTAssertEqual(verify2.id, "verify_letter")
        // Reaching the terminal step completes the procedure with its outcome.
        guard case .completed(let outcome) = try service.advanceProcedure(choice: "match") else { return XCTFail("expected completion") }
        XCTAssertEqual(outcome, "resolved")
        XCTAssertNil(service.activeProcedureTitle)
    }

    func testPressureSwitchProcedureBranchesOnDeltaP() throws {
        let (directory, _) = try stageExample()
        let service = try startSession(from: directory)
        _ = try service.startProcedure(id: "slp99_pressure_switch_lockout")
        _ = try service.advanceProcedure(choice: "low_switch")     // → check_vent
        _ = try service.advanceProcedure(choice: "clear")          // → check_tubing
        _ = try service.advanceProcedure(choice: "tubing_ok")      // → measure_delta_p
        guard case .completed(let outcome) = try service.advanceProcedure(choice: "in_range") else { return XCTFail("expected completion") }
        XCTAssertEqual(outcome, "switch_or_calibration", "an in-range Delta P ends on the switch/calibration terminal")

        // The other branch keeps working the inducer, and "go back" returns to the measurement.
        _ = try service.startProcedure(id: "slp99_pressure_switch_lockout")
        _ = try service.advanceProcedure(choice: "high_switch")
        _ = try service.advanceProcedure(choice: "clear")
        _ = try service.advanceProcedure(choice: "tubing_ok")
        guard case .moved(let outOfRange) = try service.advanceProcedure(choice: "out_of_range") else { return XCTFail("expected a move") }
        XCTAssertEqual(outOfRange.id, "inducer_check")
        XCTAssertEqual(try service.procedureBack().id, "measure_delta_p")
    }

    // MARK: - Manuals (present locally only)

    func testManualsIndexAndAnswerACodeWithThePrintedPage() async throws {
        let (directory, manualsPresent) = try stageExample()
        guard manualsPresent else { throw XCTSkip("manuals not present in documents/; see documents/README.md") }

        let store = makeStore()
        let service = try startSession(from: directory, store: store)
        let manifest = try XCTUnwrap(VaultRegistry.shared.manifest(id: Self.vaultId))
        let ledger = try await VaultImporter.syncDocuments(manifest: manifest, into: store)

        XCTAssertEqual(ledger.entries.map(\.title).sorted(), ["SLP99UHVK Installation Instructions", "SLP99UHVK Service Manual"])
        for entry in ledger.entries {
            XCTAssertGreaterThan(entry.chunkCount, 200, entry.title)
            XCTAssertEqual(entry.ocrPages, 0, "both PDFs carry a text layer: \(entry.title)")
        }
        XCTAssertTrue(service.activeVaultHasManuals)

        // A bare code reaches the manual through the exact-token search and cites the printed page
        // the diagnostic table sits on: p.20 of the Service Manual, p.47 of the Installation Instructions.
        let retriever = service.manualRetriever(store: VaultRegistry.shared.store(for: manifest))
        let outcome = retriever.retrieve(.init(turn: "E223", limit: 4))
        XCTAssertTrue(outcome.isSufficient)
        let hits = outcome.passages.filter { $0.matchedTokens == ["E223"] }
        XCTAssertFalse(hits.isEmpty, "\(outcome.passages.map(\.citation))")
        let pagesByManual = Dictionary(grouping: hits, by: \.documentName).mapValues { Set($0.compactMap(\.page)) }
        XCTAssertEqual(pagesByManual["SLP99UHVK Service Manual"], [20], "\(pagesByManual)")
        XCTAssertEqual(pagesByManual["SLP99UHVK Installation Instructions"], [47], "\(pagesByManual)")
        for passage in outcome.passages {
            print("[LENNOX] E223 → \(passage.citation) | sim \(passage.similarity) score \(passage.score)")
        }

        // A spoken sentence carrying the code. Every passage in these manuals scores ~0.9 on the
        // word-average embedder, so this only holds because an exact-token hit now sorts ahead of
        // anything without one, whatever the cosine.
        let context = try XCTUnwrap(service.promptContext(turn: "the display shows E223 on a heat call"))
        XCTAssertTrue(context.contains("MANUAL PASSAGES (retrieved"), context.suffix(600).description)
        print("[LENNOX] embedder=\(Embedder().modelId) sentenceModel=\(Embedder().usesSentenceModel)")
        XCTAssertTrue(context.contains("Source: SLP99UHVK Service Manual, page 20")
                        || context.contains("Source: SLP99UHVK Installation Instructions, page 47"),
                      "a sentence carrying the code must still cite the code's own page: \(context.suffix(1200))")

        // Every citation the pair produces is locatable: a title and a printed page, and a section
        // only when the section is a heading a technician would recognise.
        for query in ["E223", "E203", "E270", "090XV60C"] {
            for passage in retriever.retrieve(.init(turn: query, limit: 4)).passages {
                let page = try XCTUnwrap(passage.page, "\(query) → \(passage.citation) has no page")
                var expected = "\(passage.documentName), page \(page)"
                if let section = passage.section, !section.isEmpty {
                    expected += ", §\(section)"
                    assertReadableHeading(section, query: query)
                }
                XCTAssertEqual(passage.citation, expected)
            }
        }

        // Exploratory: how do natural-language questions and an out-of-scope question fare against the
        // default evidence gate? Printed, not asserted — calibrating the gate is its own piece of work.
        for turn in ["what is the manifold pressure on high fire",
                     "how long is the pre-purge before ignition",
                     "what is the torque for the blower wheel set screw",
                     "how do I replace the heat exchanger on a Carrier 58MVB"] {
            let result = retriever.retrieve(.init(turn: turn, limit: 3))
            switch result {
            case .sufficient(let passages):
                print("[LENNOX] '\(turn)' → \(passages.count) passages: \(passages.map { "\($0.citation) sim=\(String(format: "%.2f", $0.similarity)) tokens=\($0.matchedTokens)" })")
            case .insufficient:
                print("[LENNOX] '\(turn)' → insufficient")
            }
        }
    }

    /// A `§section` is spoken aloud as part of a citation, so it has to name a place. Captions,
    /// safety banners and numbered list steps are none of those.
    private func assertReadableHeading(_ section: String, query: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let context = "\(query) → §\(section)"
        XCTAssertGreaterThanOrEqual(section.split(whereSeparator: { $0.isWhitespace }).count, 2,
                                    "one-word heading: \(context)", file: file, line: line)
        for label in ["FIGURE", "TABLE", "WARNING", "CAUTION", "NOTE"] {
            XCTAssertFalse(section.uppercased().hasPrefix(label), "label, not a section: \(context)",
                           file: file, line: line)
        }
        for pattern in [#"^\d+(\.\d+)*\s+[-–—]\s"#, #"^\d+(\.\d+)*\s*\)"#, #"^\d+(\.\d+)*\.?\s+\p{Ll}"#] {
            XCTAssertNil(section.range(of: pattern, options: .regularExpression),
                         "list step, not a section: \(context)", file: file, line: line)
        }
    }
}
