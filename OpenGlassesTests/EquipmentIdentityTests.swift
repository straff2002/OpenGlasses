import XCTest
@testable import OpenGlasses

/// Plan EL P1 — the session knows which machine is in front of the technician.
///
/// The index is derived from the real example vault's core (`examples/vaults/lennox-slp99`), which
/// is where the guide's "every spelling in the model's heading" convention is actually written
/// down; the ranking test uses the real manuals when a developer has them locally and skips
/// otherwise. Nothing here depends on embedding similarity — the simulator's word-average backend
/// cannot separate anything (Plan EJ §2), so every assertion is about tokens, penalties and text.
@MainActor
final class EquipmentIdentityTests: XCTestCase {

    private static let vaultId = "lennox_slp99"
    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenGlassesTests
            .deletingLastPathComponent()   // repo root
    }
    private static var exampleDirectory: URL {
        repoRoot.appendingPathComponent("examples/vaults/lennox-slp99", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EquipmentIdentityTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Fixtures

    /// The example vault's core files, read straight off disk in manifest order.
    private func lennoxIndex() throws -> VaultModelIndex {
        let dir = Self.exampleDirectory
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("example vault not found at \(dir.path)")
        }
        let manifest = try JSONDecoder().decode(
            VaultManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        let files = try manifest.files.map {
            (filename: $0, contents: try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))
        }
        return VaultModelIndex(vaultName: manifest.name, files: files)
    }

    /// A working copy of the example vault with its manuals dropped (the core is all these tests
    /// need), installed and started in a fresh service against a temporary sessions root.
    private func startLennoxSession(assetId: String? = nil) throws -> FieldSessionService {
        let source = Self.exampleDirectory
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("example vault not found at \(source.path)")
        }
        let copy = tempRoot.appendingPathComponent("lennox", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: copy)
        let data = try Data(contentsOf: copy.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: data)
        let coreOnly = VaultManifest(id: manifest.id, name: manifest.name, version: manifest.version,
                                     files: manifest.files, proceduresDir: manifest.proceduresDir,
                                     documentsDir: nil, documents: [], gating: manifest.gating,
                                     promptRules: manifest.promptRules,
                                     sourceAttributionFormat: manifest.sourceAttributionFormat,
                                     sourceAttributionRequired: manifest.sourceAttributionRequired)
        try JSONEncoder().encode(coreOnly).write(to: copy.appendingPathComponent("manifest.json"))

        let installed = try VaultImporter.install(from: copy)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        _ = try service.startSession(vaultId: installed.id, assetId: assetId)
        return service
    }

    // MARK: - The index

    func testTheIndexIsTheVaultsOwnModelHeadings() throws {
        let index = try lennoxIndex()
        XCTAssertEqual(index.models.map(\.name),
                       ["SLP99UH070XV36BK", "SLP99UH090XV36CK", "SLP99UH090XV48CK",
                        "SLP99UH090XV60CK", "SLP99UH110XV60CK", "SLP99UH135XV60DK"])
        XCTAssertTrue(index.models.allSatisfy { $0.file == "models.md" })

        // Every spelling the manuals use for one unit — including the hyphenated table-row form —
        // lands on that unit's heading, and nothing else does.
        for spelling in ["SLP99UH090XV60CK", "090XV60C", "-090-060C", "090-060C",
                         "SLP99UHXV-090-60C", "SLP99UH090V60CK"] {
            let resolved = index.resolve(token: spelling.trimmingCharacters(in: CharacterSet(charactersIn: "-")))
            XCTAssertEqual(resolved.map(\.name), ["SLP99UH090XV60CK"], spelling)
        }

        // A fault code, a page reference and a table label are not machines.
        for notAModel in ["E223", "E203", "p.64", "TABLE 39", "39", "R-454B", "R-32", "A2L", "070"] {
            XCTAssertTrue(VaultModelIndex.modelLikeTokens(in: notAModel).isEmpty,
                          "\(notAModel) reads as a model number")
            XCTAssertFalse(index.knownModelTokens.contains(notAModel.uppercased()), notAModel)
        }
        for model in ["SLP99UH090XV60CK", "090XV60C", "58MVB", "XR15", "GMVC96"] {
            XCTAssertEqual(VaultModelIndex.modelLikeTokens(in: "the \(model) unit"), [model], model)
        }

        // A nameplate the camera split across a space still names one machine: the halves agree.
        XCTAssertEqual(index.match(text: "SLP99UH 090XV60CK").map(\.name), ["SLP99UH090XV60CK"])
        // …and a half that fits every model asks rather than guessing.
        XCTAssertEqual(index.match(text: "SLP99UHXV").count, 6)
        // A correction spoken as a size group reaches its model.
        XCTAssertEqual(index.match(fragment: "070").map(\.name), ["SLP99UH070XV36BK"])
    }

    func testABundledVaultNamesNoModelsSoIdentityIsANoOp() throws {
        let dir = Self.repoRoot.appendingPathComponent("OpenGlasses/Sources/Resources/Vaults/refrigeration",
                                                       isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".md") }
        XCTAssertFalse(names.isEmpty)
        let files = try names.sorted().map {
            (filename: $0, contents: try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))
        }
        let index = VaultModelIndex(vaultName: "Refrigeration Service", files: files)
        XCTAssertTrue(index.isEmpty, "bundled vault headings: \(index.models.map(\.heading))")
        XCTAssertEqual(EquipmentScopeCheck.check(text: "how do I replace the heat exchanger on a Carrier 58MVB",
                                                 index: index, active: nil), .inScope)
    }

    // MARK: - The scope check

    func testAMachineTheseManualsAreNotForIsRefusedByName() throws {
        let index = try lennoxIndex()
        let expected = "The loaded manuals cover Lennox SLP99 Furnace Service models "
            + "SLP99UH070XV36BK, SLP99UH090XV36CK, SLP99UH090XV48CK and 3 more; "
            + "58MVB is not one of them. Confirm the nameplate or load its manual."
        XCTAssertEqual(EquipmentScopeCheck.check(text: "how do I replace the heat exchanger on a Carrier 58MVB",
                                                 index: index, active: nil),
                       .unknownEquipment(token: "58MVB", sentence: expected))

        let trane = EquipmentScopeCheck.check(text: "what is the defrost board wiring on a Trane XR15",
                                              index: index, active: nil)
        XCTAssertEqual(trane.refusalSentence?.contains("XR15 is not one of them"), true, "\(trane)")

        // In scope: this vault's own model, a fault code it publishes, its series name, and plain
        // prose that names no machine at all.
        for turn in ["what is the manifold pressure on high fire", "the display shows E223 on a heat call",
                     "what is the AFUE of the SLP99UHVK", "does this unit use R-454B",
                     "how do I read the 090XV60C manifold pressure"] {
            XCTAssertEqual(EquipmentScopeCheck.check(text: turn, index: index, active: nil), .inScope, turn)
        }

        // A nameplate read carries a serial number, which is model-like and belongs to no model.
        // A read that names a model the vault knows puts the turn in scope regardless.
        XCTAssertEqual(EquipmentScopeCheck.check(text: nil, nameplateText: "SLP99UH090XV60CK SER 5820A12345",
                                                 index: index, active: nil), .inScope)
    }

    func testAKnownModelThatIsNotTheActiveOneIsAnsweredAndFlagged() throws {
        let index = try lennoxIndex()
        let active = try XCTUnwrap(index.match(fragment: "070").first)
        let identity = EquipmentIdentity(model: active, token: active.name, source: .nameplate)

        let outcome = EquipmentScopeCheck.check(text: "is the 090XV60C manifold pressure the same as mine",
                                                index: index, active: identity)
        XCTAssertEqual(outcome, .otherKnownModel(token: "090XV60C", model: "SLP99UH090XV60CK"))
        XCTAssertNil(outcome.refusalSentence, "comparing two of the vault's own units is never refused")

        // The same question about the active machine is not flagged.
        XCTAssertEqual(EquipmentScopeCheck.check(text: "what is the 070XV36B temperature rise",
                                                 index: index, active: identity), .inScope)
    }

    // MARK: - The session

    func testTheSessionRecordsAndForgetsTheMachineThroughTheTool() async throws {
        let service = try startLennoxSession()
        let tool = EquipmentLookupTool(sessionService: service)
        XCTAssertNil(service.activeEquipment)

        // A spoken model that names exactly one unit is recorded, and the answer says so.
        let spoken = try await tool.execute(args: ["query": "090XV60C"])
        XCTAssertTrue(spoken.hasPrefix("Active equipment: SLP99UH090XV60CK (from the technician)."), spoken)
        XCTAssertTrue(spoken.contains("## SLP99UH090XV60CK"), spoken)
        XCTAssertEqual(service.activeEquipment?.modelToken, "SLP99UH090XV60CK")
        XCTAssertEqual(service.activeEquipment?.source, .spoken)
        XCTAssertEqual(service.activeSession?.equipment, service.activeEquipment,
                       "the machine is part of the session record, not a view-model")

        // A spelling every model shares is not an identification.
        let ambiguous = try await tool.execute(args: ["query": "SLP99UHXV"])
        XCTAssertTrue(ambiguous.hasPrefix("That reads as more than one model:"), ambiguous)
        XCTAssertTrue(ambiguous.contains("SLP99UH070XV36BK"), ambiguous)
        XCTAssertEqual(service.activeEquipment?.modelToken, "SLP99UH090XV60CK", "an ambiguous read changes nothing")

        // "No, it's the 070."
        let corrected = try await tool.execute(args: ["set_equipment": "070"])
        XCTAssertTrue(corrected.hasPrefix("Active equipment: SLP99UH070XV36BK (from the technician)."), corrected)
        XCTAssertEqual(service.activeEquipment?.modelToken, "SLP99UH070XV36BK")

        // A correction naming a machine the vault has never heard of is refused, not obeyed.
        let wrong = try await tool.execute(args: ["set_equipment": "58MVB"])
        XCTAssertTrue(wrong.contains("58MVB is not one of them"), wrong)
        XCTAssertEqual(service.activeEquipment?.modelToken, "SLP99UH070XV36BK")

        let cleared = try await tool.execute(args: ["clear_equipment": true])
        XCTAssertEqual(cleared, "Cleared the active equipment (was SLP99UH070XV36BK).")
        XCTAssertNil(service.activeEquipment)
        XCTAssertNil(service.activeSession?.equipment)

        // The audit log carries both, with the heading in the payload.
        let session = try XCTUnwrap(service.activeSession)
        let log = try String(contentsOf: tempRoot.appendingPathComponent("sessions/\(session.id)/log.jsonl"),
                            encoding: .utf8)
        XCTAssertTrue(log.contains("equipment_recognised"), log)
        XCTAssertTrue(log.contains("equipment_cleared"), log)
        XCTAssertTrue(log.contains("SLP99UH090XV60CK (090XV60C"), "the heading rides in the payload: \(log)")
    }

    func testAWorkOrderThatNamesTheMachineSeedsTheIdentity() throws {
        let service = try startLennoxSession(assetId: "SLP99UH110XV60CK")
        XCTAssertEqual(service.activeEquipment?.modelToken, "SLP99UH110XV60CK")
        XCTAssertEqual(service.activeEquipment?.source, .asset)
        XCTAssertEqual(service.activeSession?.equipment?.modelToken, "SLP99UH110XV60CK")
    }

    func testAnAssetIdThatNamesNoModelLeavesTheSessionWithoutOne() throws {
        let service = try startLennoxSession(assetId: "Unit 47B")
        XCTAssertNil(service.activeEquipment)
    }

    func testThePromptCarriesTheActiveEquipmentBlock() async throws {
        let service = try startLennoxSession()
        _ = try await EquipmentLookupTool(sessionService: service).execute(args: ["query": "090XV60C"])
        let context = try XCTUnwrap(service.promptContext())
        XCTAssertTrue(context.contains("ACTIVE EQUIPMENT: SLP99UH090XV60CK — \"SLP99UH090XV60CK (090XV60C"),
                      context.suffix(400).description)
        XCTAssertTrue(context.contains("(from the technician,"), context.suffix(400).description)
        XCTAssertTrue(context.contains("Answer for this model; say when a passage is for another model."),
                      context.suffix(400).description)

        service.clearEquipment()
        XCTAssertFalse(try XCTUnwrap(service.promptContext()).contains("ACTIVE EQUIPMENT"))
    }

    // MARK: - Codable

    func testTheSessionRoundTripsItsEquipmentAndOlderSessionsStillDecode() throws {
        let identity = EquipmentIdentity(modelToken: "SLP99UH090XV60CK",
                                         heading: "SLP99UH090XV60CK (090XV60C; C cabinet)",
                                         file: "models.md", source: .nameplate,
                                         recognisedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                         nameplateText: "SLP99UH090XV60CK SER 5820A12345")
        var session = FieldSession(id: "s1", vaultId: "lennox_slp99", assetId: nil, mode: .aiOnly,
                                   startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil,
                                   pausedAt: nil, resumedAt: nil, outcome: .inProgress,
                                   startLocation: nil, endLocation: nil, escalations: [], billableSeconds: 0)
        session.equipment = identity

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FieldSession.self, from: try encoder.encode(session))
        XCTAssertEqual(decoded.equipment, identity)
        XCTAssertEqual(decoded, session)

        // A session written before any of this existed decodes with no equipment rather than failing.
        let old = """
        {"id":"s0","vaultId":"lennox_slp99","mode":"ai_only","startedAt":"2026-01-02T03:04:05Z",
         "outcome":"in_progress","escalations":[],"billableSeconds":0}
        """
        let legacy = try decoder.decode(FieldSession.self, from: Data(old.utf8))
        XCTAssertNil(legacy.equipment)
        XCTAssertEqual(legacy.id, "s0")
    }

    // MARK: - Ranking

    func testTheMismatchPenaltyMovesRowsOnlyInsideTheirOwnGroup() {
        func raw(_ index: Int, _ text: String, _ similarity: Float) -> DocumentStore.Passage {
            DocumentStore.Passage(documentId: "d", documentName: "Manual", chunkIndex: index,
                                  text: text, similarity: similarity, page: index, section: nil)
        }
        let rows = [raw(1, "Manifold pressure for all models is 3.5 in. w.g.", 0.90),
                    raw(2, "090-060C Only: low fire manifold pressure 0.30 to 0.85.", 0.91),
                    raw(3, "The 090-060C ZZ9 kit is ordered separately.", 0.10)]
        func rank(active: Set<String>) -> [Int] {
            VaultRetriever(query: { _, _ in rows },
                           policy: RetrievalEvidencePolicy(similarityFloor: 0),
                           modelScope: .init(activeTokens: active,
                                             otherTokens: ["090-060C", "070XV36B"]))
                .retrieve(.init(turn: "manifold pressure ZZ9", limit: 5))
                .passages.map(\.chunkIndex)
        }
        // The exact-token hit leads whatever the machine is (Plan EJ's invariant), and among the
        // rest the other model's row falls behind when the technician is at a 070…
        XCTAssertEqual(rank(active: ["070XV36B"]), [3, 1, 2])
        // …and leads it when they are at the 090.
        XCTAssertEqual(rank(active: ["090-060C"]), [3, 2, 1])
        // No identity, no reordering.
        XCTAssertEqual(rank(active: []), [3, 2, 1])
    }

    func testAnotherModelsTableRowRanksBelowTheSharedOneOnTheRealManuals() async throws {
        let dir = Self.repoRoot.appendingPathComponent("examples/vaults/lennox-slp99/documents", isDirectory: true)
        let files = [("SLP99UHVK Service Manual", "SLP99UHVK-service-manual.md"),
                     ("SLP99UHVK Installation Instructions", "SLP99UHVK-installation-instructions.md")]
        for (_, file) in files where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) {
            throw XCTSkip("Lennox manuals not present in \(dir.path); see its README")
        }
        let storeDirectory = tempRoot.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let store = DocumentStore(directory: storeDirectory)
        for (title, file) in files {
            _ = await store.ingest(name: title,
                                   text: try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8),
                                   sourceType: "text")
        }
        let index = try lennoxIndex()
        let ninety = try XCTUnwrap(index.models.first { $0.name == "SLP99UH090XV60CK" })
        let seventy = try XCTUnwrap(index.models.first { $0.name == "SLP99UH070XV36BK" })

        // The candidates are the manual's own passages that talk about the manifold, taken by exact
        // token rather than by similarity: the word-average backend cannot tell any two passages of
        // this manual apart (Plan EJ §2), and what is under test is the ordering, not the embedder.
        func ranked(active: VaultModelIndex.Model?) -> [VaultRetriever.Passage] {
            VaultRetriever(query: { _, limit in store.passages(containingToken: "manifold", limit: limit) },
                           policy: RetrievalEvidencePolicy(similarityFloor: 0),
                           modelScope: active.map { .init(activeTokens: Set($0.tokens),
                                                          otherTokens: index.knownModelTokens) })
                .retrieve(.init(turn: "manifold pressure", limit: 40)).passages
        }
        func row(in passages: [VaultRetriever.Passage]) throws -> (rank: Int, passage: VaultRetriever.Passage) {
            let i = try XCTUnwrap(passages.firstIndex { $0.text.contains("-090-060C Only") },
                                  "TABLE 39's 090-only row was not retrieved at all: "
                                  + "\(passages.prefix(5).map(\.citation))")
            return (i, passages[i])
        }

        // Table 39 prints one set of manifold pressures for every model and a second set for the
        // 090XV60C alone. Which of those a technician wants is decided by the machine in the room,
        // and nothing in the words of the question can say.
        let onA070 = try row(in: ranked(active: seventy))
        let onA090 = try row(in: ranked(active: ninety))
        let neutral = try row(in: ranked(active: nil))
        print("[EL] -090-060C row: no identity rank \(neutral.rank), "
              + "active 070 rank \(onA070.rank) penalty \(onA070.passage.modelPenalty), "
              + "active 090XV60C rank \(onA090.rank) penalty \(onA090.passage.modelPenalty) "
              + "→ \(neutral.passage.citation)")
        XCTAssertEqual(onA070.passage.modelPenalty, 0.5, "the 090-only row is another model's row for a 070")
        XCTAssertEqual(onA090.passage.modelPenalty, 0, "the active model's own row is never penalised")
        XCTAssertGreaterThan(onA070.rank, onA090.rank,
                             "the 090-only row must fall behind for a technician at a 070")
        XCTAssertEqual(onA090.rank, neutral.rank, "identity on the same machine changes nothing for its own row")
    }
}
