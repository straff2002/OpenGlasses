import XCTest
@testable import OpenGlasses

/// Plan MO P2b (§5a): `FieldSessionService.hintPassages`, live hints' read-only way into Field
/// Assist's manual search. The same search a turn makes, gated the same way, with none of a turn's
/// side effects. The vault, its manual and its procedure are invented for these tests.
@MainActor
final class FieldAssistHintSearchTests: XCTestCase {

    private static let vaultId = "hint_search_test"
    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FieldAssistHintSearchTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Fixtures (invented)

    private static let manualText = """
    QMX90 PUMP GUIDE

    1 STATUS LIGHTS
    Status code QXRT means the impeller is blocked on the QMX90. Switch the pump off, clear the intake basket and run it for 2 minutes.
    Status code QXRB means the float switch is stuck. Lift the float and let it drop freely.

    2 PRIMING
    Fill the priming chamber with 3 litres of water before the first run. Close the priming cap hand-tight.
    """

    /// A core file naming the vault's one model, so a question about another machine is out of scope.
    private static let coreText = """
    # Models

    ## QMX90 (QMX-90)

    The QMX90 garden pump.
    """

    private func makeStore() -> DocumentStore {
        let dir = tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DocumentStore(directory: dir)
    }

    private func writeVault(vaultOnly: Bool? = nil) -> URL {
        let dir = tempRoot.appendingPathComponent("vault-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let documents = [VaultDocument(file: "pump.txt", title: "QMX90 Pump Guide", kind: "service_manual")]
        let manifest = VaultManifest(id: Self.vaultId, name: "Garden pumps", version: "1.0.0",
                                     files: ["models.md"], proceduresDir: nil, documentsDir: "documents",
                                     documents: documents, gating: .init(iap: "enterprise"),
                                     promptRules: ["Never fabricate.", "Cite the source."], vaultOnly: vaultOnly)
        try? JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try? Self.coreText.write(to: dir.appendingPathComponent("models.md"), atomically: true, encoding: .utf8)
        let docs = dir.appendingPathComponent("documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try? Self.manualText.write(to: docs.appendingPathComponent("pump.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    private func installVault(store: DocumentStore, vaultOnly: Bool? = nil) async throws {
        let manifest = try VaultImporter.install(from: writeVault(vaultOnly: vaultOnly))
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
    }

    /// A job on the installed vault, in a fresh service of its own.
    private func openJob(store: DocumentStore, root: String = "sessions") throws -> FieldSessionService {
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent(root, isDirectory: true))
        service.documentStore = store
        _ = try service.startSession(vaultId: Self.vaultId, assetId: nil)
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        return service
    }

    private func startSession(store: DocumentStore, vaultOnly: Bool? = nil) async throws -> FieldSessionService {
        try await installVault(store: store, vaultOnly: vaultOnly)
        return try openJob(store: store)
    }

    private static let procedure: Procedure = {
        let json = #"""
        {"id":"qmx_prime","title":"Prime the pump","version":"1","safety_notes":[],
         "steps":[{"id":"fill","title":"Fill the priming chamber","instruction":"Fill the chamber with water."},
                  {"id":"cap","title":"Close the priming cap","instruction":"Close the cap hand-tight."}]}
        """#
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Procedure.self, from: Data(json.utf8))
    }()

    private let question = "What does status code QXRT mean?"

    // MARK: - The search

    func testAnOpenJobsManualsAnswerWithFieldAssistsCitation() async throws {
        let service = try await startSession(store: makeStore())
        let job = try XCTUnwrap(service.hintJobManuals)
        XCTAssertEqual(job.vaultId, Self.vaultId)
        XCTAssertEqual(job.vaultName, "Garden pumps")
        XCTAssertFalse(job.vaultOnly)

        let found = service.hintPassages(for: question, limit: 4)
        let passages = found.passages
        XCTAssertFalse(passages.isEmpty, "\(found)")
        XCTAssertTrue(passages.contains { $0.text.contains("QXRT") })
        XCTAssertTrue(passages.allSatisfy { $0.citation?.hasPrefix("QMX90 Pump Guide") == true })
        XCTAssertLessThanOrEqual(passages.count, 4)
        XCTAssertEqual(service.hintManualTitles(), ["QMX90 Pump Guide"])
    }

    func testAGateThatRefusesIsNoHint() async throws {
        let service = try await startSession(store: makeStore())
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        XCTAssertEqual(service.hintPassages(for: "how was the weather on the coast", limit: 4), .nothing(.insufficient))
    }

    func testAnotherMachineIsOutOfScope() async throws {
        let service = try await startSession(store: makeStore())
        XCTAssertEqual(service.hintPassages(for: "How do I prime the ZRB7720 pump?", limit: 4),
                       .nothing(.otherEquipment))
    }

    func testNoJobNoPausedJobAndAnEndedJobSearchNothing() async throws {
        let unopened = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("none", isDirectory: true))
        unopened.documentStore = makeStore()
        XCTAssertNil(unopened.hintJobManuals)
        XCTAssertEqual(unopened.hintPassages(for: question, limit: 4), .nothing(.noJobManuals))

        let service = try await startSession(store: makeStore())
        _ = try service.pauseSession()
        XCTAssertNil(service.hintJobManuals, "a paused job claims no conversation")
        XCTAssertEqual(service.hintPassages(for: question, limit: 4), .nothing(.noJobManuals))
        _ = try service.resumeSession()
        XCTAssertNotNil(service.hintJobManuals)
        _ = try service.endSession()
        XCTAssertNil(service.hintJobManuals)
        XCTAssertEqual(service.hintPassages(for: question, limit: 4), .nothing(.noJobManuals))
    }

    func testAVaultOnlyVaultSaysSo() async throws {
        let service = try await startSession(store: makeStore(), vaultOnly: true)
        XCTAssertEqual(service.hintJobManuals?.vaultOnly, true)
    }

    func testAnEmptyQuestionSearchesNothing() async throws {
        let service = try await startSession(store: makeStore())
        XCTAssertEqual(service.hintPassages(for: "   ", limit: 4), .nothing(.emptyQuestion))
    }

    // MARK: - No side effects

    func testAHintSearchLeavesNothingATurnReads() async throws {
        let store = makeStore()
        try await installVault(store: store)
        let hinted = try openJob(store: store, root: "hinted")
        let fresh = try openJob(store: store, root: "fresh")

        for _ in 0..<3 {
            _ = hinted.hintPassages(for: question, limit: 4)
            _ = hinted.hintPassages(for: "Show me the priming page for this pump", limit: 4)
        }
        XCTAssertNil(hinted.stagedFigure, "no page staged")
        XCTAssertNil(hinted.answerEvidence, "no evidence recorded")

        // The next turn on the job reads exactly what it would have with no hint searched.
        let turn = "the pump shows status code QXRT"
        let afterHints = try XCTUnwrap(hinted.promptContext(turn: turn))
        let untouched = try XCTUnwrap(fresh.promptContext(turn: turn))
        let block = { (context: String) -> String in
            context.range(of: "MANUAL PASSAGES").map { String(context[$0.lowerBound...]) } ?? ""
        }
        XCTAssertFalse(block(untouched).isEmpty, untouched)
        XCTAssertEqual(block(afterHints), block(untouched))
        XCTAssertEqual(hinted.stagedFigure?.citation, fresh.stagedFigure?.citation)
    }

    /// The source of everything a hint search runs, from the shared search to the titles, names
    /// none of a turn's side effects.
    func testTheHintSearchCodeNamesNoSideEffect() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/FieldAssist/FieldSessionService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func searchManuals(turn: String"))
        let end = try XCTUnwrap(source.range(of: "static let oneCheckRule", range: start.upperBound..<source.endIndex))
        let code = String(source[start.lowerBound..<end.lowerBound])
            .replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
        for name in ["stageFigure", "TurnRecorder", "noteJobTurn", "noteRetrieval", "sourceCenter", "answerEvidence",
                     "jobTurns", "turnOpenNote", "logger", "mutateSession", "pendingDisclosure", "recordModelSaid",
                     "lastTurnKind", "advanceProcedure", "answerProcedure", "procedureBack", "procedureRepeat",
                     "logCitationOpened", "noteLastShown"] {
            XCTAssertFalse(code.contains(name), "the hint search names \(name)")
        }
    }

    // MARK: - During a procedure

    func testTheRunningStepGoesBesideTheQuestion() async throws {
        let service = try await startSession(store: makeStore())
        guard case .searched(let before)? = service.hintManualSearch(for: question) else {
            return XCTFail("searched")
        }
        XCTAssertNil(before.request.procedureStep)
        XCTAssertEqual(before.request.turn, question)

        _ = try service.startProcedure(Self.procedure)
        guard case .searched(let during)? = service.hintManualSearch(for: question) else {
            return XCTFail("searched")
        }
        XCTAssertEqual(during.request.procedureStep, "Fill the priming chamber")
        XCTAssertEqual(during.request.turn, question)
    }

    func testAHintSearchMovesNothingOnTheRunner() async throws {
        let service = try await startSession(store: makeStore())
        _ = try service.startProcedure(Self.procedure)
        let runner = try XCTUnwrap(service.activeProcedureRunner)
        let step = runner.currentStep?.id
        let visited = runner.visited
        let answers = runner.answers.count
        for text in [question, "next", "yes", "done", "Fill the priming chamber with 3 litres"] {
            _ = service.hintPassages(for: text, limit: 4)
        }
        XCTAssertEqual(service.activeProcedureRunner?.currentStep?.id, step)
        XCTAssertEqual(service.activeProcedureRunner?.visited, visited)
        XCTAssertEqual(service.activeProcedureRunner?.answers.count, answers)
        XCTAssertEqual(service.activeProcedure?.id, "qmx_prime")
    }

    // MARK: - The adapter over the real search

    func testTheAdapterFollowsTheJobOpeningAndClosing() async throws {
        let store = makeStore()
        let service = try await startSession(store: store)
        let search = JobAwareHintSearch(
            personal: DocumentStoreHintSearch(store: store, scope: { HintDocumentScope.resolve(chosen: nil, activeProject: nil) }),
            job: service, preference: { .jobManualsWhenOpen }, chosen: { nil }, activeProject: { nil },
            resolvedProvider: { .local }, medicalLocalOnly: { true })
        let during = search.search(for: question, limit: 4)
        XCTAssertEqual(during.scopeKey, "vault:\(Self.vaultId)")
        XCTAssertFalse(during.passages.isEmpty)
        XCTAssertEqual(during.modelUse, .ask(allowGeneral: false), "the test vault requires citations by default")

        _ = try service.endSession()
        let after = search.search(for: question, limit: 4)
        XCTAssertEqual(after.scopeKey, "ns:global")
        XCTAssertTrue(after.passages.allSatisfy { $0.citation == nil }, "never a manual passage once the job ends")
    }
}
