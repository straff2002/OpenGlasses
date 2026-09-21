import XCTest
@testable import OpenGlasses

/// Plan FN PR2 — removing a manual under a live job, and every route that could still deliver it.
///
/// PR1 proved the manual leaves the vault. What is proved here is the half a technician actually
/// experiences: the job they are standing in does not end, everything they have recorded survives,
/// and none of the six ways manual material reaches an answer keeps working afterwards — the turn's
/// own retrieval, `manual_lookup`, `equipment_lookup`'s fall-through, `manual_figure`, the parts
/// verifier that writes a part number into a task, and a citation chip tapped ten minutes later.
///
/// Everything runs against a real temporary vault and document store, and every absence is asserted
/// on a value the query never contained — a token echoed back from the question proves nothing.
@MainActor
final class VaultManualRemovalSessionTests: XCTestCase {

    private static let vaultId = "fn_removal_session"

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultManualRemovalSessionTests-\(UUID().uuidString)", isDirectory: true)
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

    /// Two manuals, each carrying tokens the other does not, and each with a printed page and a
    /// caption so the figure and page routes have something real to find.
    private static let installText = """
    Page 7

    ### Figure 41 — Flue Clearance Detail

    The flue side clearance is 152 millimetres from the cabinet. Kit ZJ4 anchors the unit to the pad \
    and must be fitted before the collar is connected.
    """

    private static let serviceText = """
    Page 12

    ### Figure 58 — Pressure Switch Circuit

    Fault code QQ7 means the pressure switch did not close during the prepurge period. Part QX8 is \
    the replacement switch for that circuit.
    """

    private static let manuals = [
        VaultDocument(file: "install.txt", title: "SLP99 Installation Manual", kind: "install_guide"),
        VaultDocument(file: "service.txt", title: "SLP99 Service Manual", kind: "service_manual"),
    ]

    private func makeStore() -> DocumentStore {
        let dir = tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DocumentStore(directory: dir)
    }

    /// Install the two-manual vault and start a session on it, everything ingested.
    private func startSession() async throws -> (FieldSessionService, DocumentStore, VaultManifest) {
        let dir = tempRoot.appendingPathComponent("vault-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let docs = dir.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let manifest = VaultManifest(id: Self.vaultId, name: "Lennox SLP99", version: "1.0.0",
                                     files: ["safety.md"], proceduresDir: nil,
                                     documentsDir: "documents", documents: Self.manuals,
                                     gating: .init(iap: "enterprise"),
                                     promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "# Safety\n\nLock out power before opening any panel."
            .write(to: dir.appendingPathComponent("safety.md"), atomically: true, encoding: .utf8)
        try Self.installText.write(to: docs.appendingPathComponent("install.txt"),
                                   atomically: true, encoding: .utf8)
        try Self.serviceText.write(to: docs.appendingPathComponent("service.txt"),
                                   atomically: true, encoding: .utf8)

        let installed = try VaultImporter.install(from: dir)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let store = makeStore()
        _ = try await VaultImporter.syncDocuments(manifest: installed, into: store)

        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        service.documentStore = store
        // The gate is calibrated per embedding backend and the simulator's is the word-average
        // one; pinning the floor keeps these cases about removal rather than about similarity.
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        _ = try service.startSession(vaultId: installed.id, assetId: nil)
        return (service, store, installed)
    }

    /// Remove the installation manual the way the screen does: the operation, then the refresh.
    @discardableResult
    private func removeInstallManual(_ service: FieldSessionService,
                                     store: DocumentStore) async throws -> VaultManualRemoval.RemovalResult {
        let result = try await VaultManualRemoval.remove(file: "install.txt", fromVault: Self.vaultId,
                                                         documentStore: store)
        service.vaultDidRemoveManual(result)
        return result
    }

    private func auditLines(_ service: FieldSessionService) throws -> String {
        let id = try XCTUnwrap(service.activeSession?.id)
        let url = tempRoot.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("log.jsonl")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - The job survives

    func testTheJobItsTasksAndItsAuditHistorySurviveARemoval() async throws {
        let (service, store, _) = try await startSession()
        let jobId = try XCTUnwrap(service.activeSession?.id)
        service.setJobReference("WO-4471")
        _ = service.recordIdentityField(name: "Serial", value: "5819L00312", source: .spoken)
        let task = try service.proposeTask(title: "Replace the pressure switch",
                                           citation: "SLP99 Service Manual, page 12")
        service.recordEscalation(reason: "Second opinion on the flue")
        service.logUserMessage("what is the flue clearance")
        service.logAssistantMessage("152 millimetres. Source: SLP99 Installation Manual, page 7")

        let result = try await removeInstallManual(service, store: store)
        XCTAssertEqual(result.remainingDocuments, 1)

        // The job is the same job.
        XCTAssertEqual(service.activeSession?.id, jobId)
        XCTAssertTrue(service.isSessionActive)
        XCTAssertEqual(service.activeSession?.outcome, .inProgress)
        XCTAssertEqual(service.activeSession?.jobReference, "WO-4471")
        XCTAssertEqual(service.activeSession?.identityFields.map(\.value), ["5819L00312"])
        XCTAssertEqual(service.activeSession?.tasks.map(\.id), [task.id])
        XCTAssertEqual(service.activeSession?.escalations.count, 1)
        XCTAssertEqual(service.history.first?.id, jobId)

        // …and everything written before the removal is still written.
        let log = try auditLines(service)
        XCTAssertTrue(log.contains("session_started"))
        XCTAssertTrue(log.contains("job_reference_set"))
        XCTAssertTrue(log.contains("task_proposed"))
        XCTAssertTrue(log.contains("escalation_requested"))
        XCTAssertTrue(log.contains("what is the flue clearance"), "the chat is not erased")
        // The record says which book stopped being available part-way through the visit.
        XCTAssertTrue(log.contains("manual_removed"), log)
        XCTAssertTrue(log.contains("SLP99 Installation Manual"))
    }

    func testTheSessionReadsFromTheReducedVaultWithoutBeingRestarted() async throws {
        let (service, store, _) = try await startSession()
        XCTAssertEqual(service.activeVault?.manifest.documents.count, 2)
        let before = try XCTUnwrap(service.activeVault)

        try await removeInstallManual(service, store: store)

        let after = try XCTUnwrap(service.activeVault)
        XCTAssertEqual(after.manifest.documents.map(\.file), ["service.txt"])
        XCTAssertEqual(after.manifest.id, before.manifest.id, "same vault, fewer manuals")
        XCTAssertEqual(after.manifest.version, before.manifest.version)
        XCTAssertTrue(service.activeVaultHasManuals, "the other manual still answers")
    }

    func testARemovalForAnotherVaultLeavesThisSessionAlone() async throws {
        let (service, _, _) = try await startSession()
        let elsewhere = VaultManualRemoval.RemovalResult(
            vaultId: "some_other_vault", file: "x.txt", title: "Another Manual", documentId: "doc-x",
            chunksRemoved: 1, remainingDocuments: 0, removedFiles: [], keptSharedFiles: [])
        service.vaultDidRemoveManual(elsewhere)
        XCTAssertEqual(service.activeVault?.manifest.documents.count, 2)
        XCTAssertFalse(try auditLines(service).contains("manual_removed"))
    }

    func testRemovalUnderALapsedTeamEntitlementStillWorksAndKeepsTheJob() async throws {
        let (service, store, _) = try await startSession()
        let jobId = try XCTUnwrap(service.activeSession?.id)
        // The licence lapses mid-visit. Installed content is still the reader's to delete.
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        defer { _ = EntitlementTestScope.grant() }

        let result = try await removeInstallManual(service, store: store)
        XCTAssertEqual(result.title, "SLP99 Installation Manual")
        XCTAssertEqual(service.activeSession?.id, jobId)
    }

    // MARK: - The turn's own retrieval

    func testThePromptStopsCarryingTheRemovedManualAndKeepsTheOther() async throws {
        let (service, store, _) = try await startSession()
        let before = try XCTUnwrap(service.promptContext(turn: "what is the flue side clearance"))
        XCTAssertTrue(before.contains("ZJ4"), "the installation manual answers first")

        try await removeInstallManual(service, store: store)

        let after = service.promptContext(turn: "what is the flue side clearance") ?? ""
        XCTAssertFalse(after.contains("ZJ4"), after)
        XCTAssertFalse(after.contains("152 millimetres"), after)
        XCTAssertTrue((service.promptContext(turn: "what does fault code QQ7 mean") ?? "").contains("QX8"),
                      "the service manual is untouched")
    }

    func testAStagedFigureFromTheRemovedManualGoesAndTheOthersStays() async throws {
        let (service, store, _) = try await startSession()
        // Staged by caption rather than by similarity, so what is on the turn is not a question of
        // how a backend scores two short fixtures.
        let figures = ManualFigureTool(documentStore: store, sessionService: service)
        _ = try await figures.execute(args: ["figure": "Figure 41"])
        let staged = try XCTUnwrap(service.stagedFigure)
        XCTAssertEqual(staged.documentTitle, "SLP99 Installation Manual")

        try await removeInstallManual(service, store: store)
        XCTAssertNil(service.stagedFigure, "a drawing from a removed manual is not left on the turn")
        XCTAssertNil(service.restageLastFigure(), "…and “show that again” cannot bring it back")

        // A figure from the manual that stayed behaves exactly as before.
        _ = try await figures.execute(args: ["figure": "Figure 58"])
        let kept = try XCTUnwrap(service.stagedFigure)
        XCTAssertEqual(kept.documentTitle, "SLP99 Service Manual")
        XCTAssertEqual(service.restageLastFigure()?.documentTitle, "SLP99 Service Manual")
    }

    // MARK: - Citations as doors

    func testAStaleCitationSaysTheManualWasRemovedRatherThanOpeningAPage() async throws {
        let (service, store, _) = try await startSession()
        let citation = Citation(kind: .manual, title: "SLP99 Installation Manual", page: 7,
                                figure: "Figure 41")
        guard case .figure(let staged) = service.resolveCitation(citation) else {
            return XCTFail("the citation opens its page before the removal")
        }
        XCTAssertEqual(staged.page, 7)

        try await removeInstallManual(service, store: store)

        XCTAssertEqual(service.resolveCitation(citation), .removed(title: "SLP99 Installation Manual"))
        XCTAssertNil(service.stagedFigure(for: citation), "and there is no page to open")
        // The manual that stayed is still a door.
        let other = Citation(kind: .manual, title: "SLP99 Service Manual", page: 12)
        guard case .figure = service.resolveCitation(other) else {
            return XCTFail("the remaining manual still opens")
        }
    }

    func testACitationThisVaultNeverHadIsReportedAsUnknownRatherThanRemoved() async throws {
        let (service, _, _) = try await startSession()
        let invented = Citation(kind: .manual, title: "Carrier 58MVB Service Manual", page: 3)
        XCTAssertEqual(service.resolveCitation(invented),
                       .unknown(title: "Carrier 58MVB Service Manual"))
    }

    func testAPendingRemovalAlreadyReadsAsRemovedToACitation() async throws {
        let (service, _, _) = try await startSession()
        let entry = try XCTUnwrap(VaultImporter.documentLedger(for: Self.vaultId)
            .entries.first { $0.file == "install.txt" })
        // The journal is written before anything durable changes; from that moment the manual is
        // unreachable, so a chip tapped in the gap must not open its page.
        try VaultRemovalJournal.record(
            .init(file: "install.txt", title: entry.title, documentId: entry.documentId, startedAt: Date()),
            in: VaultImporter.overlayDirectory(for: Self.vaultId))
        defer { try? VaultRemovalJournal.clear(file: "install.txt",
                                               in: VaultImporter.overlayDirectory(for: Self.vaultId)) }

        let citation = Citation(kind: .manual, title: "SLP99 Installation Manual", page: 7)
        XCTAssertEqual(service.resolveCitation(citation), .removed(title: "SLP99 Installation Manual"))
    }

    func testTheFigureSheetHasNoPagesForARemovedManual() async throws {
        let (service, store, _) = try await startSession()
        _ = try await ManualFigureTool(documentStore: store, sessionService: service)
            .execute(args: ["figure": "Figure 41"])
        let staged = try XCTUnwrap(service.stagedFigure)
        XCTAssertFalse(service.manualPageSheet(for: staged).extractedPages.isEmpty,
                       "a text-route manual shows its extracted pages")

        try await removeInstallManual(service, store: store)

        let sheet = service.manualPageSheet(for: staged)
        XCTAssertTrue(sheet.extractedPages.isEmpty, "a removed manual has no page to turn to")
        XCTAssertNil(sheet.manufacturerPDF)
    }

    // MARK: - Every tool that can deliver manual material

    func testManualLookupCannotReturnTheRemovedManual() async throws {
        let (service, store, _) = try await startSession()
        let tool = ManualLookupTool(documentStore: store, sessionService: service)
        let before = try await tool.execute(args: ["query": "flue side clearance"])
        XCTAssertTrue(before.contains("ZJ4"), before)

        try await removeInstallManual(service, store: store)

        let after = try await tool.execute(args: ["query": "flue side clearance"])
        XCTAssertFalse(after.contains("ZJ4"), after)
        XCTAssertFalse(after.contains("152 millimetres"), after)
        // The tool still works for what is left.
        let kept = try await tool.execute(args: ["query": "prepurge pressure switch"])
        XCTAssertTrue(kept.contains("QX8"), kept)
    }

    func testEquipmentLookupsManualFallThroughCannotReturnTheRemovedManual() async throws {
        let (service, store, _) = try await startSession()
        let tool = EquipmentLookupTool(documentStore: store, sessionService: service)
        let before = try await tool.execute(args: ["query": "ZJ4"])
        XCTAssertTrue(before.contains("152 millimetres"), before)

        try await removeInstallManual(service, store: store)

        let after = try await tool.execute(args: ["query": "ZJ4"])
        XCTAssertFalse(after.contains("152 millimetres"), after)
        XCTAssertFalse(after.contains("Figure 41"), after)
    }

    func testManualFigureCannotShowAFigureOrAPageOfTheRemovedManual() async throws {
        let (service, store, _) = try await startSession()
        let tool = ManualFigureTool(documentStore: store, sessionService: service)
        let shownFigure = try await tool.execute(args: ["figure": "Figure 41"])
        XCTAssertTrue(shownFigure.contains("Figure 41"), shownFigure)
        let shownPage = try await tool.execute(args: ["page": 7])
        XCTAssertTrue(shownPage.contains("page 7"), shownPage)

        try await removeInstallManual(service, store: store)

        let figure = try await tool.execute(args: ["figure": "Figure 41"])
        XCTAssertTrue(figure.hasPrefix("No Figure 41"), figure)
        let page = try await tool.execute(args: ["page": 7])
        XCTAssertTrue(page.hasPrefix("Nothing is stored for page 7"), page)
        // The other manual's drawing is unaffected.
        let other = try await tool.execute(args: ["figure": "Figure 58"])
        XCTAssertTrue(other.contains("Figure 58"), other)
    }

    func testAPartNumberCannotBeVerifiedAgainstARemovedManual() async throws {
        let (service, store, _) = try await startSession()
        let before = service.verifyPart("ZJ4")
        XCTAssertTrue(before.verified)
        XCTAssertEqual(before.page?.contains("SLP99 Installation Manual"), true)

        try await removeInstallManual(service, store: store)

        let after = service.verifyPart("ZJ4")
        XCTAssertFalse(after.verified, "the book it was verified against is gone")
        XCTAssertNil(after.page)
        // A part the remaining manual names is still verified.
        XCTAssertTrue(service.verifyPart("QX8").verified)
    }
}
