import Combine
import PDFKit
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan KR P1 — one page per turn, said pages read in words, a show-me that names nothing.
/// Pure: every case is words in, a decision or a number out.
@MainActor
final class KRPagePerTurnTests: XCTestCase {

    // MARK: - Pages said in words

    func testAPageSaidInWordsIsAPage() {
        XCTAssertEqual(PageReference.pages(in: "go to page three ninety-nine"), [399])
        XCTAssertEqual(PageReference.pages(in: "open page three hundred and ninety-nine please"), [399])
        XCTAssertEqual(PageReference.pages(in: "page four oh five of the code book"), [405])
        XCTAssertEqual(PageReference.pages(in: "show me page twelve"), [12])
        XCTAssertEqual(PageReference.pages(in: "turn to page one hundred"), [100])
        XCTAssertEqual(PageReference.pages(in: "page twenty one, the wiring"), [21])
        XCTAssertEqual(PageReference.pages(in: "printed page three twelve"), [312])
        XCTAssertEqual(PageReference.pages(in: "pages twelve to fourteen"), [12, 13, 14])
        XCTAssertEqual(PageReference.pages(in: "pages twelve and twenty"), [12, 20])
        XCTAssertEqual(PageReference.pages(in: "page number seven"), [7])
        XCTAssertEqual(PageReference.pages(in: "page 34 and then page nine"), [34, 9], "digits and words together")
    }

    func testNumbersThatAreNotPagesAreLeftAlone() {
        XCTAssertEqual(PageReference.pages(in: "three wires on the terminal"), [])
        XCTAssertEqual(PageReference.pages(in: "show me the page"), [])
        XCTAssertEqual(PageReference.pages(in: "which page"), [])
        XCTAssertEqual(PageReference.pages(in: "the page has three wires"), [], "a number after other words is no page")
        XCTAssertEqual(PageReference.pages(in: "page twelve, two wires loose"), [12], "a comma does not join pages")
        XCTAssertEqual(PageReference.pages(in: "page nothing"), [])
    }

    func testThePageWordsAreBlankedOutAndEverythingElseStays() {
        let removed = PageReference.removingReferences(from: "check page three ninety-nine for the QXRT rating")
        XCTAssertFalse(removed.contains("three") || removed.contains("ninety"), removed)
        XCTAssertTrue(removed.contains("check page") && removed.contains("for the QXRT rating"), removed)
        let both = PageReference.removingReferences(from: "page 34 and page four oh five")
        XCTAssertFalse(both.contains("34") || both.contains("four") || both.contains("five"), both)
        XCTAssertTrue(both.contains("and page"), both)
    }

    func testSpokenNumbersReadTheirDigitGroupsOnlyWhenAsked() {
        XCTAssertEqual(SpokenNumber.whole("three ninety-nine"), 399)
        XCTAssertEqual(SpokenNumber.whole("four oh five"), 405)
        XCTAssertEqual(SpokenNumber.whole("one hundred and two"), 102)
        XCTAssertEqual(SpokenNumber.whole("twenty one"), 21)
        XCTAssertNil(SpokenNumber.whole("three wires"))
        XCTAssertEqual(SpokenNumber.whole("three ninety-nine", digitGroups: false), nil,
                       "without groups the second word is not part of the number")
        // A table keeps reading as it did: "table three two" is Table 3.
        XCTAssertEqual(TableReference.labels(in: "table three two"), ["Table 3"])
        XCTAssertEqual(TableReference.labels(in: "table ninety-nine"), ["Table 99"])
        XCTAssertEqual(TableReference.labels(in: "table one hundred and two"), ["Table 102"])
    }

    func testAPrintedPageSaidInWordsIsItsNumber() {
        XCTAssertEqual(ManualFigureTool.printedPage(in: "open printed page three ninety-nine"), "399")
        XCTAssertEqual(ManualFigureTool.printedPage(in: "printed page twelve"), "12")
        XCTAssertEqual(ManualFigureTool.printedPage(in: "printed page iv"), "iv", "a roman page stays as printed")
        XCTAssertEqual(ManualFigureTool.printedPage(in: "printed page A-3"), "A-3")
        XCTAssertEqual(ManualFigureTool.printedPage(in: "printed page 57"), "57")
    }

    // MARK: - A named page opens nothing by itself

    func testATurnThatNamesAPageInWordsPutsNothingOnThePhone() {
        typealias P = FigureAutoOpenPolicy
        let named = PageReference.pages(in: "go to printed page three ninety-nine")
        XCTAssertEqual(ManualTurnClassifier.classify("go to printed page three ninety-nine"), .showMe)
        XCTAssertEqual(P.decide(turnKind: .showMe, passageKind: .captioned, tokenHits: [],
                                namedPages: named, passagePage: 17),
                       .none(reason: .otherPageNamed), "the search's page is not the page asked for")
        XCTAssertEqual(P.decide(turnKind: .showMe, passageKind: .diagram, tokenHits: [],
                                namedPages: named, passagePage: 399),
                       .attachToModelOnly(reason: .pageNamed), "even on that page: it is manual_figure's to open")
        XCTAssertEqual(P.decide(turnKind: .question, passageKind: .diagram, tokenHits: ["24VAXC"],
                                namedPages: [5], passagePage: 5),
                       .attachToModelOnly(reason: .pageNamed))
        XCTAssertEqual(P.decide(turnKind: .showMe, passageKind: .diagram, tokenHits: []),
                       .present(reason: .askedForPage), "no page named: a show-me still opens what it found")
    }

    // MARK: - A show-me with no object

    func testAShowMeThatNamesNothingHasNoObject() {
        for turn in ["show me", "Show me the", "show me that.", "show me it", "show me this", "um, show me the…",
                     "can you show me that again please", "can I see it"] {
            XCTAssertTrue(ManualTurnClassifier.hasNoObject(turn), turn)
        }
        for turn in ["show me the table", "show me the wiring diagram", "show me page 12", "show me figure 3",
                     "show me the second one", "what does it say", "the", "that's it"] {
            XCTAssertFalse(ManualTurnClassifier.hasNoObject(turn), turn)
        }
    }

    // MARK: - A table looked up this turn

    func testATableLookedUpThisTurnIsTheOnlyLabelThatOpens() {
        typealias G = RetrievedFigureLabelGate
        let present = FigureAutoOpenPolicy.Decision.present(reason: .askedForPage)
        XCTAssertEqual(G.apply(present, passageKind: .tableRow, passageLabel: "Table 99", namedLabels: [],
                               lookedUpThisTurn: ["Table 98"]),
                       .none(reason: .otherLabelLookedUp))
        XCTAssertEqual(G.apply(present, passageKind: .tableRow, passageLabel: "table 98", namedLabels: [],
                               lookedUpThisTurn: ["Table 98"]),
                       present, "the table looked up still opens")
        XCTAssertEqual(G.apply(present, passageKind: .diagram, passageLabel: nil, namedLabels: [],
                               lookedUpThisTurn: ["Table 98"]),
                       .none(reason: .otherLabelLookedUp), "nor a drawing over it")
        XCTAssertEqual(G.apply(present, passageKind: .tableRow, passageLabel: "Table 99", namedLabels: [],
                               lookedUpLabels: ["Table 98"]),
                       present, "a lookup in an earlier turn does not narrow what a show-me opens")
        let attach = FigureAutoOpenPolicy.Decision.attachToModelOnly(reason: .tableNotAskedFor)
        XCTAssertEqual(G.apply(attach, passageKind: .tableRow, passageLabel: "Table 98", namedLabels: [],
                               lookedUpLabels: ["Table 98"], lookedUpThisTurn: ["Table 98"]),
                       .attachToModelOnly(reason: .labelAsked), "the model-only rules are unchanged")
    }

    func testTheLookedUpTableIsNamedByLabelWordsOrNumber() {
        XCTAssertTrue(ManualFigureTool.namesTable("Table 99", "Table 99"))
        XCTAssertTrue(ManualFigureTool.namesTable("table ninety-nine", "Table 99"))
        XCTAssertTrue(ManualFigureTool.namesTable("99", "Table 99"))
        XCTAssertFalse(ManualFigureTool.namesTable("Table 98", "Table 99"))
        XCTAssertFalse(ManualFigureTool.namesTable("Figure 3", "Table 99"))
    }
}

/// Plan KR P1 and P2 over a session: a lookup's table stays up, "show me the" reopens it, and
/// `manual_figure` asked for it marks the rows `show_source` marks. Invented tables and pages.
@MainActor
final class KRPagePerTurnSessionTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private static let vaultId = "kr_page_per_turn_test"
    private static let bookA = "Example Book A"
    private static let bookB = "Example Book B"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("KRPagePerTurnSessionTests-\(UUID().uuidString)", isDirectory: true)
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

    /// Book A: prose, Table 99 (printed 12), Table 98, Table 92. Book B: Table 99 (printed 30).
    private func startSession() async throws -> (FieldSessionService, DocumentStore) {
        let storeDir = tempRoot.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = DocumentStore(directory: storeDir)
        let dir = tempRoot.appendingPathComponent("vault", isDirectory: true)
        let docs = dir.appendingPathComponent("documents", isDirectory: true)
        _ = try TableFixtures.write(TableFixtures.pdf([TableFixtures.prosePage(), TableFixtureLayouts.simpleGrid(printed: "12"),
                                                       TableFixtureLayouts.twoLevelHeader(),
                                                       TableFixtureLayouts.captionOverProse()]),
                                    named: "a.pdf", in: docs)
        _ = try TableFixtures.write(TableFixtures.pdf([TableFixtureLayouts.simpleGrid(printed: "30", offset: 100)]),
                                    named: "b.pdf", in: docs)
        let manifest = VaultManifest(
            id: Self.vaultId, name: "KR Test", version: "1.0.0",
            files: ["safety.md"], proceduresDir: nil, documentsDir: "documents",
            documents: [VaultDocument(file: "a.pdf", title: Self.bookA), VaultDocument(file: "b.pdf", title: Self.bookB)],
            gating: .init(iap: "enterprise"), promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "# Safety\n\nIsolate before work.".write(to: dir.appendingPathComponent("safety.md"),
                                                     atomically: true, encoding: .utf8)
        let installed = try VaultImporter.install(from: dir)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        _ = try await VaultImporter.syncDocuments(manifest: installed, into: store)

        let service = FieldSessionService(sessionsRoot: tempRoot.appendingPathComponent("sessions", isDirectory: true))
        service.documentStore = store
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        service.sourceCenter = ShowSourceCenter()
        service.sourceCenter.isAppActive = { true }
        service.sourceCenter.announce = { _ in }
        _ = try service.startSession(vaultId: installed.id, assetId: nil)
        return (service, store)
    }

    private func lookupTable99(_ service: FieldSessionService, _ store: DocumentStore) async throws {
        let reply = try await TableLookupTool(documentStore: store, sessionService: service, currentUtterance: { nil })
            .execute(args: ["table": "Table 99", "row": "QXRT three conductors", "column": "rating group 2",
                            "document": "book b"])
        XCTAssertTrue(reply.contains("\"135\""), reply)
    }

    private func figureTool(_ service: FieldSessionService, _ store: DocumentStore,
                            said: String? = nil) -> ManualFigureTool {
        ManualFigureTool(documentStore: store, sessionService: service, currentUtterance: { said })
    }

    /// What the phone shows, in order: the figure sheet's pages and `show_source`'s sheets.
    @MainActor
    private final class PhoneTimeline {
        var shown: [String] = []
        var tokens: [AnyCancellable] = []
        init(_ service: FieldSessionService) {
            service.$stagedFigure.compactMap { $0 }.filter(\.presentOnPhone)
                .sink { [unowned self] in self.shown.append("\($0.documentTitle) p\($0.page)") }.store(in: &tokens)
            service.sourceCenter.$presented.compactMap { $0 }
                .sink { [unowned self] in self.shown.append($0.pages.map { "\($0.documentTitle) p\($0.page)" }.joined(separator: "|")) }
                .store(in: &tokens)
        }
    }

    /// Finding 1, the table half: the reply named the looked-up table while tool rounds re-presented
    /// another the search had found. The lookup's table, once shown, stays.
    func testALookupsTableStaysOverARetrievedOne() async throws {
        let (service, store) = try await startSession()
        let phone = PhoneTimeline(service)
        let turn = "show me the conductor ratings table for QXRT three conductors"
        service.turnSourceID = "turn-1"
        _ = service.promptContext(turn: turn)
        let firstBuild = phone.shown

        try await lookupTable99(service, store)
        _ = try await ShowSourceTool(documentStore: store, sessionService: service, currentUtterance: { nil })
            .execute(args: ["which": "the table"])
        XCTAssertEqual(phone.shown.last, "\(Self.bookB) p1")
        let staged = service.stagedFigure
        for _ in 0..<3 { _ = service.promptContext(turn: turn, stagesFigure: false) }
        _ = service.promptContext(turn: turn)
        XCTAssertEqual(phone.shown, firstBuild + ["\(Self.bookB) p1"], "nothing went up over the lookup's table")
        XCTAssertEqual(service.stagedFigure, staged)
        XCTAssertEqual(service.lookedUpThisTurn, ["Table 99"])

        service.turnSourceID = "turn-2"
        XCTAssertEqual(service.lookedUpThisTurn, [], "a lookup belongs to its turn")
        XCTAssertFalse(service.toolPutUpPageThisTurn)
    }

    /// Finding 4: within a turn whose lookup read one table, a show-me's retrieved page under
    /// another label does not open.
    func testAShowMeAfterALookupThisTurnOpensNoOtherTable() async throws {
        let (service, store) = try await startSession()
        let turn = "show me the table for QXRT three conductors"
        // Without a lookup, the turn's search opens its table.
        service.turnSourceID = "turn-0"
        _ = service.promptContext(turn: turn)
        XCTAssertEqual(service.stagedFigure?.presentOnPhone, true)
        XCTAssertEqual(service.stagedFigure?.figure, "Table 99")

        service.turnSourceID = "turn-1"
        service.stageFigure(nil)
        _ = try await TableLookupTool(documentStore: store, sessionService: service, currentUtterance: { nil })
            .execute(args: ["table": "Table 98", "row": "14", "column": "rating group 1 band a"])
        XCTAssertEqual(service.lookedUpThisTurn, ["Table 98"])
        // A build after the lookup in the same turn (a retried request) opens no other table.
        _ = service.promptContext(turn: turn)
        XCTAssertNotEqual(service.stagedFigure?.presentOnPhone, true, "only the table read this turn may open")
    }

    /// Finding 3: "show me the", cut off, after a lookup. The lookup's table opens, its row marked —
    /// the search's guess never does — and with nothing to reopen nothing opens.
    func testACutOffShowMeReopensTheLookupsTable() async throws {
        let (service, store) = try await startSession()
        service.turnSourceID = "turn-1"
        try await lookupTable99(service, store)

        service.turnSourceID = "turn-2"
        let block = try XCTUnwrap(service.promptContext(turn: "show me the"))
        let pages = try XCTUnwrap(service.sourceCenter.presented?.pages)
        XCTAssertEqual(pages.map(\.documentTitle), [Self.bookB])
        XCTAssertEqual(pages.map(\.page), [1])
        XCTAssertEqual(pages.first?.citedPassages.count, 1, "the row the lookup read")
        XCTAssertEqual(service.stagedFigure?.presentOnPhone, false, "the model gets the page; the sheet is show_source's")
        XCTAssertTrue(block.contains("SHOW ME") && block.contains("highlighted"), block)
    }

    /// Finding 5: `manual_figure` asked for the looked-up table marks the same rows `show_source`
    /// marks, and says which page opened, PDF and printed.
    func testManualFigureAfterALookupMarksTheRowsShowSourceMarks() async throws {
        let (service, store) = try await startSession()
        service.turnSourceID = "turn-1"
        try await lookupTable99(service, store)

        _ = try await ShowSourceTool(documentStore: store, sessionService: service, currentUtterance: { nil })
            .execute(args: ["which": "Table 99"])
        let bySource = try XCTUnwrap(service.sourceCenter.presented?.pages)
        XCTAssertEqual(bySource.first?.citedPassages.count, 1)

        service.turnSourceID = "turn-2"
        let reply = try await figureTool(service, store).execute(args: ["figure": "Table 99"])
        let byFigure = try XCTUnwrap(service.sourceCenter.presented?.pages)
        XCTAssertEqual(byFigure.map(\.documentId), bySource.map(\.documentId))
        XCTAssertEqual(byFigure.map(\.page), bySource.map(\.page))
        XCTAssertEqual(byFigure.map(\.citedPassages), bySource.map(\.citedPassages), "the same rows marked")
        XCTAssertTrue(reply.contains("highlighted"), reply)
        XCTAssertTrue(reply.contains("Opened PDF page 1 (printed page 30) of \(Self.bookB)"), reply)
        XCTAssertEqual(service.stagedFigure?.presentOnPhone, false)
        XCTAssertEqual(service.stagedFigure?.page, 1)

        // Nothing named, the turn right after the lookup's: the same table, marked.
        let bare = try await figureTool(service, store).execute(args: [:])
        XCTAssertTrue(bare.contains("highlighted"), bare)

        // Another table by number is a plain page, as before.
        let other = try await figureTool(service, store).execute(args: ["figure": "Table 98"])
        XCTAssertFalse(other.contains("highlighted"), other)
        XCTAssertTrue(other.contains("Table 98"), other)

        // Two turns on, nothing named asks for a figure again.
        service.turnSourceID = "turn-3"
        service.turnSourceID = "turn-4"
        let late = try await figureTool(service, store).execute(args: [:])
        XCTAssertFalse(late.contains("highlighted"), late)
    }

    /// 'again' after a lookup newer than the last page shown brings back the table, marked.
    func testAgainAfterALookupBringsBackTheTableMarked() async throws {
        let (service, store) = try await startSession()
        service.turnSourceID = "turn-1"
        _ = try await figureTool(service, store).execute(args: ["figure": "Table 98"])
        XCTAssertEqual(service.lastShownFigure?.figure, "Table 98")
        try await lookupTable99(service, store)

        service.turnSourceID = "turn-2"
        let again = try await figureTool(service, store).execute(args: ["again": true])
        XCTAssertTrue(again.contains("highlighted"), again)
        XCTAssertEqual(service.sourceCenter.presented?.pages.map(\.documentTitle), [Self.bookB])

        // Shown since: 'again' is the page last shown, as it always was.
        service.turnSourceID = "turn-3"
        let shownAgain = try await figureTool(service, store).execute(args: ["again": true])
        XCTAssertTrue(shownAgain.hasPrefix("Back to"), shownAgain)
        XCTAssertEqual(service.stagedFigure?.figure, "Table 99")
    }

    /// A printed page said in words opens through the printed page numbers.
    func testAPrintedPageSaidInWordsOpensThatPrintedPage() async throws {
        let (service, store) = try await startSession()
        let reply = try await figureTool(service, store, said: "open printed page thirty of book b")
            .execute(args: ["page": 30])
        XCTAssertTrue(reply.contains("Opened PDF page 1 (printed page 30) of \(Self.bookB)"), reply)
        XCTAssertEqual(service.stagedFigure?.page, 1)
        let spoken = try await figureTool(service, store).execute(args: ["printed_page": "twelve"])
        XCTAssertTrue(spoken.contains("Opened PDF page 2 (printed page 12) of \(Self.bookA)"), spoken)
    }
}
