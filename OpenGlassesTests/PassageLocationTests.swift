import PDFKit
import SQLite3
import XCTest
@testable import OpenGlasses

/// Plan IN P0 — where a cited passage is on its page.
///
/// The partner's electrician wants the exact supporting passage marked, so he reads the requirement
/// instead of the whole page. A wrong mark would be read as the requirement, so these tests hold
/// the locator to exact ranges on fixture pages shaped like a code book, a named `.notLocatable` on
/// a scanned page, and the printed/physical page mapping on roman-numeral front matter.
@MainActor
final class PassageLocationTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassageLocationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func fixture(_ data: Data, named name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try PassageFixtures.write(data, to: url)
        return url
    }

    private func pageText(_ url: URL, page: Int) throws -> String? {
        try XCTUnwrap(PDFDocument(url: url)?.page(at: page - 1)).string
    }

    // MARK: - The chunker records where a chunk sits

    func testChunksCarryTheirSentenceStartsAndTheirSpanOnThePage() throws {
        let page1 = "First sentence on page one. Second sentence on page one."
        let page2 = "Only sentence on page two is right here."
        let chunks = DocumentChunker(targetChars: 60, maxChars: 80, overlapChars: 0)
            .chunk(page1 + "\u{0C}" + page2)
        let first = try XCTUnwrap(chunks.first)
        XCTAssertEqual(first.page, 1)
        XCTAssertEqual(first.pageStart, 0)
        XCTAssertEqual(first.sentenceStarts.first, 0)
        for (chunk, start) in chunks.flatMap({ c in c.sentenceStarts.map { (c, $0) } }) {
            XCTAssertLessThan(start, chunk.text.count)
        }
        let onTwo = try XCTUnwrap(chunks.first { $0.page == 2 })
        XCTAssertEqual(onTwo.pageStart, 0, "the span is measured from the page's own start, not the document's")
        XCTAssertEqual(onTwo.pageEnd, page2.count)
        // The stored sentences split back into the sentences the chunker packed.
        let anchor = PassageAnchor(documentId: "d", chunkIndex: onTwo.index, text: onTwo.text, page: 2,
                                   sentenceStarts: onTwo.sentenceStarts)
        XCTAssertEqual(anchor.sentences, [page2])
        XCTAssertEqual(PassageAnchor.decode(PassageAnchor.encode([0, 112, 240])), [0, 112, 240])
    }

    // MARK: - The locator, pure

    func testFoldingIgnoresLineBreaksHyphensLigaturesAndQuotes() {
        let page = "The \u{201C}main\u{201D} switch shall be identi-\nfied and ofﬁcially la-\nbelled.\nNext."
        let location = PassageLocator.locate(
            sentences: ["The \"main\" switch shall be identified and officially labelled."], onPageText: page)
        guard case .located(let ranges, let dropped) = location else { return XCTFail("\(location)") }
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(ranges, [NSRange(location: 0, length: NSMaxRange((page as NSString).range(of: "belled.")))])
    }

    func testASentenceNotWholeOnThePageIsDroppedNotStretched() {
        let page = "Cables shall be protected. RUNNING HEADER 2018 Where buried, cables shall be marked."
        // The second sentence is interrupted by a running header in the text layer: dropped.
        let location = PassageLocator.locate(
            sentences: ["Cables shall be protected.", "Where buried, the cables shall be marked with tape."],
            onPageText: page)
        guard case .located(let ranges, let dropped) = location else { return XCTFail("\(location)") }
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(ranges, [(page as NSString).range(of: "Cables shall be protected.")])
        XCTAssertEqual(PassageLocator.locate(sentences: ["Nothing here matches."], onPageText: page),
                       .notLocatable(.notFound))
    }

    func testAShortSentenceIsMarkedOnlyWhenItCannotBeConfused() {
        let page = "Note. Cables shall be protected against damage. Note. Something else."
        guard case .located(let ranges, _) = PassageLocator.locate(
            sentences: ["Cables shall be protected against damage.", "Note."], onPageText: page) else {
            return XCTFail()
        }
        // "Note." twice on the page; only the one right after the sentence before it is taken.
        let ns = page as NSString
        let expectedEnd = ns.range(of: "Note. Something").location + 5
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(NSMaxRange(ranges[0]), expectedEnd)
        XCTAssertEqual(PassageLocator.locate(sentences: ["Note."], onPageText: page), .notLocatable(.notFound),
                       "a short sentence found twice with nothing to anchor it is not marked")
    }

    func testTheHintPicksTheNearerCopyOfARepeatedSentence() {
        let sentence = "Isolate the supply before work begins on any circuit."
        let page = sentence + " Some other text in between here. " + sentence
        let second = (page as NSString).range(of: sentence, options: .backwards)
        let location = PassageLocator.locate(sentences: [sentence], onPageText: page, hint: second.location)
        XCTAssertEqual(location.ranges, [second])
    }

    func testNoTextLayerIsNamed() {
        XCTAssertEqual(PassageLocator.locate(sentences: ["Anything."], onPageText: nil), .notLocatable(.noTextLayer))
        XCTAssertEqual(PassageLocator.locate(sentences: ["Anything."], onPageText: " \n "), .notLocatable(.noTextLayer))
    }

    // MARK: - Fixture PDFs (exit tests)

    func testTwoColumnStandardPageGivesExactRanges() throws {
        let url = try fixture(PassageFixtures.twoColumnStandard(), named: "standard.pdf")
        let text = try XCTUnwrap(try pageText(url, page: 1))
        for sentence in [PassageFixtures.depthSentence, PassageFixtures.earthingSentence] {
            let expected = try XCTUnwrap(PassageFixtures.expectedRange(of: sentence, in: text), sentence)
            XCTAssertEqual(PassageLocator.locate(sentences: [sentence], onPageText: text),
                           .located(ranges: [expected], dropped: 0), sentence)
        }
        // Two adjacent sentences are one mark, from the first's start to the second's end.
        let depth = try XCTUnwrap(PassageFixtures.expectedRange(of: PassageFixtures.depthSentence, in: text))
        let protection = try XCTUnwrap(PassageFixtures.expectedRange(of: PassageFixtures.protectionSentence, in: text))
        XCTAssertEqual(PassageLocator.locate(sentences: [PassageFixtures.depthSentence, PassageFixtures.protectionSentence],
                                             onPageText: text).ranges,
                       [NSRange(location: depth.location, length: NSMaxRange(protection) - depth.location)])
    }

    func testTheWholePipelineMarksTheChunkThatCitesTheClause() throws {
        let url = try fixture(PassageFixtures.twoColumnStandard(), named: "standard.pdf")
        let extracted = try VaultDocumentExtractor.extract(from: url)
        let chunks = DocumentChunker().chunk(extracted.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let chunk = try XCTUnwrap(chunks.first { $0.text.contains("500 mm") })
        let anchor = PassageAnchor(documentId: "d", chunkIndex: chunk.index, text: chunk.text, page: chunk.page,
                                   pageStart: chunk.pageStart, pageEnd: chunk.pageEnd,
                                   sentenceStarts: chunk.sentenceStarts)
        let text = try XCTUnwrap(try pageText(url, page: 1))
        let location = PassageLocator.locate(anchor, onPageText: text)
        guard case .located(let ranges, _) = location else { return XCTFail("\(location)") }
        let depth = try XCTUnwrap(PassageFixtures.expectedRange(of: PassageFixtures.depthSentence, in: text))
        XCTAssertTrue(ranges.contains { $0.location <= depth.location && NSMaxRange($0) >= NSMaxRange(depth) },
                      "the requirement the chunk carries is inside a mark")
    }

    func testHyphenatedPageGivesExactRanges() throws {
        let url = try fixture(PassageFixtures.hyphenatedPage(), named: "hyphenated.pdf")
        let text = try XCTUnwrap(try pageText(url, page: 1))
        let expected = try XCTUnwrap(PassageFixtures.expectedRange(of: PassageFixtures.hyphenatedSentence, in: text))
        XCTAssertEqual(PassageLocator.locate(sentences: [PassageFixtures.hyphenatedSentence], onPageText: text),
                       .located(ranges: [expected], dropped: 0))
        // And through the extractor and chunker, the chunk's own sentences find the same words.
        let extracted = try VaultDocumentExtractor.extract(from: url)
        let chunk = try XCTUnwrap(DocumentChunker().chunk(extracted.text).first { $0.text.contains("500 mm") })
        let anchor = PassageAnchor(documentId: "d", chunkIndex: 0, text: chunk.text, page: 1,
                                   sentenceStarts: chunk.sentenceStarts)
        XCTAssertTrue(PassageLocator.locate(anchor, onPageText: text).ranges.contains {
            $0.location <= expected.location && NSMaxRange($0) >= NSMaxRange(expected)
        })
    }

    func testAScannedPageWithNoTextLayerIsNotLocatable() throws {
        let url = try fixture(PassageFixtures.textThenScannedPage(), named: "scanned.pdf")
        let scanned = try pageText(url, page: 2)
        XCTAssertEqual(PassageLocator.locate(sentences: [PassageFixtures.depthSentence], onPageText: scanned),
                       .notLocatable(.noTextLayer))
        // The text page of the same file still marks.
        let text = try XCTUnwrap(try pageText(url, page: 1))
        XCTAssertFalse(PassageLocator.locate(sentences: [PassageFixtures.depthSentence], onPageText: text).ranges.isEmpty)
    }

    // MARK: - Printed and physical pages (decision 4)

    func testRomanNumeralFrontMatterMapsPrintedToPhysicalPages() throws {
        let url = try fixture(PassageFixtures.romanFrontMatter(), named: "front-matter.pdf")
        let extracted = try VaultDocumentExtractor.extract(from: url)
        XCTAssertEqual(extracted.pageLabels.map(\.label), PassageFixtures.frontMatterFooters)
        XCTAssertEqual(extracted.pageLabels.map(\.page), Array(1...6))
        let map = PageLabelMap(extracted.pageLabels)
        XCTAssertEqual(map.physical(forPrinted: "2"), 5, "printed page 2 is the fifth page of the PDF")
        XCTAssertEqual(map.physical(forPrinted: "ii"), 2)
        XCTAssertEqual(map.physical(forPrinted: "II"), 2)
        XCTAssertEqual(map.printed(forPhysical: 4), "1")
        XCTAssertNil(map.physical(forPrinted: "9"))
    }

    func testThePrintedNumberIsReadOnlyFromALineThatIsJustANumber() {
        XCTAssertEqual(PrintedPageBand.label(in: "112"), "112")
        XCTAssertEqual(PrintedPageBand.label(in: "- 112 -"), "112")
        XCTAssertEqual(PrintedPageBand.label(in: "Page 112"), "112")
        XCTAssertEqual(PrintedPageBand.label(in: "xiv"), "xiv")
        XCTAssertEqual(PrintedPageBand.label(in: "AS/NZS 3000:2018\n112"), "112")
        XCTAssertNil(PrintedPageBand.label(in: "Clause 3.9.4 Underground wiring"))
        XCTAssertNil(PrintedPageBand.label(in: "112\n113"), "two candidates: neither is trusted")
        XCTAssertNil(PrintedPageBand.label(in: ""))
        XCTAssertNil(PageLabelMap([PageLabel(page: 1, label: "3", source: .printed),
                                   PageLabel(page: 9, label: "3", source: .printed)]).physical(forPrinted: "3"),
                     "a label two pages carry opens neither")
    }

    // MARK: - A folio that shares its footer line (Plan JW P0)

    private typealias L = TableFixtureLayouts

    /// Physical page → label, as the store keeps them.
    private func labels(_ bands: [String], pdf: [Int: String] = [:]) -> [Int: String] {
        Dictionary(PrintedPageBand.labels(bands: bands, pdfLabels: pdf).map { ($0.page, $0.label) },
                   uniquingKeysWith: { first, _ in first })
    }

    func testAFolioAtTheEndOfTheFooterLineIsReadWhenItRunsInStep() {
        // A cover and a blank page, then six pages whose footer ends with the folio: physical + 20.
        let bands = ["", ""] + (3...8).map { "Example Running Head\n" + L.footerWithFolio($0 + 20) }
        XCTAssertEqual(labels(bands), [3: "23", 4: "24", 5: "25", 6: "26", 7: "27", 8: "28"])
        XCTAssertTrue(PrintedPageBand.labels(bands: bands).allSatisfy { $0.source == .printed })
        XCTAssertEqual(PrintedPageBand.lineEndNumbers(in: L.footerWithFolio(41)), [41], "the years inside the line are not candidates")
    }

    func testAYearInTheFooterIsNeverReadAsAPage() {
        let bands = (1...8).map { _ in "March 2031 \u{00A9} 2031 Example Standards Body\n2031 Edition" }
        XCTAssertTrue(labels(bands).isEmpty, "the same number on every page changes its offset with every page")
        // A year at the line's end beside a folio at the other end: only the folio runs in step.
        let mixed = (1...6).map { "\($0 + 4) Example Standards Body 2031" }
        XCTAssertEqual(labels(mixed), [1: "5", 2: "6", 3: "7", 4: "8", 5: "9", 6: "10"])
    }

    func testAFolioOnAlternatingSidesIsRead() {
        let bands = (1...6).map { $0 % 2 == 0 ? "\($0 + 10) Example Standards Body" : "Example Standards Body \($0 + 10)" }
        XCTAssertEqual(labels(bands), [1: "11", 2: "12", 3: "13", 4: "14", 5: "15", 6: "16"])
    }

    func testTooShortARunIsNotTrusted() {
        XCTAssertTrue(labels([L.footerWithFolio(7)]).isEmpty, "one page proves nothing")
        XCTAssertTrue(labels([L.footerWithFolio(7), L.footerWithFolio(8)]).isEmpty,
                      "two pages are fewer than the run the rule asks for")
        // Numbers that do not keep step with the page.
        let scattered = [3, 9, 4, 15, 2, 30].map { "Example Standards Body \($0)" }
        XCTAssertTrue(labels(scattered).isEmpty)
    }

    func testALoneNumberLineAndThePublishersLabelStillWin() {
        var bands = (1...6).map { L.footerWithFolio($0 + 20) }
        bands[2] = "Example Running Head\n7"          // a lone number prints a different page
        let read = labels(bands, pdf: [6: "A-6"])
        XCTAssertEqual(read[3], "7", "a line that is just a number wins as before")
        XCTAssertEqual(read[6], "A-6", "the publisher's label wins")
        XCTAssertEqual(read[1], "21")
        XCTAssertEqual(read[5], "25", "its neighbour across the lone-number page still agrees")
    }

    func testFrontMatterBlankPagesAndTheBodyAreEachReadTheirOwnWay() {
        // Roman front matter on lone lines, then the body numbered from 1 at the end of the
        // footer line, a full-page drawing with no footer in the middle.
        var bands = ["i", "ii", "iii"] + (1...7).map { L.footerWithFolio($0) }
        bands[6] = ""
        let read = labels(bands)
        XCTAssertEqual(read[1], "i")
        XCTAssertEqual(read[3], "iii")
        XCTAssertEqual(read[4], "1")
        XCTAssertNil(read[7], "a page with no footer gets no label")
        XCTAssertEqual(read[8], "5", "a neighbour two pages away keeps the run going")
        XCTAssertEqual(read[10], "7")
        XCTAssertEqual(read.count, 9)
        XCTAssertEqual(PageLabelMap(PrintedPageBand.labels(bands: bands)).physical(forPrinted: "5"), 8)
    }

    func testTheImportReadsAFolioAtTheEndOfARealFooterLine() throws {
        let pages = [TableFixtures.prosePage()] + (1...4).map { L.folioPage($0 + 98) }
        let url = try TableFixtures.write(TableFixtures.pdf(pages), named: "folio.pdf", in: tempRoot)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let read = VaultDocumentExtractor.pageLabels(of: document)
        XCTAssertEqual(read.map(\.page), [2, 3, 4, 5])
        XCTAssertEqual(read.map(\.label), ["99", "100", "101", "102"])
        XCTAssertNil(VaultDocumentExtractor.printedLabel(on: try XCTUnwrap(document.page(at: 1))),
                     "the page alone does not prove its folio: the run does")
    }

    // MARK: - The store

    private func makeStore() -> (DocumentStore, URL) {
        let dir = tempRoot.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DocumentStore(directory: dir), dir)
    }

    func testTheStoreKeepsEachChunksPlaceAndThePageLabels() async throws {
        let (store, _) = makeStore()
        let url = try fixture(PassageFixtures.romanFrontMatter(), named: "front.pdf")
        let extracted = try VaultDocumentExtractor.extract(from: url)
        let ref = try await XCTUnwrapAsync(await store.ingest(name: "Fixture Code", text: extracted.text,
                                                              namespace: "vault:x", pageLabels: extracted.pageLabels))
        let anchor = try XCTUnwrap(store.anchor(documentId: ref.id, chunkIndex: 0))
        XCTAssertFalse(anchor.sentenceStarts.isEmpty)
        XCTAssertNotNil(anchor.pageStart)
        XCTAssertFalse(store.needsLocation(documentId: ref.id))
        XCTAssertEqual(store.pageLabels(documentId: ref.id).physical(forPrinted: "1"), 4)

        try store.forget(documentId: ref.id, inNamespace: "vault:x")
        XCTAssertTrue(store.pageLabels(documentId: ref.id).isEmpty, "a forgotten document leaves no labels behind")
    }

    // MARK: - Migrating a store indexed before Plan KE P2

    /// A phone's index at location version 9: rows, vectors and places, and no page breaks.
    private func makeVersionNine(_ directory: URL) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("documents.sqlite").path, &db), SQLITE_OK)
        sqlite3_exec(db, "UPDATE doc_chunks SET page_breaks = NULL, location_version = 9", nil, nil, nil)
        sqlite3_close(db)
    }

    func testVersionNineGainsItsPageBreaksWithoutAReimport() async throws {
        let (store, dir) = makeStore()
        let text = "Service Tests\nOpen the service panel first.\u{0C}Then isolate the supply at the board."
        let url = tempRoot.appendingPathComponent("notes.txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let ref = try await XCTUnwrapAsync(await store.ingest(name: "Acme Notes", text: text, sourceType: "vault_document",
                                                              namespace: "vault:x"))
        XCTAssertFalse(try XCTUnwrap(store.anchor(documentId: ref.id, chunkIndex: 0)).pageBreaks.isEmpty, "an import has them")

        makeVersionNine(dir)
        XCTAssertTrue(try XCTUnwrap(store.anchor(documentId: ref.id, chunkIndex: 0)).pageBreaks.isEmpty, "the old row reads as one page")
        XCTAssertTrue(store.needsLocation(documentId: ref.id))
        XCTAssertLessThan(try XCTUnwrap(store.textLocationVersion(documentId: ref.id)), DocumentStore.textReadVersion,
                          "breaks need the text read again, not only the tables")
        let before = rows(dir)

        let entry = VaultDocumentLedger.Entry(file: "notes.txt", title: ref.name, documentId: ref.id,
                                              contentHash: "h", chunkCount: ref.chunkCount)
        let outcome = await PassageLocationMigration.migrate(entry: entry, fileURL: url, store: store)

        XCTAssertEqual(outcome, .located, "the text chunks as stored, so nothing is re-embedded")
        let after = rows(dir)
        XCTAssertEqual(after.map(\.text), before.map(\.text))
        XCTAssertEqual(after.map(\.embedding), before.map(\.embedding))
        let anchor = try XCTUnwrap(store.anchor(documentId: ref.id, chunkIndex: 0))
        XCTAssertEqual(anchor.pageBreaks.map(\.page), [1, 2])
        XCTAssertFalse(store.needsLocation(documentId: ref.id))
        let found = try XCTUnwrap(store.query("isolate the supply", namespace: "vault:x").first)
        XCTAssertEqual(found.pageBreaks, anchor.pageBreaks, "retrieval reads them too")
    }

    func testAPassageCarriesWhatIsPrintedOnItsPages() async throws {
        let (store, _) = makeStore()
        let text = "Open the service panel first.\u{0C}Then isolate the supply at the board."
        let ref = try await XCTUnwrapAsync(await store.ingest(name: "Acme Notes", text: text, namespace: "vault:x",
                                                              pageLabels: [PageLabel(page: 2, label: "3-4", source: .printed)]))
        let passages = store.passages(containingToken: "isolate", documentIds: [ref.id])
        let labelled = try XCTUnwrap(store.withPrintedLabels(passages).first)
        XCTAssertEqual(labelled.printedLabels, [2: "3-4"])
        XCTAssertEqual(labelled.text, text.replacingOccurrences(of: "first.\u{0C}", with: "first. "), "the stored words are as they were")
    }

    // MARK: - Migrating a store indexed before P0

    /// Clear the location columns, as a row stored before they existed reads.
    private func makeLegacy(_ directory: URL) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("documents.sqlite").path, &db), SQLITE_OK)
        sqlite3_exec(db, "UPDATE doc_chunks SET page_start = NULL, page_end = NULL, sentences = NULL, location_version = NULL", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM doc_page_labels", nil, nil, nil)
        sqlite3_close(db)
    }

    private func rows(_ directory: URL) -> [(index: Int, text: String, embedding: Data?, page: Int?)] {
        var db: OpaquePointer?
        sqlite3_open(directory.appendingPathComponent("documents.sqlite").path, &db)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT chunk_index, text, embedding, page FROM doc_chunks ORDER BY chunk_index", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var out: [(Int, String, Data?, Int?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let blob = sqlite3_column_blob(stmt, 2).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(stmt, 2))) }
            let page = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 3))
            out.append((Int(sqlite3_column_int(stmt, 0)), String(cString: sqlite3_column_text(stmt, 1)), blob, page))
        }
        return out
    }

    func testMigrationLocatesAnOldStoreWithoutTouchingWhatEvidenceIsKeyedOn() async throws {
        let (store, dir) = makeStore()
        let url = try fixture(PassageFixtures.twoColumnStandard(), named: "standard.pdf")
        let extracted = try VaultDocumentExtractor.extract(from: url)
        let ref = try await XCTUnwrapAsync(await store.ingest(name: "Fixture Code", text: extracted.text,
                                                              sourceType: "vault_document", namespace: "vault:x"))
        makeLegacy(dir)
        XCTAssertTrue(store.needsLocation(documentId: ref.id))
        let before = rows(dir)
        let evidenceBefore = before.compactMap { $0.page.map { PageEvidencePolicy.label(title: ref.name, page: $0) } }

        let entry = VaultDocumentLedger.Entry(file: "standard.pdf", title: ref.name, documentId: ref.id,
                                              contentHash: "h", chunkCount: ref.chunkCount)
        let outcome = await PassageLocationMigration.migrate(entry: entry, fileURL: url, store: store)
        XCTAssertEqual(outcome, .located)

        let after = rows(dir)
        XCTAssertEqual(after.map(\.index), before.map(\.index))
        XCTAssertEqual(after.map(\.text), before.map(\.text))
        XCTAssertEqual(after.map(\.embedding), before.map(\.embedding), "no chunk was re-embedded")
        XCTAssertEqual(after.compactMap { $0.page.map { PageEvidencePolicy.label(title: ref.name, page: $0) } },
                       evidenceBefore, "every page label evidence is keyed on still names the same page")
        XCTAssertEqual(store.documents.first { $0.id == ref.id }?.chunkCount, ref.chunkCount)
        XCTAssertFalse(store.needsLocation(documentId: ref.id))
        XCTAssertFalse(try XCTUnwrap(store.anchor(documentId: ref.id, chunkIndex: 0)).sentenceStarts.isEmpty)
        // A second launch has nothing to do.
        let again = await PassageLocationMigration.migrate(entry: entry, fileURL: url, store: store)
        XCTAssertEqual(again, .current)
    }

    func testMigrationRechunksUnderTheSameIdWhenTheTextNoLongerChunksTheSame() async throws {
        let (store, dir) = makeStore()
        let url = try fixture(PassageFixtures.twoColumnStandard(), named: "standard.pdf")
        let ref = try await XCTUnwrapAsync(await store.ingest(name: "Fixture Code", text: "An older extraction of this code book. It chunked differently.",
                                                              sourceType: "vault_document", namespace: "vault:x"))
        makeLegacy(dir)
        let entry = VaultDocumentLedger.Entry(file: "standard.pdf", title: ref.name, documentId: ref.id,
                                              contentHash: "h", chunkCount: ref.chunkCount)
        let outcome = await PassageLocationMigration.migrate(entry: entry, fileURL: url, store: store)
        XCTAssertEqual(outcome, .rechunked)
        XCTAssertNotNil(store.documents.first { $0.id == ref.id }, "the document keeps its id")
        XCTAssertTrue(rows(dir).contains { $0.text.contains("500 mm") })
        XCTAssertFalse(store.needsLocation(documentId: ref.id))
    }

    func testMigrationLeavesARecognisedManualAlone() async throws {
        let (store, dir) = makeStore()
        let ref = try await XCTUnwrapAsync(await store.ingest(name: "Scan", text: "Recognised text of a scan.",
                                                              namespace: "vault:x"))
        makeLegacy(dir)
        let entry = VaultDocumentLedger.Entry(file: "scan.pdf", title: "Scan", documentId: ref.id,
                                              contentHash: "h", chunkCount: 1, ocrPages: 3)
        let outcome = await PassageLocationMigration.migrate(entry: entry,
                                                             fileURL: tempRoot.appendingPathComponent("scan.pdf"),
                                                             store: store)
        XCTAssertEqual(outcome, .recognisedSkipped)
        // Its rows still locate: the sentences are split from the text itself.
        let anchor = try XCTUnwrap(store.anchor(documentId: ref.id, chunkIndex: 0))
        XCTAssertTrue(anchor.sentenceStarts.isEmpty)
        XCTAssertEqual(PassageLocator.locate(anchor, onPageText: "Header. Recognised text of a scan. Footer.").ranges.count, 1)
    }

    // MARK: - The real manual, when it is on this Mac

    /// Service Manual page 34, "2. Flame Sensor" — a real passage, on a real page. The manuals are
    /// licensed and never in the repo, so this runs only when the run names one:
    /// `TEST_RUNNER_SERVICE_MANUAL_PDF=/path/to/SLP99UHVK-service-manual.pdf xcodebuild test …`.
    func testTheFlameSensorPassageIsMarkedOnTheRealServiceManual() throws {
        guard let path = ProcessInfo.processInfo.environment["SERVICE_MANUAL_PDF"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("No licensed service manual named for this run.")
        }
        let url = URL(fileURLWithPath: path)
        let extracted = try VaultDocumentExtractor.extract(from: url)
        let chunks = DocumentChunker().chunk(extracted.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let onPage = chunks.filter { $0.page == 34 }
        XCTAssertFalse(onPage.isEmpty)
        let text = try XCTUnwrap(PDFDocument(url: url)?.page(at: 33)?.string)
        let flame = try XCTUnwrap(onPage.first { $0.text.localizedCaseInsensitiveContains("flame sensor") })
        let anchor = PassageAnchor(documentId: "d", chunkIndex: flame.index, text: flame.text, page: 34,
                                   pageStart: flame.pageStart, pageEnd: flame.pageEnd,
                                   sentenceStarts: flame.sentenceStarts)
        guard case .located(let ranges, let dropped) = PassageLocator.locate(anchor, onPageText: text) else {
            return XCTFail("the flame sensor passage was not found on page 34")
        }
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertLessThan(dropped, anchor.sentences.count, "most of the passage is marked")
    }
}

/// `XCTUnwrap` for an async expression.
private func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?, file: StaticString = #filePath,
                       line: UInt = #line) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
