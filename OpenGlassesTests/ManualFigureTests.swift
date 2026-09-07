import PDFKit
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan EK P2 — the drawing reaches the model as a picture and the technician as a page.
///
/// The end-to-end cases install a vault holding a PDF whose pages carry real type (a prose page and
/// a wiring-diagram page) plus a text manual that cites a figure it has no page for, then drive the
/// shipped extractor, store, session, tool, attachment decision, renderer, presenter and lens cue.
/// No provider is called: the decision `LLMService` makes is the function tested here, and the
/// sheet's content is decided by `ManualFigurePresenter` without SwiftUI.
@MainActor
final class ManualFigureTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private static let vaultId = "manual_figure_test"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualFigureTests-\(UUID().uuidString)", isDirectory: true)
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

    /// A line of a fixture page: the words, their point size, and whether they are bold. Same shape
    /// as `ManualStructureTests`' builder — a PDF that carries type is the only fixture that
    /// exercises the diagram rule at all.
    private struct Line {
        let text: String
        let size: CGFloat
        let bold: Bool
        init(_ text: String, size: CGFloat = 10, bold: Bool = false) {
            self.text = text
            self.size = size
            self.bold = bold
        }
    }

    private func makeTypedPDF(at url: URL, pages: [[Line]]) {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 460, height: 700))
        let data = renderer.pdfData { context in
            for page in pages {
                context.beginPage()
                var y: CGFloat = 24
                for line in page {
                    let font = UIFont(name: line.bold ? "Helvetica-Bold" : "Helvetica", size: line.size)
                        ?? UIFont.systemFont(ofSize: line.size)
                    NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: UIColor.black])
                        .draw(at: CGPoint(x: 24, y: y))
                    y += line.size + 6
                }
            }
        }
        try? data.write(to: url)
    }

    /// Page 1 prose under bold headings; page 2 a drawing — a bold caption over labels set below
    /// body size, with no sentence in it.
    private var manualPages: [[Line]] {
        [[
            Line("Turning Off Gas to Unit", bold: true),
            Line("Close the manual gas valve upstream of the union before starting."),
            Line("Wait five minutes for any accumulated gas to clear the cabinet."),
            Line("Check the union for leaks with a soap solution once the gas is back on."),
            Line("The blower door must be closed for the unit to run at all."),
            Line("A hard lockout is cleared by cycling the thermostat or the power."),
            Line("Record the manifold pressure before and after any adjustment is made.")
        ], [
            Line("FIGURE 3", bold: true),
            Line("INTEGRATED CONTROL WIRING", bold: true),
            Line("W1 LOW STAGE HEAT", size: 8),
            Line("W2 HIGH STAGE HEAT", size: 8),
            Line("G FAN", size: 8),
            Line("Y1 LOW STAGE COOL", size: 8),
            Line("Y2 HIGH STAGE COOL", size: 8),
            Line("C THERMOSTAT COMMON", size: 8),
            Line("R 24VAC POWER", size: 8),
            Line("DS DEHUMIDIFICATION", size: 8),
            Line("O HEAT PUMP REVERSING VALVE", size: 8),
            Line("LGWP1 LOW GWP SENSOR ONE", size: 8),
            Line("HUM 120 VAC OUTPUT", size: 8),
            Line("1+ DATA HIGH CONNECTION", size: 8),
            Line("C 24VAXC COMMON", size: 8)
        ]]
    }

    /// The other route: a manual imported as extracted text. It cites a figure and has no page.
    /// The caption opens the page, because a chunk takes its figure from its first sentence (EK P1).
    private static let textManual = """
    Page 3

    ### Figure 9 — Integrated Control

    Terminal W951 drives the low stage heat relay and is the first thing to check on a no heat call.
    """

    private func makeStore() -> DocumentStore {
        let dir = tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DocumentStore(directory: dir)
    }

    /// Install a vault and start a session on it, with everything ingested. `withTextManual`
    /// adds the second route — a manual imported as extracted text, which cites a figure it has
    /// no page for; the staging cases leave it out so what a turn retrieves is unambiguous.
    private func startSession(store: DocumentStore, withTextManual: Bool = true) async throws -> FieldSessionService {
        let dir = tempRoot.appendingPathComponent("vault-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let docs = dir.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        var documents = [VaultDocument(file: "install.pdf", title: "Fixture Installation Instructions", kind: "install_guide")]
        if withTextManual {
            documents.append(VaultDocument(file: "notes.txt", title: "Fixture Field Notes", kind: "service_manual"))
        }
        let manifest = VaultManifest(id: Self.vaultId, name: "Figure Test", version: "1.0.0",
                                     files: ["safety.md"], proceduresDir: nil,
                                     documentsDir: "documents", documents: documents,
                                     gating: .init(iap: "enterprise"),
                                     promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "# Safety\n\nLock out power before opening any panel."
            .write(to: dir.appendingPathComponent("safety.md"), atomically: true, encoding: .utf8)
        makeTypedPDF(at: docs.appendingPathComponent("install.pdf"), pages: manualPages)
        if withTextManual {
            try Self.textManual.write(to: docs.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        }

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

    // MARK: - Staging

    func testATurnAboutTheDrawingStagesItAndAnUnrelatedTurnClearsIt() async throws {
        let store = makeStore()
        let service = try await startSession(store: store, withTextManual: false)

        // A terminal label reaches the drawing by exact-token search, which is the path a wiring
        // question actually takes (a bag of labels embeds to noise and is out of semantic search).
        let context = try XCTUnwrap(service.promptContext(turn: "what does 24VAXC connect to"))
        XCTAssertTrue(context.contains("wiring diagram, Figure 3"), context)
        let staged = try XCTUnwrap(service.stagedFigure, "a wiring question stages its drawing")
        XCTAssertEqual(staged.figure, "Figure 3")
        XCTAssertEqual(staged.page, 2)
        XCTAssertEqual(staged.documentTitle, "Fixture Installation Instructions")
        XCTAssertEqual(staged.sourceFile, "install.pdf")
        XCTAssertEqual(staged.citation, "Fixture Installation Instructions, page 2, Figure 3")
        XCTAssertTrue(staged.hasSourcePage)

        // A question whose evidence names no drawing clears it, so a stale wiring diagram is never
        // attached to an unrelated question.
        _ = service.promptContext(turn: "how long do I wait for the gas to clear the cabinet")
        XCTAssertNil(service.stagedFigure)
        // …but it stays reachable for "show that figure again".
        XCTAssertEqual(service.lastShownFigure?.figure, "Figure 3")
        XCTAssertEqual(service.restageLastFigure()?.figure, "Figure 3")
        XCTAssertEqual(service.stagedFigure?.figure, "Figure 3")
    }

    func testSourcePageResolvesForThePDFRouteAndNotForTheTextRoute() async throws {
        let store = makeStore()
        let service = try await startSession(store: store)

        _ = service.promptContext(turn: "what does 24VAXC connect to")
        let drawing = try XCTUnwrap(service.stagedFigure)
        let url = try XCTUnwrap(service.sourcePDFURL(for: drawing), "the PDF route resolves to its baseline page")
        XCTAssertEqual(url.lastPathComponent, "install.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 2)

        _ = service.promptContext(turn: "what is terminal W951 for")
        let cited = try XCTUnwrap(service.stagedFigure, "prose that names a figure stages it too")
        XCTAssertEqual(cited.figure, "Figure 9")
        XCTAssertEqual(cited.sourceFile, "notes.txt")
        XCTAssertFalse(cited.hasSourcePage)
        XCTAssertNil(service.sourcePDFURL(for: cited), "text has no page to open")

        // A document the manifest no longer lists resolves to nothing rather than to some other file.
        let orphan = FieldSessionService.StagedFigure(
            documentId: "gone", documentTitle: "Removed Manual", page: 4,
            figure: "Figure 1", sourceFile: "removed.pdf")
        XCTAssertNil(service.sourcePDFURL(for: orphan))
    }

    // MARK: - The tool

    func testTheToolStagesByFigureByPageAndAgain() async throws {
        let store = makeStore()
        let service = try await startSession(store: store)
        let tool = ManualFigureTool(documentStore: store, sessionService: service)

        // By label, in the form a technician says it: the bare number.
        let byNumber = try await tool.execute(args: ["figure": "3"])
        XCTAssertTrue(byNumber.contains("Fixture Installation Instructions, page 2, Figure 3"), byNumber)
        XCTAssertTrue(byNumber.contains("attached to your next turn as an image"), byNumber)
        XCTAssertEqual(service.stagedFigure?.figure, "Figure 3")

        // By printed page. The drawing on the page outranks anything else stored for it.
        service.stageFigure(nil)
        let byPage = try await tool.execute(args: ["page": 2])
        XCTAssertTrue(byPage.contains("page 2, Figure 3"), byPage)
        XCTAssertEqual(service.stagedFigure?.page, 2)

        // Again, after the turn moved on.
        service.stageFigure(nil)
        let again = try await tool.execute(args: ["again": true])
        XCTAssertTrue(again.contains("Figure 3"), again)
        XCTAssertEqual(service.stagedFigure?.figure, "Figure 3")

        // A figure the manuals do not print.
        let missing = try await tool.execute(args: ["figure": "Figure 404"])
        XCTAssertTrue(missing.contains("No Figure 404"), missing)
        let empty = try await tool.execute(args: [:])
        XCTAssertNil(empty.range(of: "Figure 3"),
                     "an empty call asks for a figure rather than repeating the last one")
    }

    func testTheToolSaysWhenTheDocumentHasNoPageToShow() async throws {
        let store = makeStore()
        let service = try await startSession(store: store)
        let tool = ManualFigureTool(documentStore: store, sessionService: service)

        let result = try await tool.execute(args: ["figure": "Figure 9"])
        XCTAssertTrue(result.contains("Fixture Field Notes, page 3, Figure 9"), result)
        XCTAssertTrue(result.contains("imported as text, so there is no page to show"), result)
        XCTAssertTrue(result.contains("import the PDF"), result)
    }

    func testTheToolNeedsASession() async throws {
        let store = makeStore()
        let idle = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("idle", isDirectory: true))
        let tool = ManualFigureTool(documentStore: store, sessionService: idle)
        let result = try await tool.execute(args: ["figure": "3"])
        XCTAssertTrue(result.contains("No active Field Assist session"), result)
        XCTAssertNil(idle.stagedFigure)
    }

    func testSpokenFigureRequestsResolveToCaptions() {
        XCTAssertEqual(ManualFigureTool.candidateLabels(for: "58"), ["Figure 58", "Table 58"])
        XCTAssertEqual(ManualFigureTool.candidateLabels(for: "figure 58"), ["Figure 58"])
        XCTAssertEqual(ManualFigureTool.candidateLabels(for: "Fig. 58"), ["Figure 58"])
        XCTAssertEqual(ManualFigureTool.candidateLabels(for: "table 16"), ["Table 16"])
        XCTAssertEqual(ManualFigureTool.candidateLabels(for: "the wiring one"), [])
    }

    // MARK: - The decision the LLM service makes

    func testTheImageSlotGoesToTheCameraFirstAndNeverToAnOnDeviceModel() async throws {
        let store = makeStore()
        let service = try await startSession(store: store)
        _ = service.promptContext(turn: "what does 24VAXC connect to")
        let staged = try XCTUnwrap(service.stagedFigure)
        let source = try XCTUnwrap(service.sourcePDFURL(for: staged))

        XCTAssertEqual(ManualFigureAttachment.decide(staged: nil, sourceURL: source,
                                                     hasCameraImage: false, isOnDevice: false),
                       .skip(.noFigure))
        XCTAssertEqual(ManualFigureAttachment.decide(staged: staged, sourceURL: source,
                                                     hasCameraImage: true, isOnDevice: false),
                       .skip(.cameraFrame), "a camera frame wins the single slot")
        XCTAssertEqual(ManualFigureAttachment.decide(staged: staged, sourceURL: source,
                                                     hasCameraImage: false, isOnDevice: true),
                       .skip(.onDevice), "an on-device model is never handed a rendered page")
        XCTAssertEqual(ManualFigureAttachment.decide(staged: staged, sourceURL: nil,
                                                     hasCameraImage: false, isOnDevice: false),
                       .skip(.noSourcePage))
        XCTAssertEqual(ManualFigureAttachment.decide(staged: staged, sourceURL: source,
                                                     hasCameraImage: false, isOnDevice: false),
                       .attach(source: source, page: 2))
    }

    func testAnAttachedPageRendersAndIsAnnouncedInThePrompt() async throws {
        let store = makeStore()
        let service = try await startSession(store: store)
        _ = service.promptContext(turn: "what does 24VAXC connect to")
        let staged = try XCTUnwrap(service.stagedFigure)
        let source = try XCTUnwrap(service.sourcePDFURL(for: staged))

        let renderedOrNil = await ManualFigureAttachment.render(source: source, page: staged.page)
        let rendered = try XCTUnwrap(renderedOrNil)
        XCTAssertGreaterThan(rendered.count, 1_000, "a rendered page is a real image")
        XCTAssertLessThanOrEqual(rendered.count, LLMImagePreparer.maxBytes, "bounded for the wire")
        let image = try XCTUnwrap(UIImage(data: rendered))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height),
                                 CGFloat(ManualFigureAttachment.maxPixels))
        XCTAssertFalse(LLMImagePreparer.isDegenerate(rendered))

        let line = ManualFigureAttachment.promptLine(for: staged)
        XCTAssertTrue(line.contains("Figure 3 (page 2) is attached as this turn's image"), line)
        XCTAssertTrue(line.contains(staged.citation), line)

        // A page the document does not have renders nothing rather than the nearest one.
        let nothing = await ManualFigureAttachment.render(source: source, page: 99)
        XCTAssertNil(nothing)
    }

    // MARK: - The sheet's content, and the audit line

    func testThePresenterOpensThePageAndRecordsThatItWasShown() async throws {
        let store = makeStore()
        let service = try await startSession(store: store)
        let session = try XCTUnwrap(service.activeSession)
        _ = service.promptContext(turn: "what does 24VAXC connect to")
        let drawing = try XCTUnwrap(service.stagedFigure)

        let shown = ManualFigurePresenter.present(drawing, session: service)
        XCTAssertTrue(shown.hasPicture)
        XCTAssertEqual(shown.citation, "Fixture Installation Instructions, page 2, Figure 3")
        guard case .page(let source, let pageIndex) = shown.content else {
            return XCTFail("expected a page, got \(shown.content)")
        }
        XCTAssertEqual(source.lastPathComponent, "install.pdf")
        XCTAssertEqual(pageIndex, 1, "PDFKit's index is zero-based; the citation's page is not")

        // The text route keeps the citation and says there is no page.
        _ = service.promptContext(turn: "what is terminal W951 for")
        let cited = try XCTUnwrap(service.stagedFigure)
        let unavailable = ManualFigurePresenter.present(cited, session: service)
        XCTAssertEqual(unavailable.content, .unavailable)
        XCTAssertFalse(unavailable.hasPicture)
        XCTAssertEqual(unavailable.citation, "Fixture Field Notes, page 3, Figure 9")

        let log = tempRoot.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(session.id, isDirectory: true)
            .appendingPathComponent("log.jsonl")
        let contents = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(contents.contains("figure_shown"), contents)
        XCTAssertTrue(contents.contains("Fixture Installation Instructions, page 2, Figure 3"), contents)
        XCTAssertTrue(contents.contains("\"as_picture\":true") || contents.contains("\"as_picture\" : true"), contents)
    }

    func testTheAuditLogRecordsThePageSentToTheModel() async throws {
        let store = makeStore()
        let service = try await startSession(store: store)
        let session = try XCTUnwrap(service.activeSession)
        _ = service.promptContext(turn: "what does 24VAXC connect to")
        let drawing = try XCTUnwrap(service.stagedFigure)

        service.logFigureSent(drawing)
        let log = tempRoot.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(session.id, isDirectory: true)
            .appendingPathComponent("log.jsonl")
        let contents = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(contents.contains("figure_sent"), contents)
        XCTAssertTrue(contents.contains("Figure 3"), contents)
    }

    // MARK: - The lens cue

    func testTheLensGetsOneLineSayingWhereTheDrawingIs() async {
        let staged = FieldSessionService.StagedFigure(
            documentId: "d", documentTitle: "SLP99UHVK Installation Instructions", page: 44,
            figure: "Figure 58", sourceFile: "install.pdf")
        XCTAssertEqual(ManualFigureCue.line(for: staged), "Figure 58, page 44, on your phone")
        XCTAssertEqual(ManualFigureCue.line(for: FieldSessionService.StagedFigure(
            documentId: "d", documentTitle: "M", page: 7)), "Drawing, page 7, on your phone")

        let saved = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(saved) }
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        var frames: [GlassesDisplayService.HUDFrame] = []
        display.testRenderSink = { frames.append($0) }

        ManualFigureCue.show(staged, on: display)
        let deadline = Date(timeIntervalSinceNow: 5)
        while frames.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(frames.first, .content(body: "Figure 58, page 44, on your phone",
                                              title: nil, icon: .info),
                       "\(frames)")
    }
}
