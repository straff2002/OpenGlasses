import XCTest
@testable import OpenGlasses

/// Plan KE P1 against a real session: a temporary `DocumentStore`, a fresh `FieldSessionService`
/// and an invented vault of two families, with the turn's words stated through the service's seam.
@MainActor
final class SymptomDiagnosisSessionTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    private static let models = """
    # Models

    ## QX100 (QX100-A; rooftop)
    S:A02; U:A11; A02 suffix:00,01

    ## QX200 (rooftop)
    S:A03

    ## QY300 (split)
    No documents listed here.
    """

    private static let manuals: [(file: String, title: String, text: String)] = [
        ("a02.txt", "A02 Acme Service Manual", """
        IGNITION LOCKOUT
        On a heat call the control tries for ignition three times. After a lockout, check the flame sensor rod and measure the igniter resistance.
        """),
        ("a11.txt", "A11 Acme User Manual", """
        RESET
        Press the reset key once to clear the display after a service visit.
        """),
        ("a03.txt", "A03 Acme Service Manual", """
        IGNITION LOCKOUT
        On a heat call the control tries for ignition three times. After a lockout, check the gas valve and the pressure switch hose.
        """),
    ]

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SymptomDiagnosisSessionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        VaultImporter.uninstall(id: "ke_test")
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private func start(models: String = models) async throws -> (service: FieldSessionService, store: DocumentStore) {
        let dir = tempRoot.appendingPathComponent("vault-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let documentsDir = dir.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)
        let manifest = VaultManifest(id: "ke_test", name: "Acme Refrigeration", version: "1.0.0",
                                     files: ["models.md"], proceduresDir: nil, documentsDir: "documents",
                                     documents: Self.manuals.map { VaultDocument(file: $0.file, title: $0.title, kind: "service_manual") },
                                     gating: .init(iap: "enterprise"), promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try models.write(to: dir.appendingPathComponent("models.md"), atomically: true, encoding: .utf8)
        for manual in Self.manuals {
            try manual.text.write(to: documentsDir.appendingPathComponent(manual.file), atomically: true, encoding: .utf8)
        }
        let installed = try VaultImporter.install(from: dir)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let storeDirectory = tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let store = DocumentStore(directory: storeDirectory)
        _ = try await VaultImporter.syncDocuments(manifest: installed, into: store)
        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        service.documentStore = store
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        _ = try service.startSession(vaultId: installed.id, assetId: nil)
        return (service, store)
    }

    private func turn(_ words: String, on service: FieldSessionService) -> String {
        service.technicianWords = { words }
        return service.promptContext(turn: words) ?? ""
    }

    private func assignedTitles(_ service: FieldSessionService) -> [String] {
        service.assignedDocuments.map(\.title).sorted()
    }

    // MARK: - The model said aloud counts

    func testTheTurnThatNamesTheModelIsAlreadyScopedToIt() async throws {
        let (service, _) = try await start()
        var identityChanges = 0
        service.onJobIdentityChanged = { identityChanges += 1 }

        let prompt = turn("the QX100 has no heat, ignition lockout", on: service)

        let unit = try XCTUnwrap(service.activeEquipment)
        XCTAssertEqual(unit.stated, "QX100")
        XCTAssertEqual(unit.source, .spoken)
        XCTAssertTrue(prompt.contains("ACTIVE EQUIPMENT: QX100"), "the same prompt carries it")
        XCTAssertEqual(service.activeSession?.visitedUnits.count, 1, "the job's own record, as the tool's path writes it")
        XCTAssertEqual(identityChanges, 1, "so the title follows")
        XCTAssertNotNil(service.retrievalModelScope)
        XCTAssertEqual(assignedTitles(service), ["A02 Acme Service Manual", "A11 Acme User Manual"])
    }

    func testAFullerSpellingOfTheActiveUnitIsKept() async throws {
        let (service, _) = try await start()
        _ = turn("the QX100 has no heat", on: service)
        let first = try XCTUnwrap(service.activeEquipment)
        let scope = service.activeSession?.continuityScope
        var identityChanges = 0
        service.onJobIdentityChanged = { identityChanges += 1 }

        _ = turn("the plate says QX100-A01", on: service)

        XCTAssertEqual(service.activeEquipment?.stated, "QX100-A01")
        XCTAssertEqual(service.activeEquipment?.recognisedAt, first.recognisedAt, "the same unit, restated")
        XCTAssertEqual(service.activeSession?.continuityScope, scope)
        XCTAssertEqual(service.activeSession?.visitedUnits.count, 1)
        XCTAssertEqual(service.activeSession?.visitedUnits.last?.stated, "QX100-A01")
        XCTAssertEqual(identityChanges, 1)
    }

    func testTheToolKeepsASuffixToo() async throws {
        let (service, store) = try await start()
        _ = turn("the QX100 has no heat", on: service)
        let tool = EquipmentLookupTool(documentStore: store, sessionService: service)

        _ = try await tool.execute(args: ["query": "QX100-A01"])

        XCTAssertEqual(service.activeEquipment?.stated, "QX100-A01", "the early return on the same heading lost it")
    }

    func testADifferentModelKeepsTodaysPath() async throws {
        let (service, _) = try await start()
        _ = turn("the QX100 has no heat", on: service)
        let before = service.activeEquipment

        _ = turn("the QX200 next door does the same", on: service)

        XCTAssertEqual(service.activeEquipment, before, "a machine mentioned in passing moves nothing")
        XCTAssertNil(service.activeSession?.pendingUnitChange)
    }

    func testAPausedJobRecordsNothing() async throws {
        let (service, _) = try await start()
        _ = try service.pauseSession()

        _ = turn("my mate has a QX100 at home", on: service)

        XCTAssertNil(service.activeEquipment)
    }

    func testATurnWithNoWordsRecordsNothing() async throws {
        let (service, _) = try await start()
        service.technicianWords = { nil }

        _ = service.promptContext(turn: "the QX100 has no heat")

        XCTAssertNil(service.activeEquipment, "an agent's or a live session's turn is not the technician's words")
    }

    func testAPromptRebuiltAfterAToolDoesNotBringTheUnitBack() async throws {
        let (service, _) = try await start()
        _ = turn("forget the QX100", on: service)
        service.clearEquipment()

        _ = turn("forget the QX100", on: service)

        XCTAssertNil(service.activeEquipment)
    }

    // MARK: - Documents by model

    func testAnAssignedDocumentLeadsAGenericPageOfAnotherFamily() async throws {
        let (service, store) = try await start()
        _ = turn("QX100", on: service)
        let vault = try XCTUnwrap(service.activeVault)

        let outcome = service.makeRetriever(store: vault, documentStore: store)
            .retrieve(.init(turn: "ignition lockout on a heat call", limit: 8))

        let names = outcome.passages.map(\.documentName)
        XCTAssertEqual(names.first, "A02 Acme Service Manual")
        XCTAssertTrue(names.contains("A03 Acme Service Manual"), "ranked down, not out: it still says what the other family does")
        XCTAssertGreaterThan(outcome.passages.first { $0.documentName.hasPrefix("A03") }?.modelPenalty ?? 0, 0)
    }

    func testManualLookupSearchesTheSameScope() async throws {
        let (service, store) = try await start()
        _ = turn("QX100", on: service)
        let tool = ManualLookupTool(documentStore: store, sessionService: service)

        let reply = try await tool.execute(args: ["query": "ignition lockout on a heat call"])

        let first = try XCTUnwrap(reply.range(of: "Source: A02"))
        let second = try XCTUnwrap(reply.range(of: "Source: A03"), reply)
        XCTAssertLessThan(first.lowerBound, second.lowerBound, reply)
    }

    func testThePromptNamesTheAssignedDocuments() async throws {
        let (service, _) = try await start()
        let prompt = turn("the QX100 has an ignition lockout on a heat call", on: service)
        XCTAssertTrue(prompt.contains("DOCUMENTS FOR QX100: A02 Acme Service Manual; A11 Acme User Manual."), prompt)
    }

    func testASectionNamingNoDocumentsChangesNothing() async throws {
        let (service, store) = try await start()
        let prompt = turn("the QY300 has an ignition lockout on a heat call", on: service)
        XCTAssertEqual(service.activeEquipment?.stated, "QY300")
        XCTAssertFalse(prompt.contains("DOCUMENTS FOR"), prompt)
        XCTAssertEqual(service.retrievalModelScope?.assignedDocumentIds, [])
        let vault = try XCTUnwrap(service.activeVault)
        let outcome = service.makeRetriever(store: vault, documentStore: store).retrieve(.init(turn: "ignition lockout", limit: 8))
        XCTAssertTrue(outcome.passages.allSatisfy { $0.modelPenalty == 0 })
    }

    func testASeriesMemberTakesItsSeriesDocuments() async throws {
        let (service, _) = try await start(models: """
        ## QXT99UH100AB
        S:A02
        ## QXT99UH200AB
        U:A11
        ## QXT99UH300AB
        S:A02
        """)
        _ = turn("it's a QXT99UH400AB", on: service)

        XCTAssertEqual(service.activeEquipment?.isSeriesMember, true)
        let scope = try XCTUnwrap(service.retrievalModelScope)
        XCTAssertEqual(assignedTitles(service), ["A02 Acme Service Manual", "A11 Acme User Manual"])
        XCTAssertEqual(scope.assignedDocumentIds.count, 2)
        XCTAssertTrue(scope.activeTokens.isEmpty, "a series member's text is scored as it always was")
        XCTAssertEqual(scope.penalty(forSubjectToken: "QXT99UH100AB"), 0)
    }

    func testASeriesWithNoDocumentsHasNoScopeAsToday() async throws {
        let (service, _) = try await start(models: "## QXT99UH100AB\n## QXT99UH200AB\n## QXT99UH300AB\n")
        _ = turn("it's a QXT99UH400AB", on: service)
        XCTAssertEqual(service.activeEquipment?.isSeriesMember, true)
        XCTAssertNil(service.retrievalModelScope)
    }

    // MARK: - A follow-up keeps the job's subject

    private func lexicalGate(_ service: FieldSessionService) {
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0, minSharedTerms: 3)
    }

    func testAFollowUpFindsTheJobsPages() async throws {
        let (service, _) = try await start()
        lexicalGate(service)
        _ = turn("the QX100 shows an ignition lockout on a heat call", on: service)

        let prompt = turn("the tech sheet has gone from the door, what now?", on: service)

        XCTAssertTrue(prompt.contains("MANUAL PASSAGES (retrieved"), prompt)
        XCTAssertTrue(prompt.contains("Source: A02 Acme Service Manual"), prompt)
    }

    func testWithoutAJobToFollowTheRefusalStands() async throws {
        let (service, _) = try await start()
        lexicalGate(service)

        let prompt = turn("the tech sheet has gone from the door, what now?", on: service)

        XCTAssertTrue(prompt.contains(RetrievalEvidencePolicy.insufficientSentence), prompt)
    }

    func testASecondMissLeavesTheRefusal() async throws {
        let (service, _) = try await start()
        lexicalGate(service)
        _ = turn("the customer wants the invoice emailed", on: service)

        let prompt = turn("the tech sheet has gone from the door, what now?", on: service)

        XCTAssertTrue(prompt.contains(RetrievalEvidencePolicy.insufficientSentence), prompt)
    }

    func testAnUnknownMachineIsRefusedFirst() async throws {
        let (service, _) = try await start()
        lexicalGate(service)
        _ = turn("the QX100 shows an ignition lockout on a heat call", on: service)

        let prompt = turn("what about the ZZ9000?", on: service)

        XCTAssertTrue(prompt.contains("is not one of them"), prompt)
        XCTAssertFalse(prompt.contains("Source: A02"), prompt)
    }

    func testATurnWithNoWordsSearchesOnlyItself() async throws {
        let (service, _) = try await start()
        lexicalGate(service)
        _ = turn("the QX100 shows an ignition lockout on a heat call", on: service)

        service.technicianWords = { nil }
        let prompt = service.promptContext(turn: "the tech sheet has gone from the door, what now?") ?? ""

        XCTAssertTrue(prompt.contains(RetrievalEvidencePolicy.insufficientSentence), prompt)
    }

    func testAJobTurnIsNotWidened() async throws {
        let (service, _) = try await start()
        lexicalGate(service)
        _ = turn("the QX100 shows an ignition lockout on a heat call", on: service)

        let prompt = turn("close the job", on: service)

        XCTAssertFalse(prompt.contains("MANUAL PASSAGES (retrieved"), prompt)
    }

    func testAnotherUnitStartsClean() async throws {
        let (service, _) = try await start()
        lexicalGate(service)
        _ = turn("the QX100 is on site", on: service)
        _ = turn("it shows an ignition lockout on a heat call", on: service)

        service.startNextUnit(nil)
        let prompt = turn("the tech sheet has gone from the door, what now?", on: service)

        XCTAssertTrue(prompt.contains(RetrievalEvidencePolicy.insufficientSentence), prompt)
    }

    // MARK: - One supported check

    func testADiagnosticTurnGetsTheRule() async throws {
        let (service, _) = try await start()
        for words in ["what should I check next", "the igniter glows briefly", "supply air is 140"] {
            XCTAssertTrue(turn(words, on: service).contains(FieldSessionService.oneCheckRule), words)
        }
    }

    func testAJobTurnOrAPageRequestDoesNot() async throws {
        let (service, _) = try await start()
        for words in ["close the job", "show me the wiring diagram", "135 not 140"] {
            XCTAssertFalse(turn(words, on: service).contains(FieldSessionService.oneCheckRule), words)
        }
    }

    func testTheRuleSaysWhatThePlanSays() {
        let rule = FieldSessionService.oneCheckRule
        for words in ["one check", "what to observe", "pick the next", "specific gap", "manufacturer's first step"] {
            XCTAssertTrue(rule.contains(words), words)
        }
        XCTAssertLessThan(rule.utf8.count, 300, "it goes out on most turns of a job")
    }
}
