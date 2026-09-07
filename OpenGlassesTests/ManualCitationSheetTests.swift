import PDFKit
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan EK P3 — a citation is a door, and the page behind it says what it is.
///
/// The vault installed here holds all three cases a technician meets: a manual imported as the
/// manufacturer's PDF, a manual imported as extracted text with the original bundled beside it, and
/// a manual imported as extracted text with no original at all. Everything is driven through the
/// shipped importer, store, session and sheet model; nothing about the sheet's decisions needs a
/// screen, which is the only way this gets tested before it is on a roof.
@MainActor
final class ManualCitationSheetTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private static let vaultId = "citation_sheet_test"
    private static let pdfManual = "Fixture Service Manual"
    private static let textManual = "Fixture Field Guide"
    private static let looseManual = "Fixture Loose Notes"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualCitationSheetTests-\(UUID().uuidString)", isDirectory: true)
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

    /// A PDF with `pages` numbered pages of body text. Content only has to be extractable; the
    /// structure rules are P1's business and are tested there.
    private func makePDF(at url: URL, pages: Int) {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 460, height: 700))
        let data = renderer.pdfData { context in
            for page in 1...pages {
                context.beginPage()
                var y: CGFloat = 24
                for line in Self.pageLines(page) {
                    let font = UIFont(name: "Helvetica", size: 10) ?? UIFont.systemFont(ofSize: 10)
                    NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: UIColor.black])
                        .draw(at: CGPoint(x: 24, y: y))
                    y += 16
                }
            }
        }
        try? data.write(to: url)
    }

    private static func pageLines(_ page: Int) -> [String] {
        var lines = ["Page \(page)"]
        // Each page must be long enough to pack into a chunk of its own; otherwise the whole
        // document is one chunk carrying only the page it started on.
        for step in 1...24 {
            lines.append("Step \(step) on page \(page): close the manual gas valve and verify the reading before proceeding.")
        }
        return lines
    }

    /// The extracted-text route's document, in the Markdown-flavoured grammar both producers write.
    private static func textDocument(pages: Int) -> String {
        var parts: [String] = []
        for page in 1...pages {
            parts.append("Page \(page)")
            parts.append("## Section For Page \(page)")
            parts.append("")
            parts.append("| Code | Meaning |")
            parts.append("|------|---------|")
            parts.append("| E\(200 + page) | Fault on page \(page) |")
            parts.append("")
            parts.append(pageLines(page).dropFirst().joined(separator: " "))
            parts.append("")
        }
        return parts.joined(separator: "\n")
    }

    private func makeStore() -> DocumentStore {
        let dir = tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DocumentStore(directory: dir)
    }

    /// Install the three-document vault and start a session with everything ingested.
    @discardableResult
    private func startSession(store: DocumentStore) async throws -> FieldSessionService {
        let dir = tempRoot.appendingPathComponent("vault-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let docs = dir.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        makePDF(at: docs.appendingPathComponent("manual.pdf"), pages: 3)
        makePDF(at: docs.appendingPathComponent("guide.pdf"), pages: 3)
        try Self.textDocument(pages: 3).write(to: docs.appendingPathComponent("guide.md"),
                                              atomically: true, encoding: .utf8)
        try Self.textDocument(pages: 2).write(to: docs.appendingPathComponent("loose.md"),
                                              atomically: true, encoding: .utf8)

        let manifest = VaultManifest(
            id: Self.vaultId, name: "Citation Sheet Test", version: "1.0.0",
            files: ["safety.md"], proceduresDir: nil, documentsDir: "documents",
            documents: [
                VaultDocument(file: "manual.pdf", title: Self.pdfManual, kind: "service_manual"),
                VaultDocument(file: "guide.md", title: Self.textManual, kind: "install_guide",
                              source: "guide.pdf", sourceUrl: "https://example.com/guide.pdf"),
                VaultDocument(file: "loose.md", title: Self.looseManual, kind: "service_manual")
            ],
            gating: .init(iap: "enterprise"),
            promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "# Safety\n\nLock out power before opening any panel."
            .write(to: dir.appendingPathComponent("safety.md"), atomically: true, encoding: .utf8)

        let installed = try VaultImporter.install(from: dir)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        _ = try await VaultImporter.syncDocuments(manifest: installed, into: store)

        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        service.documentStore = store
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        _ = try service.startSession(vaultId: installed.id, assetId: nil)
        return service
    }

    private func citation(_ title: String, page: Int) -> Citation {
        Citation(kind: .manual, title: title, page: page)
    }

    private func logLines(of service: FieldSessionService) throws -> String {
        let id = try XCTUnwrap(service.activeSession?.id)
        return try String(contentsOf: tempRoot.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("log.jsonl"), encoding: .utf8)
    }

    // MARK: - Resolving a citation

    func testACitationResolvesToTheDocumentItNames() async throws {
        let service = try await startSession(store: makeStore())

        let staged = try XCTUnwrap(service.stagedFigure(for: citation(Self.pdfManual, page: 2)))
        XCTAssertEqual(staged.documentTitle, Self.pdfManual)
        XCTAssertEqual(staged.page, 2)
        XCTAssertEqual(staged.sourceFile, "manual.pdf")

        XCTAssertNotNil(service.stagedFigure(for: citation(Self.textManual, page: 3)))
        XCTAssertNil(service.stagedFigure(for: citation("A Manual This Vault Never Had", page: 1)),
                     "a title no manual answers to opens nothing rather than something else")
        XCTAssertNil(service.stagedFigure(for: Citation(kind: .coreFile, title: "safety.md")),
                     "a core file is not a manual page")
    }

    // MARK: - The header, both routes

    func testThePDFRouteIsTheManufacturersDocumentAndSaysItIsUnmodified() async throws {
        let service = try await startSession(store: makeStore())
        let staged = try XCTUnwrap(service.stagedFigure(for: citation(Self.pdfManual, page: 2)))

        var model = service.manualPageSheet(for: staged)
        XCTAssertEqual(model.route, .manufacturerPDF)
        XCTAssertTrue(model.hasContent)
        XCTAssertEqual(model.paging.title, "page 2 of 3")
        XCTAssertNil(model.originalLine, "the original is what is on screen")
        XCTAssertFalse(model.canOpenOriginal)

        model.integrity = await ManualPageIntegrity.check(url: model.manufacturerPDF, against: model.ledgerHash)
        XCTAssertEqual(model.integrity, .unmodified)
        XCTAssertEqual(model.headerLine, "Manufacturer's document \u{00B7} page 2 of 3 \u{00B7} unmodified since import")
    }

    func testAFileThatChangedAfterImportIsNotCalledUnmodified() async throws {
        let service = try await startSession(store: makeStore())
        let staged = try XCTUnwrap(service.stagedFigure(for: citation(Self.pdfManual, page: 1)))
        var model = service.manualPageSheet(for: staged)

        // The baseline is meant to be read-only; a file that no longer hashes to what the ledger
        // recorded changed behind the vault's back, and the header has to say so.
        makePDF(at: try XCTUnwrap(model.manufacturerPDF), pages: 4)
        model.integrity = await ManualPageIntegrity.check(url: model.manufacturerPDF, against: model.ledgerHash)
        XCTAssertEqual(model.integrity, .changed)
        XCTAssertTrue(model.headerLine.hasSuffix("changed since import"), model.headerLine)
    }

    func testNothingIsClaimedWhenNoHashWasRecorded() {
        XCTAssertEqual(ManualPageIntegrity.compare(fileHash: "abc", ledgerHash: "abc"), .unmodified)
        XCTAssertEqual(ManualPageIntegrity.compare(fileHash: "abc", ledgerHash: "def"), .changed)
        XCTAssertEqual(ManualPageIntegrity.compare(fileHash: "abc", ledgerHash: nil), .unknown)
        XCTAssertEqual(ManualPageIntegrity.compare(fileHash: nil, ledgerHash: "abc"), .unknown)
        XCTAssertNil(ManualPageIntegrity.unknown.clause, "silence rather than a claim")
    }

    func testTheExtractedTextRouteShowsStoredTextAndSaysWhereTheOriginalIs() async throws {
        let service = try await startSession(store: makeStore())

        let bundled = try XCTUnwrap(service.stagedFigure(for: citation(Self.textManual, page: 2)))
        let withOriginal = service.manualPageSheet(for: bundled)
        XCTAssertEqual(withOriginal.route, .extractedText)
        XCTAssertEqual(withOriginal.headerLine, "Extracted text \u{00B7} page 2")
        XCTAssertEqual(withOriginal.originalLine, "The manufacturer's original is bundled with this vault.")
        XCTAssertTrue(withOriginal.canOpenOriginal)
        XCTAssertEqual(withOriginal.publishedURL?.absoluteString, "https://example.com/guide.pdf")
        XCTAssertTrue(try XCTUnwrap(withOriginal.currentText).contains("page 2"),
                      "the sheet shows the text stored for the page the citation named")
        XCTAssertEqual(withOriginal.paging.pages, [1, 2, 3], "the store knows every page of the extract")

        let loose = try XCTUnwrap(service.stagedFigure(for: citation(Self.looseManual, page: 1)))
        let noOriginal = service.manualPageSheet(for: loose)
        XCTAssertEqual(noOriginal.originalLine, "Original not bundled in this vault")
        XCTAssertFalse(noOriginal.canOpenOriginal)
        XCTAssertNil(noOriginal.publishedURL)
        XCTAssertTrue(noOriginal.hasContent, "extracted text is still something to read")
    }

    func testOpeningTheOriginalSwitchesRouteAtTheSamePage() async throws {
        let service = try await startSession(store: makeStore())
        let staged = try XCTUnwrap(service.stagedFigure(for: citation(Self.textManual, page: 3)))
        let controller = ManualPageController(model: service.manualPageSheet(for: staged), session: service)
        await controller.open()
        XCTAssertEqual(controller.model.route, .extractedText)

        await controller.openOriginal()
        XCTAssertEqual(controller.model.route, .manufacturerPDF)
        XCTAssertEqual(controller.model.paging.currentPage, 3, "the same page, in the manufacturer's copy")
        XCTAssertEqual(controller.model.paging.title, "page 3 of 3")
        XCTAssertEqual(controller.model.integrity, .unmodified,
                       "checked against the hash recorded for the bundled original, not for the text")
        XCTAssertFalse(controller.model.canOpenOriginal, "already reading it")
    }

    // MARK: - Paging

    func testPagingModelOverAContiguousDocument() {
        var paging = FigurePagingModel(citedPage: 20, pageCount: 85)
        XCTAssertEqual(paging.currentPage, 20)
        XCTAssertEqual(paging.title, "page 20 of 85")
        XCTAssertFalse(paging.isAwayFromCitedPage)
        XCTAssertTrue(paging.canGoBack)
        XCTAssertTrue(paging.canGoForward)

        XCTAssertEqual(paging.goForward(), 21)
        XCTAssertTrue(paging.isAwayFromCitedPage)
        XCTAssertEqual(paging.title, "page 21 of 85")
        XCTAssertEqual(paging.returnToCitedPage(), 20)
        XCTAssertFalse(paging.isAwayFromCitedPage)
        XCTAssertNil(paging.returnToCitedPage(), "already there — nothing moved, nothing to log")
    }

    func testPagingModelOverSparseStoredPagesAndItsEdges() {
        var paging = FigurePagingModel(citedPage: 12, pages: [4, 12, 30])
        XCTAssertEqual(paging.currentPage, 12)
        XCTAssertEqual(paging.title, "page 12 of 3")
        XCTAssertEqual(paging.goBack(), 4)
        XCTAssertFalse(paging.canGoBack)
        XCTAssertNil(paging.goBack())
        XCTAssertEqual(paging.goForward(), 12)
        XCTAssertEqual(paging.goForward(), 30)
        XCTAssertFalse(paging.canGoForward)
        XCTAssertNil(paging.move(to: 7), "a page the document does not hold is not a page")
        XCTAssertEqual(paging.currentPage, 30)

        // A cited page the store holds nothing for still opens somewhere sensible.
        let nearest = FigurePagingModel(citedPage: 5, pages: [4, 12])
        XCTAssertEqual(nearest.currentPage, 12)
        XCTAssertTrue(nearest.isAwayFromCitedPage)

        let empty = FigurePagingModel(citedPage: 9, pages: [])
        XCTAssertEqual(empty.currentPage, 9)
        XCTAssertEqual(empty.title, "page 9 of 1")
    }

    // MARK: - The audit trail

    func testTheAuditRecordsWhatWasOpenedTurnedToAndVerified() async throws {
        let service = try await startSession(store: makeStore())
        let cited = citation(Self.pdfManual, page: 2)
        let staged = try XCTUnwrap(service.stagedFigure(for: cited))

        service.logCitationOpened(cited, origin: .chip)
        let controller = ManualPageController(model: service.manualPageSheet(for: staged), session: service)
        await controller.open()
        controller.next()
        controller.returnToCitedPage()

        let log = try logLines(of: service)
        XCTAssertTrue(log.contains("citation_opened"), log)
        XCTAssertTrue(log.contains("\"origin\":\"chip\""), log)
        XCTAssertTrue(log.contains("page_verified"), log)
        XCTAssertTrue(log.contains("\"source\":\"manufacturer_pdf\""), log)
        XCTAssertTrue(log.contains("page_viewed"), log)
        XCTAssertTrue(log.contains("\(Self.pdfManual), page 3"), "the page swiped to is recorded: \(log)")
        XCTAssertEqual(log.components(separatedBy: "page_viewed").count - 1, 1,
                       "returning to a page already seen does not log it twice")
    }

    func testAskingForAPageOutLoudIsRecordedAsSuch() async throws {
        let store = makeStore()
        let service = try await startSession(store: store)
        let tool = ManualFigureTool(documentStore: store, sessionService: service)

        let answer = try await tool.execute(args: ["page": 2])
        XCTAssertTrue(answer.contains("page 2"), answer)
        let log = try logLines(of: service)
        XCTAssertTrue(log.contains("citation_opened"), log)
        XCTAssertTrue(log.contains("\"origin\":\"voice\""), log)
    }

    // MARK: - The export

    func testTheExportSaysWhichCitationsWereOpenedAndAgainstWhat() async throws {
        let service = try await startSession(store: makeStore())
        let sessionId = try XCTUnwrap(service.activeSession?.id)
        let opened = citation(Self.pdfManual, page: 2)

        service.logUserMessage("what is on page 2")
        service.logAssistantMessage("""
        Close the manual gas valve first.
        Source: \(opened.label)
        Source: \(Self.looseManual), page 1
        """)
        service.logCitationOpened(opened, origin: .chip)
        let controller = ManualPageController(
            model: service.manualPageSheet(for: try XCTUnwrap(service.stagedFigure(for: opened))),
            session: service)
        await controller.open()
        _ = try service.endSession(outcome: .resolved)

        let dir = tempRoot.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        let export = try XCTUnwrap(SessionExporter.buildExport(sessionDir: dir))

        let checked = try XCTUnwrap(export.citations.first { $0.source == opened.label })
        XCTAssertTrue(checked.opened)
        XCTAssertEqual(checked.origin, "chip")
        XCTAssertEqual(checked.verifiedAgainst, "manufacturer_pdf")

        let untouched = try XCTUnwrap(export.citations.first { $0.source.contains(Self.looseManual) })
        XCTAssertFalse(untouched.opened, "an answer's other citation is listed, and listed as unread")
        XCTAssertNil(untouched.verifiedAgainst)

        let lines = SessionExporter.citationLines(export)
        XCTAssertTrue(lines.contains("\(opened.label) — opened, read in the manufacturer's document"), "\(lines)")
        XCTAssertTrue(lines.contains("\(Self.looseManual), page 1 — not opened"), "\(lines)")

        // And it survives the JSON write → decode round-trip a reviewer receives.
        _ = try SessionExporter.export(sessionDir: dir, formats: [.json])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let reloaded = try decoder.decode(SessionExport.self,
                                          from: Data(contentsOf: dir.appendingPathComponent("audit_export.json")))
        XCTAssertEqual(reloaded.citations.first { $0.source == opened.label }?.verifiedAgainst, "manufacturer_pdf")
    }

    func testTheExportReadsBothRoutesInPlainWords() {
        XCTAssertEqual(SessionExporter.readableSources("manufacturer_pdf"), "the manufacturer's document")
        XCTAssertEqual(SessionExporter.readableSources("extracted_text, manufacturer_pdf"),
                       "the extracted text, then the manufacturer's document")
        XCTAssertEqual(SessionExporter.readableSources("external_url"), "the manufacturer's published manual")
    }

    // MARK: - The chips

    func testChipsAreOnlyDrawnForCitationsWithSomethingBehindThem() async throws {
        let service = try await startSession(store: makeStore())
        XCTAssertTrue(service.activeVaultHasManuals)
        // The chip's label is the citation's own words — the technician is checking one against
        // the other.
        let cited = try XCTUnwrap(CitationLineParser.parse("Source: \(Self.pdfManual), page 2, Figure 3").first)
        XCTAssertEqual(cited.chipLabel, "\(Self.pdfManual), page 2, Figure 3")
        XCTAssertEqual(CitationChipsView.spokenLabel(cited), "Open \(Self.pdfManual), page 2, Figure 3")
        XCTAssertEqual(CitationChipsView.spokenLabel(Citation(kind: .coreFile, title: "safety.md")),
                       "Open safety.md")
        // Nothing opens outside a session, so nothing is drawn.
        XCTAssertFalse(CitationOpener.none.canOpen(cited))
    }

    // MARK: - The core file behind a citation

    func testACoreFileIsCutAtItsSectionsSoACitationCanLandOnOne() {
        let file = """
        # Fault Codes

        Intro line.

        ## Acme RTU-500

        | Code | Meaning |
        |------|---------|
        | ZX9  | Low charge |

        ## Acme RTU-700

        Nothing here yet.
        """
        let parts = VaultFileSection.split(file)
        XCTAssertEqual(parts.count, 3)
        XCTAssertNil(parts[0].heading)
        XCTAssertEqual(parts[1].heading, "Acme RTU-500")
        XCTAssertTrue(parts[1].text.contains("ZX9"))
        XCTAssertEqual(parts[2].heading, "Acme RTU-700")
        XCTAssertEqual(VaultFileSection.split("").count, 0)
    }
}
