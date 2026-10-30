import PDFKit
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan IN P2 — "show me the page", "show me the relevant pages".
///
/// The partner's electrician hears a code answer with the phone in his pocket, takes it out and
/// says "show me the page". The right book has to open at the right page with the requirement
/// marked — with two code books loaded, never the wrong one.
@MainActor
final class ShowSourceTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private static let vaultId = "show_source_test"
    private static let bookA = "Code Book A"
    private static let bookB = "Code Book B"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShowSourceTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Memory, pure

    private func retrieved(_ title: String, page: Int, chunk: Int = 0, text: String = "x") -> AnswerSourceMemory.Retrieved {
        .init(documentId: title, documentName: title, chunkIndex: chunk, page: page, section: nil, text: text)
    }

    func testAnAnswerThatCitesBecomesWhatShowMeMeansAndOneThatCitesNothingLeavesIt() {
        var memory = AnswerSourceMemory()
        memory.noteAnswer([Citation(kind: .manual, title: "B", page: 2), Citation(kind: .manual, title: "A", page: 1)],
                          sessionId: "s")
        XCTAssertEqual(memory.citations.map(\.title), ["B", "A"])
        memory.noteAnswer([], sessionId: "s")
        XCTAssertEqual(memory.citations.map(\.title), ["B", "A"], "a follow-up that cited nothing changes nothing")
        memory.noteAnswer([Citation(kind: .coreFile, title: "error_codes.md")], sessionId: "s")
        XCTAssertEqual(memory.citations.map(\.title), ["B", "A"], "a core file is not a page to show")
        memory.noteAnswer([Citation(kind: .manual, title: "C", page: 9)], sessionId: "other session")
        XCTAssertEqual(memory.citations.map(\.title), ["C"], "a new job starts from nothing")
    }

    func testALookupStandsInForTheAnswerUntilAnAnswerCites() {
        var memory = AnswerSourceMemory()
        memory.noteLookup([retrieved("B", page: 2), retrieved("B", page: 2, chunk: 1), retrieved("A", page: 1)],
                          sessionId: "s")
        XCTAssertEqual(memory.citations.map(\.label), ["B, page 2", "A, page 1"], "one citation per page")
        memory.noteAnswer([Citation(kind: .manual, title: "A", page: 1)], sessionId: "s")
        XCTAssertEqual(memory.citations.map(\.label), ["A, page 1"])
        // The per-turn retrieval remembers passages but never says what was cited.
        memory.noteRetrieved([retrieved("Z", page: 4)], sessionId: "s")
        XCTAssertEqual(memory.citations.map(\.label), ["A, page 1"])
        XCTAssertEqual(memory.retrieved(for: Citation(kind: .manual, title: "B", page: 2)).map(\.chunkIndex), [0, 1])
    }

    func testWhichResolvesOrdinalsAllClausesAndDocuments() {
        var memory = AnswerSourceMemory()
        memory.noteRetrieved([retrieved("Code Book B", page: 2, text: "3.9.4 Underground wiring The minimum depth…")],
                             sessionId: "s")
        memory.noteAnswer([Citation(kind: .manual, title: "Code Book B", page: 2, section: "3.9.4 Underground wiring"),
                           Citation(kind: .manual, title: "Code Book A", page: 1),
                           Citation(kind: .manual, title: "Code Book B", page: 3)], sessionId: "s")
        func pages(_ which: String?, _ document: String? = nil) -> [String] {
            guard case .sources(let found) = ShowSourceResolver.resolve(which: which, document: document, memory: memory)
            else { return [] }
            return found.map { "\($0.number):\($0.citation.title.last!)\($0.citation.page!)" }
        }
        XCTAssertEqual(pages(nil), ["1:B2"])
        XCTAssertEqual(pages("the page"), ["1:B2"])
        XCTAssertEqual(pages("second"), ["2:A1"])
        XCTAssertEqual(pages("the third one"), ["3:B3"])
        XCTAssertEqual(pages("last"), ["3:B3"])
        XCTAssertEqual(pages("all"), ["1:B2", "2:A1", "3:B3"])
        XCTAssertEqual(pages("the relevant pages"), ["1:B2", "2:A1", "3:B3"])
        XCTAssertEqual(pages("clause 3.9.4"), ["1:B2"])
        XCTAssertEqual(pages("3.9.4"), ["1:B2"])
        XCTAssertEqual(pages("all", "book a"), ["2:A1"])
        if case .problem(let sentence) = ShowSourceResolver.resolve(which: "fourth", document: nil, memory: memory) {
            XCTAssertTrue(sentence.contains("cited 3 sources"))
            XCTAssertTrue(sentence.contains("Nothing was opened"))
        } else { XCTFail("no fourth source") }
        if case .problem(let sentence) = ShowSourceResolver.resolve(which: "clause 7.1.2", document: nil, memory: memory) {
            XCTAssertTrue(sentence.contains("did not cite clause 7.1.2"))
        } else { XCTFail("an uncited clause opens nothing") }
        if case .problem(let sentence) = ShowSourceResolver.resolve(which: nil, document: "Wiring Rules", memory: memory) {
            XCTAssertTrue(sentence.contains("did not cite a manual called"))
        } else { XCTFail("an uncited book opens nothing") }
        XCTAssertEqual(ShowSourceResolver.resolve(which: nil, document: nil, memory: AnswerSourceMemory()),
                       .problem("No answer in this job has cited a manual page yet, so there is no page to show. Search with manual_lookup first. Nothing was opened."))
    }

    func testAWaitingPageOpensWhenTheAppComesBackAndIsAnnounced() {
        let center = ShowSourceCenter()
        var announced: [String] = []
        center.announce = { announced.append($0) }
        center.isAppActive = { false }
        let page = FieldSessionService.StagedFigure(documentId: "d", documentTitle: "Code Book B", page: 2)
        XCTAssertFalse(center.present([page], notice: "Code Book B, page 2 — tap to open"))
        XCTAssertNil(center.presented, "nothing claims the page is showing")
        XCTAssertEqual(announced, ["Code Book B, page 2 — tap to open"])
        center.appBecameActive()
        XCTAssertEqual(center.presented?.pages, [page])
        XCTAssertEqual(ShowSourceCenter.noticeText(for: Citation(kind: .manual, title: "AS/NZS 3000", page: 112,
                                                                 section: "3.9.4.2")),
                       "AS/NZS 3000, page 112, §3.9.4.2 — tap to open")
    }

    func testAStandardOpensOnlyOnRequest() {
        XCTAssertTrue(StandardDocumentOpenPolicy.keepsToRequest(documentKind: "standard"))
        XCTAssertTrue(StandardDocumentOpenPolicy.keepsToRequest(documentKind: " Standard "))
        XCTAssertFalse(StandardDocumentOpenPolicy.keepsToRequest(documentKind: "service_manual"))
        XCTAssertFalse(StandardDocumentOpenPolicy.keepsToRequest(documentKind: nil),
                       "a manual keeps today's diagram auto-open")
    }

    // MARK: - Scripted session, two code books (exit test)

    private func makeStore() -> DocumentStore {
        let dir = tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DocumentStore(directory: dir)
    }

    private func startSession(store: DocumentStore) async throws -> (FieldSessionService, VaultManifest) {
        let dir = tempRoot.appendingPathComponent("vault", isDirectory: true)
        let docs = dir.appendingPathComponent("documents", isDirectory: true)
        try PassageFixtures.write(PassageFixtures.codeBook(pages: [
            ("5.6.2 Earthing arrangements", PassageFixtures.earthingSentence),
            ("5.6.3 Earth electrodes", "An earth electrode shall be driven to a depth of at least 1.2 m."),
            ("5.6.4 Main earthing conductor", "The main earthing conductor shall be continuous and unjointed."),
        ]), to: docs.appendingPathComponent("a.pdf"))
        try PassageFixtures.write(PassageFixtures.codeBook(pages: [
            ("3.9.2 Wiring systems", "Wiring systems shall be selected for the external influences present."),
            ("3.9.4 Underground wiring", PassageFixtures.depthSentence),
            ("3.9.5 Bonding", PassageFixtures.bondingSentence),
        ]), to: docs.appendingPathComponent("b.pdf"))
        let manifest = VaultManifest(
            id: Self.vaultId, name: "Show Source Test", version: "1.0.0",
            files: ["safety.md"], proceduresDir: nil, documentsDir: "documents",
            documents: [VaultDocument(file: "a.pdf", title: Self.bookA, kind: "standard"),
                        VaultDocument(file: "b.pdf", title: Self.bookB, kind: "standard")],
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
        return (service, installed)
    }

    /// Remember a page's passages as retrieved this session, the way a lookup for it would.
    private func retrieve(_ title: String, page: Int, store: DocumentStore, service: FieldSessionService) throws {
        let id = try XCTUnwrap(store.documents.first { $0.name == title }?.id)
        let passages = store.passages(onPage: page, documentIds: [id], limit: 8).map {
            VaultRetriever.Passage(documentId: $0.documentId, documentName: $0.documentName, chunkIndex: $0.chunkIndex,
                                   text: $0.text, page: $0.page, section: $0.section, similarity: 1, score: 1,
                                   matchedTokens: [])
        }
        service.sourceCenter.noteRetrieved(passages, sessionId: service.activeSession?.id)
    }

    private func marks(of staged: FieldSessionService.StagedFigure, service: FieldSessionService) throws -> PassageMarks {
        let url = try XCTUnwrap(service.sourcePDFURL(for: staged))
        let text = PDFDocument(url: url)?.page(at: staged.page - 1)?.string
        return PassageMarks(passages: staged.citedPassages, page: staged.page, pageText: text)
    }

    func testShowMeThePageOpensTheCitedBookAtTheCitedPageMarked() async throws {
        let store = makeStore()
        let (service, manifest) = try await startSession(store: store)

        // The question: a code lookup, then the answer citing book B's clause 3.9.4 first.
        let lookup = try await ManualLookupTool(documentStore: store, sessionService: service)
            .execute(args: ["query": "clause 3.9.4", "document": Self.bookB])
        XCTAssertTrue(lookup.contains(Self.bookB), lookup)
        try retrieve(Self.bookA, page: 1, store: store, service: service)
        try retrieve(Self.bookB, page: 3, store: store, service: service)
        service.recordAssistantReply("""
            The minimum depth of cover at a commercial site is 500 mm.
            Sources: \(Self.bookB), page 2, §3.9.4 Underground wiring; \(Self.bookA), page 1; \(Self.bookB), page 3
            """, sourceID: "turn-1")

        let tool = ShowSourceTool(documentStore: store, sessionService: service)
        let reply = try await tool.execute(args: ["which": "the page"])
        let shown = try XCTUnwrap(service.sourceCenter.presented?.pages)
        XCTAssertEqual(shown.map(\.documentTitle), [Self.bookB])
        XCTAssertEqual(shown.map(\.page), [2])
        XCTAssertEqual(shown.first?.origin, .requested)
        let pageMarks = try marks(of: shown[0], service: service)
        XCTAssertFalse(pageMarks.located.isEmpty, "the requirement is marked")
        let pdfText = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(service.sourcePDFURL(for: shown[0])))?.page(at: 1)?.string)
        let depth = try XCTUnwrap(PassageFixtures.expectedRange(of: PassageFixtures.depthSentence, in: pdfText))
        XCTAssertTrue(pageMarks.located.flatMap(\.location.ranges).contains {
            $0.location <= depth.location && NSMaxRange($0) >= NSMaxRange(depth)
        }, "the mark covers the clause's requirement")
        XCTAssertTrue(reply.contains("Showing \(Self.bookB), page 2"), reply)
        XCTAssertTrue(reply.contains("highlighted"), reply)

        // "Show me the relevant pages": all three, in the answer's order.
        _ = try await tool.execute(args: ["which": "all"])
        let all = try XCTUnwrap(service.sourceCenter.presented?.pages)
        XCTAssertEqual(all.map { "\($0.documentTitle) p\($0.page)" },
                       ["\(Self.bookB) p2", "\(Self.bookA) p1", "\(Self.bookB) p3"])
        XCTAssertTrue(all.allSatisfy { !$0.citedPassages.isEmpty })
        XCTAssertEqual(all.map { $0.citedPassages.first?.number }, [1, 2, 3])

        // A follow-up that cited nothing, then "the second one".
        service.recordAssistantReply("Anything else on this circuit?", sourceID: "turn-2")
        _ = try await tool.execute(args: ["which": "second"])
        XCTAssertEqual(service.sourceCenter.presented?.pages.map(\.documentTitle), [Self.bookA])

        // By clause number.
        _ = try await tool.execute(args: ["which": "show me clause 3.9.4"])
        XCTAssertEqual(service.sourceCenter.presented?.pages.map(\.page), [2])
        XCTAssertEqual(service.sourceCenter.presented?.pages.map(\.documentTitle), [Self.bookB])

        // A bare page number names no book: both books have a page 2, and nothing opens.
        let bare = try await ManualFigureTool(documentStore: store, sessionService: service,
                                              currentUtterance: { nil }).execute(args: ["page": 2])
        XCTAssertTrue(bare.contains("more than one manual"), bare)
        XCTAssertTrue(bare.contains("Nothing was opened"), bare)

        // Decision 1: both books are standards, so the automatic path leaves their pages closed.
        let bId = try XCTUnwrap(store.documents.first { $0.name == Self.bookB }?.id)
        XCTAssertEqual(StandardDocumentOpenPolicy.documentKind(of: bId, in: manifest), "standard")
    }

    func testALockedPhoneKeepsThePageAndSaysItIsOnThePhone() async throws {
        let store = makeStore()
        let (service, _) = try await startSession(store: store)
        var announced: [String] = []
        service.sourceCenter.isAppActive = { false }
        service.sourceCenter.announce = { announced.append($0) }
        _ = try await ManualLookupTool(documentStore: store, sessionService: service)
            .execute(args: ["query": "clause 3.9.4", "document": Self.bookB])

        let reply = try await ShowSourceTool(documentStore: store, sessionService: service)
            .execute(args: ["which": "first"])
        XCTAssertTrue(reply.contains("It's on your phone."), reply)
        XCTAssertTrue(reply.contains("Do not say the page is showing"), reply)
        XCTAssertFalse(reply.contains("Showing"), reply)
        XCTAssertNil(service.sourceCenter.presented)
        XCTAssertEqual(announced.count, 1)
        XCTAssertTrue(announced[0].hasPrefix(Self.bookB) && announced[0].hasSuffix("— tap to open"), announced[0])
        service.sourceCenter.appBecameActive()
        XCTAssertEqual(service.sourceCenter.presented?.pages.first?.documentTitle, Self.bookB)
    }

    // MARK: - A miss says what it is (Plan KE)

    /// The tester's job: a title the parser had built from a whole line read as a removed manual.
    func testASourceThatIsNotAManualPageIsNotCalledRemoved() async throws {
        let store = makeStore()
        let (service, _) = try await startSession(store: store)
        service.recordAssistantReply("Check the fan.\nSource: Acme Manual That Was Never Loaded, page 3", sourceID: "turn-1")

        let reply = try await ShowSourceTool(documentStore: store, sessionService: service).execute(args: ["which": "first"])

        XCTAssertFalse(reply.contains("no longer in this vault"), reply)
        XCTAssertTrue(reply.contains("not a manual page"), reply)
        XCTAssertTrue(reply.contains("manual_lookup"), reply)
        XCTAssertTrue(reply.contains("Nothing was opened."), reply)
        XCTAssertNil(service.sourceCenter.presented)
    }

    /// A core file never joins what "show me" can open, so it stops earlier, with its own sentence.
    func testACoreFileIsNotCalledRemoved() async throws {
        let store = makeStore()
        let (service, _) = try await startSession(store: store)
        service.recordAssistantReply("Isolate first.\nSource: safety.md", sourceID: "turn-1")

        let reply = try await ShowSourceTool(documentStore: store, sessionService: service).execute(args: ["which": "first"])

        XCTAssertFalse(reply.contains("no longer in this vault"), reply)
        XCTAssertTrue(reply.contains("manual_lookup"), reply)
        guard case .unknown = service.resolveCitation(Citation(kind: .coreFile, title: "safety.md")) else {
            return XCTFail("a core file is not a manual page, and not a removed one")
        }
    }

    func testACitationWithOnlyAPrintedPageCanStillBeOpened() {
        var memory = AnswerSourceMemory()
        memory.noteAnswer(CitationLineParser.parse("Source: Acme Manual, printed page 2-6"), sessionId: "s")
        XCTAssertEqual(memory.citations.map(\.printedPage), ["2-6"])
    }

    func testOnlyARemovedManualIsCalledRemoved() {
        XCTAssertEqual(ShowSourceTool.nothingOpened(removed: ["Acme Manual, page 3"], notPages: []),
                       "The cited manual is no longer in this vault (Acme Manual, page 3). Nothing was opened.")
        let notPage = ShowSourceTool.nothingOpened(removed: [], notPages: ["Acme Manual, page 3"])
        XCTAssertFalse(notPage.contains("no longer"), notPage)
        let two = ShowSourceTool.nothingOpened(removed: [], notPages: ["a.md", "b.md"])
        XCTAssertTrue(two.contains("Those sources (a.md; b.md) are not manual pages"), two)
    }

    func testAReplyThatOpenedSomethingSaysEachMissForWhatItIs() {
        let staged = FieldSessionService.StagedFigure(documentId: "d", documentTitle: "Acme Manual", page: 3)
        let reply = ShowSourceTool.reply(pages: [staged], marks: [.noPassage], onScreen: true,
                                         removed: ["Acme Old Manual, page 2"], notPages: ["safety.md"])
        XCTAssertTrue(reply.contains("Not opened, because the manual is no longer in this vault: Acme Old Manual, page 2."), reply)
        XCTAssertTrue(reply.contains("Not opened: That source (safety.md) is not a manual page"), reply)
        XCTAssertFalse(reply.contains("no longer in this vault: safety.md"), reply)
    }

    /// A tapped citation that wrote "PDF page" opens that page, not page 1.
    func testAPDFPageCitationOpensThatPage() async throws {
        let store = makeStore()
        let (service, _) = try await startSession(store: store)
        let cited = try XCTUnwrap(CitationLineParser.parse("Source: \(Self.bookB), PDF page 2 (printed page 1-2), Step 4").first)
        guard case .figure(let staged) = service.resolveCitation(cited) else { return XCTFail("the manual is loaded") }
        XCTAssertEqual(staged.page, 2)
    }

    func testNothingCitedYetOpensNothing() async throws {
        let store = makeStore()
        let (service, _) = try await startSession(store: store)
        let reply = try await ShowSourceTool(documentStore: store, sessionService: service).execute(args: [:])
        XCTAssertTrue(reply.contains("Nothing was opened"), reply)
        XCTAssertNil(service.sourceCenter.presented)
    }

    // MARK: - A table cited without a lookup (Plan JW P1a)

    private func row(_ name: String, values: String, chunk: Int, table: String = "Table 99") -> AnswerSourceMemory.Retrieved {
        var passage = retrieved(Self.bookA, page: 4, chunk: chunk,
                                text: "\(table) (Sample ratings), row \(name): \(values) \u{2014} page 4")
        passage.figure = table
        passage.isTableRow = true
        return passage
    }

    func testATableCitedWithoutALookupMarksOnlyThatTablesRows() {
        var memory = AnswerSourceMemory()
        let qx = row("QX", values: "41 in Group A, 47 in Group B", chunk: 10)
        let qz = row("QZ", values: "52 in Group A, 58 in Group B", chunk: 11)
        let otherTable = row("QX", values: "3 in Group C", chunk: 12, table: "Table 98")
        let prose = retrieved(Self.bookA, page: 4, chunk: 2, text: "Notes printed beside the grid.")
        memory.noteRetrieved([qx, qz, otherTable, prose], sessionId: "s")
        let cite = Citation(kind: .manual, title: Self.bookA, page: 4, figure: "Table 99")

        // The answer's words name no row: the rows of the cited table the turn retrieved, nothing else.
        memory.noteAnswer([cite], text: "Both groups are listed there.", sessionId: "s")
        XCTAssertEqual(memory.marking(cite).passages, [qx, qz])
        XCTAssertEqual(memory.marking(cite).basis, .retrievedTableRows)

        // The answer names a row and a value from it: that row.
        memory.noteAnswer([cite], text: "Row QX gives 47 in Group B.", sessionId: "s")
        XCTAssertEqual(memory.marking(cite).passages, [qx])
        XCTAssertEqual(memory.marking(cite).basis, .answerRows)

        // A citation that names only the page still means the page.
        XCTAssertEqual(memory.retrieved(for: Citation(kind: .manual, title: Self.bookA, page: 4)).count, 4)

        // A lookup's rows win.
        memory.noteTableLookup(rows: [qz], citations: [cite], sessionId: "s")
        XCTAssertEqual(memory.marking(cite).passages, [qz])
        XCTAssertEqual(memory.marking(cite).basis, .lookupRows)
    }

    func testATableCitedWithNoRowsRetrievedMarksNothingElseOnThePage() {
        var memory = AnswerSourceMemory()
        memory.noteRetrieved([retrieved(Self.bookA, page: 4, chunk: 2, text: "Notes printed beside the grid.")],
                             sessionId: "s")
        let cite = Citation(kind: .manual, title: Self.bookA, page: 4, figure: "Table 99")
        XCTAssertEqual(memory.retrieved(for: cite), [])
    }

    func testARowPassageGivesBackItsValues() {
        XCTAssertEqual(TableRowPassage.values(ofSentence: "Table 99 (Sample ratings), row QX, two runs: 41 in Group A, "
                                              + "47 in Group B \u{2014} page 4"), ["41", "47"])
        XCTAssertEqual(TableRowPassage.values(ofSentence: "A sentence with no row in it."), [])
        XCTAssertTrue(AnswerSourceMemory.answer("For QX, two runs, use 41.",
                                                readsRow: "Table 99 (Sample ratings), row QX, two runs: 41 in Group A \u{2014} page 4"))
        XCTAssertFalse(AnswerSourceMemory.answer("For QX use 52.",
                                                 readsRow: "Table 99 (Sample ratings), row QX: 41 in Group A \u{2014} page 4"),
                       "a value from another row")
    }

    func testOnlyPassagesFoundOnThePageAreStaged() {
        let pageText = "Example heading\nThe first sentence printed here is long enough to find.\nMore text follows it.\n"
        let found = CitedPassage(number: 1, anchor: PassageAnchor(
            documentId: "d", chunkIndex: 1, text: "The first sentence printed here is long enough to find.", page: 4))
        let missing = CitedPassage(number: 1, anchor: PassageAnchor(
            documentId: "d", chunkIndex: 2, text: "A sentence that is printed nowhere on this page at all.", page: 4))
        let checked = ShowSourceTool.check([found, missing], page: 4, pageText: pageText)
        XCTAssertEqual(checked.state, .marked)
        XCTAssertEqual(checked.kept, [found], "the sheet is not told about a passage it cannot mark")
        XCTAssertEqual(checked.unmarkedText, 1)
        let none = ShowSourceTool.check([missing], page: 4, pageText: pageText)
        XCTAssertEqual(none.state, .unmarked)
        XCTAssertEqual(none.kept, [missing], "with nothing found the page still says so")

        let staged = FieldSessionService.StagedFigure(documentId: "d", documentTitle: Self.bookA, page: 4,
                                                      figure: "Table 99")
        let reply = ShowSourceTool.reply(pages: [staged], marks: [.marked], onScreen: true, removed: [],
                                         unmarkedPassages: 1)
        XCTAssertTrue(reply.contains("1 other passage the answer drew on couldn't be marked"), reply)
        let rows = ShowSourceTool.RowMarks(marked: ["QX", "QZ"], unmarked: [])
        let fallback = ShowSourceTool.reply(pages: [staged], marks: [.marked], rows: rows, onScreen: true,
                                            removed: [], retrievedRowsOf: ["Table 99"])
        XCTAssertTrue(fallback.contains("rows of Table 99 retrieved for the answer"), fallback)
        XCTAssertTrue(fallback.contains("table_lookup (table, row, column)"), fallback)
    }

    func testTheTurnsPassagesAskForTableValuesThroughTheLookup() {
        func passage(_ kind: DocumentChunker.Kind) -> VaultRetriever.Passage {
            .init(documentId: "d", documentName: Self.bookA, chunkIndex: 1,
                  text: "Table 99 (Sample ratings), row QX: 41 in Group A \u{2014} page 4", page: 4, section: nil,
                  similarity: 0.9, score: 0.9, matchedTokens: [], kind: kind, figure: "Table 99")
        }
        XCTAssertTrue(VaultRetriever.promptBlock(.sufficient([passage(.tableRow)])).contains(VaultRetriever.tableRowRule))
        XCTAssertTrue(VaultRetriever.toolResult(.sufficient([passage(.tableRow)]), query: "q")
            .contains(VaultRetriever.tableRowRule))
        XCTAssertFalse(VaultRetriever.promptBlock(.sufficient([passage(.prose)])).contains(VaultRetriever.tableRowRule))
    }
}
